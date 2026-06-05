# runtests_warm.jl — Warm-path test entry for MiniTarget fixture
#
# Uses "using MiniTarget" instead of include(src) so the warm worker's
# eval-into-module works correctly (include re-reads disk and defeats warm eval).
# The worker starts with --project=MiniTarget_dir so "using MiniTarget" loads
# the already-in-memory (possibly mutated) module.
#
# COLD path uses runtests.jl (include-based, works without Pkg context).
# WARM path uses this file (using-based, works when --project=pkgdir).

using Test
using MiniTarget

@testset "MiniTarget" begin
    # Tests for add/2 — covers the KILLABLE site (+ operator)
    @test MiniTarget.add(2, 3) == 5
    @test MiniTarget.add(0, 0) == 0
    @test MiniTarget.add(-1, 1) == 0

    # Tests for is_positive — covers the site, but only with strictly positive x.
    # OP_GT_TO_GE mutation (> → >=) gives same result for x > 0 inputs.
    # So the mutant SURVIVES — tests can't distinguish > from >= for x=5.
    @test MiniTarget.is_positive(5) == true
    @test MiniTarget.is_positive(-1) == false
    # NOTE: is_positive(0) is deliberately NOT tested, so > vs >= is undetectable.
end
