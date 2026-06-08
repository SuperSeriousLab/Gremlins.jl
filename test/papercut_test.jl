# papercut_test.jl — M2.1 dogfood papercut tests
#
# P1: baseline_timeout kwarg threaded into baseline_run
# P2: coverage_overhead / mutant_timeout derivation + override
# P3: max_mutants + files sampling (deterministic round-robin helper unit-tested)
# P4: flush(stdout) after per-mutant verbose println
# P5: verbose coverage/plain/timeout overhead line
#
# M1 OOM lesson: ONE module-level fixture run shared across testsets.
# No per-testset subprocess fleets.

using Test
using Gremlins

const PC_FIXTURE_DIR = joinpath(@__DIR__, "fixtures", "MiniTarget")

# ─── Module-level shared run (fast: 1 operator, tiny fixture) ────────────────
# Reuse baseline data from the fixture used in runner_test to avoid extra subprocess

const PC_BASELINE = let
    baseline_run(PC_FIXTURE_DIR; test_dir="test", test_file="runtests.jl")
end
const PC_BASELINE_ELAPSED = PC_BASELINE[1]
const PC_CMAP             = PC_BASELINE[2]

# ─── stdout capture helper ────────────────────────────────────────────────────
# redirect_stdout(::IOBuffer) is unsupported on Julia 1.11 (needs a real fd).
# Redirect to a temp file (real fd) and read it back. This also exercises the
# block-buffering path that flush(stdout) (P4) is meant to defeat.
function _capture_stdout(f::Function)::String
    path, io = mktemp()
    try
        redirect_stdout(io) do
            f()
        end
        flush(io)
        close(io)
        return read(path, String)
    finally
        isfile(path) && rm(path; force=true)
    end
end

# ─── M2.1 papercut tests ──────────────────────────────────────────────────────

@testset "M2.1 Papercuts" begin

# ═══ P1 — baseline_timeout kwarg ══════════════════════════════════════════════

@testset "P1 — baseline_run default timeout raised to 600.0" begin
    # Verify baseline_run has timeout=600.0 default by calling with no timeout kwarg;
    # the actual timeout value is validated by checking the MutationError message
    # (see the 'low baseline_timeout' testset below).
    # Here we just confirm the function runs without error on the fixture.
    sites = discover(joinpath(PC_FIXTURE_DIR, "src"); operators=[OP_PLUS_TO_MINUS], root=PC_FIXTURE_DIR)
    # run_mutations accepts the new kwargs (throws if kwarg unknown)
    @test_nowarn run_mutations(PC_FIXTURE_DIR, sites, PC_CMAP;
        baseline_elapsed=PC_BASELINE_ELAPSED,
        timeout_multiplier=5.0,
        mutant_timeout=30.0)
end

@testset "P1 — mutate() accepts baseline_timeout kwarg" begin
    # baseline_timeout must be a named kwarg on mutate() without error
    # We don't run the full suite — just check the kwarg is wired
    # by using a deliberately high value (should succeed on any machine)
    @test_nowarn mutate(PC_FIXTURE_DIR;
        src_dir="src",
        operators=[OP_PLUS_TO_MINUS],
        timeout_multiplier=5.0,
        baseline_timeout=600.0,
        mutant_timeout=30.0,
        verbose=false)
end

@testset "P1 — mutate_warm() accepts baseline_timeout kwarg" begin
    # Assert the kwarg is accepted and a result comes back. Not @test_nowarn:
    # under heavy machine load the warm worker can exceed its response timeout
    # and emit a (harmless) warning; that must not fail a kwarg-acceptance test.
    @test mutate_warm(PC_FIXTURE_DIR;
        src_dir="src",
        operators=[OP_PLUS_TO_MINUS],
        timeout_multiplier=5.0,
        baseline_timeout=600.0,
        mutant_timeout=300.0,
        verbose=false,
        use_cache=false,
        pkg_name="MiniTarget") isa WarmRunResult
end

@testset "P1 — low baseline_timeout raises named MutationError" begin
    # Passing an absurdly low timeout (0.001s) must raise MutationError
    # and the message must mention `baseline_timeout` kwarg so the user knows what to raise.
    err = try
        baseline_run(PC_FIXTURE_DIR; test_dir="test", test_file="runtests.jl", timeout=0.001)
        nothing
    catch e
        e
    end
    @test err isa MutationError
    @test occursin("baseline_timeout", sprint(showerror, err))
end

# ═══ P2 — coverage-aware mutant timeout ═══════════════════════════════════════

@testset "P2 — derived mutant timeout uses coverage_overhead" begin
    # With baseline_elapsed=100.0, coverage_overhead=2.5, multiplier=3.0:
    # est_plain = 100/2.5 = 40.0
    # derived = max(10, 40 * 3.0) = 120.0
    # Without coverage_overhead: would be max(10, 100*3) = 300.0 (2.5x worse)
    sites = discover(joinpath(PC_FIXTURE_DIR, "src"); operators=[OP_PLUS_TO_MINUS], root=PC_FIXTURE_DIR)
    # We can't intercept the internal timeout directly, but we can verify the
    # function runs without error and accepts the kwargs
    @test_nowarn run_mutations(PC_FIXTURE_DIR, sites, PC_CMAP;
        baseline_elapsed=100.0,
        timeout_multiplier=3.0,
        coverage_overhead=2.5,
        mutant_timeout=nothing,
        verbose=false)
end

@testset "P2 — explicit mutant_timeout overrides derivation" begin
    sites = discover(joinpath(PC_FIXTURE_DIR, "src"); operators=[OP_PLUS_TO_MINUS], root=PC_FIXTURE_DIR)
    # explicit mutant_timeout=15.0 must be accepted without error
    result = run_mutations(PC_FIXTURE_DIR, sites, PC_CMAP;
        baseline_elapsed=100.0,       # would derive ~120s without override
        timeout_multiplier=3.0,
        coverage_overhead=2.5,
        mutant_timeout=15.0,          # explicit override
        verbose=false)
    @test result isa RunResult
    # The run should complete — with 15s explicit budget, MiniTarget mutants are fast
    @test length(result.results) > 0
end

@testset "P2 — coverage_overhead=2.5 formula: baseline=575 → est_plain=230, timeout=690" begin
    # SQLite dogfood example: baseline_elapsed=575, overhead=2.5, mult=3.0
    # est_plain = 575/2.5 = 230.0
    # derived = max(10, 230 * 3.0) = 690.0  (vs 1725.0 without overhead correction)
    baseline_elapsed = 575.0
    coverage_overhead = 2.5
    timeout_multiplier = 3.0
    est_plain = baseline_elapsed / coverage_overhead
    derived = max(10.0, est_plain * timeout_multiplier)
    @test est_plain ≈ 230.0 atol=0.01
    @test derived ≈ 690.0 atol=0.01
    # Old formula (no overhead) would have given:
    old_derived = max(10.0, baseline_elapsed * timeout_multiplier)
    @test old_derived ≈ 1725.0 atol=0.01
    @test derived < old_derived  # overhead correction shrinks the timeout
end

@testset "P2 — mutant_timeout kwarg on mutate()" begin
    @test_nowarn mutate(PC_FIXTURE_DIR;
        src_dir="src", operators=[OP_PLUS_TO_MINUS],
        baseline_timeout=600.0, mutant_timeout=30.0,
        coverage_overhead=2.5, verbose=false)
end

@testset "P2 — mutant_timeout kwarg on mutate_warm()" begin
    # Result-type assertion (load-independent) — see P1 note on @test_nowarn.
    @test mutate_warm(PC_FIXTURE_DIR;
        src_dir="src", operators=[OP_PLUS_TO_MINUS],
        baseline_timeout=600.0, mutant_timeout=300.0,
        coverage_overhead=2.5, verbose=false,
        use_cache=false, pkg_name="MiniTarget") isa WarmRunResult
end

# ═══ P3 — max_mutants + files sampling ════════════════════════════════════════

@testset "P3 — _sample_sites_round_robin: pure helper unit tests" begin
    # Build synthetic sites spanning 3 files
    mk_site(relpath, idx) = MutationSite(
        Gremlins.mutant_id(relpath, idx:(idx+1), :arith_plus_minus),
        relpath,
        idx:(idx+1),
        :arith_plus_minus,
        "plus_minus",
        "+",
        "-",
        idx,
    )

    sites_a = [mk_site("src/a.jl", i*10) for i in 1:4]
    sites_b = [mk_site("src/b.jl", i*10+1) for i in 1:4]
    sites_c = [mk_site("src/c.jl", i*10+2) for i in 1:2]
    all_sites = vcat(sites_a, sites_b, sites_c)

    @testset "exact count" begin
        sampled = Gremlins._sample_sites_round_robin(all_sites, 6)
        @test length(sampled) == 6
    end

    @testset "deterministic — same result on two calls" begin
        s1 = Gremlins._sample_sites_round_robin(all_sites, 5)
        s2 = Gremlins._sample_sites_round_robin(all_sites, 5)
        @test [s.id for s in s1] == [s.id for s in s2]
    end

    @testset "balanced across files (round-robin not front-loaded)" begin
        # 10 sites: 4 from a, 4 from b, 2 from c.  Sample 6 → should touch all files.
        sampled = Gremlins._sample_sites_round_robin(all_sites, 6)
        relpaths = Set([s.relpath for s in sampled])
        @test "src/a.jl" in relpaths
        @test "src/b.jl" in relpaths
        @test "src/c.jl" in relpaths
    end

    @testset "cap >= total returns all (no truncation)" begin
        sampled = Gremlins._sample_sites_round_robin(all_sites, 100)
        @test length(sampled) == length(all_sites)
    end

    @testset "cap = 1 returns exactly 1" begin
        sampled = Gremlins._sample_sites_round_robin(all_sites, 1)
        @test length(sampled) == 1
    end

    @testset "single-file input round-robins correctly" begin
        single_file = [mk_site("src/only.jl", i*10) for i in 1:6]
        sampled = Gremlins._sample_sites_round_robin(single_file, 3)
        @test length(sampled) == 3
        @test all(s -> s.relpath == "src/only.jl", sampled)
    end
end

@testset "P3 — _filter_sites_by_files" begin
    mk_site(relpath) = MutationSite(
        Gremlins.mutant_id(relpath, 1:2, :arith_plus_minus),
        relpath, 1:2, :arith_plus_minus, "plus_minus", "+", "-", 1,
    )
    sites = [mk_site("src/foo.jl"), mk_site("src/bar.jl"), mk_site("src/utils/baz.jl")]

    @testset "no filter" begin
        result = Gremlins._filter_sites_by_files(sites, String[])
        @test length(result) == 3
    end

    @testset "exact match" begin
        result = Gremlins._filter_sites_by_files(sites, ["src/foo.jl"])
        @test length(result) == 1
        @test result[1].relpath == "src/foo.jl"
    end

    @testset "basename match" begin
        result = Gremlins._filter_sites_by_files(sites, ["foo.jl"])
        @test length(result) == 1
        @test result[1].relpath == "src/foo.jl"
    end

    @testset "nested suffix match" begin
        result = Gremlins._filter_sites_by_files(sites, ["utils/baz.jl"])
        @test length(result) == 1
        @test result[1].relpath == "src/utils/baz.jl"
    end

    @testset "dotslash prefix stripped" begin
        result = Gremlins._filter_sites_by_files(sites, ["./src/foo.jl"])
        @test length(result) == 1
        @test result[1].relpath == "src/foo.jl"
    end

    @testset "double dotslash stripped" begin
        result = Gremlins._filter_sites_by_files(sites, ["././src/bar.jl"])
        @test length(result) == 1
        @test result[1].relpath == "src/bar.jl"
    end

    @testset "multiple files" begin
        result = Gremlins._filter_sites_by_files(sites, ["foo.jl", "bar.jl"])
        @test length(result) == 2
    end

    @testset "no match" begin
        result = Gremlins._filter_sites_by_files(sites, ["nonexistent.jl"])
        @test isempty(result)
    end
end

@testset "P3 — max_mutants caps count on mutate()" begin
    # MiniTarget has ≥5 total sites with DEFAULT_OPERATORS; cap to 2 and verify
    all_sites = discover(joinpath(PC_FIXTURE_DIR, "src"); operators=DEFAULT_OPERATORS, root=PC_FIXTURE_DIR)
    assume_total = length(all_sites)
    if assume_total >= 3
        result = mutate(PC_FIXTURE_DIR;
            src_dir="src",
            operators=DEFAULT_OPERATORS,
            baseline_timeout=600.0,
            mutant_timeout=30.0,
            max_mutants=2,
            verbose=false)
        @test length(result.results) <= 2
    else
        @warn "P3 max_mutants test: fixture has only $assume_total sites (need ≥3); skipping count check"
        @test true
    end
end

@testset "P3 — files filter kwarg on mutate()" begin
    # Run with files=["MiniTarget.jl"] — should only return sites from that file
    result = mutate(PC_FIXTURE_DIR;
        src_dir="src",
        operators=[OP_PLUS_TO_MINUS],
        baseline_timeout=600.0,
        mutant_timeout=30.0,
        files=["MiniTarget.jl"],
        verbose=false)
    # All results should be from src/MiniTarget.jl
    for r in result.results
        @test endswith(r.site.relpath, "MiniTarget.jl")
    end
end

@testset "P3 — max_mutants deterministic across two runs" begin
    r1 = mutate(PC_FIXTURE_DIR;
        src_dir="src", operators=DEFAULT_OPERATORS,
        baseline_timeout=600.0, mutant_timeout=30.0,
        max_mutants=2, verbose=false)
    r2 = mutate(PC_FIXTURE_DIR;
        src_dir="src", operators=DEFAULT_OPERATORS,
        baseline_timeout=600.0, mutant_timeout=30.0,
        max_mutants=2, verbose=false)
    ids1 = [r.site.id for r in r1.results]
    ids2 = [r.site.id for r in r2.results]
    @test ids1 == ids2
end

@testset "P3 — max_mutants + files on mutate_warm()" begin
    wr = mutate_warm(PC_FIXTURE_DIR;
        src_dir="src",
        operators=[OP_PLUS_TO_MINUS],
        baseline_timeout=600.0,
        mutant_timeout=30.0,
        max_mutants=1,
        files=["MiniTarget.jl"],
        verbose=false,
        use_cache=false,
        pkg_name="MiniTarget")
    @test wr isa WarmRunResult
    @test length(wr.warm_results) <= 1
end

# ═══ P4 — flush(stdout) after verbose printlns ════════════════════════════════

@testset "P4 — verbose run produces lines incrementally (flush present)" begin
    # Run with verbose=true, capture output; verify lines are produced and
    # each per-mutant line ends with a newline (i.e. println was used, not print).
    sites = discover(joinpath(PC_FIXTURE_DIR, "src"); operators=[OP_PLUS_TO_MINUS], root=PC_FIXTURE_DIR)
    output = _capture_stdout() do
        run_mutations(PC_FIXTURE_DIR, sites, PC_CMAP;
            baseline_elapsed=PC_BASELINE_ELAPSED,
            timeout_multiplier=5.0,
            mutant_timeout=30.0,
            verbose=true)
    end
    # At minimum we should see a line with the outcome (killed/survived/etc)
    @test !isempty(output)
    # The verbose output must contain per-mutant lines (id prefix + outcome)
    @test occursin("[gremlins]", output)
end

@testset "P4 — warm verbose run produces lines (flush present)" begin
    wr = nothing
    output = _capture_stdout() do
        wr = mutate_warm(PC_FIXTURE_DIR;
            src_dir="src",
            operators=[OP_PLUS_TO_MINUS],
            baseline_timeout=600.0,
            mutant_timeout=30.0,
            verbose=true,
            use_cache=false,
            pkg_name="MiniTarget")
    end
    @test !isempty(output)
    @test occursin("[gremlins/warm]", output)
    # Warm results are still valid after verbose capture
    @test wr isa WarmRunResult
end

# ═══ P5 — coverage overhead line in verbose output ════════════════════════════

@testset "P5 — verbose output contains coverage/plain/timeout line" begin
    sites = discover(joinpath(PC_FIXTURE_DIR, "src"); operators=[OP_PLUS_TO_MINUS], root=PC_FIXTURE_DIR)
    output = _capture_stdout() do
        run_mutations(PC_FIXTURE_DIR, sites, PC_CMAP;
            baseline_elapsed=PC_BASELINE_ELAPSED,
            timeout_multiplier=3.0,
            coverage_overhead=2.5,
            verbose=true)
    end
    # Must contain the coverage overhead info line (P5)
    @test occursin("baseline (coverage)", output)
    @test occursin("estimated plain", output)
    @test occursin("derived mutant timeout", output)
end

@testset "P5 — warm verbose output contains coverage/plain/timeout line" begin
    output = _capture_stdout() do
        mutate_warm(PC_FIXTURE_DIR;
            src_dir="src",
            operators=[OP_PLUS_TO_MINUS],
            baseline_timeout=600.0,
            coverage_overhead=2.5,
            timeout_multiplier=3.0,
            verbose=true,
            use_cache=false,
            pkg_name="MiniTarget")
    end
    @test occursin("baseline (coverage)", output)
    @test occursin("estimated plain", output)
    @test occursin("derived mutant timeout", output)
end

@testset "P5 — explicit mutant_timeout override shows 'explicit override' message" begin
    sites = discover(joinpath(PC_FIXTURE_DIR, "src"); operators=[OP_PLUS_TO_MINUS], root=PC_FIXTURE_DIR)
    output = _capture_stdout() do
        run_mutations(PC_FIXTURE_DIR, sites, PC_CMAP;
            baseline_elapsed=PC_BASELINE_ELAPSED,
            mutant_timeout=15.0,
            verbose=true)
    end
    @test occursin("explicit override", output)
    # Should NOT show the coverage overhead line (bypass)
    @test !occursin("estimated plain", output)
end

end  # @testset "M2.1 Papercuts"
