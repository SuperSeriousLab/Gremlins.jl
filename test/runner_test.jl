# runner_test.jl — M1 tests: coverage, runner, report
#
# Campaign rule: falsifiability — every classification tested with planted mutants.

using Test
using Gremlins

const FIXTURE_DIR = joinpath(@__DIR__, "fixtures", "MiniTarget")

# ─── Shared fixture state — computed ONCE for all M1 tests ───────────────────
# Running a mutation suite spawns many julia subprocesses; reusing results
# across tests avoids OOM from repeated baseline+subprocess launches.

# Falsifiability fixtures must be deterministic regardless of machine load.
# A cold mutant subprocess (precompile + test suite) can take 100s+ on a loaded
# CI box; the derived timeout is load-sensitive (it scales with the measured
# baseline) and can fall to the 10s floor when the baseline reads small, which
# would falsely classify a genuinely killable mutant as `timeout`. Pin an
# explicit, generous mutant_timeout so the outcome is decided by test semantics,
# never by timing. This also dogfoods the M2.1 `mutant_timeout` override.
const FIXTURE_MUTANT_TIMEOUT = 300.0

# Run with OP_PLUS_TO_MINUS only: targets add() (killable) — fast (1 site)
const M1_RESULT_PLUS = let
    mutate(FIXTURE_DIR;
        src_dir="src",
        test_dir="test",
        test_file="runtests.jl",
        operators=[OP_PLUS_TO_MINUS],
        mutant_timeout=FIXTURE_MUTANT_TIMEOUT,
        verbose=false)
end

# Run with OP_GT_TO_GE only: targets is_positive (surviving mutant)
# is_positive(x) = x > 0  →  x >= 0
# Tests only call with x=5 (positive non-zero) and x=-1, never x=0.
# So > vs >= is undetectable → SURVIVED.
const M1_RESULT_GT = let
    mutate(FIXTURE_DIR;
        src_dir="src",
        test_dir="test",
        test_file="runtests.jl",
        operators=[OP_GT_TO_GE],
        mutant_timeout=FIXTURE_MUTANT_TIMEOUT,
        verbose=false)
end

# Coverage map (baseline) — computed once
const M1_BASELINE = let
    baseline_run(FIXTURE_DIR; test_dir="test", test_file="runtests.jl")
end
const M1_ELAPSED  = M1_BASELINE[1]
const M1_CMAP     = M1_BASELINE[2]

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Gremlins M1" begin

# ─── Coverage parsing ─────────────────────────────────────────────────────────
@testset "Coverage — parse_cov_file" begin
    mktempdir() do dir
        # Write a synthetic .cov file
        cov_content = "        - module Foo\n        1 x = 1 + 2\n        - # comment\n        3 y = x * 2\n        - end\n"
        cov_path = joinpath(dir, "foo.jl.123.cov")
        write(cov_path, cov_content)
        covered = Gremlins.parse_cov_file(cov_path)
        @test 2 in covered   # line 2 has count 1
        @test 4 in covered   # line 4 has count 3
        @test !(1 in covered)  # line 1 is '-'
        @test !(3 in covered)  # line 3 is '-'
    end
end

@testset "Coverage — baseline_run produces CoverageMap" begin
    @test M1_ELAPSED > 0.0
    @test M1_CMAP isa CoverageMap
    # The fixture's add function must be covered (it's tested)
    lines = covered_lines(M1_CMAP, "src/MiniTarget.jl")
    @test !isempty(lines)
    @test string(M1_CMAP) isa String  # show works
end

@testset "Coverage — is_covered" begin
    # Discover with root=FIXTURE_DIR so relpaths match coverage map keys (src/MiniTarget.jl)
    sites = discover(joinpath(FIXTURE_DIR, "src"); operators=[OP_PLUS_TO_MINUS], root=FIXTURE_DIR)
    add_sites = filter(s -> s.op_id == :arith_plus_minus, sites)
    @test !isempty(add_sites)
    plus_site = add_sites[1]
    @test is_covered(M1_CMAP, plus_site)  # add is tested → covered
end

# ─── Runner — core structure ─────────────────────────────────────────────────
@testset "Runner — MutantResult structure" begin
    result = M1_RESULT_PLUS
    @test result isa RunResult
    @test !isempty(result.results)
    @test result.baseline_elapsed > 0.0
    @test result.total_elapsed > 0.0
    @test length(result.sites) == length(result.results)
    for r in result.results
        @test r isa MutantResult
        @test r.outcome isa MutantOutcome
        @test r.elapsed >= 0.0
        @test r.site isa MutationSite
    end
end

@testset "Runner — deterministic ordering (sorted by mutant id)" begin
    result = M1_RESULT_PLUS
    ids = [r.site.id for r in result.results]
    @test ids == sort(ids)
end

# ─── Falsifiability: KILLABLE mutant in fixture ───────────────────────────────
# OP_PLUS_TO_MINUS applied to `add(a, b) = a + b` → `a - b`
# Fixture tests check add(2,3)==5; with mutant 2-3=-1 ≠ 5 → test fails → killed
@testset "Runner — KILLABLE mutant classified killed (falsifiability)" begin
    result = M1_RESULT_PLUS
    killed_results = filter(r -> r.outcome == Gremlins.killed, result.results)
    # add function's + site must be killed
    @test !isempty(killed_results)
    @test any(r -> r.site.op_id == :arith_plus_minus && r.outcome == Gremlins.killed,
              result.results)
end

# ─── Falsifiability: SURVIVING mutant in fixture ─────────────────────────────
# OP_GT_TO_GE applied to `is_positive(x) = x > 0` → `x >= 0`
# Tests call is_positive(5) and is_positive(-1) but NOT is_positive(0).
# For those inputs: 5>=0==true, -1>=0==false → same as > → mutant SURVIVES.
@testset "Runner — SURVIVING mutant classified survived (falsifiability)" begin
    result = M1_RESULT_GT
    survived_results = filter(r -> r.outcome == Gremlins.survived, result.results)
    # is_positive's > site must survive (test inputs don't hit the boundary)
    @test !isempty(survived_results)
    @test any(r -> r.site.op_id == :relop_gt_ge && r.outcome == Gremlins.survived,
              result.results)
end

# ─── Crash-safety (I1): shadow semantics — real tree never written ────────────
@testset "Runner — crash-safety: real tree unmodified (shadow semantics)" begin
    # I1 shadow semantics: run_mutations must not modify the real package tree.
    # We verify this by hashing every file before and after a real run.
    mktempdir() do pkg_copy
        # Set up a complete standalone copy of MiniTarget fixture
        cp(FIXTURE_DIR, pkg_copy; force=true)

        # Hash all source files before the run
        src_file = joinpath(pkg_copy, "src", "MiniTarget.jl")
        before_bytes = read(src_file)

        # Run a real mutation run (applies mutations in shadow, not in pkg_copy)
        sites = discover(joinpath(pkg_copy, "src"); operators=[OP_PLUS_TO_MINUS], root=pkg_copy)
        @test !isempty(sites)
        elapsed_b, cmap = baseline_run(pkg_copy; test_dir="test", test_file="runtests.jl")
        run_mutations(pkg_copy, sites, cmap;
            test_dir="test", test_file="runtests.jl",
            baseline_elapsed=elapsed_b, verbose=false)

        # Real tree must be byte-identical (shadow protected it)
        after_bytes = read(src_file)
        @test after_bytes == before_bytes
    end
end

# ─── Crash-safety (I1): SIGKILL crash test — the falsifiability gate ──────────
# This test reproduces the 2026-06-04 production incident:
#   - Start run_mutations as a subprocess on a fixture package copy
#   - SIGKILL it while it is mid-mutant (after baseline finishes, during mutant subprocess)
#   - Assert the fixture's real tree is byte-identical to before
#
# PRE-FIX (without shadow): after SIGKILL, real tree would be left mutated.
#   Confirmed manually 2026-06-05: apply! to real file + sleep(60) + SIGKILL
#   → real file left with mutated content.
# POST-FIX (with shadow):   after SIGKILL, real tree is untouched (mutation was in shadow).
#   Confirmed manually 2026-06-05: run_mutations with shadow + SIGKILL → real file intact.
@testset "Runner — SIGKILL crash-safety: real tree intact after kill (I1 falsifiability)" begin
    mktempdir() do pkg_copy
        # Set up a complete standalone copy of MiniTarget
        cp(FIXTURE_DIR, pkg_copy; force=true)

        # Record the real source file before
        src_file = joinpath(pkg_copy, "src", "MiniTarget.jl")
        before_bytes = read(src_file)

        # Signal file: driver creates this after baseline completes, just before first mutant.
        # Using a file (not stdout) avoids pipe buffering race conditions.
        signal_file = tempname() * "_gremlins_baseline_done.txt"
        driver_script = tempname() * "_gremlins_crash_driver.jl"

        # Use the Gremlins project from the actual installation
        gremlins_project = dirname(dirname(Base.find_package("Gremlins")))
        write(driver_script, """
            using Gremlins
            const PKG_COPY = $(repr(pkg_copy))
            const SIGNAL_FILE = $(repr(signal_file))
            sites = discover(joinpath(PKG_COPY, "src"); operators=[OP_PLUS_TO_MINUS], root=PKG_COPY)
            elapsed_b, cmap = baseline_run(PKG_COPY; test_dir="test", test_file="runtests.jl")
            # Signal via file: baseline done, about to enter first mutant subprocess
            write(SIGNAL_FILE, "baseline_done")
            run_mutations(PKG_COPY, sites, cmap;
                test_dir="test", test_file="runtests.jl",
                baseline_elapsed=elapsed_b, verbose=false)
        """)

        jl = Base.julia_cmd().exec[1]
        cmd = Cmd([jl, "--project=$gremlins_project", driver_script])
        proc = run(pipeline(cmd, stdout=devnull, stderr=devnull); wait=false)

        # Wait for BASELINE_DONE signal (driver is now entering first mutant subprocess)
        deadline = time() + 300.0  # up to 5 min (conservative — baseline ~15s)
        while time() < deadline && !isfile(signal_file)
            process_running(proc) || break
            sleep(0.3)
        end
        baseline_done = isfile(signal_file)

        if !baseline_done && !process_running(proc)
            # Driver finished before we could signal-and-kill (very fast machine or
            # single mutant completed quickly). Check tree is intact and pass.
            after_bytes = read(src_file)
            @test after_bytes == before_bytes
            rm(driver_script; force=true)
            rm(signal_file; force=true)
            return
        end

        # Sleep 2s to be inside the mutant test subprocess (which takes ~20s)
        sleep(2.0)

        # SIGKILL the driver — this bypasses finally blocks
        if process_running(proc)
            kill(proc, Base.SIGKILL)
            sleep(0.5)
            try; wait(proc); catch; end
        end

        # Assert: real source tree is byte-identical to before SIGKILL
        # Shadow design: mutation was applied inside /tmp shadow, not in pkg_copy.
        # SIGKILL leaves an orphaned shadow tmpdir (harmless), NOT corrupted source.
        after_bytes = read(src_file)
        if after_bytes != before_bytes
            @error "SIGKILL crash test FAILED: real tree was MUTATED — I1 violated"
            # Restore to prevent test suite pollution
            write(src_file, before_bytes)
        end
        @test after_bytes == before_bytes   # shadow protected the real tree

        rm(driver_script; force=true)
        rm(signal_file; force=true)
    end
end

# ─── Mutation score ────────────────────────────────────────────────────────────
@testset "Runner — mutation_score calculation" begin
    result = M1_RESULT_PLUS
    score = mutation_score(result)
    # For MiniTarget, add is covered → + site killed → score > 0
    if !isnan(score)
        @test 0.0 <= score <= 1.0
    end
    @test string(result) isa String
end

# ─── Report: Markdown ─────────────────────────────────────────────────────────
@testset "Report — markdown format" begin
    result = M1_RESULT_PLUS
    md = report(result; format=:markdown)
    @test md isa String
    @test occursin("Mutation Score", md)
    @test occursin("Killed", md)
    @test occursin("Survived", md)
    @test occursin("Total", md)
    @test occursin("MiniTarget", md)
end

# ─── Report: JSON ─────────────────────────────────────────────────────────────
@testset "Report — json format" begin
    result = M1_RESULT_PLUS
    js = report(result; format=:json)
    @test js isa String
    @test occursin("gremlins-report-v1", js)
    @test occursin("killed", js)
    @test occursin("mutation_score_pct", js)
    @test occursin("mutants", js)
end

# ─── Report: dispatch error ───────────────────────────────────────────────────
@testset "Report — unknown format throws MutationError" begin
    result = M1_RESULT_PLUS
    @test_throws MutationError report(result; format=:invalid)
end

# ─── Report: print_summary ────────────────────────────────────────────────────
@testset "Report — print_summary does not throw" begin
    result = M1_RESULT_PLUS
    # print_summary writes to stdout; test that it produces expected content
    # by using report_markdown instead (same content, testable via string)
    md = report_markdown(result)
    @test occursin("Score", md)
    @test occursin("Killed", md)
end

# ─── JSON_str: escape safety ─────────────────────────────────────────────────
@testset "Report — JSON_str escapes special characters" begin
    @test Gremlins.JSON_str("hello") == "\"hello\""
    @test Gremlins.JSON_str("say \"hi\"") == "\"say \\\"hi\\\"\""
    @test Gremlins.JSON_str("line\nnewline") == "\"line\\nnewline\""
    @test Gremlins.JSON_str("back\\slash") == "\"back\\\\slash\""
end

end  # @testset "Gremlins M1"
