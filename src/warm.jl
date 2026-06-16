# warm.jl — Warm-worker pool execution for Gremlins.jl (M2b)
#
# Design:
#   - ONE persistent Julia worker process per run (started lazily, recycled periodically).
#   - Worker starts with --project=<pkgdir>, loads the target package ONCE.
#   - Per mutant (warm path, disk NEVER touched):
#       a. Core.eval(TargetPkg, mutated_body)  — replaces methods in-place
#       b. Run test file in fresh Module via Base.invokelatest(Base.include, m, test_path)
#       c. Core.eval(TargetPkg, original_body) — always restored (try/finally in worker)
#   - Protocol: JSON-Lines over worker's stdin/stdout.
#   - Worker recycled every WORKER_RECYCLE_INTERVAL mutants or after fallback_evalerr.
#   - Ineligible sites (macro defs, type defs, const globals) route cold directly.
#   - Dynamic fallback: warm eval error → cold re-run + fallback_evalerr taxonomy.
#   - I4 agreement invariant: ≥10 warm-run mutants sampled and re-run cold;
#     any outcome mismatch is a hard error surfaced in the report.
#
# Public API:
#   WarmEligibility           — struct with flag + reason       (warm_eligibility.jl)
#   FallbackReason            — enum                             (warm_eligibility.jl)
#   WarmRunResult             — warm-run summary
#   classify_warm_eligibility — static eligibility check         (warm_eligibility.jl)
#   run_mutations_warm        — warm-pool runner (returns WarmRunResult)
#   GREMLINS_VERSION          — version string used in cache keys
#
# NOTE: FallbackReason / WarmEligibility / classify_warm_eligibility and the
# byte-locator helpers live in warm_eligibility.jl; the WorkerHandle pool +
# JSON-Lines transport + per-mutant/schema worker commands live in worker_pool.jl.
# Both are included BEFORE this file in Gremlins.jl.

# ─── Gremlins version string (cache key component) ────────────────────────────

const GREMLINS_VERSION = "0.1.0-m2b"

# ─── Worker recycle interval ──────────────────────────────────────────────────

"""Number of warm mutants run before recycling the worker (state-pollution hygiene)."""
const WORKER_RECYCLE_INTERVAL = 25

# ─── WarmMutantResult ─────────────────────────────────────────────────────────

"""
    WarmMutantResult

Extends MutantResult with warm-path metadata.
"""
struct WarmMutantResult
    base::MutantResult         # underlying outcome (same enum as cold path)
    fallback_reason::FallbackReason  # warm_ok = ran warm; else = cold fallback cause
    warm_elapsed::Float64      # 0.0 if ran cold
    cold_elapsed::Float64      # 0.0 if ran warm (or matched warm)
end

# ─── WarmRunResult ─────────────────────────────────────────────────────────────

"""
    WarmRunResult

Complete result of a warm-pool mutation run.

Includes I4 agreement check results and fallback taxonomy counts.
"""
struct WarmRunResult
    run::RunResult                       # base run (warm outcomes, adapted)
    warm_results::Vector{WarmMutantResult}
    fallback_taxonomy::Dict{FallbackReason, Int}
    i4_sample_count::Int
    i4_mismatches::Vector{String}        # non-empty = hard error
    cache_hits::Int
    worker_recycles::Int                 # number of worker restarts during run
end

# ─── Main warm runner ─────────────────────────────────────────────────────────

"""
    run_mutations_warm(pkgdir, sites, cmap;
                       test_dir="test", test_file="runtests.jl",
                       baseline_elapsed=nothing,
                       timeout_multiplier=3.0,
                       coverage_overhead=2.5,
                       mutant_timeout=nothing,
                       n_workers=nothing,    # accepted for API compat; warm uses 1 worker
                       verbose=false,
                       cache=nothing,
                       pkg_name=nothing) -> WarmRunResult

Warm-pool mutation runner.

For each site (sorted by id, respecting I2):
1. Check cache — if hit, skip execution.
2. Classify warm eligibility (static, at run time per site).
3. Ineligible sites → cold path (with taxonomy reason); cold runs in shadow (I1).
4. Eligible sites → warm path: mutated content shipped to persistent worker.
   Worker evals into module (NO disk write), runs test in fresh Module, restores.
5. Dynamic fallback on warm error → cold re-run in shadow + fallback_evalerr taxonomy.
   Worker recycled after each fallback_evalerr.
6. Worker recycled every WORKER_RECYCLE_INTERVAL mutants (hygiene).
7. After all mutants: I4 sample check (≥10 warm-run mutants re-run cold in shadow).
8. Any I4 mismatch → record in WarmRunResult.i4_mismatches (hard error for caller).

Cold fallbacks use a shadow copy of the package (I1 crash-safety: real tree is
never written). The warm path already never touches disk. Shadow is created once
per run and cleaned up in finally.

`pkg_name`: target package name (e.g. "TeleTUI", "MiniTarget"). If not provided,
inferred from pkgdir/Project.toml. Required for worker startup.

`test_file`: for the warm path, if a file named `<stem>_warm.jl` exists alongside
`test_file`, it is used instead (warm-compatible variant that uses `using PkgName`
rather than `include(src)`). The cold path always uses `test_file` (inside shadow).

`coverage_overhead`: factor by which `--code-coverage=user` inflates the baseline
elapsed time (default 2.5). Used to estimate plain-run time for the per-mutant
timeout. See run_mutations for full rationale.

`mutant_timeout`: explicit per-mutant timeout override. Bypasses derivation.
"""
function run_mutations_warm(
    pkgdir::AbstractString,
    sites::Vector{MutationSite},
    cmap::CoverageMap;
    test_dir::AbstractString     = "test",
    test_file::AbstractString    = "runtests.jl",
    baseline_elapsed::Union{Float64, Nothing} = nothing,
    timeout_multiplier::Float64  = 3.0,
    coverage_overhead::Float64   = 2.5,
    mutant_timeout::Union{Float64, Nothing} = nothing,
    n_workers::Union{Int, Nothing} = nothing,  # API compat — warm uses 1 worker
    verbose::Bool                = false,
    cache::Union{MutantCache, Nothing} = nothing,
    pkg_name::Union{String, Nothing} = nothing,
)::WarmRunResult
    pkgdir = abspath(pkgdir)

    # Infer package name from Project.toml if not provided
    if isnothing(pkg_name)
        pkg_name = _infer_pkg_name(pkgdir)
    end

    # Establish baseline
    if isnothing(baseline_elapsed)
        verbose && println("[gremlins/warm] Running baseline...")
        elapsed_b, _ = baseline_run(pkgdir; test_dir=test_dir, test_file=test_file)
        baseline_elapsed = elapsed_b
        verbose && println("[gremlins/warm] Baseline: $(round(elapsed_b, digits=2))s")
    end

    # Derive per-mutant timeout (same logic as run_mutations — coverage overhead aware)
    derived_timeout = if !isnothing(mutant_timeout)
        mutant_timeout
    else
        est_plain = baseline_elapsed / coverage_overhead
        max(COLD_START_TIMEOUT_FLOOR, est_plain * timeout_multiplier)
    end
    if verbose
        if !isnothing(mutant_timeout)
            println("[gremlins/warm] Mutant timeout: $(round(derived_timeout, digits=1))s (explicit override)")
        else
            est_plain = baseline_elapsed / coverage_overhead
            println("[gremlins/warm] baseline (coverage) $(round(baseline_elapsed, digits=2))s, " *
                    "estimated plain ≈ $(round(est_plain, digits=2))s (÷$(coverage_overhead)), " *
                    "derived mutant timeout $(round(derived_timeout, digits=1))s")
        end
    end
    actual_mutant_timeout = derived_timeout

    # Sort sites deterministically (I2)
    sorted_sites = sort(sites, by = s -> s.id)

    # Determine warm test file (prefer _warm.jl variant)
    warm_test_path = _find_warm_test_file(pkgdir, test_dir, test_file)
    verbose && println("[gremlins/warm] Warm test : $warm_test_path")

    warm_results   = WarmMutantResult[]
    taxonomy       = Dict{FallbackReason, Int}()
    warm_ran       = WarmMutantResult[]   # track warm-executed for I4
    cache_hits     = 0
    worker_recycles = 0
    run_t0         = time()

    # Create shadow copy ONCE — cold fallbacks run in shadow, real tree never written (I1)
    shadow = _make_shadow(pkgdir)
    verbose && println("[gremlins/warm] Shadow copy at: $shadow")
    shadow_test_path = joinpath(shadow, test_dir, test_file)

    # Start worker
    worker = nothing
    if !isnothing(pkg_name)
        worker = _spawn_worker(pkgdir, pkg_name)
        if isnothing(worker)
            verbose && println("[gremlins/warm] WARNING: worker spawn failed; all mutants run cold")
        else
            verbose && println("[gremlins/warm] Worker started (pkg=$pkg_name)")
        end
    end

    try
        for (i, site) in enumerate(sorted_sites)
            # Coverage check
            if !is_covered(cmap, site)
                if verbose
                    println("[gremlins/warm] [$i/$(length(sorted_sites))] $(site.id[1:8])… no_coverage")
                    flush(stdout)
                end
                base = MutantResult(site, no_coverage, 0.0, "")
                wr = WarmMutantResult(base, warm_ok, 0.0, 0.0)
                push!(warm_results, wr)
                _tally!(taxonomy, warm_ok)
                continue
            end

            # Cache check (reads real source for content hash — cache stays real-side)
            if !isnothing(cache)
                abs_path = _find_abs_path_or_throw(pkgdir, site)
                src_content = try; read(abs_path, String); catch; ""; end
                cached = cache_get(cache, src_content, site.id)
                if !isnothing(cached)
                    cache_hits += 1
                    base = MutantResult(site, cached.outcome, cached.elapsed, "")
                    wr = WarmMutantResult(base, warm_ok, 0.0, 0.0)
                    push!(warm_results, wr)
                    if verbose
                        println("[gremlins/warm] [$i/$(length(sorted_sites))] $(site.id[1:8])… cache_hit ($(cached.outcome))")
                        flush(stdout)
                    end
                    _tally!(taxonomy, warm_ok)
                    continue
                end
            end

            # Static warm eligibility
            elig = classify_warm_eligibility(site, pkgdir)

            if !elig.eligible
                if verbose
                    println("[gremlins/warm] [$i/$(length(sorted_sites))] $(site.id[1:8])… cold ($(elig.reason))")
                    flush(stdout)
                end
                cold_outcome, cold_elapsed, cold_err = _run_cold_single(site, pkgdir, shadow, shadow_test_path, actual_mutant_timeout)
                base = MutantResult(site, cold_outcome, cold_elapsed, cold_err)
                wr = WarmMutantResult(base, elig.reason, 0.0, cold_elapsed)
                push!(warm_results, wr)
                _tally!(taxonomy, elig.reason)
                if !isnothing(cache)
                    abs_path = _find_abs_path_or_throw(pkgdir, site)
                    src_content = try; read(abs_path, String); catch; ""; end
                    cache_put!(cache, src_content, site.id, cold_outcome, cold_elapsed)
                end
                continue
            end

            # Warm path — requires worker
            abs_path = try
                _find_abs_path_or_throw(pkgdir, site)
            catch e
                base = MutantResult(site, error, 0.0, "cannot locate source: $e")
                wr = WarmMutantResult(base, fallback_evalerr, 0.0, 0.0)
                push!(warm_results, wr)
                _tally!(taxonomy, fallback_evalerr)
                continue
            end

            src_content = try
                read(abs_path, String)
            catch e
                base = MutantResult(site, error, 0.0, "cannot read source: $e")
                wr = WarmMutantResult(base, fallback_evalerr, 0.0, 0.0)
                push!(warm_results, wr)
                _tally!(taxonomy, fallback_evalerr)
                continue
            end

            mutated_content = try
                apply(site, src_content)
            catch e
                base = MutantResult(site, error, 0.0, "apply failed: $e")
                wr = WarmMutantResult(base, fallback_evalerr, 0.0, 0.0)
                push!(warm_results, wr)
                _tally!(taxonomy, fallback_evalerr)
                continue
            end

            # Check worker recycle threshold
            if !isnothing(worker) && worker.alive &&
               worker.mutants_served >= WORKER_RECYCLE_INTERVAL
                verbose && println("[gremlins/warm] Recycling worker at $(worker.mutants_served) mutants")
                _send_request(worker, "{\"cmd\":\"exit\"}", 5.0)
                _kill_worker!(worker)
                worker = _spawn_worker(pkgdir, pkg_name)
                worker_recycles += 1
                if isnothing(worker)
                    verbose && println("[gremlins/warm] WARNING: worker re-spawn failed")
                end
            end

            # Attempt warm execution
            ran_warm = false
            if !isnothing(worker) && worker.alive
                if verbose
                    print("[gremlins/warm] [$i/$(length(sorted_sites))] $(site.id[1:8])… warm ")
                    flush(stdout)
                end

                outcome, warm_elapsed, errmsg, fallback_r = _run_mutant_via_worker(
                    worker, abs_path, mutated_content, src_content, site, warm_test_path, actual_mutant_timeout
                )

                if fallback_r == fallback_evalerr
                    # Dynamic fallback: error in worker → cold re-run in shadow
                    if verbose
                        print("→ fallback_evalerr, cold ")
                        flush(stdout)
                    end
                    # Recycle worker on error (state may be contaminated)
                    if !isnothing(worker) && worker.alive
                        _send_request(worker, "{\"cmd\":\"exit\"}", 3.0)
                        _kill_worker!(worker)
                        worker = _spawn_worker(pkgdir, pkg_name)
                        worker_recycles += 1
                        if isnothing(worker)
                            verbose && println("[gremlins/warm] WARNING: worker re-spawn after fallback failed")
                        end
                    end
                    cold_outcome, cold_elapsed, cold_err = _run_cold_single(site, pkgdir, shadow, shadow_test_path, actual_mutant_timeout)
                    base = MutantResult(site, cold_outcome, cold_elapsed, cold_err)
                    wr = WarmMutantResult(base, fallback_evalerr, 0.0, cold_elapsed)
                    push!(warm_results, wr)
                    _tally!(taxonomy, fallback_evalerr)
                    if verbose
                        println(string(cold_outcome))
                        flush(stdout)
                    end
                    if !isnothing(cache)
                        cache_put!(cache, src_content, site.id, cold_outcome, cold_elapsed)
                    end
                    continue
                end

                # Warm execution succeeded
                base = MutantResult(site, outcome, warm_elapsed, errmsg)
                wr = WarmMutantResult(base, warm_ok, warm_elapsed, 0.0)
                push!(warm_results, wr)
                push!(warm_ran, wr)
                _tally!(taxonomy, warm_ok)
                if verbose
                    println(string(outcome), " ($(round(warm_elapsed, digits=2))s)")
                    flush(stdout)
                end
                if !isnothing(cache)
                    cache_put!(cache, src_content, site.id, outcome, warm_elapsed)
                end
                ran_warm = true
            end

            # Fallback: no worker available — run cold in shadow
            if !ran_warm
                if verbose
                    print("[gremlins/warm] [$i/$(length(sorted_sites))] $(site.id[1:8])… cold (no_worker) ")
                    flush(stdout)
                end
                cold_outcome, cold_elapsed, cold_err = _run_cold_single(site, pkgdir, shadow, shadow_test_path, actual_mutant_timeout)
                base = MutantResult(site, cold_outcome, cold_elapsed, cold_err)
                wr = WarmMutantResult(base, fallback_evalerr, 0.0, cold_elapsed)
                push!(warm_results, wr)
                _tally!(taxonomy, fallback_evalerr)
                if verbose
                    println(string(cold_outcome))
                    flush(stdout)
                end
                if !isnothing(cache)
                    cache_put!(cache, src_content, site.id, cold_outcome, cold_elapsed)
                end
            end
        end

        total_elapsed = time() - run_t0

        # Shut down worker
        if !isnothing(worker) && worker.alive
            _send_request(worker, "{\"cmd\":\"exit\"}", 5.0)
            _kill_worker!(worker)
            worker = nothing
        end

        # I4 agreement invariant — sample min(10, N) warm-ran mutants, re-run cold in shadow
        # Gate spec: ≥10 sampled. We sample min(10, N) to bound I4 overhead.
        i4_mismatches = String[]
        n_sample = min(10, length(warm_ran))
        sample = warm_ran[1:n_sample]

        verbose && println("[gremlins/warm] I4 agreement check: sampling $(length(sample)) warm-ran mutants cold (in shadow)...")
        for wr in sample
            site = wr.base.site
            cold_outcome2, _, _ = try
                _run_cold_single(site, pkgdir, shadow, shadow_test_path, actual_mutant_timeout)
            catch
                continue
            end
            if cold_outcome2 != wr.base.outcome
                push!(i4_mismatches,
                    "I4 MISMATCH: site=$(site.id[1:8]) warm=$(wr.base.outcome) cold=$(cold_outcome2)")
                verbose && println("[gremlins/warm] WARNING: $(i4_mismatches[end])")
            end
        end

        # Assemble base RunResult from warm_results
        base_results = [wr.base for wr in warm_results]
        run_result = RunResult(pkgdir, sorted_sites, base_results, baseline_elapsed, total_elapsed)

        return WarmRunResult(
            run_result,
            warm_results,
            taxonomy,
            length(sample),
            i4_mismatches,
            cache_hits,
            worker_recycles,
        )
    finally
        # Shut down worker if still alive (e.g. error path)
        if !isnothing(worker) && worker.alive
            try; _send_request(worker, "{\"cmd\":\"exit\"}", 3.0); catch; end
            _kill_worker!(worker)
        end
        # Clean up shadow
        rm(shadow; recursive=true, force=true)
    end
end

# ─── Internal helpers ─────────────────────────────────────────────────────────

"""
Run one mutant on the cold path, returning (outcome, elapsed, errmsg).

`shadow_dir`: disposable shadow copy of pkgdir (created once by the caller).
Mutations are applied to the shadow file; the real tree is never touched (I1).
In-shadow revert after each mutant keeps the shadow valid for the next call.
`shadow_test_path`: test file path inside the shadow.
"""
function _run_cold_single(
    site::MutationSite,
    pkgdir::AbstractString,
    shadow_dir::AbstractString,
    shadow_test_path::AbstractString,
    timeout_secs::Float64,
)::Tuple{MutantOutcome, Float64, String}
    real_abs_path = try
        _find_abs_path_or_throw(pkgdir, site)
    catch e
        return (error, 0.0, "cannot locate source: $e")
    end

    shadow_abs_path = try
        _shadow_abs_path(pkgdir, shadow_dir, real_abs_path)
    catch e
        return (error, 0.0, "shadow path error: $e")
    end

    shadow_original_src = try
        read(shadow_abs_path, String)
    catch e
        return (error, 0.0, "cannot read shadow source: $e")
    end

    outcome   = survived
    err_msg   = ""
    mutant_t0 = time()

    try
        apply!(site, shadow_abs_path)
        jl = _julia_exe()
        cmd = Cmd([jl, "--project=$shadow_dir", shadow_test_path])
        exit_code, _ = _run_with_timeout(cmd, timeout_secs)

        outcome = if exit_code == :timeout
            timeout
        elseif exit_code != 0
            killed
        else
            survived
        end
    catch e
        outcome = error
        err_msg = sprint(showerror, e)
    finally
        # In-shadow restoration (hygiene — keeps shadow valid for next mutant)
        # Real tree was never touched; SIGKILL at this point leaves harmless tmp garbage.
        try
            _atomic_write(shadow_abs_path, shadow_original_src)
        catch restore_err
            @warn "[gremlins/warm] Failed to restore shadow source" path=shadow_abs_path err=restore_err
        end
    end

    elapsed = time() - mutant_t0
    return (outcome, elapsed, err_msg)
end

"""Throw if source file cannot be located."""
function _find_abs_path_or_throw(pkgdir::AbstractString, site::MutationSite)::String
    p = _find_abs_path(pkgdir, site)
    p !== nothing && return p
    throw(MutationError("cannot locate source file for site $(site.id): relpath=$(site.relpath)"))
end

"""Increment taxonomy counter."""
function _tally!(d::Dict{FallbackReason, Int}, r::FallbackReason)
    d[r] = get(d, r, 0) + 1
end

"""
    _infer_pkg_name(pkgdir) -> Union{String, Nothing}

Read the package name from Project.toml in pkgdir.
"""
function _infer_pkg_name(pkgdir::AbstractString)::Union{String, Nothing}
    toml_path = joinpath(pkgdir, "Project.toml")
    isfile(toml_path) || return nothing
    content = try; read(toml_path, String); catch; return nothing; end
    m = match(r"""^name\s*=\s*"([^"]+)"""m, content)
    m === nothing && return nothing
    return m.captures[1]
end

"""
    _find_warm_test_file(pkgdir, test_dir, test_file) -> String

Return the warm-path test file path. If a `<stem>_warm.jl` variant exists
alongside `test_file`, return its path; otherwise return the standard path.

Warm variants use `using PkgName` instead of `include(src)` so the worker's
eval-into-module works correctly.
"""
function _find_warm_test_file(
    pkgdir::AbstractString,
    test_dir::AbstractString,
    test_file::AbstractString,
)::String
    base = test_file
    stem, ext = splitext(base)
    warm_file = stem * "_warm" * ext
    warm_path = joinpath(pkgdir, test_dir, warm_file)
    isfile(warm_path) && return warm_path
    return joinpath(pkgdir, test_dir, test_file)
end

# ─── High-level entry point ───────────────────────────────────────────────────

"""
    mutate_warm(pkgdir;
                src_dir="src",
                test_dir="test", test_file="runtests.jl",
                operators=DEFAULT_OPERATORS,
                timeout_multiplier=3.0,
                baseline_timeout=600.0,
                coverage_overhead=2.5,
                mutant_timeout=nothing,
                max_mutants=nothing,
                files=nothing,
                n_workers=nothing,
                verbose=false,
                use_cache=true,
                pkg_name=nothing) -> WarmRunResult

High-level entry point for warm-pool mutation run.
Discovers mutations, runs baseline, executes all mutants with warm-pool + cache.

`baseline_timeout`: timeout in seconds for the baseline test run (default 600.0).

`coverage_overhead`: factor by which `--code-coverage=user` inflates the baseline
elapsed time (default 2.5). Used to estimate plain-run time for mutant timeouts.

`mutant_timeout`: explicit per-mutant timeout override. Bypasses derivation.

`max_mutants`: cap the number of mutation sites (deterministic round-robin).

`files`: restrict to sites whose relpath matches any entry (same normalization as
CLI `--files`: strips leading `./`, backslash→slash, basename or suffix match).
"""
function mutate_warm(
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
    n_workers::Union{Int, Nothing} = nothing,
    verbose::Bool                 = false,
    use_cache::Bool               = true,
    pkg_name::Union{String, Nothing} = nothing,
)::WarmRunResult
    pkgdir = abspath(pkgdir)
    verbose && println("[gremlins/warm] Discovering mutations in $(joinpath(pkgdir, src_dir))...")

    sites = discover(joinpath(pkgdir, src_dir); operators=operators, root=pkgdir)
    verbose && println("[gremlins/warm] Discovered $(length(sites)) mutation sites")

    # Apply files filter (same normalization as CLI --files)
    if !isnothing(files) && !isempty(files)
        sites = _filter_sites_by_files(sites, files)
        verbose && println("[gremlins/warm] After files filter: $(length(sites)) sites")
    end

    # Apply max_mutants cap with deterministic round-robin sampling
    if !isnothing(max_mutants) && length(sites) > max_mutants
        sites = _sample_sites_round_robin(sites, max_mutants)
        verbose && println("[gremlins/warm] Capped to $(length(sites)) sites (max_mutants=$max_mutants)")
    end

    verbose && println("[gremlins/warm] Running baseline test suite...")
    baseline_elapsed, cmap = baseline_run(pkgdir; test_dir=test_dir, test_file=test_file, timeout=baseline_timeout)
    verbose && println("[gremlins/warm] Baseline: $(round(baseline_elapsed, digits=2))s")

    cache = use_cache ? load_cache(pkgdir) : nothing

    result = run_mutations_warm(pkgdir, sites, cmap;
        test_dir=test_dir,
        test_file=test_file,
        baseline_elapsed=baseline_elapsed,
        timeout_multiplier=timeout_multiplier,
        coverage_overhead=coverage_overhead,
        mutant_timeout=mutant_timeout,
        n_workers=n_workers,
        verbose=verbose,
        cache=cache,
        pkg_name=pkg_name,
    )

    if !isnothing(cache) && use_cache
        save_cache(cache)
    end

    return result
end
