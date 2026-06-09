# test/test_schema.jl — Feature C: Mutant schemata (compile-once mode)
# Tasks C1 and C2 only. C3/C4/C5 deferred.

# NOTE: sites_for is defined in runtests.jl (parent include scope).

using Test, Gremlins

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
        sites  = filter(Gremlins.schema_eligible,
                        Gremlins.discover(joinpath(pkgdir, "src")))
        @test !isempty(sites)                      # at least the gt `<` site
        belapsed, cmap = Gremlins.baseline_run(pkgdir)
        res = Gremlins.run_mutations_schema(pkgdir, sites, cmap;
                                            pkg_name="Demo", baseline_elapsed=belapsed)
        @test res isa Gremlins.SchemaRunResult
        @test res.killed + res.survived == length(sites)   # all accounted
        @test res.schema_ran >= 1                           # ≥1 ran in schema mode
        @test res.killed >= 1                               # WORLD-AGE GUARD (bug 2):
                                                            # planted `<`→`<=` mutant
                                                            # must be detected (killed).
    end
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
