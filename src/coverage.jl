# coverage.jl — Baseline coverage run and line→testfile map for Gremlins.jl
#
# Public API:
#   baseline_run(pkgdir; test_cmd, timeout) -> (elapsed_seconds, CoverageMap)
#   CoverageMap                              — line→testfile data structure
#   covered_lines(cmap, relpath)             -> Set{Int} of covered lines
#
# Strategy:
#   Run the package test suite once with `--code-coverage=user`.
#   Parse the resulting *.cov files to build a map: (relpath → Set{line}).
#   Per-testfile granularity is not available without per-test runners;
#   M1 uses whole-suite coverage (conservative: if ANY test covers a line,
#   the mutant is run against ALL tests). Coverage-guided selection is
#   therefore "has coverage" vs "no coverage" — a finding, not a skip.
#
# Invariants:
#   I4 — Static analysis only during discovery. Coverage runs the real test suite.

# ─── Types ───────────────────────────────────────────────────────────────────

"""
    CoverageMap

Maps source relpaths (forward-slash) to the set of 1-based line numbers
that were executed during the baseline test run.
"""
struct CoverageMap
    # relpath (forward-slash, relative to pkgdir) → Set{Int} of covered lines
    data::Dict{String, Set{Int}}
    pkgdir::String
end

function Base.show(io::IO, cm::CoverageMap)
    n_files = length(cm.data)
    n_lines = sum(length(v) for v in values(cm.data); init=0)
    print(io, "CoverageMap($n_files files, $n_lines covered lines)")
end

# ─── Coverage file parsing ────────────────────────────────────────────────────

"""
    parse_cov_file(path) -> Set{Int}

Parse a Julia `.cov` coverage file and return the set of covered line numbers.

Julia .cov format: each line starts with whitespace + count (or `-` for
non-executable) + space + source text. Lines with count > 0 are covered.
"""
function parse_cov_file(path::AbstractString)::Set{Int}
    covered = Set{Int}()
    lines = try
        readlines(path)
    catch e
        throw(MutationError("parse_cov_file: cannot read '$path': $e"))
    end
    for (i, line) in enumerate(lines)
        # Format: "        N source..." or "        - source..."
        # The count field is right-aligned in a fixed-width column before the space+source.
        m = match(r"^\s+(-|\d+)\s", line)
        m === nothing && continue
        count_str = m.captures[1]
        count_str == "-" && continue
        count = tryparse(Int, count_str)
        count === nothing && continue
        count > 0 && push!(covered, i)
    end
    return covered
end

# ─── Baseline run ─────────────────────────────────────────────────────────────

"""
    baseline_run(pkgdir; test_dir="test", test_file="runtests.jl",
                 timeout=600.0) -> (elapsed::Float64, CoverageMap)

Run the package's test suite once with `--code-coverage=user` to build
the coverage map. Returns elapsed time in seconds and a `CoverageMap`.

The test command is: `julia --project=<shadow> --code-coverage=user <shadow_test_file>`

The run executes inside a disposable shadow copy of the package (I1 crash-safety:
the real package tree is never written). .cov files are parsed from the shadow;
CoverageMap keys are remapped to real relpaths so downstream callers (is_covered,
runner) see the same paths as mutation-site relpaths.

Throws `MutationError` if the baseline run fails (non-zero exit or timeout).
If Pkg resolution fails in the shadow (possible with relative-path deps), throws
a typed MutationError asking the user to check their Manifest — does NOT fall back
to mutating the real tree.
"""
function baseline_run(
    pkgdir::AbstractString;
    test_dir::AbstractString = "test",
    test_file::AbstractString = "runtests.jl",
    timeout::Float64 = 600.0,
)::Tuple{Float64, CoverageMap}
    pkgdir = abspath(pkgdir)
    test_path = joinpath(pkgdir, test_dir, test_file)
    isfile(test_path) || throw(MutationError(
        "baseline_run: test file not found: '$test_path'"
    ))

    # Create shadow copy — real tree is never written (I1 crash-safety)
    shadow = _make_shadow(pkgdir)
    try
        shadow_test_path = joinpath(shadow, test_dir, test_file)

        jl = _julia_exe()
        cmd = Cmd([jl, "--project=$shadow", "--code-coverage=user", shadow_test_path])

        t0 = time()
        exit_code, output = _run_with_timeout(cmd, timeout)
        elapsed = time() - t0

        if exit_code == :timeout
            throw(MutationError(
                "baseline_run: test suite timed out after $(timeout)s — " *
                "cannot establish baseline; raise `baseline_timeout` on mutate()"
            ))
        end
        if exit_code != 0
            # Detect Pkg resolution failures in the shadow
            if occursin("PkgError", output) || occursin("could not find", output) ||
               occursin("manifest", lowercase(output))
                throw(MutationError(
                    "baseline_run: Pkg resolution failed in shadow copy — " *
                    "your Manifest.toml may use relative paths that do not resolve outside the real package directory. " *
                    "Check your [deps] or Manifest.toml for relative path references. " *
                    "Output: $(output[1:min(500,length(output))])"
                ))
            end
            throw(MutationError(
                "baseline_run: test suite failed with exit code $exit_code — " *
                "fix tests before running mutation testing"
            ))
        end

        # Collect .cov files from shadow; remap keys to real relpaths
        shadow_cmap = _collect_coverage(shadow)
        cmap = _remap_cmap_to_real(shadow_cmap, pkgdir, shadow)
        return (elapsed, cmap)
    finally
        rm(shadow; recursive=true, force=true)
    end
end

# ─── Coverage file collection ────────────────────────────────────────────────

"""
    _collect_coverage(pkgdir) -> CoverageMap

Walk `pkgdir/src/` and find all *.cov files left by the coverage run.
Build and return a CoverageMap.
"""
function _collect_coverage(pkgdir::AbstractString)::CoverageMap
    data = Dict{String, Set{Int}}()
    src_dir = joinpath(pkgdir, "src")
    isdir(src_dir) || return CoverageMap(data, pkgdir)

    for (dirpath, _, filenames) in walkdir(pkgdir)
        for fn in filenames
            # Julia coverage files: <source>.jl.<pid>.cov  or  <source>.jl.cov
            m = match(r"^(.+\.jl)(?:\.\d+)?\.cov$", fn)
            m === nothing && continue
            cov_path = joinpath(dirpath, fn)
            src_name = m.captures[1]
            # The source file should exist alongside (or the .cov is stale)
            src_path = joinpath(dirpath, src_name)

            # Derive relpath relative to pkgdir
            rel = try
                rp = relpath(src_path, pkgdir)
                replace(rp, Base.Filesystem.path_separator => "/")
            catch
                src_name
            end

            covered = try
                parse_cov_file(cov_path)
            catch
                Set{Int}()
            end

            if !isempty(covered)
                existing = get(data, rel, Set{Int}())
                data[rel] = union(existing, covered)
            end
        end
    end

    return CoverageMap(data, pkgdir)
end

# ─── Shadow remap ────────────────────────────────────────────────────────────

"""
    _remap_cmap_to_real(shadow_cmap::CoverageMap, pkgdir, shadow_dir) -> CoverageMap

Take a CoverageMap built from shadow paths and return one with keys relative
to the REAL pkgdir (forward-slash, as expected by is_covered/covered_lines).

This is needed because baseline_run runs in the shadow but callers compare
coverage against real relpaths (derived from site.relpath which is real-rooted).

The data (covered line sets) is unchanged; only keys are remapped.
Since shadow is byte-identical to real, shadow_rel == real_rel for all files.
"""
function _remap_cmap_to_real(
    shadow_cmap::CoverageMap,
    pkgdir::AbstractString,
    shadow_dir::AbstractString,
)::CoverageMap
    new_data = Dict{String, Set{Int}}()
    for (shadow_rel, lines) in shadow_cmap.data
        # shadow_rel is already relative to shadow_dir with forward slashes.
        # The real package has the same directory structure, so real_rel == shadow_rel.
        # We recompute via joinpath/relpath to be robust.
        real_abs = joinpath(pkgdir, replace(shadow_rel, "/" => Base.Filesystem.path_separator))
        real_rel = replace(relpath(real_abs, pkgdir), Base.Filesystem.path_separator => "/")
        existing = get(new_data, real_rel, Set{Int}())
        new_data[real_rel] = union(existing, lines)
    end
    return CoverageMap(new_data, pkgdir)
end

# ─── Query helpers ────────────────────────────────────────────────────────────

"""
    covered_lines(cmap::CoverageMap, relpath::AbstractString) -> Set{Int}

Return the set of covered lines for a given source relpath.
Returns empty set if the file has no coverage data.
"""
function covered_lines(cmap::CoverageMap, relpath::AbstractString)::Set{Int}
    # Normalise path separators
    key = replace(relpath, Base.Filesystem.path_separator => "/")
    return get(cmap.data, key, Set{Int}())
end

"""
    is_covered(cmap::CoverageMap, site::MutationSite) -> Bool

Return true if the mutation site's line is covered by the baseline test run.
"""
function is_covered(cmap::CoverageMap, site::MutationSite)::Bool
    lines = covered_lines(cmap, site.relpath)
    return site.line in lines
end

# ─── Subprocess helpers (shared with runner.jl) ───────────────────────────────

"""Return the path to the Julia executable currently running."""
function _julia_exe()::String
    return Base.julia_cmd().exec[1]
end

"""
    _run_with_timeout(cmd, timeout_secs) -> (exit_code, output::String)

Run `cmd` capturing combined stdout+stderr. Returns `:timeout` as exit code
if the process exceeds `timeout_secs`. Output is capped internally for memory
safety but not returned in full (runner classifies by exit code, not output).
"""
function _run_with_timeout(cmd::Cmd, timeout_secs::Float64)::Tuple{Any, String}
    buf = IOBuffer()
    proc = try
        run(pipeline(cmd, stdout=buf, stderr=buf); wait=false)
    catch e
        return (-1, "launch error: $e")
    end

    deadline = time() + timeout_secs
    while process_running(proc)
        if time() > deadline
            try; kill(proc, Base.SIGTERM); catch; end
            sleep(0.5)
            if process_running(proc)
                try; kill(proc, Base.SIGKILL); catch; end
            end
            wait(proc)
            return (:timeout, "")
        end
        sleep(0.05)
    end
    wait(proc)
    return (proc.exitcode, String(take!(buf)))
end
