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

    # no focused driver errored — so "not blamed" below means "didn't cover", not "crashed"
    @test isempty(rep.failed_units)

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
