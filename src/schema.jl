# schema.jl — Mutant schemata: compile-once mode for operator-swap sites.
#
# Design (atlas-flash-tightened):
#   - Schema-eligible = operator-swap ops only (relop/bool/cmp_chain).
#   - Constant-literal guard: reject sites whose original expression const-folds.
#   - Disjoint-only guard: nested byte-ranges fall back to warm (flat splice safe).
#   - World-age: instrumented fn eval'd once; tests include'd fresh per mutant.
#
# C1: enum member added to warm.jl; __GREM_ACTIVE + eligibility here.
# C2: instrument_function + disjoint_eligible here.
# C3-C5: deferred (run_mutations_schema, agreement, CLI wiring).

"""Global mutant selector. 0 = all-original baseline; k = activate site k."""
const __GREM_ACTIVE = Ref(0)

const _SCHEMA_ELIGIBLE_OPS = Set{Symbol}([
    :relop_lt_le, :relop_le_lt, :relop_gt_ge, :relop_ge_gt,
    :relop_eq_neq, :relop_neq_eq, :bool_and_or, :bool_or_and, :cmp_chain,
])

"""
    schema_eligible(site::MutationSite) -> Bool

True iff `site` may run in schema mode: an operator-swap op whose original
expression does NOT lower to a constant literal (the const-prop/Val-dispatch
guard). Everything else falls back to the warm path.
"""
function schema_eligible(site::MutationSite)::Bool
    site.op_id in _SCHEMA_ELIGIBLE_OPS || return false
    return !_lowers_to_constant(site.original)
end

"""
    _lowers_to_constant(expr_text) -> Bool

True if `expr_text` contains no variable references (all operand leaves are
literals/booleans) — meaning the expression is a purely constant computation
that inference will const-fold (e.g. `1 < 2`). Schema instrumentation would
be invisible to the test suite for such sites.

SOUNDNESS (one-directional toward safety): on any parse failure or uncertainty,
return `true` (treat as constant-folding ⇒ ineligible ⇒ safe). Never return
`false` when uncertain — conservatism here only causes a warm-path fallback,
never a misclassification.

Implementation: JuliaSyntax tree walk — if any K"Identifier" leaf in a non-
operator position is found, the expression references a variable and is NOT
purely constant.
"""
function _lowers_to_constant(expr_text::AbstractString)::Bool
    tree = try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, expr_text; filename="<schema>")
    catch
        return true     # parse failure → assume constant → ineligible (safe)
    end
    # Returns true if a variable-reference Identifier is found (⇒ NOT constant)
    function _has_variable_ref(node::JuliaSyntax.SyntaxNode, is_op_pos::Bool=false)::Bool
        if JuliaSyntax.is_leaf(node)
            k = JuliaSyntax.kind(node)
            # An Identifier in non-operator position = variable reference
            return k == JuliaSyntax.K"Identifier" && !is_op_pos
        end
        cs = JuliaSyntax.children(node)
        isnothing(cs) && return false
        nk = JuliaSyntax.kind(node)
        for (i, c) in enumerate(cs)
            # In K"call" nodes, child 2 is the operator identifier — skip it
            op_pos = (nk == JuliaSyntax.K"call" && i == 2)
            _has_variable_ref(c, op_pos) && return true
        end
        return false
    end
    # If no variable refs found → expression is purely constant → lowers to constant
    return !_has_variable_ref(tree)
end
