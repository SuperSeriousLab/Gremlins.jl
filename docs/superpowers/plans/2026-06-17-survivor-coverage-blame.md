# Survivor-Coverage Blame Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For each surviving source mutant, name the test file(s) whose execution covers the mutated line — turning the flat survivor list into a per-test "your assertions ran this code and missed the change" to-do list.

**Architecture:** Additive, opt-in pass after a normal mutation campaign. A new `src/blame.jl` parses `runtests.jl` with JuliaSyntax to split it into a shared *prelude* (top-level defs) plus independently-runnable *units* (each `include("test_*.jl")`, plus one synthetic `<inline>` unit for runtests' own `@testset`s). It runs each unit under `--code-coverage=user` in a single reused shadow copy (cov files cleared between units), builds a per-unit `CoverageMap`, then joins survivors `(relpath,line)` against each unit's coverage. Whole-suite `coverage.jl`/`baseline_run` is left untouched; `blame.jl` only *reuses* coverage.jl's internal helpers.

**Tech Stack:** Julia ≥1.10, JuliaSyntax (already a dep), Test stdlib.

## Global Constraints

- Julia ≥ 1.10. **JuliaSyntax for ALL parsing — never regex over Julia source.** (Classifying a filename *string* or stripping quotes from an already-located string node is not "regex over source" and is allowed.)
- Throw typed `MutationError` in library paths; no bare `error("...")` strings.
- Deterministic, sorted output everywhere (units sorted by label; survivors sorted by `(relpath, line, id)`).
- **One-directional honesty (non-negotiable):** a unit whose focused driver errors/times out is recorded in `failed_units`; its would-be-blamed survivors fall through to `unattributed`. **Never falsely blame.**
- No mtime-based caching. No `eval` of mutated code into `Main`.
- Reuse coverage.jl internals (`_make_shadow`, `_julia_exe`, `_run_with_timeout`, `_collect_coverage`, `_remap_cmap_to_real`, `covered_lines`); do **not** modify `baseline_run` or any existing coverage.jl function.
- `.cov` files accumulate cumulatively in a directory and `_collect_coverage` unions all it finds — **delete every `.cov` under the shadow between units** or maps go cumulative.

---

## File Structure

- `src/blame.jl` (new) — everything: `TestUnit`, `detect_units` (+ `_is_testset`, `_include_target`, `_is_test_unit`), `per_unit_coverage` (+ `_rm_cov_files`), `BlameReport`, `_join_blame`, `blame_survivors`, `render_blame`.
- `src/Gremlins.jl` (modify) — `include("blame.jl")` after `report.jl`; export public names.
- `bin/gremlins-cli.jl` (modify) — add `--blame` flag, run the pass after `print_summary`.
- `test/test_blame.jl` (new) — unit tests for `detect_units` + `_join_blame` + `render_blame`.
- `test/blame_fixture_test.jl` (new) — §5 falsifiability: end-to-end against a fixture package.
- `test/fixtures/blame_pkg/` (new) — fixture package (src + test suite) exercising blamed / not-blamed / unattributed.
- `test/runtests.jl` (modify) — `include` the two new test files.
- `test/cli_test.jl` (modify) — assert `--blame` parses.

---

### Task 1: `detect_units` — JuliaSyntax split of runtests.jl into prelude + units

**Files:**
- Create: `src/blame.jl`
- Test: `test/test_blame.jl`

**Interfaces:**
- Consumes: `JuliaSyntax` (already `using`-ed in discover.jl; blame.jl adds its own `using JuliaSyntax`).
- Produces:
  - `struct TestUnit; label::String; driver::String; end`
  - `detect_units(runtests_path::AbstractString; test_dir::AbstractString=dirname(runtests_path)) -> Tuple{String, Vector{TestUnit}}` — returns `(prelude, units)`. Units are include-units (label = included filename, sorted by label) followed by at most one `TestUnit("<inline>", ...)` when runtests has top-level `@testset` blocks. Each `TestUnit.driver` is complete runnable Julia source.
  - helpers `_is_testset(node)::Bool`, `_include_target(node)::Union{String,Nothing}`, `_is_test_unit(name::AbstractString, test_dir::AbstractString)::Bool`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_blame.jl`:

```julia
using Test
using Gremlins
using Gremlins: detect_units, TestUnit, _is_test_unit

@testset "detect_units — split prelude / include-units / inline" begin
    mktempdir() do dir
        testdir = joinpath(dir, "test"); mkpath(testdir)
        write(joinpath(testdir, "test_alpha.jl"), "@testset \"a\" begin @test 1==1 end\n")
        write(joinpath(testdir, "beta_test.jl"), "@testset \"b\" begin @test 2==2 end\n")
        runtests = joinpath(testdir, "runtests.jl")
        write(runtests, """
        using Test
        using Gremlins

        helper() = 42

        @testset "inline" begin
            @test helper() == 42
        end

        include("test_alpha.jl")
        include("beta_test.jl")
        """)

        prelude, units = detect_units(runtests)

        # prelude holds defs, not the @testset or the includes
        @test occursin("helper() = 42", prelude)
        @test occursin("using Gremlins", prelude)
        @test !occursin("@testset", prelude)
        @test !occursin("include(", prelude)

        labels = [u.label for u in units]
        # include-units sorted by label, then the synthetic inline unit last
        @test labels == ["beta_test.jl", "test_alpha.jl", "<inline>"]

        # each include-unit driver = prelude + its own include only
        alpha = units[findfirst(u -> u.label == "test_alpha.jl", units)]
        @test occursin("helper() = 42", alpha.driver)
        @test occursin("include(\"test_alpha.jl\")", alpha.driver)
        @test !occursin("beta_test.jl", alpha.driver)
        @test !occursin("@testset \"inline\"", alpha.driver)

        # the inline unit driver = prelude + the inline @testset, no includes
        inline = units[findfirst(u -> u.label == "<inline>", units)]
        @test occursin("@testset \"inline\"", inline.driver)
        @test occursin("helper() = 42", inline.driver)
        @test !occursin("include(", inline.driver)
    end
end

@testset "_is_test_unit — filename gate" begin
    mktempdir() do dir
        write(joinpath(dir, "test_x.jl"), "")
        write(joinpath(dir, "y_test.jl"), "")
        write(joinpath(dir, "setup.jl"), "")
        @test _is_test_unit("test_x.jl", dir)
        @test _is_test_unit("y_test.jl", dir)
        @test !_is_test_unit("setup.jl", dir)        # not a test name -> stays prelude
        @test !_is_test_unit("test_missing.jl", dir)  # name ok but file absent
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()' 2>&1 | grep -i blame` (or run the file directly once wired in Task-final).
Expected: FAIL — `detect_units` / `TestUnit` not defined (UndefVarError).

- [ ] **Step 3: Write minimal implementation**

Create `src/blame.jl`:

```julia
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
    return JuliaSyntax.sourcetext(cs[1]) == "@testset"
end

"""Return the included path string for an `include("...")` call, else nothing."""
function _include_target(node)::Union{String, Nothing}
    JuliaSyntax.kind(node) == JuliaSyntax.K"call" || return nothing
    cs = JuliaSyntax.children(node)
    length(cs) >= 2 || return nothing
    JuliaSyntax.sourcetext(cs[1]) == "include" || return nothing
    for c in cs[2:end]
        if JuliaSyntax.kind(c) == JuliaSyntax.K"string"
            return strip(JuliaSyntax.sourcetext(c), ['"'])
        end
    end
    return nothing
end

"""True if `name` looks like a test file AND exists in `test_dir`."""
_is_test_unit(name::AbstractString, test_dir::AbstractString)::Bool =
    (startswith(name, "test_") || endswith(name, "_test.jl")) &&
    isfile(joinpath(test_dir, name))

"""
    detect_units(runtests_path; test_dir=dirname(runtests_path)) -> (prelude, units)

Parse `runtests_path` with JuliaSyntax. Classify each top-level statement:
include of a test file -> a unit; `@testset` -> inline tests; else -> prelude
(defs shared by every unit). Returns the prelude source and the unit list
(include-units sorted by label, then one "<inline>" unit if any @testset exists).
"""
function detect_units(runtests_path::AbstractString;
                      test_dir::AbstractString = dirname(runtests_path))
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
```

Wire it temporarily so the test can run: in `src/Gremlins.jl`, add `include("blame.jl")` immediately after the `include("report.jl")` line. (Full exports come in Task 5; the test uses `Gremlins.detect_units` etc. via `using Gremlins: ...`, which works for unexported names.)

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'include("test/test_blame.jl")'`
Expected: PASS — both `@testset`s green.

- [ ] **Step 5: Commit**

```bash
git add src/blame.jl src/Gremlins.jl test/test_blame.jl
git commit -m "feat(blame): detect_units — JuliaSyntax split of runtests into prelude+units"
```

---

### Task 2: `per_unit_coverage` — per-unit coverage in one reused shadow

**Files:**
- Modify: `src/blame.jl`
- Test: `test/test_blame.jl`

**Interfaces:**
- Consumes: `detect_units` (Task 1); coverage.jl internals `_make_shadow`, `_julia_exe`, `_run_with_timeout`, `_collect_coverage`, `_remap_cmap_to_real`; `CoverageMap`, `covered_lines`.
- Produces: `per_unit_coverage(pkgdir; test_dir="test", test_file="runtests.jl", timeout::Float64=600.0) -> Tuple{Dict{String,CoverageMap}, Vector{String}}` — `(label => CoverageMap, failed_labels)`. A unit whose driver exits non-zero/timeout is omitted from the dict and appended (sorted) to `failed_labels`. Also `_rm_cov_files(dir)`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_blame.jl`:

```julia
using Gremlins: per_unit_coverage, covered_lines

@testset "per_unit_coverage — line attributed to the covering unit only" begin
    mktempdir() do pkg
        mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "test"))
        write(joinpath(pkg, "Project.toml"),
              "name = \"BlameCov\"\nuuid = \"00000000-0000-0000-0000-0000000000c0\"\n")
        # src: line 2 is f's body, line 5 is g's body
        write(joinpath(pkg, "src", "BlameCov.jl"), """
        module BlameCov
        f(x) = x + 1
        export f
        g(x) = x - 1
        export g
        end
        """)
        write(joinpath(pkg, "test", "test_f.jl"), """
        @testset "f" begin
            @test BlameCov.f(1) == 2
        end
        """)
        write(joinpath(pkg, "test", "test_g.jl"), """
        @testset "g" begin
            @test BlameCov.g(1) == 0
        end
        """)
        write(joinpath(pkg, "test", "runtests.jl"), """
        using Test
        using BlameCov
        include("test_f.jl")
        include("test_g.jl")
        """)

        maps, failed = per_unit_coverage(pkg)
        @test isempty(failed)
        @test Set(keys(maps)) == Set(["test_f.jl", "test_g.jl"])
        # f's body line (2) covered only by test_f.jl; g's body line (4) only by test_g.jl
        @test 2 in covered_lines(maps["test_f.jl"], "src/BlameCov.jl")
        @test !(4 in covered_lines(maps["test_f.jl"], "src/BlameCov.jl"))
        @test 4 in covered_lines(maps["test_g.jl"], "src/BlameCov.jl")
        @test !(2 in covered_lines(maps["test_g.jl"], "src/BlameCov.jl"))
    end
end

@testset "per_unit_coverage — broken unit recorded as failed, never crashes" begin
    mktempdir() do pkg
        mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "test"))
        write(joinpath(pkg, "Project.toml"),
              "name = \"BlameBroke\"\nuuid = \"00000000-0000-0000-0000-0000000000c1\"\n")
        write(joinpath(pkg, "src", "BlameBroke.jl"),
              "module BlameBroke\nf(x) = x + 1\nexport f\nend\n")
        write(joinpath(pkg, "test", "test_ok.jl"),
              "@testset \"ok\" begin\n    @test BlameBroke.f(1) == 2\nend\n")
        write(joinpath(pkg, "test", "test_bad.jl"),
              "@testset \"bad\" begin\n    @test NONEXISTENT_SYMBOL == 1\nend\n")
        write(joinpath(pkg, "test", "runtests.jl"), """
        using Test
        using BlameBroke
        include("test_ok.jl")
        include("test_bad.jl")
        """)
        maps, failed = per_unit_coverage(pkg)
        @test "test_bad.jl" in failed
        @test haskey(maps, "test_ok.jl")
        @test !haskey(maps, "test_bad.jl")
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'include("test/test_blame.jl")'`
Expected: FAIL — `per_unit_coverage` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `src/blame.jl`:

```julia
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'include("test/test_blame.jl")'`
Expected: PASS — both new `@testset`s green (these spawn real julia subprocesses; allow a few seconds each).

- [ ] **Step 5: Commit**

```bash
git add src/blame.jl test/test_blame.jl
git commit -m "feat(blame): per_unit_coverage — isolated per-unit coverage in one shadow"
```

---

### Task 3: `BlameReport` + `_join_blame` + `blame_survivors` + `render_blame`

**Files:**
- Modify: `src/blame.jl`
- Test: `test/test_blame.jl`

**Interfaces:**
- Consumes: `MutantResult`, `MutationSite`, `RunResult`, `survived` (runner.jl); `CoverageMap`, `covered_lines` (coverage.jl); `per_unit_coverage` (Task 2).
- Produces:
  - `struct BlameReport; blamed::Dict{String,Vector{MutantResult}}; unattributed::Vector{MutantResult}; failed_units::Vector{String}; end`
  - `_join_blame(survivors::Vector{MutantResult}, maps::Dict{String,CoverageMap}, failed::Vector{String}) -> BlameReport` (pure; subprocess-free).
  - `blame_survivors(result::RunResult, pkgdir; test_dir="test", test_file="runtests.jl", timeout=600.0) -> BlameReport`.
  - `render_blame(io::IO, report::BlameReport)`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_blame.jl`:

```julia
using Gremlins: BlameReport, _join_blame, render_blame, CoverageMap,
                MutantResult, MutationSite, survived

# helper: build a synthetic survivor at (relpath, line)
function _surv(relpath, line, id)
    site = MutationSite(id, relpath, 1:1, :op, "op", "<", "<=", line)
    return MutantResult(site, survived, 0.0, "")
end

@testset "_join_blame — attribution, multi-blame, unattributed, failed" begin
    s1 = _surv("src/a.jl", 10, "1111111111111111")  # covered by t1 only
    s2 = _surv("src/a.jl", 20, "2222222222222222")  # covered by t1 and t2
    s3 = _surv("src/b.jl", 30, "3333333333333333")  # covered by nobody -> unattributed
    survivors = [s1, s2, s3]

    pkg = "/fake"
    maps = Dict(
        "t1.jl" => CoverageMap(Dict("src/a.jl" => Set([10, 20])), pkg),
        "t2.jl" => CoverageMap(Dict("src/a.jl" => Set([20])), pkg),
    )
    rep = _join_blame(survivors, maps, ["t_broken.jl"])

    @test Set(keys(rep.blamed)) == Set(["t1.jl", "t2.jl"])
    @test [r.site.id for r in rep.blamed["t1.jl"]] == [s1.site.id, s2.site.id]  # sorted by (relpath,line)
    @test [r.site.id for r in rep.blamed["t2.jl"]] == [s2.site.id]
    @test [r.site.id for r in rep.unattributed] == [s3.site.id]
    @test rep.failed_units == ["t_broken.jl"]
end

@testset "render_blame — deterministic section text" begin
    s1 = _surv("src/a.jl", 10, "1111111111111111")
    s3 = _surv("src/b.jl", 30, "3333333333333333")
    rep = BlameReport(Dict("t1.jl" => [s1]), [s3], ["t_broken.jl"])
    buf = IOBuffer()
    render_blame(buf, rep)
    out = String(take!(buf))
    @test occursin("Survivors by Responsible Test", out)
    @test occursin("t1.jl", out)
    @test occursin("src/a.jl:10", out)
    @test occursin("Unattributed survivors", out)
    @test occursin("src/b.jl:30", out)
    @test occursin("t_broken.jl", out)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'include("test/test_blame.jl")'`
Expected: FAIL — `BlameReport` / `_join_blame` / `render_blame` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `src/blame.jl`:

```julia
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'include("test/test_blame.jl")'`
Expected: PASS — all `test_blame.jl` `@testset`s green.

- [ ] **Step 5: Commit**

```bash
git add src/blame.jl test/test_blame.jl
git commit -m "feat(blame): BlameReport + join + render_blame"
```

---

### Task 4: §5 falsifiability — end-to-end against a fixture package

**Files:**
- Create: `test/fixtures/blame_pkg/Project.toml`, `test/fixtures/blame_pkg/src/BlamePkg.jl`, `test/fixtures/blame_pkg/test/runtests.jl`, `test/fixtures/blame_pkg/test/test_weak.jl`, `test/fixtures/blame_pkg/test/test_strong.jl`, `test/fixtures/blame_pkg/test/test_unrelated.jl`
- Create: `test/blame_fixture_test.jl`

**Interfaces:**
- Consumes: `discover`, `baseline_run`, `run_mutations`, `blame_survivors`, `BlameReport` (public API).
- Produces: nothing (acceptance test).

**Design of the fixture (maps to §5):**
- `f(x) = x < 0 ? ...` — the mutated function. `OP_LT_TO_LE` plants a survivable mutant on `f`'s `<`.
- `test_weak.jl` — *calls* `f` but asserts nothing discriminating (`@test f(...) isa Any`). Covers `f`'s line, does **not** kill the `<`→`<=` mutant → **(a) must be blamed**.
- `test_strong.jl` — tests a *different* function `g` (and kills `g`'s mutants). Never calls `f` → does not cover `f`'s line → **(b)/(c) must NOT be blamed** for `f`'s survivor; and `g`'s killed mutants never appear in the blame list at all.
- `test_unrelated.jl` — asserts only `@test true`; covers nothing in src → not blamed.

(The "unattributed" path is already covered by Task 2's broken-unit test; this task focuses on the blame-vs-not-blame discrimination of §5 a/b/c against the *real* pipeline.)

- [ ] **Step 1: Write the fixture package + the failing test**

`test/fixtures/blame_pkg/Project.toml`:

```toml
name = "BlamePkg"
uuid = "00000000-0000-0000-0000-0000000000b1"
version = "0.0.1"
```

`test/fixtures/blame_pkg/src/BlamePkg.jl`:

```julia
module BlamePkg

# sign(x): mutating `<` to `<=` changes only the x==0 boundary.
function sign_of(x)
    if x < 0
        return -1
    else
        return 1
    end
end

# g: clearly killable so test_strong kills its mutants (never blamed).
add1(x) = x + 1

export sign_of, add1

end
```

`test/fixtures/blame_pkg/test/test_weak.jl`:

```julia
@testset "weak — calls sign_of but asserts nothing discriminating" begin
    # exercises sign_of's `<` line but never checks the x==0 boundary,
    # so the `<`->`<=` mutant survives and this file is to blame.
    @test sign_of(5) isa Int
    @test sign_of(-5) isa Int
end
```

`test/fixtures/blame_pkg/test/test_strong.jl`:

```julia
@testset "strong — tests add1 only, kills its mutants" begin
    @test add1(1) == 2
    @test add1(0) == 1
end
```

`test/fixtures/blame_pkg/test/test_unrelated.jl`:

```julia
@testset "unrelated — touches no source" begin
    @test true
end
```

`test/fixtures/blame_pkg/test/runtests.jl`:

```julia
using Test
using BlamePkg

include("test_weak.jl")
include("test_strong.jl")
include("test_unrelated.jl")
```

`test/blame_fixture_test.jl`:

```julia
using Test
using Gremlins

@testset "blame fixture — §5 falsifiability (a/b/c)" begin
    pkg = joinpath(@__DIR__, "fixtures", "blame_pkg")
    src_dir = joinpath(pkg, "src")

    sites = Gremlins.discover(src_dir; root=pkg)
    @test !isempty(sites)

    baseline_elapsed, cmap = Gremlins.baseline_run(pkg)
    result = Gremlins.run_mutations(pkg, sites, cmap; baseline_elapsed=baseline_elapsed)

    # there must be at least one survivor (the sign_of `<`->`<=` boundary mutant)
    survivors = filter(r -> r.outcome == Gremlins.survived, result.results)
    @test any(r -> occursin("BlamePkg.jl", r.site.relpath) && r.site.original == "<", survivors)

    rep = Gremlins.blame_survivors(result, pkg)

    # (a) the weak file is blamed for a sign_of survivor
    @test haskey(rep.blamed, "test_weak.jl")
    @test any(r -> r.site.original == "<", rep.blamed["test_weak.jl"])

    # (b)/(c) strong + unrelated files are NOT blamed
    @test !haskey(rep.blamed, "test_strong.jl")
    @test !haskey(rep.blamed, "test_unrelated.jl")

    # killed add1 mutants never surface anywhere in the blame report
    for (_, rs) in rep.blamed
        @test !any(r -> r.site.original == "+", rs)
    end
end
```

- [ ] **Step 2: Run test to verify it fails (then passes)**

Run: `julia --project -e 'include("test/blame_fixture_test.jl")'`
Expected: PASS once Tasks 1–3 are in place (this task adds only data + an integration test over already-implemented code). If it FAILS on "weak not blamed", inspect: confirm `sign_of`'s `<` line is the survivor and that `test_weak.jl` covers it (`per_unit_coverage(pkg)` then `covered_lines`).

- [ ] **Step 3: (no new implementation)**

This task is fixtures + integration test only. If the test reveals a real defect in Tasks 1–3, fix it there with systematic-debugging, not by weakening the assertions.

- [ ] **Step 4: Re-run to confirm green**

Run: `julia --project -e 'include("test/blame_fixture_test.jl")'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/blame_pkg test/blame_fixture_test.jl
git commit -m "test(blame): §5 falsifiability fixture — weak blamed, strong/unrelated not"
```

---

### Task 5: Wire `--blame` into the CLI + exports + suite registration

**Files:**
- Modify: `src/Gremlins.jl` (exports)
- Modify: `bin/gremlins-cli.jl` (`ParsedArgs`, `_parse_args`, `_print_usage`, `main`)
- Modify: `test/runtests.jl` (include the two new test files)
- Modify: `test/cli_test.jl` (assert `--blame` parses)

**Interfaces:**
- Consumes: `blame_survivors`, `render_blame` (Tasks 2–3).
- Produces: `--blame` CLI flag; public exports `blame_survivors`, `render_blame`, `BlameReport`, `per_unit_coverage`, `detect_units`, `TestUnit`.

- [ ] **Step 1: Write the failing test**

In `test/cli_test.jl`, find the arg-parse `@testset` (mirrors `_parse_args`) and add a case asserting `--blame` flips a flag. The fixture loop there already handles `--warm`/`--schema` as valueless flags; add the same shape. Add this `@testset` near the other parse tests:

```julia
@testset "CLI parse — --blame flag" begin
    # mirror of bin/gremlins-cli.jl _parse_args: --blame is a valueless bool
    function has_blame(argv)
        blame = false
        i = 1
        while i <= length(argv)
            argv[i] == "--blame" && (blame = true)
            i += 1
        end
        return blame
    end
    @test has_blame(["--pkg", "x", "--blame"])
    @test !has_blame(["--pkg", "x"])
end
```

(Note: `cli_test.jl` re-implements the parse loop locally — keep this test consistent with that file's existing style; the real assertion that the *binary* honors `--blame` is exercised by running it in Step 4.)

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'include("test/cli_test.jl")'`
Expected: PASS for the helper test (it is self-contained) — but the *binary* does not yet accept `--blame`; verify that first:
Run: `julia --project bin/gremlins-cli.jl --pkg test/fixtures/blame_pkg --blame --max-sites 1`
Expected: FAIL — `ERROR: unknown argument: "--blame"`, exit 2.

- [ ] **Step 3: Write minimal implementation**

In `src/Gremlins.jl`, after the report exports block, add:

```julia
# Survivor-coverage blame
export BlameReport
export blame_survivors
export render_blame
export per_unit_coverage
export detect_units
export TestUnit
```

In `bin/gremlins-cli.jl`:

1. Add field to `ParsedArgs` (after `schema::Bool`):

```julia
    blame::Bool                 # --blame: opt-in survivor-coverage blame pass
```

2. In `_parse_args`, add the local `blame = false` beside `schema = false`, add the branch alongside `--schema`:

```julia
        elseif arg == "--blame"
            blame = true
```

and pass it in the constructor (keep field order — `blame` goes right after `schema`):

```julia
    return ParsedArgs(pkg, files, test_file, warm, schema, blame, json_out, strong, acceptable, max_sites, indiff_ref)
```

3. In `_print_usage`, add a line documenting `--blame` (after the `--schema` line) — e.g.:

```
  --blame              After the run, name the test file(s) covering each surviving mutant (N extra coverage runs)
```

4. In `main`, after `Gremlins.print_summary(run_result)` and before the JSON block, add:

```julia
    # Opt-in survivor-coverage blame pass
    if args.blame
        elog("[gremlins] Running survivor-coverage blame (per-test coverage)...")
        try
            blame_report = Gremlins.blame_survivors(run_result, pkgdir;
                test_dir=test_dir, test_file=test_file_bare)
            Gremlins.render_blame(stdout, blame_report)
        catch e
            elog("WARNING: blame pass failed: $e")
        end
    end
```

In `test/runtests.jl`, add at the end (after the dispatch-operators include):

```julia
# ─── Feature 2: survivor-coverage blame ──────────────────────────────────────
include("test_blame.jl")
include("blame_fixture_test.jl")
```

- [ ] **Step 4: Run tests + binary to verify they pass**

Run: `julia --project bin/gremlins-cli.jl --pkg test/fixtures/blame_pkg --blame --max-sites 50`
Expected: normal summary, then a "━━━ Survivors by Responsible Test" section listing `test_weak.jl` with a `sign_of` survivor.

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: full suite PASS, including `test_blame.jl` + `blame_fixture_test.jl`.

- [ ] **Step 5: Commit**

```bash
git add src/Gremlins.jl bin/gremlins-cli.jl test/runtests.jl test/cli_test.jl
git commit -m "feat(blame): --blame CLI flag + exports + suite wiring"
```

---

## Self-Review

**Spec coverage:**
- §3 pipeline (survivors → per-test coverage map → join → report lens): Task 3 (`blame_survivors` join) + Task 2 (coverage map) + Task 3 (`render_blame`). ✅
- §4 approach (i) JuliaSyntax prelude, units = includes + inline, sequential one-shadow, `.cov` cleared between units: Tasks 1–2. ✅
- §4 honesty (errored unit → unattributed, never false blame): Task 2 (`failed`) + Task 3 (`_join_blame` routes uncovered survivors to `unattributed`) + Task 2 broken-unit test + Task 3 test. ✅
- §5 falsifiability (weak blamed / strong+unrelated not / killed absent / unattributed): Task 4 (a/b/c + killed-absent) + Task 2 (unattributed/failed-unit). ✅
- §7.2 file-level granularity: unit = file/`<inline>`. ✅
- §7.3 lives in new `blame.jl`, `baseline_run` untouched: confirmed (blame.jl only *reuses* coverage.jl internals; **deviation from spec §8**: `per_unit_coverage` lives in `blame.jl` not `coverage.jl`, which keeps coverage.jl literally unmodified — strictly better for the "untouched" requirement). ✅
- §7.4 opt-in surface (`blame_survivors` API + `--blame` CLI): Task 5. ✅
- §7.5 one shadow, sequential, `.cov` cleanup trap: Task 2 (`_rm_cov_files`). ✅

**Placeholder scan:** No TBD/TODO/"add error handling" — every code step is complete. ✅

**Type consistency:** `TestUnit{label,driver}`, `BlameReport{blamed,unattributed,failed_units}`, `per_unit_coverage -> (Dict{String,CoverageMap}, Vector{String})`, `blame_survivors -> BlameReport`, `_join_blame(survivors, maps, failed) -> BlameReport` — names/signatures consistent across Tasks 1–5. `MutationSite` positional constructor `(id, relpath, byte_range, op_id, op_name, original, replacement, line)` matches `src/discover.jl:31-40`. `MutantResult(site, outcome, elapsed, error_msg)` matches `src/runner.jl:47-52`. `ParsedArgs` field `blame` inserted after `schema` and threaded through the constructor consistently. ✅
