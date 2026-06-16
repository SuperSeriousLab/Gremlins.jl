# equivalence.jl — Lowered-IR equivalence pruning (opt-in soundness filter).
#
# A mutant whose lowered IR is byte-identical to the original is *provably*
# semantically equivalent: testing it wastes a subprocess and inflates the
# survivor count with un-killable noise. We can safely skip it.
#
# SOUNDNESS (one-directional). We prune ONLY on positive proof of identity and
# treat every uncertainty — parse failure, a macro that won't expand in a bare
# module, any lowering error, a top-level site we can't isolate — as "not
# equivalent" (keep the mutant). This can never hide a real survivor; the worst
# case is failing to prune a genuine equivalent.
#
# MEASURED YIELD (2026-06-08, Opus). Julia *lowering* desugars syntax but does
# NOT constant-fold or dead-branch-eliminate — those are optimization/inference,
# which run later and require resolved types. Of six realistic mutations only
# `stmt_delete` of a pure-value statement (e.g. `(1; x)` → `(x)`) collapses
# under lowering; relop/arith/bool/literal/return swaps all survive lowering
# distinctly. So this prune is sound and cheap but narrow today. Its value grows
# with future sugar-producing operators; a higher-yield prune would need typed
# IR (`code_typed`), which executes code and is out of scope for static
# discovery. Opt in with `discover(...; prune_equivalent=true)`.

using JuliaSyntax

"""
    _lowered_repr(text, M) -> Union{String,Nothing}

Parse `text`, strip line numbers, lower it in module `M`, and return a stable
string rendering of the lowered IR. `nothing` on any parse or lowering failure.
"""
function _lowered_repr(text::AbstractString, M::Module)::Union{String,Nothing}
    expr = try
        Meta.parse(text; raise = false)
    catch
        return nothing
    end
    (expr isa Expr) || return nothing
    (expr.head === :error || expr.head === :incomplete) && return nothing
    Base.remove_linenums!(expr)
    lowered = try
        Meta.lower(M, expr)
    catch
        return nothing
    end
    return sprint(show, lowered)
end

"""
    _is_lowering_equivalent(node, br_clamped, replacement, src) -> Bool

True iff splicing `replacement` over `br_clamped` yields a lowered IR
byte-identical to the original, within the smallest enclosing function. Both
sides lower in the *same* fresh module so SSA/gensym numbering lines up. Returns
`false` (keep the mutant) on any uncertainty — see the soundness note above.
"""
function _is_lowering_equivalent(
    node::JuliaSyntax.SyntaxNode,
    br_clamped::UnitRange{Int},
    replacement::AbstractString,
    src::AbstractString,
)::Bool
    fn = _enclosing_func(node)
    isnothing(fn) && return false   # top-level: no isolated unit to lower — keep

    ubr = JuliaSyntax.byte_range(fn)
    u0, u1 = first(ubr), last(ubr)
    (u0 <= first(br_clamped) && last(br_clamped) <= u1) || return false

    cu = codeunits(src)
    orig_unit = try
        String(cu[u0:u1])
    catch
        return false
    end

    # Splice the replacement into the unit (offsets relative to unit start).
    rel0 = first(br_clamped) - u0 + 1
    rel1 = last(br_clamped)  - u0 + 1
    ocu  = codeunits(orig_unit)
    (1 <= rel0 <= rel1 + 1 && rel1 <= ncodeunits(orig_unit)) || return false
    mut_unit = try
        String(ocu[1:rel0-1]) * String(replacement) * String(ocu[rel1+1:end])
    catch
        return false
    end

    M = Module(:GremlinsEquivCheck)
    a = _lowered_repr(orig_unit, M)
    b = _lowered_repr(mut_unit,  M)
    (isnothing(a) || isnothing(b)) && return false
    return a == b
end
