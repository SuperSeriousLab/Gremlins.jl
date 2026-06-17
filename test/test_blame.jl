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
        # no phantom key for the synthetic driver file
        @test !any(k -> occursin("__gremlins_blame_driver", k),
                   keys(maps["test_f.jl"].data))
        @test !any(k -> occursin("__gremlins_blame_driver", k),
                   keys(maps["test_g.jl"].data))
        # lines covered only by test_f.jl vs only by test_g.jl prove per-unit isolation
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

using Gremlins: BlameReport, _join_blame, render_blame, CoverageMap,
                MutantResult, MutationSite, survived

# helper: build a synthetic survivor at (relpath, line)
function _surv(relpath, line, id)
    site = MutationSite(id, relpath, 1:1, :op, "op", "<", "<=", line)
    return MutantResult(site, survived, 0.0, "")
end

@testset "_join_blame — attribution, multi-blame, unattributed, failed" begin
    s1 = _surv("src/a.jl", 10, "1111111111111111")  # covered by t1 only
    s2 = _surv("src/a.jl", 20, "2222222222222222")  # covered by t1 and t2
    s3 = _surv("src/b.jl", 30, "3333333333333333")  # covered by nobody -> unattributed
    survivors = [s1, s2, s3]

    maps = Dict(
        "t1.jl" => CoverageMap(Dict("src/a.jl" => Set([10, 20]))),
        "t2.jl" => CoverageMap(Dict("src/a.jl" => Set([20]))),
    )
    rep = _join_blame(survivors, maps, ["t_broken.jl"])

    @test Set(keys(rep.blamed)) == Set(["t1.jl", "t2.jl"])
    @test [r.site.id for r in rep.blamed["t1.jl"]] == [s1.site.id, s2.site.id]  # sorted by (relpath,line)
    @test [r.site.id for r in rep.blamed["t2.jl"]] == [s2.site.id]
    @test [r.site.id for r in rep.unattributed] == [s3.site.id]
    @test rep.failed_units == ["t_broken.jl"]
end

@testset "render_blame — deterministic section text" begin
    s1 = _surv("src/a.jl", 10, "1111111111111111")
    s3 = _surv("src/b.jl", 30, "3333333333333333")
    rep = BlameReport(Dict("t1.jl" => [s1]), [s3], ["t_broken.jl"])
    buf = IOBuffer()
    render_blame(buf, rep)
    out = String(take!(buf))
    @test occursin("Survivors by Responsible Test", out)
    @test occursin("t1.jl", out)
    @test occursin("src/a.jl:10", out)
    @test occursin("Unattributed survivors", out)
    @test occursin("src/b.jl:30", out)
    @test occursin("t_broken.jl", out)
end
