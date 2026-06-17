# runner.jl — Process-per-mutant execution engine for Gremlins.jl
#
# Public API:
#   MutantResult         — outcome for one mutant
#   RunResult            — full run outcome (all mutants)
#   run_mutations(pkgdir, sites, cmap; ...) -> RunResult
#
# Invariants:
#   I1  — The REAL package tree is NEVER written by mutation runs.
#          All mutation execution happens in a disposable shadow copy under mktempdir.
#          A SIGKILL/OOM event leaves orphaned tmp dirs — harmless — NOT corrupted source.
#          Production incident 2026-06-04: in-process try/finally is not crash-safe.
#   I2  — Deterministic: mutants processed in sorted order (id).
#   I3  — Timeout = 3× baseline elapsed (configurable).

# Floor for the derived per-mutant timeout. Every mutant runs as a fresh
# `julia --project test` subprocess that pays cold-start precompile (~10-20s)
# before any test executes; a floor below that spuriously classifies slow-start
# mutants on small/fast-baseline packages as `timeout` instead of killed.
const COLD_START_TIMEOUT_FLOOR = 60.0

# ─── Outcome enum ─────────────────────────────────────────────────────────────

"""
Outcome for a single mutant:
- `:killed`      — test suite failed with non-zero exit (mutant detected)
- `:survived`    — test suite passed (mutant not caught by tests)
- `:timeout`     — test run exceeded time limit
- `:no_coverage` — no baseline coverage on the mutation site's line
- `:error`       — runner infrastructure error (apply/revert failed, etc.)
"""
@enum MutantOutcome begin
    killed
    survived
    timeout
    no_coverage
    error
end

# ─── Result structs ───────────────────────────────────────────────────────────

"""
    MutantResult

Outcome record for a single mutant execution.
"""
struct MutantResult
    site::MutationSite
    outcome::MutantOutcome
    elapsed::Float64        # seconds for this mutant's subprocess
    error_msg::String       # non-empty only for outcome==error
end

function Base.show(io::IO, r::MutantResult)
    print(io, "MutantResult($(r.site.id[1:8])… $(r.outcome) $(round(r.elapsed, digits=2))s)")
end

"""
    RunResult

Complete result of a mutation run.
"""
struct RunResult
    pkgdir::String
    sites::Vector{MutationSite}       # all sites evaluated (sorted)
    results::Vector{MutantResult}     # one per site, same order
    baseline_elapsed::Float64          # seconds for baseline test run
    total_elapsed::Float64             # wall time for entire run
end

function Base.show(io::IO, r::RunResult)
    s = mutation_score(r)
    print(io, "RunResult($(length(r.results)) mutants, score=$(round(s*100, digits=1))%)")
end

# ─── Mutation score ────────────────────────────────────────────────────────────

"""
    mutation_score(r::RunResult) -> Float64

Mutation score = killed / (total - no_coverage - error).
Returns NaN if the denominator is 0.
"""
function mutation_score(r::RunResult)::Float64
    n_killed   = count(x -> x.outcome == killed,      r.results)
    n_nocov    = count(x -> x.outcome == no_coverage,  r.results)
    n_err      = count(x -> x.outcome == error,        r.results)
    denom      = length(r.results) - n_nocov - n_err
    denom == 0 && return NaN
    return n_killed / denom
end

# ─── Core runner ──────────────────────────────────────────────────────────────

"""
    run_mutations(pkgdir, sites, cmap;
                  test_dir="test", test_file="runtests.jl",
                  baseline_elapsed=nothing,
                  timeout_multiplier=3.0,
                  coverage_overhead=2.5,
                  mutant_timeout=nothing,
                  verbose=false) -> RunResult

For each `MutationSite` in `sites` (processed in sorted id order):
1. Check coverage — skip to `:no_coverage` if site's line not covered.
2. Apply the mutation to the SHADOW file (real tree never touched — I1).
3. Run the test suite as a subprocess with `--project=<shadow>`.
4. Classify outcome.
5. Revert the shadow file (hygiene — keeps shadow valid for the next mutant).
   This revert is NOT the safety mechanism; it is cheap in-shadow restoration.
   The safety property is that the real tree was never written, so SIGKILL cannot
   corrupt it. A leaked shadow tmpdir is harmless garbage in /tmp.

`baseline_elapsed`: if provided, timeout = baseline_elapsed × timeout_multiplier.
If not provided, a new baseline run is performed.

`coverage_overhead`: the factor by which coverage instrumentation inflates the
baseline elapsed time vs. a plain run (default 2.5 — empirically ~2–3× on typical
packages). The derived per-mutant timeout uses `est_plain = baseline_elapsed /
coverage_overhead` to avoid grossly over-allocated timeouts (e.g. a 575s coverage
baseline on SQLite.jl would otherwise yield ~29min per mutant, while the real plain
run is ~205s).

`mutant_timeout`: explicit per-mutant timeout in seconds. When set, bypasses the
`est_plain * timeout_multiplier` derivation entirely. Use when you know the exact
budget needed.

Shadow is created ONCE per run (not per mutant) and cleaned up in finally.
"""
function run_mutations(
    pkgdir::AbstractString,
    sites::Vector{MutationSite},
    cmap::CoverageMap;
    test_dir::AbstractString     = "test",
    test_file::AbstractString    = "runtests.jl",
    baseline_elapsed::Union{Float64, Nothing} = nothing,
    timeout_multiplier::Float64  = 3.0,
    coverage_overhead::Float64   = 2.5,
    mutant_timeout::Union{Float64, Nothing} = nothing,
    verbose::Bool                = false,
)::RunResult
    pkgdir = abspath(pkgdir)

    # Establish baseline if not provided
    if isnothing(baseline_elapsed)
        verbose && println("[gremlins] Running baseline to measure test time...")
        elapsed_b, _ = baseline_run(pkgdir; test_dir=test_dir, test_file=test_file)
        baseline_elapsed = elapsed_b
        verbose && println("[gremlins] Baseline: $(round(elapsed_b, digits=2))s")
    end

    # Derive per-mutant timeout:
    #   est_plain = baseline_elapsed / coverage_overhead  (removes coverage inflation)
    #   mutant_timeout = max(COLD_START_TIMEOUT_FLOOR, est_plain * timeout_multiplier)
    # coverage_overhead accounts for the ~2-3x slowdown from --code-coverage=user.
    # An explicit mutant_timeout kwarg bypasses this derivation entirely.
    derived_timeout = if !isnothing(mutant_timeout)
        mutant_timeout
    else
        est_plain = baseline_elapsed / coverage_overhead
        max(COLD_START_TIMEOUT_FLOOR, est_plain * timeout_multiplier)
    end
    if verbose
        if !isnothing(mutant_timeout)
            println("[gremlins] Mutant timeout: $(round(derived_timeout, digits=1))s (explicit override)")
        else
            est_plain = baseline_elapsed / coverage_overhead
            println("[gremlins] baseline (coverage) $(round(baseline_elapsed, digits=2))s, " *
                    "estimated plain ≈ $(round(est_plain, digits=2))s (÷$(coverage_overhead)), " *
                    "derived mutant timeout $(round(derived_timeout, digits=1))s")
        end
    end
    # Sort sites deterministically by id
    sorted_sites = sort(sites, by = s -> s.id)

    jl = _julia_exe()
    results = MutantResult[]
    run_t0 = time()

    # Create shadow copy ONCE — real tree is NEVER written (I1 crash-safety)
    # If SIGKILL hits us, the shadow tmpdir is left in /tmp as harmless garbage.
    shadow = _make_shadow(pkgdir)
    verbose && println("[gremlins] Shadow copy at: $shadow")

    # Augment shadow with test-only deps so `--project=<shadow>` can load them.
    # No-op (returns false) when the package has no non-stdlib test deps.
    _augment_shadow_with_test_deps(pkgdir, shadow)

    try
        shadow_test_path = joinpath(shadow, test_dir, test_file)

        for (i, site) in enumerate(sorted_sites)
            # 1. Coverage check
            if !is_covered(cmap, site)
                if verbose
                    println("[gremlins] [$i/$(length(sorted_sites))] $(site.id[1:8])… no_coverage")
                    flush(stdout)
                end
                push!(results, MutantResult(site, no_coverage, 0.0, ""))
                continue
            end

            if verbose
                print("[gremlins] [$i/$(length(sorted_sites))] $(site.id[1:8])… ")
                flush(stdout)
            end

            # 2. Determine shadow path (real path is never touched)
            real_abs_path = _site_abs_path(pkgdir, site)
            shadow_abs_path = try
                _shadow_abs_path(pkgdir, shadow, real_abs_path)
            catch e
                push!(results, MutantResult(site, error, 0.0, "shadow path error: $e"))
                if verbose
                    println("error (shadow path)")
                    flush(stdout)
                end
                continue
            end

            mutant_t0 = time()
            outcome   = survived
            err_msg   = ""

            shadow_original_src = try
                read(shadow_abs_path, String)
            catch e
                push!(results, MutantResult(site, error, 0.0, "cannot read shadow source: $e"))
                if verbose
                    println("error (read shadow)")
                    flush(stdout)
                end
                continue
            end

            # 3. Apply mutation to shadow + run + revert shadow (hygiene, not safety)
            try
                apply!(site, shadow_abs_path)

                # 4. Run test subprocess against shadow project
                cmd = Cmd([jl, "--project=$shadow", shadow_test_path])
                exit_code, _ = _run_with_timeout(cmd, derived_timeout)

                if exit_code == :timeout
                    outcome = timeout
                elseif exit_code != 0
                    outcome = killed
                else
                    outcome = survived
                end
            catch e
                outcome = error
                err_msg = sprint(showerror, e)
            finally
                # In-shadow restoration (hygiene: keeps shadow valid for next mutant)
                # This is NOT the crash-safety mechanism — real tree was never touched.
                try
                    _atomic_write(shadow_abs_path, shadow_original_src)
                catch restore_err
                    @warn "[gremlins] Failed to restore shadow source (harmless — shadow will be cleaned up)" path=shadow_abs_path err=restore_err
                end
            end

            elapsed = time() - mutant_t0
            push!(results, MutantResult(site, outcome, elapsed, err_msg))
            if verbose
                println(string(outcome), " ($(round(elapsed, digits=2))s)")
                flush(stdout)
            end
        end
    finally
        # Clean up shadow — a SIGKILL skip of this cleanup leaves harmless tmp garbage
        rm(shadow; recursive=true, force=true)
    end

    total_elapsed = time() - run_t0
    return RunResult(pkgdir, sorted_sites, results, baseline_elapsed, total_elapsed)
end

# ─── Convenience entry point ──────────────────────────────────────────────────

"""
    mutate(pkgdir;
           src_dir="src",
           test_dir="test", test_file="runtests.jl",
           operators=DEFAULT_OPERATORS,
           timeout_multiplier=3.0,
           baseline_timeout=600.0,
           coverage_overhead=2.5,
           mutant_timeout=nothing,
           max_mutants=nothing,
           files=nothing,
           verbose=false) -> RunResult

High-level entry point: discover mutations, run baseline, execute all mutants.

`baseline_timeout`: timeout in seconds for the baseline test run (default 600.0).
Raise this if your package's covered test suite exceeds 10 minutes.

`coverage_overhead`: factor by which `--code-coverage=user` inflates the baseline
elapsed time (default 2.5). Used to estimate plain-run time for deriving the
per-mutant timeout budget. Typical packages are 2–3×.

`mutant_timeout`: explicit per-mutant timeout. When set, bypasses the
`est_plain * timeout_multiplier` derivation. Useful for pinning a hard bound.

`max_mutants`: cap the number of mutation sites to this many (deterministic spread:
sorted by id, then round-robin across files). `nothing` = no cap.

`files`: restrict to sites whose relpath matches any of these entries. Accepts
bare filenames, relative paths, and `./`-prefixed paths — same normalization as
the CLI `--files` flag. `nothing` = all files.
"""
function mutate(
    pkgdir::AbstractString;
    src_dir::AbstractString       = "src",
    test_dir::AbstractString      = "test",
    test_file::AbstractString     = "runtests.jl",
    operators::Vector{MutationOperator} = DEFAULT_OPERATORS,
    timeout_multiplier::Float64   = 3.0,
    baseline_timeout::Float64     = 600.0,
    coverage_overhead::Float64    = 2.5,
    mutant_timeout::Union{Float64, Nothing} = nothing,
    max_mutants::Union{Int, Nothing} = nothing,
    files::Union{Vector{String}, Nothing} = nothing,
    verbose::Bool                 = false,
)::RunResult
    pkgdir = abspath(pkgdir)
    verbose && println("[gremlins] Discovering mutations in $(joinpath(pkgdir, src_dir))...")

    # root=pkgdir ensures relpaths are relative to pkgdir (matching coverage map keys)
    sites = discover(joinpath(pkgdir, src_dir); operators=operators, root=pkgdir)
    verbose && println("[gremlins] Discovered $(length(sites)) mutation sites")

    # Apply files filter (same normalization as CLI --files)
    if !isnothing(files) && !isempty(files)
        sites = _filter_sites_by_files(sites, files)
        verbose && println("[gremlins] After files filter: $(length(sites)) sites")
    end

    # Apply max_mutants cap with deterministic round-robin sampling
    if !isnothing(max_mutants) && length(sites) > max_mutants
        sites = _sample_sites_round_robin(sites, max_mutants)
        verbose && println("[gremlins] Capped to $(length(sites)) sites (max_mutants=$max_mutants)")
    end

    verbose && println("[gremlins] Running baseline test suite...")
    baseline_elapsed, cmap = baseline_run(pkgdir;
        test_dir=test_dir, test_file=test_file, timeout=baseline_timeout)
    verbose && println("[gremlins] Baseline: $(round(baseline_elapsed, digits=2))s  coverage: $cmap")

    return run_mutations(pkgdir, sites, cmap;
        test_dir=test_dir,
        test_file=test_file,
        baseline_elapsed=baseline_elapsed,
        timeout_multiplier=timeout_multiplier,
        coverage_overhead=coverage_overhead,
        mutant_timeout=mutant_timeout,
        verbose=verbose)
end

# ─── Sampling helper (P3) ─────────────────────────────────────────────────────

"""
    _normalize_relpath(pat::String) -> String

Normalize a file pattern for robust path matching:
- Replace backslashes with forward slashes (Windows-safe)
- Strip leading "./" (e.g. "./src/foo.jl" → "src/foo.jl")

Same normalization as the CLI `--files` flag — do NOT duplicate divergent logic.
"""
function _normalize_relpath(pat::String)::String
    p = replace(pat, '\\' => '/')
    while startswith(p, "./")
        p = p[3:end]
    end
    return p
end

"""
    _filter_sites_by_files(sites, file_patterns) -> Vector{MutationSite}

Keep only sites whose relpath matches any of the given patterns.
Matching rules (applied after normalizing the pattern with _normalize_relpath):
1. Exact match: relpath == normalized_pat
2. Suffix match: endswith(relpath, "/" * normalized_pat)
3. Basename match: endswith(relpath, "/" * basename(normalized_pat)) OR relpath == basename

All comparisons use forward slashes. Empty patterns = no filter (all sites).
Normalization is the same as the CLI -- do not duplicate divergent logic.
"""
function _filter_sites_by_files(sites::Vector{MutationSite}, file_patterns::Vector{String})::Vector{MutationSite}
    isempty(file_patterns) && return sites
    return filter(sites) do site
        rp = site.relpath
        any(file_patterns) do raw_pat
            pat = _normalize_relpath(raw_pat)
            rp == pat && return true
            endswith(rp, "/" * pat) && return true
            bn = basename(pat)
            endswith(rp, "/" * bn) || rp == bn
        end
    end
end

"""
    _sample_sites_round_robin(sites, n) -> Vector{MutationSite}

Take a deterministic sample of `n` sites from `sites` using round-robin across
files, so the cap is balanced rather than front-loaded into one file.

Algorithm:
1. Sort all sites by id (already deterministic per I2).
2. Bucket by relpath.
3. Round-robin: pick one site from each bucket in sorted-relpath order until n reached.

Deterministic: same input → same output. No randomness, no clock.
"""
function _sample_sites_round_robin(sites::Vector{MutationSite}, n::Int)::Vector{MutationSite}
    n >= length(sites) && return sites

    # Sort by id first (deterministic, per I2)
    sorted = sort(sites, by = s -> s.id)

    # Bucket by relpath; keep buckets in sorted-relpath order
    bucket_keys = unique(sort([s.relpath for s in sorted]))
    buckets = Dict{String, Vector{MutationSite}}()
    for s in sorted
        push!(get!(buckets, s.relpath, MutationSite[]), s)
    end

    # Round-robin across buckets until we have n
    result = MutationSite[]
    bucket_indices = Dict(k => 1 for k in bucket_keys)
    taken = 0
    while taken < n
        advanced = false
        for k in bucket_keys
            taken >= n && break
            idx = bucket_indices[k]
            bkt = buckets[k]
            if idx <= length(bkt)
                push!(result, bkt[idx])
                bucket_indices[k] = idx + 1
                taken += 1
                advanced = true
            end
        end
        advanced || break  # all buckets exhausted
    end
    return result
end

# ─── Internal helpers ─────────────────────────────────────────────────────────

"""
Derive the absolute path to the source file for a mutation site.
site.relpath is relative to the discovery root (pkgdir/src or pkgdir).
We try pkgdir/relpath first, then pkgdir/src/relpath.
"""
function _site_abs_path(pkgdir::AbstractString, site::MutationSite)::String
    candidate = joinpath(pkgdir, site.relpath)
    isfile(candidate) && return candidate
    # Also try with src/ prefix stripped — if discovery was run on pkgdir/src/
    # the relpath might already include src/
    candidate2 = joinpath(pkgdir, "src", site.relpath)
    isfile(candidate2) && return candidate2
    throw(MutationError("cannot locate source file for site $(site.id): relpath=$(site.relpath)"))
end
