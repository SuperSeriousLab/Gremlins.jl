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
