using Test

# Load MiniTarget without Pkg — compatible with subprocess execution
# where the package may not be registered.
push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))
include(joinpath(@__DIR__, "..", "src", "MiniTarget.jl"))

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
