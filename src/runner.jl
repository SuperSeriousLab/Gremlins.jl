# runner.jl — Process-per-mutant execution engine for Gremlins.jl
#
# Public API:
#   MutantResult         — outcome for one mutant
#   RunResult            — full run outcome (all mutants)
#   run_mutations(pkgdir, sites, cmap; ...) -> RunResult
#
# Invariants:
#   I1  — Source is ALWAYS restored: apply!/revert! wrapped in try/finally.
#          A crashed run must never leave mutated source on disk.
#   I2  — Deterministic: mutants processed in sorted order (id).
#   I3  — Timeout = 3× baseline elapsed (configurable).

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
    s = _score(r)
    print(io, "RunResult($(length(r.results)) mutants, score=$(round(s*100, digits=1))%)")
end

# ─── Mutation score ────────────────────────────────────────────────────────────

"""
    mutation_score(r::RunResult) -> Float64

Mutation score = killed / (total - no_coverage - error).
Returns NaN if the denominator is 0.
"""
function mutation_score(r::RunResult)::Float64
    return _score(r)
end

function _score(r::RunResult)::Float64
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
                  verbose=false) -> RunResult

For each `MutationSite` in `sites` (processed in sorted id order):
1. Check coverage — skip to `:no_coverage` if site's line not covered.
2. Apply the mutation to the source file.
3. Run the test suite as a subprocess.
4. Classify outcome.
5. ALWAYS revert the source (try/finally).

`baseline_elapsed`: if provided, timeout = baseline_elapsed × timeout_multiplier.
If not provided, a new baseline run is performed.
"""
function run_mutations(
    pkgdir::AbstractString,
    sites::Vector{MutationSite},
    cmap::CoverageMap;
    test_dir::AbstractString     = "test",
    test_file::AbstractString    = "runtests.jl",
    baseline_elapsed::Union{Float64, Nothing} = nothing,
    timeout_multiplier::Float64  = 3.0,
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

    mutant_timeout = max(10.0, baseline_elapsed * timeout_multiplier)
    verbose && println("[gremlins] Mutant timeout: $(round(mutant_timeout, digits=1))s ($(timeout_multiplier)x baseline)")

    # Sort sites deterministically by id
    sorted_sites = sort(sites, by = s -> s.id)

    test_path = joinpath(pkgdir, test_dir, test_file)
    jl = _julia_exe()

    results = MutantResult[]
    run_t0 = time()

    for (i, site) in enumerate(sorted_sites)
        # 1. Coverage check
        if !is_covered(cmap, site)
            verbose && println("[gremlins] [$i/$(length(sorted_sites))] $(site.id[1:8])… no_coverage")
            push!(results, MutantResult(site, no_coverage, 0.0, ""))
            continue
        end

        verbose && print("[gremlins] [$i/$(length(sorted_sites))] $(site.id[1:8])… ")

        # 2. Determine the full path to mutate
        abs_path = _site_abs_path(pkgdir, site)

        mutant_t0 = time()
        outcome   = survived   # default: assume survived
        err_msg   = ""

        original_src = try
            read(abs_path, String)
        catch e
            push!(results, MutantResult(site, error, 0.0, "cannot read source: $e"))
            verbose && println("error (read)")
            continue
        end

        # 3. Apply mutation + run + revert (I1: ALWAYS revert)
        try
            apply!(site, abs_path)

            # 4. Run test subprocess
            cmd = Cmd([jl, "--project=$pkgdir", test_path])
            exit_code, _ = _run_with_timeout(cmd, mutant_timeout)

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
            # 5. ALWAYS restore original — crashes must not leave mutated source
            try
                _atomic_write(abs_path, original_src)
            catch restore_err
                # If restore fails, this is critical — surface it loudly
                @error "CRITICAL: failed to restore source after mutation" path=abs_path err=restore_err
            end
        end

        elapsed = time() - mutant_t0
        push!(results, MutantResult(site, outcome, elapsed, err_msg))
        verbose && println(string(outcome), " ($(round(elapsed, digits=2))s)")
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
           verbose=false) -> RunResult

High-level entry point: discover mutations, run baseline, execute all mutants.
"""
function mutate(
    pkgdir::AbstractString;
    src_dir::AbstractString       = "src",
    test_dir::AbstractString      = "test",
    test_file::AbstractString     = "runtests.jl",
    operators::Vector{MutationOperator} = DEFAULT_OPERATORS,
    timeout_multiplier::Float64   = 3.0,
    verbose::Bool                 = false,
)::RunResult
    pkgdir = abspath(pkgdir)
    verbose && println("[gremlins] Discovering mutations in $(joinpath(pkgdir, src_dir))...")

    # root=pkgdir ensures relpaths are relative to pkgdir (matching coverage map keys)
    sites = discover(joinpath(pkgdir, src_dir); operators=operators, root=pkgdir)
    verbose && println("[gremlins] Discovered $(length(sites)) mutation sites")

    verbose && println("[gremlins] Running baseline test suite...")
    baseline_elapsed, cmap = baseline_run(pkgdir;
        test_dir=test_dir, test_file=test_file)
    verbose && println("[gremlins] Baseline: $(round(baseline_elapsed, digits=2))s  coverage: $cmap")

    return run_mutations(pkgdir, sites, cmap;
        test_dir=test_dir,
        test_file=test_file,
        baseline_elapsed=baseline_elapsed,
        timeout_multiplier=timeout_multiplier,
        verbose=verbose)
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
