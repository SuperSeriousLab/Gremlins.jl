# schema_instrument.jl — Schema-mode instrumentation primitives (Feature C).
#
# Split out of schema.jl: function-body instrumentation (ternary guard splice),
# disjointness partitioning, and the JuliaSyntax helpers that expand a swap site
# to its enclosing wrappable expression. Pure code-move — no behavior change.

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

"""
    _enclosing_toplevel(content, target_byte, filename) -> Union{Tuple{String,UnitRange{Int}}, Nothing}

Like warm.jl `_extract_toplevel_at_byte`, but ALSO returns the byte-range of the
enclosing top-level expression in `content`. The range lets us convert a site's
file-absolute byte_range into a function-relative one for `instrument_function`.

Returns `(func_text, func_byte_range)` or `nothing` if not found.
"""
function _enclosing_toplevel(
    content::AbstractString,
    target_byte::Int,
    filename::AbstractString,
)::Union{Tuple{String, UnitRange{Int}}, Nothing}
    tree = try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, content;
            filename=filename, ignore_errors=true)
    catch
        return nothing
    end

    # If wrapped in a module, search inside its body (mirrors warm.jl logic).
    search_children = JuliaSyntax.children(tree)
    if !isnothing(search_children)
        for child in search_children
            if JuliaSyntax.kind(child) == JuliaSyntax.K"module"
                cs = JuliaSyntax.children(child)
                if !isnothing(cs) && length(cs) >= 2
                    body_node = cs[end]
                    body_children = JuliaSyntax.children(body_node)
                    isnothing(body_children) || (search_children = body_children)
                end
                break
            end
        end
    end

    isnothing(search_children) && return nothing
    for child in search_children
        br = JuliaSyntax.byte_range(child)
        if first(br) <= target_byte <= last(br)
            lo = max(1, first(br))
            hi = min(ncodeunits(content), last(br))
            return (content[lo:hi], UnitRange{Int}(lo, hi))
        end
    end
    return nothing
end

# Node kinds that form a complete, ternary-wrappable expression for a swap site.
const _SCHEMA_WRAP_KINDS = (
    JuliaSyntax.K"call", JuliaSyntax.K"dotcall",
    JuliaSyntax.K"comparison", JuliaSyntax.K"&&", JuliaSyntax.K"||",
)

"""
    _deepest_node_at(node, target_byte) -> SyntaxNode

Return the deepest node whose byte-range contains `target_byte`.
"""
function _deepest_node_at(node::JuliaSyntax.SyntaxNode, target_byte::Int)::JuliaSyntax.SyntaxNode
    cs = JuliaSyntax.children(node)
    if !isnothing(cs)
        for c in cs
            br = JuliaSyntax.byte_range(c)
            if first(br) <= target_byte <= last(br)
                return _deepest_node_at(c, target_byte)
            end
        end
    end
    return node
end

"""
    _schema_instr_unit(content, site, filename)
        -> Union{Tuple{UnitRange{Int}, String, String}, Nothing}

Expand a swap site to the smallest *complete expression* node that can be wrapped
in a ternary guard, and return `(expr_range, orig_text, mut_text)` in file-absolute
codeunit coords.

The discover sites are NOT uniform: relop/arith sites carry the OPERATOR-TOKEN
byte-range (`original="<"`, `replacement="<="`), while bool/cmp_chain sites carry
the WHOLE-EXPRESSION range (`original="a && b"`, `replacement="a || b"`). A bare
operator token cannot be ternary-wrapped (`(c ? (<=) : (<))` is a syntax error),
so for token-range sites we expand to the enclosing call/comparison node and splice
`site.replacement` into it; for whole-expression sites we use `site.replacement`
directly.

Returns `nothing` if the enclosing wrappable expression cannot be located (caller
routes the site to the warm path).
"""
function _schema_instr_unit(
    content::AbstractString,
    site::MutationSite,
    filename::AbstractString,
)::Union{Tuple{UnitRange{Int}, String, String}, Nothing}
    tree = try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, content;
            filename=filename, ignore_errors=true)
    catch
        return nothing
    end
    target = first(site.byte_range)
    cu = codeunits(content)
    n = length(cu)

    # Find the wrappable node. Two cases:
    #  A) whole-expression site (bool/cmp_chain): site.byte_range == a node's range.
    #  B) operator-token site (relop/arith): walk up from the deepest node at the
    #     token start to the smallest wrap-kind ancestor whose range CONTAINS the
    #     full site range (so we don't stop at an inner sub-call).
    leaf = _deepest_node_at(tree, target)
    node = leaf
    wrap = nothing
    while node !== nothing
        nbr = JuliaSyntax.byte_range(node)
        if JuliaSyntax.kind(node) in _SCHEMA_WRAP_KINDS &&
           first(nbr) <= first(site.byte_range) && last(site.byte_range) <= last(nbr)
            wrap = node
            break
        end
        node = node.parent
    end
    wrap === nothing && return nothing

    wbr = JuliaSyntax.byte_range(wrap)
    lo = max(1, first(wbr)); hi = min(n, last(wbr))
    lo <= hi || return nothing
    orig_text = String(cu[lo:hi])

    if first(site.byte_range) == lo && last(site.byte_range) == hi
        # Whole-expression site (bool_and_or / cmp_chain): replacement is full expr.
        return (UnitRange{Int}(lo, hi), orig_text, site.replacement)
    else
        # Token-range site (relop/arith): splice replacement at the operator's
        # position within the enclosing expression.
        op_lo = first(site.byte_range) - lo + 1
        op_hi = last(site.byte_range)  - lo + 1
        (1 <= op_lo <= op_hi <= ncodeunits(orig_text)) || return nothing
        ocu = codeunits(orig_text)
        # Confirm the spliced token matches site.original (sanity)
        token = String(ocu[op_lo:op_hi])
        token == site.original || return nothing
        mut_text = String(ocu[1:op_lo-1]) * site.replacement * String(ocu[op_hi+1:end])
        return (UnitRange{Int}(lo, hi), orig_text, mut_text)
    end
end
