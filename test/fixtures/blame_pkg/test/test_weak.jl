@testset "weak — calls sign_of but asserts nothing discriminating" begin
    # exercises sign_of's `<` line but never checks the x==0 boundary,
    # so the `<`->`<=` mutant survives and this file is to blame.
    @test sign_of(5) isa Int
    @test sign_of(-5) isa Int
end
