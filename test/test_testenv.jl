# test_testenv.jl — Test that Gremlins honours test-only deps (GitHub #2/#3)
#
# Root cause: baseline_run and run_mutations execute the test suite with
# `julia --project=<shadow>`, where <shadow> is the package's main environment.
# `Pkg.test()` instead builds a *test environment* = package + test/Project.toml deps.
# Any non-stdlib dep declared only in test/Project.toml is missing under `--project=<shadow>`.
#
# Fix: after _make_shadow, augment the shadow's Project.toml with test-only deps
# (and [sources] entries for path-based local packages), then run Pkg.resolve +
# Pkg.instantiate so the shadow Manifest gains those deps.
#
# Fixture: hermetic local package (no network) via test/Project.toml [sources].

@testset "Test-env deps (#2/#3)" begin

    # ── Build hermetic fixture ──────────────────────────────────────────────────
    #
    # Layout:
    #   tmpdir/
    #     LocalHelper/        ← tiny helper package (no registry, local path)
    #       Project.toml
    #       src/LocalHelper.jl
    #     FixturePkg/         ← the package under mutation
    #       Project.toml      ← no test deps here (main env)
    #       src/FixturePkg.jl ← has one killable mutant site (x < 0)
    #       test/
    #         Project.toml    ← [deps] LocalHelper + Test; [sources] path
    #         runtests.jl     ← uses LocalHelper (forces test-env augmentation)

    tmpdir = mktempdir()

    # ── LocalHelper ──────────────────────────────────────────────────────────
    helper_dir = joinpath(tmpdir, "LocalHelper")
    mkpath(joinpath(helper_dir, "src"))
    write(joinpath(helper_dir, "Project.toml"),
        "name = \"LocalHelper\"\n" *
        "uuid = \"00000000-ffff-0000-0001-000000000001\"\n" *
        "version = \"0.1.0\"\n")
    write(joinpath(helper_dir, "src", "LocalHelper.jl"),
        "module LocalHelper\nsentinel() = 99\nend\n")

    # ── FixturePkg ───────────────────────────────────────────────────────────
    fixture_dir = joinpath(tmpdir, "FixturePkg")
    mkpath(joinpath(fixture_dir, "src"))
    mkpath(joinpath(fixture_dir, "test"))

    write(joinpath(fixture_dir, "Project.toml"),
        "name = \"FixturePkg\"\n" *
        "uuid = \"00000000-ffff-0000-0002-000000000001\"\n" *
        "version = \"0.1.0\"\n")

    write(joinpath(fixture_dir, "src", "FixturePkg.jl"),
        "module FixturePkg\n" *
        "sign_of(x) = x < 0 ? -1 : 1\n" *
        "export sign_of\n" *
        "end\n")

    # test/Project.toml: non-stdlib dep + [sources] (path-based, hermetic)
    write(joinpath(fixture_dir, "test", "Project.toml"),
        "[deps]\n" *
        "LocalHelper = \"00000000-ffff-0000-0001-000000000001\"\n" *
        "Test = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n" *
        "\n" *
        "[sources]\n" *
        "LocalHelper = {path = \"$(helper_dir)\"}\n")

    write(joinpath(fixture_dir, "test", "runtests.jl"),
        "using Test, FixturePkg, LocalHelper\n" *
        "@testset \"fixture\" begin\n" *
        "    @test LocalHelper.sentinel() == 99\n" *
        "    @test sign_of(5)  ==  1\n" *
        "    @test sign_of(-3) == -1\n" *
        "end\n")

    # ── RED sanity: confirm the fixture itself would fail WITHOUT the fix ─────
    # (We can't revert the fix once it's applied, so we just confirm the fixture
    #  package and structure are correct by checking that baseline_run succeeds
    #  AFTER the fix.  The RED evidence is in the commit message / CI before fix.)

    # ── GREEN: baseline_run must succeed (test dep is found) ─────────────────
    @testset "baseline_run succeeds with test-only dep" begin
        elapsed, cmap = @test_nowarn baseline_run(fixture_dir)
        @test elapsed > 0.0
        @test cmap isa CoverageMap
        # src/FixturePkg.jl line with the sign_of function should be covered
        covered = covered_lines(cmap, "src/FixturePkg.jl")
        @test !isempty(covered)
    end

    # ── GREEN: mutants also see the test dep (run_mutations end-to-end) ──────
    @testset "run_mutations succeeds with test-only dep" begin
        # root=fixture_dir ensures relpaths match coverage map keys (src/FixturePkg.jl)
        sites = discover(joinpath(fixture_dir, "src"); root=fixture_dir)
        @test !isempty(sites)

        elapsed_b, cmap = baseline_run(fixture_dir)

        # Use a generous mutant_timeout (cold Julia startup is ~30-60s)
        rr = run_mutations(fixture_dir, sites, cmap;
                           mutant_timeout = 120.0,
                           verbose = false)
        @test rr isa RunResult
        # At least one mutant result (campaign completed — no missing-dep crash)
        @test !isempty(rr.results)
        # No mutant should fail with a LoadError (missing dep) infrastructure error
        # Use Gremlins.error (not Base.error) — the MutantOutcome enum value
        n_load_errors = count(r -> r.outcome == Gremlins.error &&
                                   occursin("LoadError", r.error_msg), rr.results)
        @test n_load_errors == 0
        # With coverage working, at least one mutant should be killed or survived
        # (not all no_coverage) — proves the test dep was loaded in mutant runs
        n_executed = count(r -> r.outcome in (killed, survived, Gremlins.timeout),
                           rr.results)
        @test n_executed > 0
    end

    # ── GREEN: run_mutations_warm also sees the test dep (warm path) ──────────
    #
    # FALSIFIABILITY NOTE: this test FAILS if the _augment_shadow_with_test_deps
    # call is removed from run_mutations_warm (warm.jl). Without augmentation the
    # cold-fallback subprocess cannot load LocalHelper, causing all mutants to
    # :error rather than :killed/:survived/:no_coverage.
    @testset "run_mutations_warm succeeds with test-only dep" begin
        sites = discover(joinpath(fixture_dir, "src"); root=fixture_dir)
        @test !isempty(sites)

        elapsed_b, cmap = baseline_run(fixture_dir)

        wrr = run_mutations_warm(fixture_dir, sites, cmap;
                                 mutant_timeout = 120.0,
                                 verbose = false,
                                 pkg_name = "FixturePkg")
        @test wrr isa WarmRunResult
        @test !isempty(wrr.warm_results)
        # No env-resolution failure: no mutant should have a LoadError error_msg
        n_load_errors = count(wrr.warm_results) do wr
            wr.base.outcome == Gremlins.error &&
            occursin("LoadError", wr.base.error_msg)
        end
        @test n_load_errors == 0
        # At least one mutant executed (killed/survived/timeout) rather than :error
        n_executed = count(wrr.warm_results) do wr
            wr.base.outcome in (killed, survived, Gremlins.timeout)
        end
        @test n_executed > 0
    end

    # ── GREEN: per_unit_coverage (blame path) sees the test dep ──────────────
    #
    # FALSIFIABILITY NOTE: this test FAILS if the _augment_shadow_with_test_deps
    # call is removed from per_unit_coverage (blame.jl). Without augmentation each
    # unit driver subprocess cannot load LocalHelper, so every unit errors out and
    # failed_units becomes non-empty (containing the fixture's inline testset unit).
    @testset "per_unit_coverage has no env-resolution failures" begin
        maps, failed_units = per_unit_coverage(fixture_dir; timeout = 120.0)
        # All units must run cleanly — no LoadError from missing LocalHelper
        # If augmentation is removed, failed_units will contain "<inline>" or the
        # included test-file label, proving the fix is load-bearing.
        @test isempty(failed_units)
        # At least one unit produced coverage
        @test !isempty(maps)
    end

    rm(tmpdir; recursive=true, force=true)
end
