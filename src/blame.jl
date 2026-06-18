# blame.jl — Survivor-coverage blame: name the test file(s) covering each
# surviving mutant. Opt-in pass after a normal campaign. Reuses coverage.jl
# internals; never modifies baseline_run / whole-suite coverage.
#
# Soundness: an `include("test_X.jl")` in runtests.jl runs in Main's top-level
# scope, so a subfile can only depend on top-level definitions (the prelude),
# never on @testset-local bindings. A prelude = (top-level statements minus
# testfile-includes minus @testset blocks) is therefore sufficient for any
# subfile that runs correctly in the real suite. Detection failure -> the unit
# is reported failed and its survivors fall back to "unattributed".
#
# Known limitations:
# - a bare @test at top level in runtests.jl (outside any @testset) is treated as
#   prelude and runs in every unit driver, which can widen blame (over-attribution);
#   it never causes false blame of an uncovered line.
# - top-level defs interleaved between testsets are emitted in the prelude before
#   all inline testsets, not at their original position — harmless because top-level
#   defs resolve by name at call time.

using JuliaSyntax

"""
    TestUnit

One independently-runnable test unit. `label` is the included filename
(e.g. "test_x.jl") or "<inline>" for runtests' own top-level @testset blocks.
`driver` is complete Julia source: the shared prelude followed by this unit's
tests, written into the shadow test/ dir and run under --code-coverage.
"""
struct TestUnit
    label::String
    driver::String
end

_is_testset(node)::Bool = begin
    JuliaSyntax.kind(node) == JuliaSyntax.K"macrocall" || return false
    cs = JuliaSyntax.children(node)
    isempty(cs) && return false
    return JuliaSyntax.sourcetext(cs[1]) == "testset"
end

"""Return the included path string for an `include("...")` call, else nothing."""
function _include_target(node)::Union{String, Nothing}
    JuliaSyntax.kind(node) == JuliaSyntax.K"call" || return nothing
    cs = JuliaSyntax.children(node)
    length(cs) >= 2 || return nothing
    JuliaSyntax.sourcetext(cs[1]) == "include" || return nothing
    for c in cs[2:end]
        if JuliaSyntax.kind(c) == JuliaSyntax.K"string"
            return String(strip(JuliaSyntax.sourcetext(c), ['"']))
        end
    end
    return nothing
end

"""True if `name` looks like a test file AND exists in `test_dir`."""
_is_test_unit(name::AbstractString, test_dir::AbstractString)::Bool =
    (startswith(name, "test_") || endswith(name, "_test.jl")) &&
    isfile(joinpath(test_dir, name))

"""
    _is_retestitems_layout(tree, src) -> Bool

Return true when the top-level statements of a parsed runtests.jl reference
ReTestItems or TestItemRunner via identifiers/macros that signal the
"no include()" auto-discovery layout.  Detection is purely AST-text based
(JuliaSyntax sourcetext over located nodes — no regex over raw source).
Signals: any top-level node whose sourcetext contains one of the known tokens.
"""
function _is_retestitems_layout(tree, src::AbstractString)::Bool
    signals = ("ReTestItems", "TestItemRunner", "@run_package_tests")
    for node in JuliaSyntax.children(tree)
        txt = JuliaSyntax.sourcetext(node)
        for sig in signals
            occursin(sig, txt) && return true
        end
        # Also check for a bare `runtests(` call at top level (not inside include)
        if JuliaSyntax.kind(node) == JuliaSyntax.K"call"
            cs = JuliaSyntax.children(node)
            if !isempty(cs) && JuliaSyntax.sourcetext(cs[1]) == "runtests"
                return true
            end
        end
    end
    return false
end

"""
    _find_retestitems_units(test_dir, pkg_src_dir) -> Vector{TestUnit}

Enumerate `*_test.jl` and `*_tests.jl` files under `test_dir` and optionally
`pkg_src_dir` (src-collocated test items). Each file becomes a `TestUnit` whose
driver invokes `using ReTestItems; runtests("<abs path>")`.
Units are sorted by label for determinism.
"""
function _find_retestitems_units(test_dir::AbstractString,
                                 pkg_src_dir::Union{AbstractString,Nothing})::Vector{TestUnit}
    search_dirs = AbstractString[test_dir]
    pkg_src_dir !== nothing && isdir(pkg_src_dir) && push!(search_dirs, pkg_src_dir)

    units = TestUnit[]
    seen  = Set{String}()  # guard against duplicates if dirs overlap
    for search_dir in search_dirs
        isdir(search_dir) || continue
        for (dp, _, fns) in walkdir(search_dir)
            for fn in fns
                (endswith(fn, "_test.jl") || endswith(fn, "_tests.jl")) || continue
                abs_path = joinpath(dp, fn)
                abs_path in seen && continue
                push!(seen, abs_path)
                # label = basename (consistent with classic include-unit labels)
                label = fn
                driver = "using ReTestItems\nruntests(\"$abs_path\")\n"
                push!(units, TestUnit(label, driver))
            end
        end
    end
    sort!(units, by = u -> u.label)
    return units
end

"""
    detect_units(runtests_path; test_dir=dirname(runtests_path),
                 pkg_src_dir=nothing) -> (prelude, units)

Parse `runtests_path` with JuliaSyntax. Classify each top-level statement:
include of a test file -> a unit; `@testset` -> inline tests; else -> prelude
(defs shared by every unit). Returns the prelude source and the unit list
(include-units sorted by label, then one "<inline>" unit if any @testset exists).

**ReTestItems/TestItemRunner layout** (no include() present and the file
references `ReTestItems`, `TestItemRunner`, or `@run_package_tests`): instead,
enumerate `*_test.jl` / `*_tests.jl` files under `test_dir` (and `pkg_src_dir`
if provided). Each becomes a `TestUnit` whose driver calls
`using ReTestItems; runtests("<abs path>")`. If no such files exist, a `@warn`
is emitted and an empty unit list is returned (blame will mark everything
unattributed rather than crashing).
"""
function detect_units(runtests_path::AbstractString;
                      test_dir::AbstractString = dirname(runtests_path),
                      pkg_src_dir::Union{AbstractString,Nothing} = nothing)
    isfile(runtests_path) || throw(MutationError("detect_units: not a file: $runtests_path"))
    src = read(runtests_path, String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, src; filename=runtests_path)

    defs = String[]
    inlines = String[]
    include_units = Tuple{String, String}[]   # (label, statement source)

    for node in JuliaSyntax.children(tree)
        txt = JuliaSyntax.sourcetext(node)
        inc = _include_target(node)
        if inc !== nothing && _is_test_unit(inc, test_dir)
            push!(include_units, (inc, txt))
        elseif _is_testset(node)
            push!(inlines, txt)
        else
            push!(defs, txt)
        end
    end

    # If the normal paths found nothing AND the file looks like a ReTestItems layout,
    # fall back to enumerating *_test.jl / *_tests.jl files.
    if isempty(include_units) && isempty(inlines) && _is_retestitems_layout(tree, src)
        units = _find_retestitems_units(test_dir, pkg_src_dir)
        if isempty(units)
            @warn "detect_units: ReTestItems/TestItemRunner layout detected in " *
                  "$runtests_path but no *_test.jl / *_tests.jl files found under " *
                  "$(test_dir)$(pkg_src_dir === nothing ? "" : " or $pkg_src_dir"). " *
                  "Per-file blame is unsupported for this layout — all survivors " *
                  "will be unattributed."
        end
        return "", units
    end

    sort!(include_units, by = first)
    prelude = join(defs, "\n\n")

    units = TestUnit[]
    for (label, stmt) in include_units
        push!(units, TestUnit(label, prelude * "\n\n" * stmt * "\n"))
    end
    if !isempty(inlines)
        push!(units, TestUnit("<inline>", prelude * "\n\n" * join(inlines, "\n\n") * "\n"))
    end
    return prelude, units
end

"""Recursively delete every `.cov` file under `dir` (cov counts accumulate)."""
function _rm_cov_files(dir::AbstractString)
    for (dp, _, fns) in walkdir(dir), fn in fns
        endswith(fn, ".cov") && rm(joinpath(dp, fn); force=true)
    end
end

"""
    per_unit_coverage(pkgdir; test_dir="test", test_file="runtests.jl",
                      timeout=600.0) -> (Dict{String,CoverageMap}, Vector{String})

Run each detected test unit in isolation under `--code-coverage=user` in one
reused shadow copy, returning per-unit coverage maps (keyed by unit label,
remapped to real relpaths) plus the sorted labels of units that errored/timed
out. The real package tree is never written (shadow only). `.cov` files are
cleared between units so maps are per-unit, not cumulative.
"""
function per_unit_coverage(pkgdir::AbstractString;
                           test_dir::AbstractString = "test",
                           test_file::AbstractString = "runtests.jl",
                           timeout::Float64 = 600.0)
    pkgdir = abspath(pkgdir)
    runtests_path = joinpath(pkgdir, test_dir, test_file)
    isfile(runtests_path) || throw(MutationError(
        "per_unit_coverage: test file not found: $runtests_path"))

    _, units = detect_units(runtests_path; test_dir=joinpath(pkgdir, test_dir))

    maps = Dict{String, CoverageMap}()
    failed = String[]
    shadow = _make_shadow(pkgdir)

    # Augment shadow with test-only deps so `--project=<shadow>` can load them.
    # No-op (returns false) when the package has no non-stdlib test deps.
    _augment_shadow_with_test_deps(pkgdir, shadow)

    try
        shadow_testdir = joinpath(shadow, test_dir)
        driver_path = joinpath(shadow_testdir, "__gremlins_blame_driver.jl")
        jl = _julia_exe()
        for u in units
            _rm_cov_files(shadow)
            write(driver_path, u.driver)
            cmd = Cmd([jl, "--project=$shadow", "--code-coverage=user", driver_path])
            exit_code, _ = _run_with_timeout(cmd, timeout)
            rm(driver_path; force=true)
            # Remove any .cov files the driver emitted so _collect_coverage
            # never returns a phantom "test/__gremlins_blame_driver.jl" key.
            for fn in readdir(shadow_testdir)
                if startswith(fn, "__gremlins_blame_driver.jl") && endswith(fn, ".cov")
                    rm(joinpath(shadow_testdir, fn); force=true)
                end
            end
            if exit_code != 0
                push!(failed, u.label)
                continue
            end
            shadow_cmap = _collect_coverage(shadow)
            maps[u.label] = _remap_cmap_to_real(shadow_cmap, pkgdir, shadow)
        end
    finally
        rm(shadow; recursive=true, force=true)
    end
    return maps, sort(failed)
end

"""
    BlameReport

`blamed`: unit label => survivors whose mutated line that unit covers (a
survivor may appear under several units). `unattributed`: covered whole-suite
but attributed to no single unit (e.g. every covering unit errored).
`failed_units`: units whose focused driver errored/timed out.
"""
struct BlameReport
    blamed::Dict{String, Vector{MutantResult}}
    unattributed::Vector{MutantResult}
    failed_units::Vector{String}
end

_blame_key(r::MutantResult) = (r.site.relpath, r.site.line, r.site.id)

"""Pure join: survivors × per-unit coverage -> BlameReport. No subprocesses."""
function _join_blame(survivors::Vector{MutantResult},
                     maps::Dict{String, CoverageMap},
                     failed::Vector{String})::BlameReport
    blamed = Dict{String, Vector{MutantResult}}()
    attributed = Set{String}()
    for label in sort(collect(keys(maps)))
        cmap = maps[label]
        hits = filter(s -> s.site.line in covered_lines(cmap, s.site.relpath), survivors)
        isempty(hits) && continue
        for h in hits
            push!(attributed, h.site.id)
        end
        blamed[label] = sort(hits, by=_blame_key)
    end
    unattributed = sort(filter(s -> !(s.site.id in attributed), survivors), by=_blame_key)
    return BlameReport(blamed, unattributed, sort(failed))
end

"""
    blame_survivors(result, pkgdir; test_dir="test", test_file="runtests.jl",
                    timeout=600.0) -> BlameReport

Opt-in pass: take the surviving mutants from `result`, acquire per-unit
coverage, and name the test units covering each survivor. N×(startup+load) cost
— not the default campaign.
"""
function blame_survivors(result::RunResult, pkgdir::AbstractString;
                         test_dir::AbstractString = "test",
                         test_file::AbstractString = "runtests.jl",
                         timeout::Float64 = 600.0)::BlameReport
    survivors = filter(r -> r.outcome == survived, result.results)
    maps, failed = per_unit_coverage(pkgdir; test_dir=test_dir,
                                     test_file=test_file, timeout=timeout)
    return _join_blame(survivors, maps, failed)
end

"""Print the human-readable blame section. Deterministic, sorted."""
function render_blame(io::IO, report::BlameReport)
    println(io, "━━━ Survivors by Responsible Test ━━━━━━━━━━━━━")
    if isempty(report.blamed)
        println(io, "  (no survivors attributed to any test file)")
    else
        for label in sort(collect(keys(report.blamed)))
            rs = report.blamed[label]
            println(io, "  $label  ($(length(rs)) survivor$(length(rs) == 1 ? "" : "s"))")
            for r in rs
                s = r.site
                println(io, "    - $(s.relpath):$(s.line)  $(s.op_name)  " *
                            "$(repr(s.original))→$(repr(s.replacement))  [$(s.id[1:8])]")
            end
        end
    end
    if !isempty(report.unattributed)
        println(io, "  Unattributed survivors ($(length(report.unattributed))):")
        for r in report.unattributed
            s = r.site
            println(io, "    - $(s.relpath):$(s.line)  $(s.op_name)  [$(s.id[1:8])]")
        end
    end
    if !isempty(report.failed_units)
        println(io, "  Units that errored under focused driver " *
                    "(their survivors fell back to unattributed):")
        for l in report.failed_units
            println(io, "    - $l")
        end
    end
    println(io, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
end
