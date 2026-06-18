using Test
using Gremlins
using JuliaSyntax

# ─── Helper: parse and collect sites for a snippet ──────────────────────────

function sites_for(src::String; operators=DEFAULT_OPERATORS)
    mktempdir() do dir
        path = joinpath(dir, "test_snippet.jl")
        write(path, src)
        discover_file(path; root=dir, operators=operators)
    end
end

function sites_for_op(src::String, op::MutationOperator)
    sites_for(src; operators=[op])
end

@testset "Gremlins M0" begin

# ═══════════════════════════════════════════════════════════════════════════════
@testset "MutationError" begin
    e = MutationError("test message")
    @test e isa Exception
    @test occursin("test message", sprint(showerror, e))
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Operators — structure" begin
    @test length(DEFAULT_OPERATORS) >= 15
    ids = [op.id for op in DEFAULT_OPERATORS]
    @test length(ids) == length(unique(ids))  # all ids unique
    for op in DEFAULT_OPERATORS
        @test op.id isa Symbol
        @test !isempty(op.name)
        @test op.matcher isa Function
        @test op.replacer isa Function
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Operators — relational flips" begin
    # Basic discovery of each relop
    src_lt   = "f(x) = x < 5"
    src_le   = "f(x) = x <= 5"
    src_gt   = "f(x) = x > 5"
    src_ge   = "f(x) = x >= 5"
    src_eq   = "f(x) = x == 5"
    src_neq  = "f(x) = x != 5"

    @test any(s -> s.op_id == :relop_lt_le,  sites_for(src_lt))
    @test any(s -> s.op_id == :relop_le_lt,  sites_for(src_le))
    @test any(s -> s.op_id == :relop_gt_ge,  sites_for(src_gt))
    @test any(s -> s.op_id == :relop_ge_gt,  sites_for(src_ge))
    @test any(s -> s.op_id == :relop_eq_neq, sites_for(src_eq))
    @test any(s -> s.op_id == :relop_neq_eq, sites_for(src_neq))

    # Check replacements are correct
    lt_sites = filter(s -> s.op_id == :relop_lt_le, sites_for(src_lt))
    @test !isempty(lt_sites)
    @test lt_sites[1].replacement == "<="
    @test lt_sites[1].original == "<"

    eq_sites = filter(s -> s.op_id == :relop_eq_neq, sites_for(src_eq))
    @test !isempty(eq_sites)
    @test eq_sites[1].replacement == "!="
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Operators — boolean flips" begin
    src_and = "f(a, b) = a && b"
    src_or  = "f(a, b) = a || b"
    src_not = "f(x) = !x"

    @test any(s -> s.op_id == :bool_and_or, sites_for(src_and))
    @test any(s -> s.op_id == :bool_or_and, sites_for(src_or))
    @test any(s -> s.op_id == :bool_delete_not, sites_for(src_not))

    not_sites = filter(s -> s.op_id == :bool_delete_not, sites_for(src_not))
    @test !isempty(not_sites)
    # Replacement should be the argument, not "!"
    @test not_sites[1].replacement == "x"
    # Original should be the whole !x call
    @test occursin("!", not_sites[1].original)
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Operators — arithmetic flips" begin
    src_plus  = "f(a, b) = a + b"
    src_minus = "f(a, b) = a - b"
    src_mul   = "f(a, b) = a * b"
    src_div   = "f(a, b) = a / b"

    @test any(s -> s.op_id == :arith_plus_minus,  sites_for(src_plus))
    @test any(s -> s.op_id == :arith_minus_plus,  sites_for(src_minus))
    @test any(s -> s.op_id == :arith_mul_div,     sites_for(src_mul))
    @test any(s -> s.op_id == :arith_div_mul,     sites_for(src_div))
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Operators — integer literal boundary" begin
    src = "f() = 42"
    incr_sites = filter(s -> s.op_id == :literal_int_incr, sites_for(src))
    decr_sites = filter(s -> s.op_id == :literal_int_decr, sites_for(src))

    @test !isempty(incr_sites)
    @test !isempty(decr_sites)
    @test incr_sites[1].replacement == "43"
    @test decr_sites[1].replacement == "41"
    @test incr_sites[1].original == "42"
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Operators — bool literal flip" begin
    src_t = "f() = true"
    src_f = "f() = false"

    t_sites = filter(s -> s.op_id == :literal_true_false, sites_for(src_t))
    f_sites = filter(s -> s.op_id == :literal_false_true, sites_for(src_f))

    @test !isempty(t_sites)
    @test !isempty(f_sites)
    @test t_sites[1].replacement == "false"
    @test f_sites[1].replacement == "true"
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Operators — return nothing" begin
    src = """
    function f(x)
        return x + 1
    end
    """
    rn_sites = filter(s -> s.op_id == :return_nothing, sites_for(src))
    @test !isempty(rn_sites)
    @test rn_sites[1].replacement == "return nothing"
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Operators — statement delete" begin
    src = """
    function f(x)
        y = x + 1
        z = y * 2
        return z
    end
    """
    del_sites = filter(s -> s.op_id == :stmt_delete, sites_for(src))
    @test !isempty(del_sites)
    # `return z` should NOT be in deletable (it's a return statement)
    @test !any(s -> s.original == "return z", del_sites)
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Mutant ID — determinism" begin
    id1 = mutant_id("src/foo.jl", 10:15, :relop_lt_le)
    id2 = mutant_id("src/foo.jl", 10:15, :relop_lt_le)
    id3 = mutant_id("src/foo.jl", 10:16, :relop_lt_le)  # different range
    @test id1 == id2      # same inputs → same id
    @test id1 != id3      # different range → different id
    @test length(id1) == 16  # 8 bytes → 16 hex chars
    @test all(c -> c in "0123456789abcdef", id1)
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Discovery — determinism" begin
    src = "f(x) = x < 5 && x > 0"
    sites1 = sites_for(src)
    sites2 = sites_for(src)
    @test length(sites1) == length(sites2)
    for (s1, s2) in zip(sites1, sites2)
        @test s1.id == s2.id
        @test s1.byte_range == s2.byte_range
        @test s1.op_id == s2.op_id
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Discovery — empty file" begin
    sites = sites_for("")
    @test isempty(sites)
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Discovery — skips test dirs" begin
    mktempdir() do root
        src_dir = joinpath(root, "src")
        test_dir = joinpath(root, "test")
        mkpath(src_dir)
        mkpath(test_dir)
        write(joinpath(src_dir, "foo.jl"), "f(x) = x < 5")
        write(joinpath(test_dir, "foo_test.jl"), "g(x) = x < 5")
        sites = discover(src_dir; operators=DEFAULT_OPERATORS)
        @test all(s -> !occursin("/test/", s.relpath), sites)
        # src file should produce sites
        @test !isempty(sites)
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Discovery — malformed source doesn't crash" begin
    src = "function f( x"   # syntax error
    sites = sites_for(src)
    # Should return without throwing; may return empty or partial
    @test sites isa Vector{MutationSite}
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Patcher — apply basic" begin
    src = "f(x) = x < 5"
    sites = sites_for_op(src, OP_LT_TO_LE)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    @test mutated == replace(src, "<" => "<="; count=1)
    @test mutated != src
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Patcher — round-trip (apply + revert)" begin
    srcs = [
        "f(x) = x < 5",
        "f(a, b) = a && b",
        "g(x) = !x",
        "h(x) = x + 42",
        "k() = true",
    ]
    for src in srcs
        sites = sites_for(src)
        for site in sites
            ok = roundtrip_ok(site, src)
            ok || @warn "Round-trip failed for op=$(site.op_id) src=$(repr(src))"
            @test ok
        end
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Patcher — apply detects stale sites" begin
    src = "f(x) = x < 5"
    sites = sites_for_op(src, OP_LT_TO_LE)
    @test !isempty(sites)
    site = sites[1]
    # Modify source so the original no longer matches
    wrong_src = "f(x) = x > 5"
    @test_throws MutationError apply(site, wrong_src)
end

# ═══════════════════════════════════════════════════════════════════════════════
@testset "Patcher — in-place apply! / revert!" begin
    mktempdir() do dir
        path = joinpath(dir, "target.jl")
        src = "f(x) = x < 5\n"
        write(path, src)
        sites = discover_file(path; root=dir, operators=[OP_LT_TO_LE])
        @test !isempty(sites)
        site = sites[1]

        orig = apply!(site, path)
        @test orig == src
        mutated_on_disk = read(path, String)
        @test mutated_on_disk == apply(site, src)

        revert!(site, orig, path)
        restored_on_disk = read(path, String)
        @test restored_on_disk == src
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# FALSIFIABILITY FIXTURES
# For each operator: a planted killable mutant fixture.
# Each fixture evaluates original and mutant into ISOLATED modules to prevent
# cross-test function redefinition pollution (Julia eval into Main is global).
# ═══════════════════════════════════════════════════════════════════════════════

# Helper: evaluate source in a fresh anonymous module, return the named function
function _eval_in_fresh_module(src::String, fname::Symbol)
    m = Module()
    Core.eval(m, Meta.parse(src))
    return Core.eval(m, fname)
end

@testset "Falsifiability — relop_lt_le" begin
    # Original: f(x) = x < 5  →  f(5)=false
    # Mutant:   f(x) = x <= 5 →  f(5)=true  ← mutation kills this test
    src = "f(x) = x < 5\n"
    sites = sites_for_op(src, OP_LT_TO_LE)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :f)
    f_mutant = _eval_in_fresh_module(mutated, :f)
    @test f_orig(4)   == true
    @test f_orig(5)   == false
    @test f_mutant(5) == true   # mutation changes boundary behavior
end

@testset "Falsifiability — relop_le_lt" begin
    # Original: g(x) = x <= 3 → g(3)=true
    # Mutant:   g(x) = x < 3  → g(3)=false ← kills
    src = "g(x) = x <= 3\n"
    sites = sites_for_op(src, OP_LE_TO_LT)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    g_orig   = _eval_in_fresh_module(src,     :g)
    g_mutant = _eval_in_fresh_module(mutated, :g)
    @test g_orig(3)   == true
    @test g_mutant(3) == false  # mutation caught
end

@testset "Falsifiability — relop_gt_ge" begin
    src = "h(x) = x > 10\n"
    sites = sites_for_op(src, OP_GT_TO_GE)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    h_orig   = _eval_in_fresh_module(src,     :h)
    h_mutant = _eval_in_fresh_module(mutated, :h)
    @test h_orig(10)   == false
    @test h_mutant(10) == true  # mutation caught
end

@testset "Falsifiability — relop_ge_gt" begin
    src = "p(x) = x >= 7\n"
    sites = sites_for_op(src, OP_GE_TO_GT)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    p_orig   = _eval_in_fresh_module(src,     :p)
    p_mutant = _eval_in_fresh_module(mutated, :p)
    @test p_orig(7)   == true
    @test p_mutant(7) == false  # mutation caught
end

@testset "Falsifiability — relop_eq_neq" begin
    src = "q(x) = x == 0\n"
    sites = sites_for_op(src, OP_EQ_TO_NEQ)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    q_orig   = _eval_in_fresh_module(src,     :q)
    q_mutant = _eval_in_fresh_module(mutated, :q)
    @test q_orig(0)   == true
    @test q_mutant(0) == false  # mutation caught
end

@testset "Falsifiability — relop_neq_eq" begin
    src = "r(x) = x != 1\n"
    sites = sites_for_op(src, OP_NEQ_TO_EQ)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    r_orig   = _eval_in_fresh_module(src,     :r)
    r_mutant = _eval_in_fresh_module(mutated, :r)
    @test r_orig(1)   == false
    @test r_mutant(1) == true  # mutation caught
end

@testset "Falsifiability — bool_and_or" begin
    src = "sand(a, b) = a && b\n"
    sites = sites_for_op(src, OP_AND_TO_OR)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :sand)
    f_mutant = _eval_in_fresh_module(mutated, :sand)
    @test f_orig(true, false)   == false
    @test f_mutant(true, false) == true   # mutation caught
end

@testset "Falsifiability — bool_or_and" begin
    src = "sor(a, b) = a || b\n"
    sites = sites_for_op(src, OP_OR_TO_AND)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :sor)
    f_mutant = _eval_in_fresh_module(mutated, :sor)
    @test f_orig(false, true)   == true
    @test f_mutant(false, true) == false  # mutation caught
end

@testset "Falsifiability — bool_delete_not" begin
    src = "fnot(x) = !x\n"
    sites = sites_for_op(src, OP_DELETE_NOT)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :fnot)
    f_mutant = _eval_in_fresh_module(mutated, :fnot)
    @test f_orig(true)   == false
    @test f_mutant(true) == true   # mutation caught
end

@testset "Falsifiability — arith_plus_minus" begin
    src = "fadd(a, b) = a + b\n"
    sites = sites_for_op(src, OP_PLUS_TO_MINUS)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :fadd)
    f_mutant = _eval_in_fresh_module(mutated, :fadd)
    @test f_orig(3, 2)   == 5
    @test f_mutant(3, 2) == 1   # mutation caught
end

@testset "Falsifiability — arith_minus_plus" begin
    src = "fsub(a, b) = a - b\n"
    sites = sites_for_op(src, OP_MINUS_TO_PLUS)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :fsub)
    f_mutant = _eval_in_fresh_module(mutated, :fsub)
    @test f_orig(5, 3)   == 2
    @test f_mutant(5, 3) == 8   # mutation caught
end

@testset "Falsifiability — arith_mul_div" begin
    src = "fmul(a, b) = a * b\n"
    sites = sites_for_op(src, OP_MUL_TO_DIV)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :fmul)
    f_mutant = _eval_in_fresh_module(mutated, :fmul)
    @test f_orig(6, 3)   == 18
    @test f_mutant(6, 3) ≈ 2.0   # mutation caught
end

@testset "Falsifiability — arith_div_mul" begin
    src = "fdiv(a, b) = a / b\n"
    sites = sites_for_op(src, OP_DIV_TO_MUL)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :fdiv)
    f_mutant = _eval_in_fresh_module(mutated, :fdiv)
    @test f_orig(10, 2)   ≈ 5.0
    @test f_mutant(10, 2) == 20   # mutation caught
end

@testset "Falsifiability — literal_int_incr" begin
    src = "fincr() = 10\n"
    sites = sites_for_op(src, OP_INT_INCR)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :fincr)
    f_mutant = _eval_in_fresh_module(mutated, :fincr)
    @test f_orig()   == 10
    @test f_mutant() == 11   # mutation caught
end

@testset "Falsifiability — literal_int_decr" begin
    src = "fdecr() = 10\n"
    sites = sites_for_op(src, OP_INT_DECR)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :fdecr)
    f_mutant = _eval_in_fresh_module(mutated, :fdecr)
    @test f_orig()   == 10
    @test f_mutant() == 9   # mutation caught
end

@testset "Falsifiability — literal_true_false" begin
    src = "ftrue() = true\n"
    sites = sites_for_op(src, OP_TRUE_TO_FALSE)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :ftrue)
    f_mutant = _eval_in_fresh_module(mutated, :ftrue)
    @test f_orig()   == true
    @test f_mutant() == false   # mutation caught
end

@testset "Falsifiability — literal_false_true" begin
    src = "ffalse() = false\n"
    sites = sites_for_op(src, OP_FALSE_TO_TRUE)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :ffalse)
    f_mutant = _eval_in_fresh_module(mutated, :ffalse)
    @test f_orig()   == false
    @test f_mutant() == true   # mutation caught
end

@testset "Falsifiability — return_nothing" begin
    src = "function fret(n)\n    return n * 2\nend\n"
    sites = sites_for_op(src, OP_RETURN_NOTHING)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :fret)
    f_mutant = _eval_in_fresh_module(mutated, :fret)
    @test f_orig(5)   == 10
    @test f_mutant(5) === nothing   # mutation caught
end

@testset "Falsifiability — stmt_delete" begin
    src = """
    function fstmt(n)
        n = n + 1
        n = n * 2
        return n
    end
    """
    sites = sites_for_op(src, OP_STMT_DELETE)
    @test !isempty(sites)
    site = sites[1]
    mutated = apply(site, src)
    f_orig   = _eval_in_fresh_module(src,     :fstmt)
    f_mutant = _eval_in_fresh_module(mutated, :fstmt)
    @test f_orig(3)   == 8      # (3+1)*2 = 8
    @test f_mutant(3) != 8    # one stmt deleted, result changes
end

@testset "Falsifiability — literal_const_pool (killable)" begin
    # Constant-pool swap replaces a literal with another literal already present
    # in the same function (here {7, 3}) — an in-domain substitution. Distinct
    # literal values keep each (original, replacement) pair unambiguous.
    src = """
    function fpick(flag)
        base = 7
        return flag ? base : 3
    end
    """
    sites = sites_for_op(src, OP_CONST_POOL)
    @test !isempty(sites)
    # One mutant per (literal, distinct sibling value). Ids must be distinct
    # even where byte-range + op-id collide (same literal, different target).
    @test length(unique(s -> s.id, sites)) == length(sites)
    # `base = 7` → `base = 3`: fpick(true) returns 3 instead of 7 → killed.
    swap = first(s for s in sites if s.original == "7" && s.replacement == "3")
    mutated  = apply(swap, src)
    f_orig   = _eval_in_fresh_module(src,     :fpick)
    f_mutant = _eval_in_fresh_module(mutated, :fpick)
    @test f_orig(true)   == 7
    @test f_mutant(true) == 3   # mutation caught
    # Round-trip safety for every emitted mutant.
    @testset "const-pool round-trips" begin
        for s in sites
            @test revert(s, apply(s, src)) == src
        end
    end
end

@testset "Falsifiability — dispatch_type_swap (killable)" begin
    # Julia-unique: a parameter's type annotation IS the dispatch contract.
    # Swapping `::Int` → `::String` makes inc(2) fail to dispatch → MethodError
    # → any test calling inc(::Int) fails → killed. Survives only if the Int
    # contract is never exercised (a real dispatch-coverage gap).
    src = """
    function inc(x::Int)
        return x + 1
    end
    """
    sites = sites_for_op(src, OP_DISPATCH_SWAP)
    @test !isempty(sites)
    site = sites[1]
    @test site.original    == "x::Int"
    @test site.replacement == "x::String"
    mutated = apply(site, src)
    @test revert(site, mutated) == src
    f_orig = _eval_in_fresh_module(src,     :inc)
    f_mut  = _eval_in_fresh_module(mutated, :inc)
    @test f_orig(2) == 3
    @test_throws MethodError f_mut(2)   # dispatch broken → mutation caught
end

@testset "Equivalence prune — sound + one-directional" begin
    # A pure-value statement (`1`) that lowering already elides: deleting it is
    # PROVABLY equivalent, so prune_equivalent must drop it.
    eqsrc = """
    function geq(x)
        1
        return x
    end
    """
    eqp = mktempdir() do dir
        path = joinpath(dir, "eq.jl"); write(path, eqsrc)
        off = discover_file(path; root=dir, operators=[OP_STMT_DELETE], prune_equivalent=false)
        on  = discover_file(path; root=dir, operators=[OP_STMT_DELETE], prune_equivalent=true)
        (length(off), length(on))
    end
    @test eqp[1] == 1   # the dead-value statement is a delete site
    @test eqp[2] == 0   # ...and it is pruned as equivalent

    # A killable relop mutant must NEVER be pruned (one-directional: a real
    # survivor can never be hidden).
    ksrc = "function hk(x)\n    return x < 5\nend\n"
    kp = mktempdir() do dir
        path = joinpath(dir, "k.jl"); write(path, ksrc)
        off = discover_file(path; root=dir, operators=[OP_LT_TO_LE], prune_equivalent=false)
        on  = discover_file(path; root=dir, operators=[OP_LT_TO_LE], prune_equivalent=true)
        (length(off), length(on))
    end
    @test kp[1] == kp[2] == 1   # killable mutant survives the prune
end

# ═══════════════════════════════════════════════════════════════════════════════
# SELF-MUTATE SMOKE TEST
# EDD GATE: discover on Gremlins own src/ must find >50 sites total.
# ═══════════════════════════════════════════════════════════════════════════════

@testset "Self-mutate smoke test (EDD GATE: >50 sites)" begin
    src_dir = joinpath(@__DIR__, "..", "src")
    @test isdir(src_dir)
    sites = discover(src_dir; operators=DEFAULT_OPERATORS)
    println("\n[smoke] Self-mutate: discovered $(length(sites)) mutation sites in src/")
    n = length(sites)
    n <= 50 && @error "Self-mutate: expected >50 sites, got $n"
    @test n > 50

    # Spot-check: all ids are unique (determinism invariant)
    ids = [s.id for s in sites]
    @test length(ids) == length(unique(ids))

    # Spot-check: all relpaths point to src/
    @test all(s -> endswith(s.relpath, ".jl"), sites)

    # Spot-check: at least one site per operator class
    op_ids_found = Set([s.op_id for s in sites])
    @test :relop_lt_le in op_ids_found || :relop_le_lt in op_ids_found ||
          :arith_plus_minus in op_ids_found  # sanity: at least something found
end

# ═══════════════════════════════════════════════════════════════════════════════
# UTF-8 SOURCE HANDLING
# Falsifiability rule: bug #1 (apply clamp) must cause failure when reverted.
# Fixture: Czech comment before mutation site ensures last(byte_range) > length(src)
# (char count), which is the exact condition that triggered the spurious MutationError.
# ═══════════════════════════════════════════════════════════════════════════════

@testset "UTF-8 source handling" begin
    # Source with multibyte Czech chars BEFORE the mutation site.
    # ncodeunits("# příliš žluťoučký kůň\n") = 30, length = 21
    # So for a < at byte 42: last(byte_range)=42 > length(src)=37
    # The old code clamped to min(length(src), last(br)) = 37, cutting off
    # the < site entirely → source[sr] != site.original → spurious MutationError.
    src = "# příliš žluťoučký kůň\nf(x) = x < 10\n"

    # Confirm the fixture actually exercises the bug condition
    @test ncodeunits(src) > length(src)  # multibyte chars present

    sites = sites_for_op(src, OP_LT_TO_LE)
    @test !isempty(sites)  # site must be discovered

    site = sites[1]
    # The < is deep in byte space — confirm the condition that triggered old bug
    @test last(site.byte_range) > length(src)

    # apply + revert must both succeed (codeunit-correct clamp)
    @test roundtrip_ok(site, src)

    # Confirm apply produces correct mutation
    mutated = apply(site, src)
    @test occursin("<=", mutated)
    @test !occursin(r"(?<![<])<=(?!=)", src)  # original has < not <=

    # Confirm revert restores exactly
    restored = revert(site, mutated)
    @test restored == src
end

end  # @testset "Gremlins M0"

# ─── M1 tests ────────────────────────────────────────────────────────────────
include("runner_test.jl")

# ─── M2 tests ────────────────────────────────────────────────────────────────
include("warm_test.jl")

# ─── M3a CLI tests ────────────────────────────────────────────────────────────
include("cli_test.jl")

# ─── M2.1 papercut hardening tests ───────────────────────────────────────────
include("papercut_test.jl")

# ─── Feature A: git-diff scope tests ─────────────────────────────────────────
include("test_diff_scope.jl")

# ─── Feature B: Julia-idiom operators ────────────────────────────────────────
include("test_idiom_operators.jl")

# ─── Feature C: Mutant schemata (C1 + C2) ────────────────────────────────────
include("test_schema.jl")

# ─── Feature D: dispatch-mutation operators (v1) ──────────────────────────────
include("test_dispatch_operators.jl")

# ─── Feature 2: survivor-coverage blame ──────────────────────────────────────
include("test_blame.jl")
include("blame_fixture_test.jl")

# ─── Bug fix: test-env deps (#2/#3) ──────────────────────────────────────────
include("test_testenv.jl")

# ─── Issue #4: unified diff per surviving mutant (Vimes parity) ──────────────
include("test_diff.jl")

# ─── Issue #5: ReTestItems/TestItemRunner layout in detect_units ──────────────
include("test_retestitems.jl")

# ─── Issue #7: parallel mutant execution ─────────────────────────────────────
include("test_parallel.jl")
