using Test
using Gremlins

# ─── Item A: unified diff per surviving mutant ─────────────────────────────────
#
# render_survivor_diffs(result::RunResult, pkgdir::String) -> String
#
# For each surviving mutant (sorted by relpath, line, id), emits a minimal
# unified diff hunk:
#   --- a/<relpath>
#   +++ b/<relpath>
#   @@ -<line> +<line> @@
#   -<original line text>
#   +<mutated line text>
#
# The function is exported from Gremlins.

@testset "render_survivor_diffs — basic hunk structure" begin
    mktempdir() do pkgdir
        # Write a tiny source file with a known mutation site
        src_dir = joinpath(pkgdir, "src")
        mkpath(src_dir)
        src_content = "f(x) = x < 5\n"
        src_file = joinpath(src_dir, "myfile.jl")
        write(src_file, src_content)

        # Discover mutation sites on this file
        sites = discover_file(src_file; root=pkgdir, operators=[OP_LT_TO_LE])
        @test !isempty(sites)
        site = sites[1]

        # Build a RunResult with exactly one surviving mutant
        survived_result = MutantResult(site, survived, 0.1, "")
        run_result = RunResult(
            pkgdir,
            [site],
            [survived_result],
            1.0,   # baseline_elapsed
            2.0,   # total_elapsed
        )

        diff_output = render_survivor_diffs(run_result, pkgdir)

        # Must contain the @@ hunk header with the correct line number
        @test occursin("@@ -$(site.line)", diff_output)

        # Must contain the --- and +++ headers
        @test occursin("--- a/", diff_output)
        @test occursin("+++ b/", diff_output)

        # Must contain the original line prefixed with '-'
        # The original line is "f(x) = x < 5"
        @test occursin("-f(x) = x < 5", diff_output)

        # Must contain the mutated line prefixed with '+'
        # The mutant replaces '<' with '<=' so the line becomes "f(x) = x <= 5"
        @test occursin("+f(x) = x <= 5", diff_output)
    end
end

@testset "render_survivor_diffs — empty when no survivors" begin
    mktempdir() do pkgdir
        src_dir = joinpath(pkgdir, "src")
        mkpath(src_dir)
        src_content = "f(x) = x < 5\n"
        src_file = joinpath(src_dir, "myfile.jl")
        write(src_file, src_content)

        sites = discover_file(src_file; root=pkgdir, operators=[OP_LT_TO_LE])
        @test !isempty(sites)
        site = sites[1]

        # All killed — no survivors
        killed_result = MutantResult(site, killed, 0.1, "")
        run_result = RunResult(pkgdir, [site], [killed_result], 1.0, 2.0)

        diff_output = render_survivor_diffs(run_result, pkgdir)
        @test isempty(strip(diff_output))
    end
end
