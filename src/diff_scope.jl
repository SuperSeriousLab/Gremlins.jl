# diff_scope.jl
# Git-diff scoping: restrict mutation sites to lines a diff added/changed.
# Pure pre-execution filter — composes with cache/warm/schema unchanged.

"""
    parse_diff_hunks(diff::AbstractString) -> Dict{String,Vector{UnitRange{Int}}}

Parse `git diff --unified=0` output. Returns post-image (new file) path →
added/changed line ranges. Pure-deletion hunks (`+c,0`) contribute nothing.
Paths are the `+++ b/<path>` path with the leading `b/` stripped.
"""
function parse_diff_hunks(diff::AbstractString)::Dict{String,Vector{UnitRange{Int}}}
    out = Dict{String,Vector{UnitRange{Int}}}()
    curfile = ""
    for line in eachline(IOBuffer(diff))
        if startswith(line, "+++ ")
            p = strip(line[5:end])
            p = startswith(p, "b/") ? p[3:end] : p
            curfile = p
        elseif startswith(line, "@@")
            # @@ -a,b +c,d @@  — capture c,d
            m = match(r"\+(\d+)(?:,(\d+))?", line)
            m === nothing && continue
            c = Base.parse(Int, m.captures[1])
            d = m.captures[2] === nothing ? 1 : Base.parse(Int, m.captures[2])
            d == 0 && continue            # pure deletion: no added line
            isempty(curfile) && continue
            push!(get!(out, curfile, UnitRange{Int}[]), c:(c + d - 1))
        end
    end
    return out
end

"""
    scope_to_diff(sites, diff_lines) -> (kept::Vector{MutationSite}, suppressed::Int)

Keep only sites whose `.line` falls in a changed range for `.relpath`.
Returns kept sites and the count suppressed (for the no-silent-caps report line).
"""
function scope_to_diff(sites::Vector{MutationSite},
                       diff_lines::Dict{String,Vector{UnitRange{Int}}})
    kept = MutationSite[]
    for s in sites
        ranges = get(diff_lines, s.relpath, nothing)
        if ranges !== nothing && any(r -> s.line in r, ranges)
            push!(kept, s)
        end
    end
    return kept, length(sites) - length(kept)
end

"""
    changed_lines(base; pkgdir=".") -> Dict{String,Vector{UnitRange{Int}}}

Run `git -C pkgdir diff --unified=0 <base> -- '*.jl'` and parse it.
Throws MutationError if git fails (e.g. not a repo) — never a silent empty scope.
"""
function changed_lines(base::AbstractString; pkgdir::AbstractString=".")
    cmd = `git -C $pkgdir diff --unified=0 $base -- "*.jl"`
    out = try
        read(cmd, String)
    catch e
        throw(MutationError("changed_lines: git diff failed for base=$(repr(base)) in $(pkgdir): $e"))
    end
    return parse_diff_hunks(out)
end
