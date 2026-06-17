@testset "strong — tests add1 only, kills its mutants" begin
    @test add1(1) == 2
    @test add1(0) == 1
end
