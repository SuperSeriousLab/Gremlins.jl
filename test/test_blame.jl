using Test
using Gremlins
using Gremlins: detect_units, TestUnit, _is_test_unit

@testset "detect_units — split prelude / include-units / inline" begin
    mktempdir() do dir
        testdir = joinpath(dir, "test"); mkpath(testdir)
        write(joinpath(testdir, "test_alpha.jl"), "@testset \"a\" begin @test 1==1 end\n")
        write(joinpath(testdir, "beta_test.jl"), "@testset \"b\" begin @test 2==2 end\n")
        runtests = joinpath(testdir, "runtests.jl")
        write(runtests, """
        using Test
        using Gremlins

        helper() = 42

        @testset "inline" begin
            @test helper() == 42
        end

        include("test_alpha.jl")
        include("beta_test.jl")
        """)

        prelude, units = detect_units(runtests)

        # prelude holds defs, not the @testset or the includes
        @test occursin("helper() = 42", prelude)
        @test occursin("using Gremlins", prelude)
        @test !occursin("@testset", prelude)
        @test !occursin("include(", prelude)

        labels = [u.label for u in units]
        # include-units sorted by label, then the synthetic inline unit last
        @test labels == ["beta_test.jl", "test_alpha.jl", "<inline>"]

        # each include-unit driver = prelude + its own include only
        alpha = units[findfirst(u -> u.label == "test_alpha.jl", units)]
        @test occursin("helper() = 42", alpha.driver)
        @test occursin("include(\"test_alpha.jl\")", alpha.driver)
        @test !occursin("beta_test.jl", alpha.driver)
        @test !occursin("@testset \"inline\"", alpha.driver)

        # the inline unit driver = prelude + the inline @testset, no includes
        inline = units[findfirst(u -> u.label == "<inline>", units)]
        @test occursin("@testset \"inline\"", inline.driver)
        @test occursin("helper() = 42", inline.driver)
        @test !occursin("include(", inline.driver)
    end
end

@testset "_is_test_unit — filename gate" begin
    mktempdir() do dir
        write(joinpath(dir, "test_x.jl"), "")
        write(joinpath(dir, "y_test.jl"), "")
        write(joinpath(dir, "setup.jl"), "")
        @test _is_test_unit("test_x.jl", dir)
        @test _is_test_unit("y_test.jl", dir)
        @test !_is_test_unit("setup.jl", dir)        # not a test name -> stays prelude
        @test !_is_test_unit("test_missing.jl", dir)  # name ok but file absent
    end
end
