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

using Gremlins: per_unit_coverage, covered_lines

@testset "per_unit_coverage — line attributed to the covering unit only" begin
    mktempdir() do pkg
        mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "test"))
        write(joinpath(pkg, "Project.toml"),
              "name = \"BlameCov\"\nuuid = \"00000000-0000-0000-0000-0000000000c0\"\n")
        # src: line 2 is f's body, line 5 is g's body
        write(joinpath(pkg, "src", "BlameCov.jl"), """
        module BlameCov
        f(x) = x + 1
        export f
        g(x) = x - 1
        export g
        end
        """)
        write(joinpath(pkg, "test", "test_f.jl"), """
        @testset "f" begin
            @test BlameCov.f(1) == 2
        end
        """)
        write(joinpath(pkg, "test", "test_g.jl"), """
        @testset "g" begin
            @test BlameCov.g(1) == 0
        end
        """)
        write(joinpath(pkg, "test", "runtests.jl"), """
        using Test
        using BlameCov
        include("test_f.jl")
        include("test_g.jl")
        """)

        maps, failed = per_unit_coverage(pkg)
        @test isempty(failed)
        @test Set(keys(maps)) == Set(["test_f.jl", "test_g.jl"])
        # f's body line (2) covered only by test_f.jl; g's body line (4) only by test_g.jl
        @test 2 in covered_lines(maps["test_f.jl"], "src/BlameCov.jl")
        @test !(4 in covered_lines(maps["test_f.jl"], "src/BlameCov.jl"))
        @test 4 in covered_lines(maps["test_g.jl"], "src/BlameCov.jl")
        @test !(2 in covered_lines(maps["test_g.jl"], "src/BlameCov.jl"))
    end
end

@testset "per_unit_coverage — broken unit recorded as failed, never crashes" begin
    mktempdir() do pkg
        mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "test"))
        write(joinpath(pkg, "Project.toml"),
              "name = \"BlameBroke\"\nuuid = \"00000000-0000-0000-0000-0000000000c1\"\n")
        write(joinpath(pkg, "src", "BlameBroke.jl"),
              "module BlameBroke\nf(x) = x + 1\nexport f\nend\n")
        write(joinpath(pkg, "test", "test_ok.jl"),
              "@testset \"ok\" begin\n    @test BlameBroke.f(1) == 2\nend\n")
        write(joinpath(pkg, "test", "test_bad.jl"),
              "@testset \"bad\" begin\n    @test NONEXISTENT_SYMBOL == 1\nend\n")
        write(joinpath(pkg, "test", "runtests.jl"), """
        using Test
        using BlameBroke
        include("test_ok.jl")
        include("test_bad.jl")
        """)
        maps, failed = per_unit_coverage(pkg)
        @test "test_bad.jl" in failed
        @test haskey(maps, "test_ok.jl")
        @test !haskey(maps, "test_bad.jl")
    end
end
