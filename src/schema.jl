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

KNOWN FALSE-ELIGIBLE HOLE (v1, acceptable): Named module-level constants
(`pi`, `π`, `Inf`, `MY_CONST`, any SCREAMING_SNAKE global `const`) parse as
plain K"Identifier" leaves — indistinguishable from runtime variable references
at the AST level. Consequently, `pi < 2` or `MY_CONST < threshold` are
incorrectly marked schema-eligible even though inference will const-fold them
and schema instrumentation will be invisible.

This is acceptable for v1 for two reasons:
  (a) The direction is safe: the hole is false-eligible (extra sites may
      enter the schema path), never false-ineligible (real variable sites
      can never be silently skipped). The worst outcome is wasted schema
      instrumentation, not a missed mutation.
  (b) C4's warm-vs-schema agreement check is the runtime backstop: any
      misclassified site whose schema result disagrees with the warm result
      surfaces as a hard error, so no misclassification can silently corrupt
      the survival report.

A fix would require a type-inference or binding-analysis pass (out of scope
for static discovery). Track as a known limitation; address in a future pass
that annotates K"Identifier" leaves as constant vs. dynamic.
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

# ─── C2: instrument_function + disjoint_eligible ─────────────────────────────

"""
    instrument_function(src, sites) -> String

`sites :: Vector{Tuple{UnitRange{Int}, Int, String}}` — (byte_range, key, mutated_text)
relative to `src` (1-based). Ranges MUST be pairwise disjoint (the disjoint-only
guard in `disjoint_eligible` enforces this; nested sites fall back to warm).

Returns `src` with each site's bytes replaced by
`(Main.__GREM_ACTIVE[] == key ? (mutated) : (original))`, splicing right-to-left
so earlier offsets stay valid.
"""
function instrument_function(src::AbstractString,
        sites::Vector{Tuple{UnitRange{Int},Int,String}})::String
    isempty(sites) && return String(src)
    # Defensive: disjointness is a precondition (atlas-flash bug 1). Verify.
    ranges = sort([s[1] for s in sites]; by = first)
    for i in 2:length(ranges)
        first(ranges[i]) <= last(ranges[i-1]) &&
            throw(MutationError("instrument_function: overlapping sites $(ranges[i-1]) / $(ranges[i]) — nested sites must route to warm fallback"))
    end
    # Splice right-to-left so byte offsets of earlier sites remain valid
    ordered = sort(sites; by = s -> first(s[1]), rev = true)
    buf = String(src)
    for (br, key, mut) in ordered
        orig = String(codeunits(buf)[br])
        guarded = "(Main.__GREM_ACTIVE[] == $key ? ($mut) : ($orig))"
        buf = String(codeunits(buf)[1:first(br)-1]) * guarded * String(codeunits(buf)[last(br)+1:end])
    end
    return buf
end

"""
    disjoint_eligible(sites) -> (schema::Vector{MutationSite}, nested::Vector{MutationSite})

Partition eligible sites: a site is schema-runnable only if its byte-range is
disjoint from every other eligible site in the collection. Containing/contained
sites (byte-range overlap) go to `nested` (→ warm fallback).
O(n²) — fine since n is per-function small.
"""
function disjoint_eligible(sites::Vector{MutationSite})
    schema = MutationSite[]
    nested = MutationSite[]
    for (i, s) in enumerate(sites)
        overlaps = any(enumerate(sites)) do (j, t)
            j == i && return false
            s.relpath == t.relpath || return false
            # ranges overlap if they are NOT completely separated
            !(last(s.byte_range) < first(t.byte_range) ||
              last(t.byte_range) < first(s.byte_range))
        end
        push!(overlaps ? nested : schema, s)
    end
    return schema, nested
end
