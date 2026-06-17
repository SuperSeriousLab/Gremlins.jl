# test_dispatch_operators.jl — dispatch-mutation operators (v1: union-drop, where-relax)
using Test
using Gremlins
using JuliaSyntax
using JuliaSyntax: @K_str, kind, children, is_leaf

# Reuse the same fresh-module eval helper shape as runtests.jl.
function _eval_fresh(src::String, fname::Symbol)
    m = Module()
    Core.eval(m, Meta.parse(src))
    return Core.eval(m, fname)
end

# Collect sites for a snippet under a single operator (mirrors runtests.jl helpers).
function _sites(src::String, op::MutationOperator)
    mktempdir() do dir
        path = joinpath(dir, "snip.jl")
        write(path, src)
        discover_file(path; root=dir, operators=[op])
    end
end

@testset "Dispatch operators (v1)" begin

# ── Helper: _is_dispatch_sig_param accepts where-methods, rejects non-params ──
@testset "_is_dispatch_sig_param — where-aware" begin
    # Find the `x::T` :: node in a snippet and run the helper on it.
    function _param_node(code)
        t = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, code; ignore_errors=true)
        found = Ref{Any}(nothing)
        walk(n) = begin
            if kind(n) == K"::" && !is_leaf(n) && children(n) !== nothing &&
               length(children(n)) == 2 && is_leaf(children(n)[1]) &&
               children(n)[1].val === :x
                found[] = n
            end
            cs = children(n); cs === nothing || foreach(walk, cs)
        end
        walk(t)
        found[]
    end
    f = Gremlins._is_dispatch_sig_param
    @test f(_param_node("g(x::Int) = x")) == true                       # short-form
    @test f(_param_node("function g(x::Int); x; end")) == true          # long-form
    @test f(_param_node("g(x::T) where T<:Real = x")) == true           # short where
    @test f(_param_node("function g(x::T) where T<:Real; x; end")) == true  # long where
    @test f(_param_node("g() = (x::Int = 3; x)")) == false              # typed local
end


# ── OP_UNION_DROP ──
@testset "OP_UNION_DROP — enumeration + falsifiability" begin
    src = "fu(x::Union{Int,String}) = x isa Int ? 1 : 2\n"
    sites = _sites(src, OP_UNION_DROP)
    # One mutant per dropped member → 2 sites (→Int, →String).
    @test length(sites) == 2
    @test Set(s.replacement for s in sites) == Set(["Int", "String"])
    @test all(s -> s.op_id == :union_drop, sites)
    @test all(s -> s.original == "Union{Int,String}", sites)
    # Distinct ids despite identical (range, op_id) — replacement disambiguates.
    @test length(unique(s -> s.id, sites)) == 2
    # Round-trip safety for every emitted mutant.
    for s in sites
        @test revert(s, apply(s, src)) == src
    end

    # Falsifiability: dropping `String` leaves `fu(x::Int)`; fu("a") no longer
    # dispatches → MethodError → any test calling fu(::String) fails → killed.
    drop_to_int = first(s for s in sites if s.replacement == "Int")
    mutated = apply(drop_to_int, src)
    f_orig = _eval_fresh(src, :fu)
    f_mut  = _eval_fresh(mutated, :fu)
    @test f_orig("a") == 2
    @test f_orig(3)   == 1
    @test_throws MethodError f_mut("a")   # String branch dropped → killed
    @test f_mut(3) == 1                    # surviving member still works
end

# ── OP_UNION_DROP must NOT fire on non-signature unions ──
@testset "OP_UNION_DROP — negative cases" begin
    # Union as a value in the body, not a signature param type.
    @test isempty(_sites("g() = Union{Int,String}\n", OP_UNION_DROP))
    # Single-member curly is degenerate → no mutant.
    @test isempty(_sites("h(x::Union{Int}) = x\n", OP_UNION_DROP))
    # Non-Union curly (parametric type) → no mutant.
    @test isempty(_sites("k(x::Vector{Int}) = x\n", OP_UNION_DROP))
end

end  # @testset
