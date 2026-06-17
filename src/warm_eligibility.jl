# warm_eligibility.jl — Static warm-path eligibility classification (M2b)
#
# Split out of warm.jl: the FallbackReason taxonomy enum, WarmEligibility struct,
# static eligibility classification, and the JuliaSyntax ancestry/byte-locator
# helpers it depends on. Pure code-move — no behavior change.

# ─── Fallback taxonomy ────────────────────────────────────────────────────────

"""
    FallbackReason

Enum classifying why a mutant ran on the cold path instead of the warm path.

Values:
- `warm_ok`           — ran warm successfully, no fallback
- `fallback_macro`    — site is inside a macro definition (static)
- `fallback_typedef`  — site is inside struct/abstract/primitive type def (static)
- `fallback_const`    — site is inside a const global assignment (static)
- `fallback_evalerr`  — warm eval threw an exception (dynamic)
"""
@enum FallbackReason begin
    warm_ok
    fallback_macro
    fallback_typedef
    fallback_const
    fallback_evalerr
    fallback_schema_ineligible
end

# ─── Warm eligibility ─────────────────────────────────────────────────────────

"""
    WarmEligibility

Static classification of whether a mutation site can run on the warm path.

Fields:
- `eligible`  — true if the site can use the warm path
- `reason`    — FallbackReason (warm_ok when eligible, otherwise explains why not)
"""
struct WarmEligibility
    eligible::Bool
    reason::FallbackReason
end

# ─── Static eligibility classification ───────────────────────────────────────

"""
    classify_warm_eligibility(site::MutationSite) -> WarmEligibility

Static check: parse the source file and determine whether the mutation site
is inside a macro definition, type definition, or const global assignment.
These constructs cannot be safely eval'd into a fresh anonymous module.

Uses JuliaSyntax tree ancestry — never regex.
"""
function classify_warm_eligibility(site::MutationSite, pkgdir::AbstractString)::WarmEligibility
    abs_path = _find_abs_path(pkgdir, site)
    abs_path === nothing && return WarmEligibility(true, warm_ok)  # assume eligible if can't locate

    src = try
        read(abs_path, String)
    catch
        return WarmEligibility(true, warm_ok)
    end

    tree = try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, src;
            filename=abs_path, ignore_errors=true)
    catch
        return WarmEligibility(true, warm_ok)
    end

    # Find the node covering the mutation's byte range start
    target_byte = first(site.byte_range)
    node = _find_node_at_byte(tree, target_byte, src)
    node === nothing && return WarmEligibility(true, warm_ok)

    reason = _check_ancestry(node)
    return WarmEligibility(reason == warm_ok, reason)
end

"""
Walk ancestry checking for ineligible parent kinds.
Returns warm_ok if no disqualifying ancestor found, else the reason.
"""
function _check_ancestry(node::JuliaSyntax.SyntaxNode)::FallbackReason
    p = node.parent
    while !isnothing(p)
        k = JuliaSyntax.kind(p)
        # Macro definition body
        if k == JuliaSyntax.K"macro"
            return fallback_macro
        end
        # Struct / abstract type / primitive type definitions
        if k in (JuliaSyntax.K"struct", JuliaSyntax.K"abstract",
                 JuliaSyntax.K"primitive")
            return fallback_typedef
        end
        # Const assignment at module level
        if k == JuliaSyntax.K"const"
            return fallback_const
        end
        p = p.parent
    end
    return warm_ok
end

"""
Find the deepest leaf node whose byte range contains `target_byte`.
"""
function _find_node_at_byte(
    root::JuliaSyntax.SyntaxNode,
    target_byte::Int,
    src::String,
)::Union{JuliaSyntax.SyntaxNode, Nothing}
    br = JuliaSyntax.byte_range(root)
    (first(br) <= target_byte <= last(br)) || return nothing

    cs = JuliaSyntax.children(root)
    if !isnothing(cs)
        for child in cs
            result = _find_node_at_byte(child, target_byte, src)
            result !== nothing && return result
        end
    end
    return root
end

"""
Find the absolute path to a site's source file.
Returns nothing if not locatable.
"""
function _find_abs_path(pkgdir::AbstractString, site::MutationSite)::Union{String, Nothing}
    candidate = joinpath(pkgdir, site.relpath)
    isfile(candidate) && return candidate
    candidate2 = joinpath(pkgdir, "src", site.relpath)
    isfile(candidate2) && return candidate2
    return nothing
end
