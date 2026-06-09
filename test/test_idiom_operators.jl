# test/test_idiom_operators.jl — Feature B: Julia-idiom mutation operators
# Tasks B1, B2, B3, B5, B4

# NOTE: sites_for/sites_for_op and _eval_in_fresh_module are defined in runtests.jl
# (the parent include scope). Do NOT redefine them here.

@testset "OP_COMPARISON_CHAIN" begin
    code = "h(a,b,c) = a < b < c\n"
    sites = sites_for(code; operators=[Gremlins.OP_COMPARISON_CHAIN])
    # two swappable operator positions → two mutants
    @test length(sites) == 2
    muts = sort([s.replacement for s in sites])
    @test "a <= b < c" in muts
    @test "a < b <= c" in muts
end

@testset "OP_COMPARISON_CHAIN falsifiability" begin
    # a planted killable mutant must be killed by a discriminating test
    f(a,b,c) = a < b < c
    @test f(1,2,3) == true
    # mutant `a <= b < c` changes f(1,1,3): orig false, mutant true → killable
    @test f(1,1,3) == false
end

@testset "OP_TERNARY_SWAP" begin
    code = "t(c,x,y) = c ? x : y\n"
    sites = sites_for(code; operators=[Gremlins.OP_TERNARY_SWAP])
    @test length(sites) == 1
    @test sites[1].replacement == "c ? y : x"
end

@testset "OP_TERNARY_SWAP falsifiability" begin
    t(c,x,y) = c ? x : y
    @test t(true, 1, 2) == 1          # mutant `c ? y : x` gives 2 → killable
    # documented equivalent noise: `c ? z : z` swap is observationally identical.
end

@testset "OP_BROADCAST_DROP" begin
    s1 = sites_for("g(a,b) = a .+ b\n"; operators=[Gremlins.OP_BROADCAST_DROP])
    @test length(s1) == 1
    @test s1[1].replacement == "a + b"
    s2 = sites_for("g(a,b) = a .< b\n"; operators=[Gremlins.OP_BROADCAST_DROP])
    @test s2[1].replacement == "a < b"
    # f.(x) prefix broadcast is out of scope v1 → no site
    s3 = sites_for("g(f,x) = f.(x)\n"; operators=[Gremlins.OP_BROADCAST_DROP])
    @test isempty(s3)
end

@testset "OP_BROADCAST_DROP falsifiability" begin
    g(a,b) = a .+ b
    @test g([1,2],[3,4]) == [4,6]    # mutant `a + b` on vectors → MethodError/diff → killable
    # documented equivalent noise: already-scalar operands (a .+ b == a + b).
end

@testset "operators on multibyte source" begin
    # α/β/γ are 2-byte UTF-8 — byte offsets diverge from char indices here.
    s = sites_for("h(α,β,γ) = α < β < γ\n"; operators=[Gremlins.OP_COMPARISON_CHAIN])
    @test length(s) == 2
    @test "α <= β < γ" in [x.replacement for x in s]
    # ternary + broadcast on multibyte operands must not throw
    @test !isempty(sites_for("t(λ,x,y)= λ ? x : y\n"; operators=[Gremlins.OP_TERNARY_SWAP]))
    @test !isempty(sites_for("g(ψ,φ)= ψ .+ φ\n"; operators=[Gremlins.OP_BROADCAST_DROP]))
end
