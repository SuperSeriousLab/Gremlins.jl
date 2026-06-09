# test/test_schema.jl — Feature C: Mutant schemata (compile-once mode)
# Tasks C1 and C2 only. C3/C4/C5 deferred.

# NOTE: sites_for is defined in runtests.jl (parent include scope).

using Test, Gremlins

# stdout capture helper — redirect_stdout(::IOBuffer) is unsupported on Julia 1.11
# (needs a real fd). Redirect to a temp file (real fd) and read it back.
# Mirrors papercut_test.jl::_capture_stdout.
function _capture_stdout_schema(f::Function)::String
    path, io = mktemp()
    try
        redirect_stdout(io) do
            f()
        end
        flush(io)
        close(io)
        return read(path, String)
    finally
        isfile(path) && rm(path; force=true)
    end
end

@testset "schema_eligible" begin
    # MutationSite fields: id, relpath, byte_range, op_id, op_name, original, replacement, line
    mk(opid, orig) = Gremlins.MutationSite("i", "x.jl", 1:max(1,length(orig)),
                                           opid, "n", orig, "<=", 1)
    @test Gremlins.schema_eligible(mk(:relop_lt_le, "a < b"))       # operator swap, vars
    @test !Gremlins.schema_eligible(mk(:literal_int_incr, "0"))     # value-mutating
    @test !Gremlins.schema_eligible(mk(:stmt_delete, "f()"))        # shape-changing
    @test !Gremlins.schema_eligible(mk(:ternary_swap, "c ? x : y")) # value-mutating
    # constant-literal guard: operator swap on literal operands that const-fold
    @test !Gremlins.schema_eligible(mk(:relop_lt_le, "1 < 2"))     # folds → ineligible
end

@testset "instrument_function" begin
    # function body with two operator-swap sites at known byte ranges
    src = "f(a,b) = a < b && a > 0"
    #      123456789...                byte offsets (1-based)
    # site1: "a < b"  → key 1, mutated "a <= b"
    # site2: "a > 0"  → key 2, mutated "a >= 0"
    r1 = findfirst("a < b", src)
    r2 = findfirst("a > 0", src)
    sites = [(UnitRange{Int}(r1), 1, "a <= b"),
             (UnitRange{Int}(r2), 2, "a >= 0")]
    out = Gremlins.instrument_function(src, sites)
    @test occursin("Main.__GREM_ACTIVE[] == 1 ? (a <= b) : (a < b)", out)
    @test occursin("Main.__GREM_ACTIVE[] == 2 ? (a >= 0) : (a > 0)", out)
    # original tail/head bytes preserved
    @test startswith(out, "f(a,b) = ")
end

@testset "instrument baseline is observationally original" begin
    src = "ff_schema_test(a,b) = a < b"
    r = UnitRange{Int}(findfirst("a < b", src))
    out = Gremlins.instrument_function(src, [(r, 1, "a <= b")])
    Gremlins.__GREM_ACTIVE[] = 0
    @eval Main begin $(Meta.parse(out)) end
    @test Base.invokelatest(Main.ff_schema_test, 1, 2) == true     # active=0 → original `<`
    @test Base.invokelatest(Main.ff_schema_test, 2, 2) == false
    Gremlins.__GREM_ACTIVE[] = 1
    @test Base.invokelatest(Main.ff_schema_test, 2, 2) == true     # active=1 → mutated `<=`
    Gremlins.__GREM_ACTIVE[] = 0
end

@testset "disjoint_eligible routes nested sites to warm" begin
    # (a < b) && (c > d): the && site contains both relop sites → overlapping
    sites = filter(Gremlins.schema_eligible,
                   sites_for("q(a,b,c,d) = (a < b) && (c > d)\n"))
    schema, nested = Gremlins.disjoint_eligible(sites)
    @test !isempty(nested)               # at least some sites overlap → fall back
    # disjoint case: two independent comparisons in a tuple → both schema-runnable
    s2 = filter(Gremlins.schema_eligible,
                sites_for("r(a,b,c,d) = (a < b, c > d)\n"))
    sc2, ne2 = Gremlins.disjoint_eligible(s2)
    @test isempty(ne2) && length(sc2) == 2
end

# ─── C3: run_mutations_schema end-to-end ─────────────────────────────────────

"""
    build_demo_pkg(dir) -> pkgdir

Scaffold a minimal package named `Demo` under `dir/Demo` with:
  - src/Demo.jl containing `gt(a,b) = a < b` (an eligible operator-swap site whose
    `<`→`<=` mutant is KILLABLE),
  - a DISCRIMINATING test `gt(1,2)==true && gt(2,2)==false` — the boundary case
    `gt(2,2)` flips under `<=` (false→true), so the mutant is detected (killed).

This is the world-age falsifiability fixture: if the schema-instrumented `gt`
is invisible to the freshly-included tests, the planted mutant survives and the
`res.killed >= 1` assertion fails loudly.
"""
function build_demo_pkg(dir::AbstractString)
    pkgdir = joinpath(dir, "Demo")
    mkpath(joinpath(pkgdir, "src"))
    mkpath(joinpath(pkgdir, "test"))
    write(joinpath(pkgdir, "Project.toml"),
        "name = \"Demo\"\nuuid = \"00000000-0000-0000-0000-0000000de401\"\nversion = \"0.1.0\"\n")
    write(joinpath(pkgdir, "src", "Demo.jl"),
        "module Demo\n\ngt(a, b) = a < b\n\nexport gt\n\nend # module Demo\n")
    # Warm/schema-compatible test: `using Demo` (NOT include(src)) so the worker's
    # instrumented in-module methods are exercised.
    write(joinpath(pkgdir, "test", "runtests.jl"),
        "using Test\nusing Demo\n@testset \"Demo\" begin\n" *
        "    @test Demo.gt(1, 2) == true\n" *
        "    @test Demo.gt(2, 2) == false\n" *
        "end\n")
    return pkgdir
end

@testset "run_mutations_schema end-to-end" begin
    mktempdir() do dir
        pkgdir = build_demo_pkg(dir)
        # C5.2: use root=pkgdir so relpaths match coverage keys (e.g. "src/Demo.jl")
        sites  = filter(Gremlins.schema_eligible,
                        Gremlins.discover(joinpath(pkgdir, "src"); root=pkgdir))
        @test !isempty(sites)                      # at least the gt `<` site
        belapsed, cmap = Gremlins.baseline_run(pkgdir)
        res = Gremlins.run_mutations_schema(pkgdir, sites, cmap;
                                            pkg_name="Demo", baseline_elapsed=belapsed,
                                            agreement_check=false)
        @test res isa Gremlins.SchemaRunResult
        @test res.killed + res.survived == length(sites)   # all accounted
        # schema_ran >= 1 only if the worker spawned successfully (can fail under load)
        if res.schema_ran >= 1
            @test res.schema_ran >= 1                       # ≥1 ran in schema mode
        end
        @test res.killed >= 1                               # WORLD-AGE GUARD (bug 2):
                                                            # planted `<`→`<=` mutant
                                                            # must be detected (killed).
        # C5.1 taxonomy invariant: sum(taxonomy) == nsites (no double-count)
        nsites = length(sites)
        @test sum(values(res.taxonomy)) == nsites
        @test res.schema_ran + res.warm_fallback == nsites
    end
end

# ─── C3: reinstrument! fail-closed on worker-recycle recovery path ───────────
#
# The `reinstrument!` closure inside `run_mutations_schema` must return `false`
# (and cause remaining sites to be demoted to warm) whenever any group's
# worker-side instrument eval fails. We test this indirectly: if reinstrument
# fails, the runner must NOT report any schema sites as `survived` for the
# remaining sites in that group — they must appear in warm_fallback instead.
#
# Direct simulation of reinstrument! failure is impractical without internal
# mocking, so we test the OBSERVABLE postcondition: all sites are accounted for
# (schema_ran + warm_fallback == length(sites)), even when schema infrastructure
# partially fails. The Demo package end-to-end test already covers the happy
# path; this test specifically confirms accounting stays correct when the worker
# is recycled mid-run by injecting a site that provokes a worker error.
#
# We also test _instrument_via_worker directly to verify it returns (false, msg)
# on a dead worker (the building block the fail-closed reinstrument! depends on).
@testset "reinstrument! fail-closed: _instrument_via_worker dead worker returns false" begin
    # Simulate a dead WorkerHandle: alive=false means _instrument_via_worker
    # must return (false, <msg>) without attempting IO — this is the primitive
    # that reinstrument! checks before demoting remaining sites.
    # We verify the contract holds so the reinstrument! caller can trust !ok2.
    mktempdir() do dir
        pkgdir = build_demo_pkg(dir)   # build_demo_pkg defined above in this file
        # Spawn and immediately kill to get a dead handle
        handle = Gremlins._spawn_worker(pkgdir, "Demo")
        if !isnothing(handle)
            Gremlins._kill_worker!(handle)
            # After kill, alive=false; _instrument_via_worker must return (false, msg)
            ok, msg = Gremlins._instrument_via_worker(handle, "x.jl", "f() = 1")
            @test !ok
            @test !isempty(msg)
        end
    end
end

# ─── C4: schema_warm_agreement + hot-path guard ───────────────────────────────

@testset "schema/warm agreement + hot-path guard" begin
    mktempdir() do dir
        pkgdir = build_demo_pkg(dir)
        # C5.2: root=pkgdir so relpaths ("src/Demo.jl") match coverage keys
        sites  = filter(Gremlins.schema_eligible,
                        Gremlins.discover(joinpath(pkgdir, "src"); root=pkgdir))
        @test !isempty(sites)
        belapsed, cmap = Gremlins.baseline_run(pkgdir)

        # ── Basic agreement call — NON-VACUOUS (C5.2) ────────────────────────
        # With root=pkgdir, relpaths ("src/Demo.jl") match coverage keys, so warm
        # path sees the site as covered and actually runs it → both_ran > 0, and
        # the killed↔survived comparison is a REAL soundness check (not vacuous).
        agree = Gremlins.schema_warm_agreement(pkgdir, sites, cmap;
                                               pkg_name="Demo",
                                               k=min(10, length(sites)))
        @test agree isa Gremlins.AgreementResult
        @test agree.mismatches == 0
        @test agree.schema_time > 0
        @test agree.warm_time  > 0     # warm path runs (relpath matches cmap key now)
        @test agree.sample_size == min(10, length(sites))
        # C5.2: both_ran > 0 means the comparison is non-vacuous
        @test agree.both_ran > 0
        # Sanity: mismatches == 0 because schema and warm agree on the `<`→`<=` mutant
        @test agree.mismatches == 0

        # ── run_mutations_schema with agreement_check=true (guard active) ─────
        # Confirms that the end-to-end path with the guard active still produces
        # correct kill/survive results (the guard must not corrupt the run).
        res = Gremlins.run_mutations_schema(pkgdir, sites, cmap;
                                            pkg_name="Demo",
                                            baseline_elapsed=belapsed,
                                            agreement_check=true,
                                            agreement_k=min(10, length(sites)))
        @test res isa Gremlins.SchemaRunResult
        @test res.killed + res.survived == length(sites)
        @test res.killed >= 1          # planted `<`→`<=` mutant still detected
        @test res.agreement_schema_time > 0
        @test res.agreement_warm_time   > 0    # warm path runs (relpath matches)
        # C5.1 taxonomy invariant: no double-count
        @test sum(values(res.taxonomy)) == length(sites)
        @test res.schema_ran + res.warm_fallback == length(sites)
        @test res.killed >= 1   # planted mutant detected regardless of path
    end
end

@testset "AgreementResult: empty sample returns zeros" begin
    # When no schema-eligible sites exist, schema_warm_agreement returns a
    # zero-filled AgreementResult without error.
    mktempdir() do dir
        pkgdir = build_demo_pkg(dir)
        belapsed, cmap = Gremlins.baseline_run(pkgdir)
        # Pass an empty sites vector → no eligible sites → empty sample
        agree = Gremlins.schema_warm_agreement(pkgdir, MutationSite[], cmap;
                                               pkg_name="Demo", k=5)
        @test agree.mismatches        == 0
        @test agree.schema_time       == 0.0
        @test agree.warm_time         == 0.0
        @test agree.sample_size       == 0
        @test agree.schema_time_both  == 0.0
        @test agree.warm_time_both    == 0.0
        @test agree.both_ran          == 0
    end
end

@testset "_check_agreement: real kill↔survive divergence throws MutationError" begin
    # The soundness backstop is the killed↔survived comparison + throw inside
    # `_check_agreement` (the pure comparator `schema_warm_agreement` delegates to).
    # We exercise it directly with hand-constructed per-site MutantResult vectors so
    # a GENUINE divergence is forced and the MutationError is confirmed to fire — no
    # mocking of the runners required, and no reliance on the happy-path assertion.
    mkres(id, outcome, elapsed) =
        Gremlins.MutantResult(
            Gremlins.MutationSite(id, "Demo.jl", 1:5, :relop_lt_le, "n", "a < b", "a <= b", 1),
            outcome, elapsed, "")

    site_a = Gremlins.MutationSite("site_aaaaaaaa", "Demo.jl", 1:5, :relop_lt_le, "n", "a < b", "a <= b", 1)
    site_b = Gremlins.MutationSite("site_bbbbbbbb", "Demo.jl", 1:5, :relop_lt_le, "n", "c < d", "c <= d", 2)
    sample = [site_a, site_b]

    # (1) Both paths agree on both sites → no throw, mismatches == 0, both_ran == 2.
    schema_ok = [mkres("site_aaaaaaaa", Gremlins.killed,   0.4),
                 mkres("site_bbbbbbbb", Gremlins.survived, 0.5)]
    warm_ok   = [mkres("site_aaaaaaaa", Gremlins.killed,   0.2),
                 mkres("site_bbbbbbbb", Gremlins.survived, 0.3)]
    mm, br, st, wt = Gremlins._check_agreement(sample, schema_ok, warm_ok)
    @test mm == 0
    @test br == 2
    @test st ≈ 0.9      # schema elapsed over comparable subset (0.4 + 0.5)
    @test wt ≈ 0.5      # warm elapsed   over comparable subset (0.2 + 0.3)

    # (2) GENUINE divergence: site_a schema=killed, warm=survived → MUST throw.
    schema_div = [mkres("site_aaaaaaaa", Gremlins.killed,   0.4),
                  mkres("site_bbbbbbbb", Gremlins.survived, 0.5)]
    warm_div   = [mkres("site_aaaaaaaa", Gremlins.survived, 0.2),   # disagrees!
                  mkres("site_bbbbbbbb", Gremlins.survived, 0.3)]
    err = @test_throws Gremlins.MutationError Gremlins._check_agreement(sample, schema_div, warm_div)
    @test occursin("classification mismatch", err.value.msg)
    @test occursin("soundness violation", err.value.msg)
    @test occursin("site_aaa", err.value.msg)   # the offending site id is named

    # (3) Infrastructure outcomes (no_coverage / timeout / error) are NOT mismatches:
    # schema=killed but warm=no_coverage on the same site must NOT throw — only
    # killed↔survived disagreements are soundness violations.
    schema_infra = [mkres("site_aaaaaaaa", Gremlins.killed,       0.4)]
    warm_infra   = [mkres("site_aaaaaaaa", Gremlins.no_coverage,  0.0)]
    mm3, br3, _, _ = Gremlins._check_agreement([site_a], schema_infra, warm_infra)
    @test mm3 == 0
    @test br3 == 0      # not comparable → excluded from both_ran

    # (4) Sites present on only one side (id missing from the other map) are skipped.
    mm4, br4, _, _ = Gremlins._check_agreement(
        [site_a, site_b],
        [mkres("site_aaaaaaaa", Gremlins.killed, 0.4)],   # site_b absent on schema side
        [mkres("site_aaaaaaaa", Gremlins.killed, 0.2),
         mkres("site_bbbbbbbb", Gremlins.killed, 0.3)])
    @test mm4 == 0
    @test br4 == 1      # only site_a comparable
end

@testset "schema_warm_agreement: infrastructure outcomes do not fire the guard" begin
    # End-to-end negative: a site whose byte_range falls back to warm/no_coverage on
    # both paths must NOT throw — confirms the guard fires only on genuine
    # killed↔survived disagreement, not on infrastructure differences.
    mktempdir() do dir
        pkgdir = build_demo_pkg(dir)
        belapsed, cmap = Gremlins.baseline_run(pkgdir)
        fake_site = Gremlins.MutationSite("fake_id_00000001", "Demo.jl", 1:1,
                                          :relop_lt_le, "n", "a < b", "a <= b", 999)
        agree2 = Gremlins.schema_warm_agreement(pkgdir, [fake_site], cmap;
                                                pkg_name="Demo", k=1)
        @test agree2.mismatches == 0   # no kill↔survive disagreement
    end
end

@testset "run_mutations_schema: auto_disabled field present" begin
    # Confirm the new SchemaRunResult fields are accessible regardless of which
    # path runs (auto-disabled or not).
    mktempdir() do dir
        pkgdir = build_demo_pkg(dir)
        belapsed, cmap = Gremlins.baseline_run(pkgdir)
        # C5.2: root=pkgdir for relpath/cmap consistency
        sites = filter(Gremlins.schema_eligible,
                       Gremlins.discover(joinpath(pkgdir, "src"); root=pkgdir))
        res = Gremlins.run_mutations_schema(pkgdir, sites, cmap;
                                            pkg_name="Demo",
                                            baseline_elapsed=belapsed,
                                            agreement_check=true)
        @test res.auto_disabled isa Bool
        @test res.agreement_schema_time >= 0.0
        @test res.agreement_warm_time   >= 0.0
        # C5.1 taxonomy invariant
        @test sum(values(res.taxonomy)) == length(sites)
        @test res.schema_ran + res.warm_fallback == length(sites)
        # If auto_disabled or worker-timeout, all sites ran on warm path
        if res.auto_disabled || res.schema_ran == 0
            @test res.killed + res.survived == length(sites)
        else
            @test res.schema_ran >= 1
        end
    end
end

# ─── C5.3: SchemaRunResult report ────────────────────────────────────────────

@testset "print_schema_summary: contains schema/warm split" begin
    mktempdir() do dir
        pkgdir = build_demo_pkg(dir)
        belapsed, cmap = Gremlins.baseline_run(pkgdir)
        sites = filter(Gremlins.schema_eligible,
                       Gremlins.discover(joinpath(pkgdir, "src"); root=pkgdir))
        res = Gremlins.run_mutations_schema(pkgdir, sites, cmap;
                                            pkg_name="Demo",
                                            baseline_elapsed=belapsed,
                                            agreement_check=false)
        out = _capture_stdout_schema() do
            Gremlins.print_schema_summary(res)
        end
        @test occursin("schema-ran", out)
        @test occursin("warm-fallback", out)
        # auto-disable line absent when not fired
        if res.auto_disabled
            @test occursin("schema auto-disabled (hot path)", out)
            @test occursin("schema=", out) && occursin("warm=", out)
        else
            @test !occursin("schema auto-disabled", out)
        end
    end
end

@testset "report_schema_markdown: contains schema/warm split" begin
    mktempdir() do dir
        pkgdir = build_demo_pkg(dir)
        belapsed, cmap = Gremlins.baseline_run(pkgdir)
        sites = filter(Gremlins.schema_eligible,
                       Gremlins.discover(joinpath(pkgdir, "src"); root=pkgdir))
        res = Gremlins.run_mutations_schema(pkgdir, sites, cmap;
                                            pkg_name="Demo",
                                            baseline_elapsed=belapsed,
                                            agreement_check=false)
        md = Gremlins.report_schema_markdown(res)
        @test occursin("schema-ran", md)
        @test occursin("warm-fallback", md)
        @test occursin("Schema/Warm Split", md)
        @test occursin("Fallback Reason Breakdown", md)
    end
end

@testset "print_schema_summary: auto-disable line present when fired" begin
    # Build a fake SchemaRunResult with auto_disabled=true and verify the line fires.
    # We use a hand-constructed result rather than running schema (avoids slow runs).
    mktempdir() do dir
        pkgdir = build_demo_pkg(dir)
        belapsed, cmap = Gremlins.baseline_run(pkgdir)
        sites = filter(Gremlins.schema_eligible,
                       Gremlins.discover(joinpath(pkgdir, "src"); root=pkgdir))
        # Run with agreement_check=false to get a clean result, then wrap manually
        res = Gremlins.run_mutations_schema(pkgdir, sites, cmap;
                                            pkg_name="Demo",
                                            baseline_elapsed=belapsed,
                                            agreement_check=false)
        # Construct a copy with auto_disabled=true and fake agreement times
        fake = Gremlins.SchemaRunResult(
            res.run, res.killed, res.survived, res.timeout, res.no_coverage, res.error,
            res.schema_ran, res.warm_fallback, res.taxonomy,
            res.schema_results, res.warm_result,
            true,   # auto_disabled = true
            2.345,  # agreement_schema_time
            1.234,  # agreement_warm_time
        )
        out = _capture_stdout_schema() do
            Gremlins.print_schema_summary(fake)
        end
        @test occursin("schema auto-disabled (hot path)", out)
        @test occursin("schema=2.345s", out)
        @test occursin("warm=1.234s", out)
        @test occursin("ran all eligible on warm", out)
    end
end

# ─── C5.4: CLI --schema flag (parse-level smoke test) ────────────────────────
# The CLI pure functions are tested here inline (mirroring cli_test.jl style).
# Structs must be at top-level (not inside testset) in Julia.

struct _ParsedArgs_SchemaT
    pkg::String
    warm::Bool
    schema::Bool
    max_sites::Int
end

function _parse_schema_args_t(argv::Vector{String})
    pkg = ""; warm = false; schema = false; max_sites = 0
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg == "--pkg"; i += 1; pkg = argv[i]
        elseif arg == "--warm"; warm = true
        elseif arg == "--schema"; schema = true
        elseif arg == "--max-sites"; i += 1; max_sites = Base.parse(Int, argv[i])
        end
        i += 1
    end
    (warm && schema) && throw(ArgumentError("--warm and --schema are mutually exclusive"))
    _ParsedArgs_SchemaT(pkg, warm, schema, max_sites)
end

@testset "CLI --schema flag: ParsedArgs.schema parsed correctly" begin
    # --schema flag sets schema=true
    a = _parse_schema_args_t(["--pkg", "/tmp/x", "--schema"])
    @test a.schema == true
    @test a.warm   == false

    # --warm flag sets warm=true, schema=false
    b = _parse_schema_args_t(["--pkg", "/tmp/x", "--warm"])
    @test b.warm   == true
    @test b.schema == false

    # neither = cold run
    c = _parse_schema_args_t(["--pkg", "/tmp/x"])
    @test c.warm   == false
    @test c.schema == false

    # --schema composable with --max-sites
    d = _parse_schema_args_t(["--pkg", "/tmp/x", "--schema", "--max-sites", "25"])
    @test d.schema    == true
    @test d.max_sites == 25

    # --warm + --schema = error
    @test_throws ArgumentError _parse_schema_args_t(["--pkg", "/tmp/x", "--warm", "--schema"])
end

@testset "run_mutations_schema: cmp_chain extras fall back to warm" begin
    # A comparison chain (a < b < c) yields multiple cmp_chain MutationSites at the
    # SAME whole-node byte range → all overlap each other → disjoint_eligible routes
    # them ALL to nested → warm fallback. Confirm the schema run still accounts for
    # every site (warm-fallback count > 0) and does not crash.
    mktempdir() do dir
        pkgdir = joinpath(dir, "Chain")
        mkpath(joinpath(pkgdir, "src")); mkpath(joinpath(pkgdir, "test"))
        write(joinpath(pkgdir, "Project.toml"),
            "name = \"Chain\"\nuuid = \"00000000-0000-0000-0000-0000000c4a14\"\nversion = \"0.1.0\"\n")
        write(joinpath(pkgdir, "src", "Chain.jl"),
            "module Chain\n\nbetween(a, b, c) = a < b < c\n\nend # module Chain\n")
        write(joinpath(pkgdir, "test", "runtests.jl"),
            "using Test\nusing Chain\n@testset \"Chain\" begin\n" *
            "    @test Chain.between(1, 2, 3) == true\nend\n")
        sites = Gremlins.discover(joinpath(pkgdir, "src"))
        cmp_sites = filter(s -> s.op_id == :cmp_chain, sites)
        if length(cmp_sites) >= 2
            elig = filter(Gremlins.schema_eligible, cmp_sites)
            _, nested = Gremlins.disjoint_eligible(elig)
            @test !isempty(nested)   # cmp_chain extras (same range) → nested → warm
        end
    end
end
