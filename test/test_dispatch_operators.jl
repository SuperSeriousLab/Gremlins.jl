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

end  # @testset
