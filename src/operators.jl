# operators.jl — Mutation operator definitions for Gremlins.jl
#
# In JuliaSyntax SyntaxNode (the AST tree used here):
# - Infix binary operators (< <= > >= == != + - * /) appear as Identifier leaves
#   with the operator symbol as `val` (e.g. val=:< for `<`)
# - `&&` and `||` appear as non-leaf inner nodes with kind K"&&" / K"||"
# - Prefix `!` appears as an Identifier leaf with val=:! as first child of a call
# - `return` appears as a non-leaf return-kind node
# - Integer literals: Identifier leaves with kind K"Integer" and Int `val`
# - Bool literals: leaves with kind K"Bool"

using JuliaSyntax

# ─── Error type ────────────────────────────────────────────────────────────────

"""
    MutationError(msg)

Typed error for all library-path failures in Gremlins. Never use `error("...")`.
"""
struct MutationError <: Exception
    msg::String
end
Base.showerror(io::IO, e::MutationError) = print(io, "MutationError: ", e.msg)

# ─── Operator struct ────────────────────────────────────────────────────────────

"""
    MutationOperator

Defines a single mutation rule.

Fields:
- `id`        — stable Symbol used in mutant hash
- `name`      — human label
- `matcher`   — `(node, src) -> Bool`
- `replacer`  — `(node, src) -> String` (single replacement text for `node`'s byte range)
"""
struct MutationOperator
    id::Symbol
    name::String
    matcher::Function
    replacer::Function
end

# ─── Helpers ────────────────────────────────────────────────────────────────────

"""Return the source bytes that the given node spans."""
function node_text(node::JuliaSyntax.SyntaxNode, src::AbstractString)::String
    br = JuliaSyntax.byte_range(node)
    src[br]
end

"""Check whether a node is anywhere inside a macro definition or @eval/@generated."""
function _is_inside_macro_def(node::JuliaSyntax.SyntaxNode)::Bool
    p = node.parent
    while !isnothing(p)
        k = JuliaSyntax.kind(p)
        k == JuliaSyntax.K"macro" && return true
        if k == JuliaSyntax.K"macrocall"
            cs = JuliaSyntax.children(p)
            if !isnothing(cs) && !isempty(cs)
                mn = cs[1]
                if JuliaSyntax.is_leaf(mn) && mn.val isa Symbol
                    mname = string(mn.val)
                    mname in ("@eval", "@generated") && return true
                end
            end
        end
        p = p.parent
    end
    return false
end

"""Check whether a node is a binary infix Identifier leaf with the given Symbol val."""
function _is_infix_op(node::JuliaSyntax.SyntaxNode, op::Symbol)::Bool
    JuliaSyntax.is_leaf(node) &&
    JuliaSyntax.kind(node) == JuliaSyntax.K"Identifier" &&
    node.val === op &&
    !isnothing(node.parent) &&
    JuliaSyntax.kind(node.parent) == JuliaSyntax.K"call" &&
    !_is_inside_macro_def(node)
end

# ─── 1. Relational operators ──────────────────────────────────────────────────
# < ↔ <=,  > ↔ >=,  == ↔ !=

function _make_relop(id::Symbol, from_sym::Symbol, to_str::String)
    MutationOperator(
        id,
        "relop: $(from_sym) → $(to_str)",
        (node, src) -> _is_infix_op(node, from_sym),
        (node, src) -> to_str,
    )
end

const OP_LT_TO_LE    = _make_relop(:relop_lt_le,  :<,   "<=")
const OP_LE_TO_LT    = _make_relop(:relop_le_lt,  :<=,  "<")
const OP_GT_TO_GE    = _make_relop(:relop_gt_ge,  :>,   ">=")
const OP_GE_TO_GT    = _make_relop(:relop_ge_gt,  :>=,  ">")
const OP_EQ_TO_NEQ   = _make_relop(:relop_eq_neq, :(==), "!=")
const OP_NEQ_TO_EQ   = _make_relop(:relop_neq_eq, :!=,  "==")

# ─── 2. Boolean operators ─────────────────────────────────────────────────────
# && ↔ ||  (inner nodes of kind K"&&" / K"||")
# delete !  (match the call node whose first child is a `!` identifier)

# For &&/||: the node IS the whole `a && b` expression.
# We replace just the operator token inside the source text by building
# the mutated text: left_text + " || " + right_text  (or && for the reverse).
# Since byte-splice must be exact, we find the operator bytes in the source span.

function _swap_boolean_op(node::JuliaSyntax.SyntaxNode, src::String, from_op::String, to_op::String)::String
    full_txt = node_text(node, src)
    # Find the operator in the raw source text of this node.
    # It sits between the two children.
    cs = JuliaSyntax.children(node)
    if isnothing(cs) || length(cs) < 2
        throw(MutationError("_swap_boolean_op: expected 2 children, got $(isnothing(cs) ? 0 : length(cs))"))
    end
    left_br  = JuliaSyntax.byte_range(cs[1])
    right_br = JuliaSyntax.byte_range(cs[end])
    node_start = first(JuliaSyntax.byte_range(node))
    # Operator occupies bytes between end of left and start of right (relative to node start)
    op_start = last(left_br)  - node_start + 2   # 1-based offset into full_txt
    op_end   = first(right_br) - node_start       # 1-based offset into full_txt
    # Build replacement: keep prefix/suffix around the operator token
    prefix = full_txt[1:op_start-1]
    suffix = full_txt[op_end+1:end]
    # Strip and replace the operator from the middle
    mid = full_txt[op_start:op_end]
    # Replace the from_op token in mid (handles whitespace around it)
    if !occursin(from_op, mid)
        throw(MutationError("_swap_boolean_op: '$from_op' not found in mid=$(repr(mid))"))
    end
    new_mid = replace(mid, from_op => to_op; count=1)
    return prefix * new_mid * suffix
end

const OP_AND_TO_OR = MutationOperator(
    :bool_and_or,
    "bool: && → ||",
    (node, src) -> begin
        JuliaSyntax.kind(node) == JuliaSyntax.K"&&" &&
        !JuliaSyntax.is_leaf(node) &&
        !_is_inside_macro_def(node)
    end,
    (node, src) -> _swap_boolean_op(node, src, "&&", "||"),
)

const OP_OR_TO_AND = MutationOperator(
    :bool_or_and,
    "bool: || → &&",
    (node, src) -> begin
        JuliaSyntax.kind(node) == JuliaSyntax.K"||" &&
        !JuliaSyntax.is_leaf(node) &&
        !_is_inside_macro_def(node)
    end,
    (node, src) -> _swap_boolean_op(node, src, "||", "&&"),
)

# Delete `!`: match the CALL node whose first child is the `!` identifier.
# Replacement = just the argument text (second child).
# The byte_range used for splicing is the CALL node's range (from discover.jl).
const OP_DELETE_NOT = MutationOperator(
    :bool_delete_not,
    "bool: delete !",
    (node, src) -> begin
        # Match the call node `(! arg)`
        k = JuliaSyntax.kind(node)
        k == JuliaSyntax.K"call" &&
        !JuliaSyntax.is_leaf(node) &&
        !isnothing(JuliaSyntax.children(node)) &&
        length(JuliaSyntax.children(node)) == 2 &&
        JuliaSyntax.is_leaf(JuliaSyntax.children(node)[1]) &&
        JuliaSyntax.children(node)[1].val === :! &&
        !_is_inside_macro_def(node)
    end,
    (node, src) -> begin
        cs = JuliaSyntax.children(node)
        # cs[1] = `!`, cs[2] = argument
        node_text(cs[2], src)
    end,
)

# ─── 3. Arithmetic operators ─────────────────────────────────────────────────
# + ↔ -,  * ↔ /  (Identifier leaves with the op symbol as val)

const OP_PLUS_TO_MINUS  = _make_relop(:arith_plus_minus,  :+,  "-")
const OP_MINUS_TO_PLUS  = _make_relop(:arith_minus_plus,  :-,  "+")
const OP_MUL_TO_DIV     = _make_relop(:arith_mul_div,     :*,  "/")
const OP_DIV_TO_MUL     = _make_relop(:arith_div_mul,     :/,  "*")

# ─── 4. Integer literal boundary mutations ───────────────────────────────────

const OP_INT_INCR = MutationOperator(
    :literal_int_incr,
    "literal: integer+1",
    (node, src) -> begin
        JuliaSyntax.is_leaf(node) &&
        JuliaSyntax.kind(node) == JuliaSyntax.K"Integer" &&
        !_is_inside_macro_def(node)
    end,
    (node, src) -> begin
        v = node.val
        v isa Integer || throw(MutationError("literal_int_incr: node.val is not Integer: $(typeof(v))"))
        string(v + 1)
    end,
)

const OP_INT_DECR = MutationOperator(
    :literal_int_decr,
    "literal: integer-1",
    (node, src) -> begin
        JuliaSyntax.is_leaf(node) &&
        JuliaSyntax.kind(node) == JuliaSyntax.K"Integer" &&
        !_is_inside_macro_def(node)
    end,
    (node, src) -> begin
        v = node.val
        v isa Integer || throw(MutationError("literal_int_decr: node.val is not Integer: $(typeof(v))"))
        string(v - 1)
    end,
)

# ─── 5. Bool literal flip ─────────────────────────────────────────────────────

const OP_TRUE_TO_FALSE = MutationOperator(
    :literal_true_false,
    "literal: true → false",
    (node, src) -> begin
        JuliaSyntax.is_leaf(node) &&
        JuliaSyntax.kind(node) == JuliaSyntax.K"Bool" &&
        node.val === true &&
        !_is_inside_macro_def(node)
    end,
    (node, src) -> "false",
)

const OP_FALSE_TO_TRUE = MutationOperator(
    :literal_false_true,
    "literal: false → true",
    (node, src) -> begin
        JuliaSyntax.is_leaf(node) &&
        JuliaSyntax.kind(node) == JuliaSyntax.K"Bool" &&
        node.val === false &&
        !_is_inside_macro_def(node)
    end,
    (node, src) -> "true",
)

# ─── 6. Return value mutation ─────────────────────────────────────────────────
# `return x` → `return nothing`
# Match the argument node inside a return statement (not the `return` keyword itself).
# We match the RETURN node and replace its argument child's text with "nothing".
# Implementation: match the return inner node; replacer replaces just the argument span.
# Since our patcher operates on a single byte range, we target the argument child.
const OP_RETURN_NOTHING = MutationOperator(
    :return_nothing,
    "return: return x → return nothing",
    (node, src) -> begin
        # Match non-leaf return node that has an explicit value
        k = JuliaSyntax.kind(node)
        k == JuliaSyntax.K"return" &&
        !JuliaSyntax.is_leaf(node) &&
        !isnothing(JuliaSyntax.children(node)) &&
        !isempty(JuliaSyntax.children(node)) &&
        # Don't mutate `return nothing` (already nothing)
        !(
            length(JuliaSyntax.children(node)) == 1 &&
            JuliaSyntax.is_leaf(JuliaSyntax.children(node)[1]) &&
            JuliaSyntax.children(node)[1].val === :nothing
        ) &&
        !_is_inside_macro_def(node)
    end,
    (node, src) -> begin
        # Replace the entire return statement's source with `return nothing`
        "return nothing"
    end,
)

# ─── 7. Statement deletion ────────────────────────────────────────────────────
# Delete a whole statement from a block.
# matcher is permissive; discover.jl applies guards via _safe_to_delete.
const OP_STMT_DELETE = MutationOperator(
    :stmt_delete,
    "stmt: delete statement",
    (node, src) -> begin
        p = node.parent
        !isnothing(p) &&
        JuliaSyntax.kind(p) == JuliaSyntax.K"block" &&
        !_is_inside_macro_def(node)
    end,
    (node, src) -> "",
)

# ─── Default operator set ──────────────────────────────────────────────────────

"""
    DEFAULT_OPERATORS :: Vector{MutationOperator}

Canonical v1 operator set. Order is stable — important for determinism.
"""
const DEFAULT_OPERATORS = MutationOperator[
    OP_LT_TO_LE,
    OP_LE_TO_LT,
    OP_GT_TO_GE,
    OP_GE_TO_GT,
    OP_EQ_TO_NEQ,
    OP_NEQ_TO_EQ,
    OP_AND_TO_OR,
    OP_OR_TO_AND,
    OP_DELETE_NOT,
    OP_PLUS_TO_MINUS,
    OP_MINUS_TO_PLUS,
    OP_MUL_TO_DIV,
    OP_DIV_TO_MUL,
    OP_INT_INCR,
    OP_INT_DECR,
    OP_TRUE_TO_FALSE,
    OP_FALSE_TO_TRUE,
    OP_RETURN_NOTHING,
    OP_STMT_DELETE,
]
