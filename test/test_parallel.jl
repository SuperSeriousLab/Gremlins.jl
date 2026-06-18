# test_parallel.jl — Issue #7: parallel mutant execution correctness gate
#
# Core guarantee: run_mutations(...; parallel=4) produces IDENTICAL per-site
# outcomes to run_mutations(...; parallel=1) for every site.
#
# Also verifies: parallel kwarg accepted, sequential default unchanged.
#
# These tests are subprocess-heavy (each spawns julia subprocesses); they are
# expected to take a few minutes. That is intentional — this is the correctness
# gate for the parallel path.

using Test
using Gremlins

const PARALLEL_FIXTURE_DIR = joinpath(@__DIR__, "fixtures", "MiniTarget")
const PARALLEL_MUTANT_TIMEOUT = 300.0  # generous fixed budget, avoids load-sensitive flap

# ─── RED phase check: parallel kwarg must exist ────────────────────────────────
# This test fails until parallel= is wired into run_mutations.
@testset "Gremlins parallel — kwarg accepted" begin
    # Verify the kwarg exists by calling with parallel=1 (should be a no-op).
    # If the kwarg is missing this throws MethodError at call-site.
    baseline_elapsed, cmap = baseline_run(PARALLEL_FIXTURE_DIR;
        test_dir="test", test_file="runtests.jl")
    sites = discover(joinpath(PARALLEL_FIXTURE_DIR, "src");
        operators=[OP_PLUS_TO_MINUS, OP_GT_TO_GE],
        root=PARALLEL_FIXTURE_DIR)
    result = run_mutations(PARALLEL_FIXTURE_DIR, sites, cmap;
        test_dir="test", test_file="runtests.jl",
        baseline_elapsed=baseline_elapsed,
        mutant_timeout=PARALLEL_MUTANT_TIMEOUT,
        parallel=1)   # RED: parallel kwarg must exist
    @test result isa RunResult
end

# ─── Core determinism test: parallel==sequential outcomes ─────────────────────
# Run the SAME campaign twice: once sequential (parallel=1), once parallel=4.
# Assert every site has the SAME outcome (keyed by site id).
@testset "Gremlins parallel — parallel==sequential outcomes" begin
    baseline_elapsed, cmap = baseline_run(PARALLEL_FIXTURE_DIR;
        test_dir="test", test_file="runtests.jl")

    # Use two operators: OP_PLUS_TO_MINUS (killed) + OP_GT_TO_GE (survived)
    # This ensures both killed and survived outcomes appear in both runs.
    sites = discover(joinpath(PARALLEL_FIXTURE_DIR, "src");
        operators=[OP_PLUS_TO_MINUS, OP_GT_TO_GE],
        root=PARALLEL_FIXTURE_DIR)

    @test !isempty(sites)

    result_seq = run_mutations(PARALLEL_FIXTURE_DIR, sites, cmap;
        test_dir="test", test_file="runtests.jl",
        baseline_elapsed=baseline_elapsed,
        mutant_timeout=PARALLEL_MUTANT_TIMEOUT,
        parallel=1)

    result_par = run_mutations(PARALLEL_FIXTURE_DIR, sites, cmap;
        test_dir="test", test_file="runtests.jl",
        baseline_elapsed=baseline_elapsed,
        mutant_timeout=PARALLEL_MUTANT_TIMEOUT,
        parallel=4)

    # Same number of results
    @test length(result_seq.results) == length(result_par.results)

    # Results must be in the same order (same sites order)
    @test [r.site.id for r in result_seq.results] == [r.site.id for r in result_par.results]

    # Per-site outcomes must be identical
    seq_outcomes = Dict(r.site.id => r.outcome for r in result_seq.results)
    par_outcomes = Dict(r.site.id => r.outcome for r in result_par.results)

    for id in keys(seq_outcomes)
        @test haskey(par_outcomes, id)
        seq_o = seq_outcomes[id]
        par_o = par_outcomes[id]
        if seq_o != par_o
            @error "Outcome mismatch for site $id: seq=$seq_o par=$par_o"
        end
        @test seq_o == par_o
    end

    # Additional sanity: both runs return a RunResult with all sites
    @test result_seq.sites == result_par.sites
    @test length(result_seq.results) == length(sites)
    @test length(result_par.results) == length(sites)

    # Verify expected outcomes are present (kills for plus, survived for gt boundary)
    @test any(r -> r.outcome == killed,   result_seq.results)
    @test any(r -> r.outcome == survived, result_seq.results)
    @test any(r -> r.outcome == killed,   result_par.results)
    @test any(r -> r.outcome == survived, result_par.results)
end

# ─── Sequential regression: parallel=1 does not change existing behavior ──────
# This piggy-backs on the identical-outcomes test above; here we explicitly
# assert the sequential result matches the existing M1 expectations.
@testset "Gremlins parallel — sequential regression (parallel=1 unchanged)" begin
    baseline_elapsed, cmap = baseline_run(PARALLEL_FIXTURE_DIR;
        test_dir="test", test_file="runtests.jl")

    sites_plus = discover(joinpath(PARALLEL_FIXTURE_DIR, "src");
        operators=[OP_PLUS_TO_MINUS],
        root=PARALLEL_FIXTURE_DIR)
    result_plus = run_mutations(PARALLEL_FIXTURE_DIR, sites_plus, cmap;
        test_dir="test", test_file="runtests.jl",
        baseline_elapsed=baseline_elapsed,
        mutant_timeout=PARALLEL_MUTANT_TIMEOUT,
        parallel=1)
    # add() uses +, OP_PLUS_TO_MINUS changes it to -, test catches this → killed
    @test any(r -> r.outcome == killed, result_plus.results)

    sites_gt = discover(joinpath(PARALLEL_FIXTURE_DIR, "src");
        operators=[OP_GT_TO_GE],
        root=PARALLEL_FIXTURE_DIR)
    result_gt = run_mutations(PARALLEL_FIXTURE_DIR, sites_gt, cmap;
        test_dir="test", test_file="runtests.jl",
        baseline_elapsed=baseline_elapsed,
        mutant_timeout=PARALLEL_MUTANT_TIMEOUT,
        parallel=1)
    # is_positive() boundary gap → survived
    @test any(r -> r.outcome == survived, result_gt.results)
end

# ─── No-coverage sites: classified directly without consuming a shadow ─────────
@testset "Gremlins parallel — no_coverage sites handled correctly" begin
    baseline_elapsed, cmap = baseline_run(PARALLEL_FIXTURE_DIR;
        test_dir="test", test_file="runtests.jl")

    # Discover all sites (some may not be covered)
    sites = discover(joinpath(PARALLEL_FIXTURE_DIR, "src");
        operators=DEFAULT_OPERATORS,
        root=PARALLEL_FIXTURE_DIR)

    result_seq = run_mutations(PARALLEL_FIXTURE_DIR, sites, cmap;
        test_dir="test", test_file="runtests.jl",
        baseline_elapsed=baseline_elapsed,
        mutant_timeout=PARALLEL_MUTANT_TIMEOUT,
        parallel=1)

    result_par = run_mutations(PARALLEL_FIXTURE_DIR, sites, cmap;
        test_dir="test", test_file="runtests.jl",
        baseline_elapsed=baseline_elapsed,
        mutant_timeout=PARALLEL_MUTANT_TIMEOUT,
        parallel=4)

    # Fixture guarantee: multiply() is never called by the test suite, so at least
    # one no_coverage site must arise. This makes the testset falsifiable — if
    # every site were covered, the equality below would pass vacuously.
    n_nocov_seq = count(r -> r.outcome == no_coverage, result_seq.results)
    n_nocov_par = count(r -> r.outcome == no_coverage, result_par.results)
    @test n_nocov_seq > 0          # fixture must have ≥1 uncovered site
    @test n_nocov_seq == n_nocov_par

    # All outcomes must match per site
    seq_outcomes = Dict(r.site.id => r.outcome for r in result_seq.results)
    par_outcomes = Dict(r.site.id => r.outcome for r in result_par.results)
    for id in keys(seq_outcomes)
        @test get(par_outcomes, id, nothing) == seq_outcomes[id]
    end
end
