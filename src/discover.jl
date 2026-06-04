# discover.jl — Mutation-site discovery via JuliaSyntax parse tree walking
#
# Public API:
#   discover(dir_or_file; operators=DEFAULT_OPERATORS) -> Vector{MutationSite}
#   discover_file(path; operators=DEFAULT_OPERATORS)   -> Vector{MutationSite}
#
# Invariants (from docs/INVARIANTS.md):
#   I2 — Deterministic: same source → identical ordered list across runs
#   I4 — Static only: no eval of mutated code

using JuliaSyntax
using SHA: sha256

# ─── MutationSite struct ────────────────────────────────────────────────────────

"""
    MutationSite

Represents a single candidate mutation in source text.

Fields:
- `id`           — stable 16-hex-char string: SHA256(relpath ∥ byte_range ∥ op_id)
- `relpath`      — path relative to discover root (normalized, forward-slash)
- `byte_range`   — 1-based UnitRange{Int} covering the splice target in the file
- `op_id`        — Symbol: the operator's stable id
- `op_name`      — human-readable operator name
- `original`     — original source text for the range
- `replacement`  — mutated text to splice in
- `line`         — 1-based source line of first byte
"""
struct MutationSite
    id::String
    relpath::String
    byte_range::UnitRange{Int}
    op_id::Symbol
    op_name::String
    original::String
    replacement::String
    line::Int
end

function Base.show(io::IO, m::MutationSite)
    print(io, "MutationSite($(m.id[1:8])… $(m.relpath):$(m.line) [$(m.op_name)] $(repr(m.original))→$(repr(m.replacement)))")
end

# ─── Deterministic id ──────────────────────────────────────────────────────────

"""
    mutant_id(relpath, byte_range, op_id) -> String

16-hex-char stable mutant identifier. Deterministic across machines.
"""
function mutant_id(relpath::String, byte_range::UnitRange{Int}, op_id::Symbol)::String
    payload = "$(relpath):$(first(byte_range))-$(last(byte_range)):$(op_id)"
    bytes = sha256(payload)
    join(string(b, base=16, pad=2) for b in bytes[1:8])
end

# ─── Stmt-delete guard ────────────────────────────────────────────────────────

"""
Return true if `node` (a direct child of a block) is safe to delete.
"""
function _safe_to_delete(node::JuliaSyntax.SyntaxNode, block::JuliaSyntax.SyntaxNode)::Bool
    k = JuliaSyntax.kind(node)
    # Never delete return statements
    k == JuliaSyntax.K"return" && return false
    # Never delete struct/module definitions
    k in (JuliaSyntax.K"struct", JuliaSyntax.K"module") && return false
    cs = JuliaSyntax.children(block)
    isnothing(cs) && return false
    length(cs) <= 1 && return false
    # Never delete the last child of a block (implicit return value)
    cs[end] === node && return false
    return true
end

# ─── Core tree walker ─────────────────────────────────────────────────────────

"""
Walk the syntax tree depth-first, collecting MutationSites.
"""
function _walk!(
    sites::Vector{MutationSite},
    node::JuliaSyntax.SyntaxNode,
    src::String,
    relpath::String,
    operators::Vector{MutationOperator},
)
    for op in operators
        matched = false
        try
            matched = op.matcher(node, src)
        catch
            matched = false
        end

        if matched
            # For stmt_delete: apply the guard
            if op.id == :stmt_delete
                blk = node.parent
                isnothing(blk) && continue
                _safe_to_delete(node, blk) || continue
            end

            # The splice target is the matched node itself
            br = JuliaSyntax.byte_range(node)
            br_clamped = max(1, first(br)):min(ncodeunits(src), last(br))
            isempty(br_clamped) && continue

            original = src[br_clamped]
            replacement = ""
            try
                replacement = op.replacer(node, src)
            catch
                continue
            end

            # Skip identity mutations
            replacement == original && continue

            # Source line
            ln = 1
            try
                sf = JuliaSyntax.sourcefile(node)
                if !isnothing(sf)
                    ln = JuliaSyntax.source_line(sf, first(br_clamped))
                end
            catch
            end

            site = MutationSite(
                mutant_id(relpath, UnitRange{Int}(br_clamped), op.id),
                relpath,
                UnitRange{Int}(br_clamped),
                op.id,
                op.name,
                original,
                replacement,
                ln,
            )
            push!(sites, site)
        end
    end

    # Recurse into children
    cs = JuliaSyntax.children(node)
    if !isnothing(cs)
        for child in cs
            _walk!(sites, child, src, relpath, operators)
        end
    end
end

# ─── File-level discovery ─────────────────────────────────────────────────────

"""
    discover_file(path; root=dirname(path), operators=DEFAULT_OPERATORS) -> Vector{MutationSite}

Discover all mutation sites in a single Julia source file.
Returns sites sorted deterministically by (byte start, op_id string).
"""
function discover_file(
    path::AbstractString;
    root::AbstractString = dirname(path),
    operators::Vector{MutationOperator} = DEFAULT_OPERATORS,
)::Vector{MutationSite}
    src = try
        read(path, String)
    catch e
        throw(MutationError("Cannot read file '$path': $e"))
    end

    isempty(src) && return MutationSite[]

    tree = try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, src;
                              filename = path,
                              ignore_errors = true)
    catch
        return MutationSite[]
    end

    relpath = let
        rp = try
            relpath_str = Base.relpath(path, root)
            replace(relpath_str, Base.Filesystem.path_separator => "/")
        catch
            basename(path)
        end
        rp
    end

    sites = MutationSite[]
    _walk!(sites, tree, src, relpath, operators)
    sort!(sites, by = s -> (first(s.byte_range), string(s.op_id)))
    return sites
end

# ─── Directory-level discovery ────────────────────────────────────────────────

"""
    discover(dir_or_file; operators=DEFAULT_OPERATORS) -> Vector{MutationSite}

Discover mutation sites across all `.jl` files in `dir_or_file` (recursive).
Skips `test/` and `tests/` directories (CLAUDE.md: no mutation of test files).
Returns sites sorted globally by (relpath, byte start, op_id).
"""
function discover(
    dir_or_file::AbstractString;
    operators::Vector{MutationOperator} = DEFAULT_OPERATORS,
)::Vector{MutationSite}
    if isfile(dir_or_file)
        return discover_file(dir_or_file; root = dirname(dir_or_file), operators = operators)
    end

    isdir(dir_or_file) || throw(MutationError("'$dir_or_file' is neither a file nor a directory"))

    root = dir_or_file
    all_sites = MutationSite[]
    jl_files = String[]

    for (dirpath, dirnames, filenames) in walkdir(root)
        # Prune test directories
        filter!(d -> d != "test" && d != "tests", dirnames)
        for fn in filenames
            endswith(fn, ".jl") || continue
            push!(jl_files, joinpath(dirpath, fn))
        end
    end
    sort!(jl_files)

    for fpath in jl_files
        sites = discover_file(fpath; root = root, operators = operators)
        append!(all_sites, sites)
    end

    sort!(all_sites, by = s -> (s.relpath, first(s.byte_range), string(s.op_id)))
    return all_sites
end
