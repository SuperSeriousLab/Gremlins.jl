# cache.jl — Incremental mutant result cache for Gremlins.jl (M2)
#
# Cache key: SHA256(source file content) || mutant_id || GREMLINS_VERSION
# Cache value: (outcome, elapsed_seconds)
# Storage: .gremlins_cache.json in the target pkgdir
# No mtime anywhere (CLAUDE.md hard rule — git checkout refreshes mtimes).
#
# Public API:
#   MutantCache        — in-memory cache state
#   load_cache(pkgdir) -> MutantCache
#   save_cache(cache)  -> nothing
#   cache_get(cache, src_content, mutant_id) -> Union{CachedResult, Nothing}
#   cache_put!(cache, src_content, mutant_id, outcome, elapsed) -> nothing

using SHA: sha256

# ─── Cache entry types ────────────────────────────────────────────────────────

"""
    CachedResult

Single cached mutant outcome.
"""
struct CachedResult
    outcome::MutantOutcome
    elapsed::Float64
end

# ─── Cache struct ─────────────────────────────────────────────────────────────

"""
    MutantCache

In-memory mutant result cache.

Key: String of the form "sha256:<file_sha>:mid:<mutant_id>:ver:<version>"
Value: CachedResult
"""
struct MutantCache
    pkgdir::String
    data::Dict{String, CachedResult}
    path::String                    # path to .gremlins_cache.json
    dirty::Ref{Bool}               # true if data was modified since last save
end

# ─── Cache key ────────────────────────────────────────────────────────────────

"""
    _cache_key(src_content, mutant_id) -> String

Stable cache key: SHA256(source file bytes) + mutant_id + GREMLINS_VERSION.
Not mtime-based.
"""
function _cache_key(src_content::AbstractString, mutant_id::AbstractString)::String
    file_hash = join(string(b, base=16, pad=2) for b in sha256(src_content))
    return "sha256:$(file_hash):mid:$(mutant_id):ver:$(GREMLINS_VERSION)"
end

# ─── Load and save ────────────────────────────────────────────────────────────

"""
    load_cache(pkgdir) -> MutantCache

Load the cache from `.gremlins_cache.json` in `pkgdir`.
Returns an empty cache if the file doesn't exist or is malformed.
"""
function load_cache(pkgdir::AbstractString)::MutantCache
    pkgdir = abspath(pkgdir)
    path = joinpath(pkgdir, ".gremlins_cache.json")
    data = Dict{String, CachedResult}()

    if isfile(path)
        try
            raw = read(path, String)
            data = _parse_cache_json(raw)
        catch e
            @warn "[gremlins/cache] Failed to parse cache at $path: $e — starting fresh"
        end
    end

    return MutantCache(pkgdir, data, path, Ref(false))
end

"""
    save_cache(cache::MutantCache) -> nothing

Persist the cache to disk (atomic write). No-op if cache is not dirty.
"""
function save_cache(cache::MutantCache)
    cache.dirty[] || return nothing
    try
        json = _serialize_cache_json(cache.data)
        _atomic_write(cache.path, json)
        cache.dirty[] = false
    catch e
        @warn "[gremlins/cache] Failed to save cache to $(cache.path): $e"
    end
    return nothing
end

# ─── Cache query and update ───────────────────────────────────────────────────

"""
    cache_get(cache, src_content, mutant_id) -> Union{CachedResult, Nothing}

Look up a cached result. Returns `nothing` on miss.
"""
function cache_get(
    cache::MutantCache,
    src_content::AbstractString,
    mutant_id::AbstractString,
)::Union{CachedResult, Nothing}
    key = _cache_key(src_content, mutant_id)
    return get(cache.data, key, nothing)
end

"""
    cache_put!(cache, src_content, mutant_id, outcome, elapsed) -> nothing

Store a result in the cache. Marks the cache dirty.
"""
function cache_put!(
    cache::MutantCache,
    src_content::AbstractString,
    mutant_id::AbstractString,
    outcome::MutantOutcome,
    elapsed::Float64,
)
    key = _cache_key(src_content, mutant_id)
    cache.data[key] = CachedResult(outcome, elapsed)
    cache.dirty[] = true
    return nothing
end

# ─── JSON serialisation (no external deps) ───────────────────────────────────

function _serialize_cache_json(data::Dict{String, CachedResult})::String
    buf = IOBuffer()
    write(buf, "{\n  \"schema\": \"gremlins-cache-v1\",\n  \"version\": ")
    write(buf, JSON_str(GREMLINS_VERSION))
    write(buf, ",\n  \"entries\": {\n")
    entries = collect(data)
    for (i, (key, val)) in enumerate(entries)
        write(buf, "    ")
        write(buf, JSON_str(key))
        write(buf, ": {\"outcome\": ")
        write(buf, JSON_str(string(val.outcome)))
        write(buf, ", \"elapsed\": ")
        write(buf, string(round(val.elapsed, digits=4)))
        write(buf, "}")
        i < length(entries) && write(buf, ",")
        write(buf, "\n")
    end
    write(buf, "  }\n}")
    return String(take!(buf))
end

function _parse_cache_json(raw::String)::Dict{String, CachedResult}
    data = Dict{String, CachedResult}()
    # Scan for each entry pattern directly in the raw JSON.
    # Pattern: "key": {"outcome": "VALUE", "elapsed": NUMBER}
    # The key may contain colons (it does — sha256:...:mid:...:ver:...).
    # We match greedily on the key (no quotes inside keys in our format).
    for em in eachmatch(
        r"\"([^\"]+)\"\s*:\s*\{\"outcome\"\s*:\s*\"([^\"]+)\"\s*,\s*\"elapsed\"\s*:\s*([\d.eE+-]+)\}",
        raw,
    )
        key         = em.captures[1]
        outcome_str = em.captures[2]
        elapsed_str = em.captures[3]
        # Skip schema/version keys that look like entries
        occursin(":mid:", key) || continue
        outcome = _parse_outcome(outcome_str)
        outcome === nothing && continue
        elapsed = tryparse(Float64, elapsed_str)
        elapsed === nothing && continue
        data[key] = CachedResult(outcome, elapsed)
    end
    return data
end

function _parse_outcome(s::AbstractString)::Union{MutantOutcome, Nothing}
    s == "killed"      && return killed
    s == "survived"    && return survived
    s == "timeout"     && return timeout
    s == "no_coverage" && return no_coverage
    s == "error"       && return error
    return nothing
end

# ─── Cache count helper ───────────────────────────────────────────────────────

"""
    cache_size(cache::MutantCache) -> Int

Return the number of entries currently in the cache.
"""
function cache_size(cache::MutantCache)::Int
    return length(cache.data)
end
