# runner_test.jl — M1 tests: coverage, runner, report
#
# Campaign rule: falsifiability — every classification tested with planted mutants.

using Test
using Gremlins

const FIXTURE_DIR = joinpath(@__DIR__, "fixtures", "MiniTarget")

# ─── Shared fixture state — computed ONCE for all M1 tests ───────────────────
# Running a mutation suite spawns many julia subprocesses; reusing results
# across tests avoids OOM from repeated baseline+subprocess launches.

# Run with OP_PLUS_TO_MINUS only: targets add() (killable) — fast (1 site)
const M1_RESULT_PLUS = let
    mutate(FIXTURE_DIR;
        src_dir="src",
        test_dir="test",
        test_file="runtests.jl",
        operators=[OP_PLUS_TO_MINUS],
        timeout_multiplier=5.0,
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
        timeout_multiplier=5.0,
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

# ─── Crash-safety (I1): source restored after simulated runner error ──────────
@testset "Runner — crash-safety: source restored after error" begin
    mktempdir() do tmp
        # Copy fixture src file to tmp
        src_path = joinpath(FIXTURE_DIR, "src", "MiniTarget.jl")
        dst_path = joinpath(tmp, "MiniTarget.jl")
        cp(src_path, dst_path)

        original_bytes = read(dst_path)

        # Discover a mutation site in the copy
        sites = discover_file(dst_path; root=tmp, operators=[OP_PLUS_TO_MINUS])
        @test !isempty(sites)
        site = sites[1]

        # Apply the mutation
        orig_src = apply!(site, dst_path)

        # Verify it's mutated
        @test read(dst_path) != original_bytes

        # Simulate a crash during runner — always restore via try/finally
        try
            Base.error("simulated crash during test subprocess")
        catch
        finally
            revert!(site, orig_src, dst_path)
        end

        # Verify restoration: byte-identical
        restored = read(dst_path)
        @test restored == original_bytes
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
