using Test
using Gremlins
using Gremlins: detect_units, TestUnit

# ─── Issue #5: detect_units handles ReTestItems/TestItemRunner layout ──────────
#
# Hermetic tests: we test DETECTION + ENUMERATION logic only, not a live
# ReTestItems run (no network access in CI, ReTestItems not installed).
# What is NOT covered: end-to-end campaign running *_test.jl units under
# coverage via a real ReTestItems install.

@testset "detect_units — ReTestItems layout, two _test.jl files detected" begin
    mktempdir() do dir
        # Build a minimal package tree with ReTestItems layout
        testdir = joinpath(dir, "test")
        srcdir  = joinpath(dir, "src")
        mkpath(testdir)
        mkpath(srcdir)

        # runtests.jl in ReTestItems style — no include(), just runtests(Foo)
        write(joinpath(testdir, "runtests.jl"), """
        using ReTestItems
        runtests(Foo)
        """)

        # Two *_test.jl test item files (trivial contents — detection test only)
        write(joinpath(testdir, "a_test.jl"), """
        @testitem "a" begin
            @test 1 + 1 == 2
        end
        """)
        write(joinpath(testdir, "b_test.jl"), """
        @testitem "b" begin
            @test 2 + 2 == 4
        end
        """)

        runtests_path = joinpath(testdir, "runtests.jl")
        _, units = detect_units(runtests_path; test_dir=testdir, pkg_src_dir=srcdir)

        labels = [u.label for u in units]

        # Must detect exactly the two *_test.jl files, sorted by label
        @test length(units) == 2
        @test "a_test.jl" in labels
        @test "b_test.jl" in labels
        @test issorted(labels)   # sorted by label (determinism)

        # Each unit's driver must invoke runtests( on its own specific file path
        for u in units
            @test occursin("runtests(", u.driver)
            @test occursin(u.label, u.driver)
        end
    end
end

@testset "detect_units — ReTestItems layout, no _test.jl files → zero units" begin
    mktempdir() do dir
        testdir = joinpath(dir, "test")
        srcdir  = joinpath(dir, "src")
        mkpath(testdir)
        mkpath(srcdir)

        # ReTestItems runtests with no matching *_test.jl files present
        write(joinpath(testdir, "runtests.jl"), """
        using ReTestItems
        runtests(Bar)
        """)
        # Deliberately no *_test.jl files created

        runtests_path = joinpath(testdir, "runtests.jl")

        # Should return zero units, not error
        _, units = detect_units(runtests_path; test_dir=testdir, pkg_src_dir=srcdir)
        @test isempty(units)
    end
end

@testset "detect_units — classic include layout still works (regression)" begin
    mktempdir() do dir
        testdir = joinpath(dir, "test")
        srcdir  = joinpath(dir, "src")
        mkpath(testdir)
        mkpath(srcdir)

        # Classic style with include("test_x.jl")
        write(joinpath(testdir, "test_x.jl"), "@testset \"x\" begin @test 1==1 end\n")
        write(joinpath(testdir, "runtests.jl"), """
        using Test
        helper() = 42
        include("test_x.jl")
        """)

        runtests_path = joinpath(testdir, "runtests.jl")
        prelude, units = detect_units(runtests_path; test_dir=testdir, pkg_src_dir=srcdir)

        labels = [u.label for u in units]
        # Classic layout: include-unit with the short filename label
        @test "test_x.jl" in labels
        # Prelude carries the helper def
        @test occursin("helper() = 42", prelude)
        # No ReTestItems detection triggered
        @test !any(u -> occursin("ReTestItems", u.driver), units)
    end
end

@testset "detect_units — src-collocated _test.jl enumerated via pkg_src_dir" begin
    mktempdir() do dir
        testdir = joinpath(dir, "test")
        srcdir  = joinpath(dir, "src")
        mkpath(testdir)
        mkpath(srcdir)

        write(joinpath(testdir, "runtests.jl"), """
        using ReTestItems
        runtests(Baz)
        """)
        # test item collocated under src/ (a valid ReTestItems convention)
        write(joinpath(srcdir, "c_test.jl"), """
        @testitem "c" begin
            @test true
        end
        """)

        runtests_path = joinpath(testdir, "runtests.jl")
        # without pkg_src_dir the src-collocated file is missed; with it, found
        _, none = detect_units(runtests_path; test_dir=testdir)
        @test isempty(none)
        _, units = detect_units(runtests_path; test_dir=testdir, pkg_src_dir=srcdir)
        @test length(units) == 1
        @test units[1].label == "c_test.jl"
        @test occursin("runtests(", units[1].driver)
    end
end

@testset "detect_units — @run_package_tests layout detected as ReTestItems" begin
    mktempdir() do dir
        testdir = joinpath(dir, "test")
        srcdir  = joinpath(dir, "src")
        mkpath(testdir)
        mkpath(srcdir)

        # @run_package_tests macro style (TestItemRunner)
        write(joinpath(testdir, "runtests.jl"), """
        using TestItemRunner
        @run_package_tests
        """)

        write(joinpath(testdir, "foo_test.jl"), """
        @testitem "foo" begin
            @test true
        end
        """)

        runtests_path = joinpath(testdir, "runtests.jl")
        _, units = detect_units(runtests_path; test_dir=testdir, pkg_src_dir=srcdir)

        labels = [u.label for u in units]
        @test length(units) == 1
        @test "foo_test.jl" in labels
    end
end
