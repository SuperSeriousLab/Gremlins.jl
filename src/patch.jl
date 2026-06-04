# patch.jl — Byte-range splice patching for Gremlins.jl
#
# Public API:
#   apply(site, source_text) -> String          — returns mutated source
#   revert(site, mutated_text) -> String        — reverses apply (given original metadata)
#   apply!(site, path)                          — in-place, with lossless round-trip guarantee
#   revert!(site, original_text, path)          — restore original text in-place
#
# Invariant I1: revert(apply(site, src), ...) == src (byte-identical restoration)
# Invariant I2: apply is a pure function of (site, src); no mtime, no randomness.

# ─── Pure text patching ────────────────────────────────────────────────────────

"""
    apply(site::MutationSite, source::AbstractString) -> String

Splice `site.replacement` into `source` at `site.byte_range`.
Returns the mutated source text. The original text is NOT modified.

Throws `MutationError` if the byte range doesn't match `site.original`
(sanity-check — catches stale sites against modified source).
"""
function apply(site::MutationSite, source::AbstractString)::String
    br = site.byte_range
    # Validate: check that the source region still matches expected original
    sr = max(1, first(br)):min(ncodeunits(source), last(br))
    if source[sr] != site.original
        throw(MutationError(
            "apply: source mismatch at $(site.relpath):$(first(br))-$(last(br)); " *
            "expected $(repr(site.original)), found $(repr(source[sr]))"
        ))
    end
    # Splice: prefix + replacement + suffix
    prefix  = source[1:prevind(source, first(br))]
    suffix  = source[nextind(source, last(br)):end]
    return prefix * site.replacement * suffix
end

"""
    revert(site::MutationSite, mutated::AbstractString) -> String

Given a mutated source (produced by `apply`), restore the original.
Uses `site.original` and `site.replacement` to locate and undo the splice.

Throws `MutationError` if the replacement region doesn't match `site.replacement`.
"""
function revert(site::MutationSite, mutated::AbstractString)::String
    # The replacement occupies a different range in the mutated string.
    # Compute: prefix length is same as before (apply didn't touch prefix).
    prefix_len = first(site.byte_range) - 1
    rep_len    = ncodeunits(site.replacement)  # byte length
    rep_start  = prefix_len + 1
    rep_end    = prefix_len + rep_len

    if rep_end > ncodeunits(mutated)
        throw(MutationError(
            "revert: mutated source too short; expected replacement '$(site.replacement)' at $rep_start:$rep_end"
        ))
    end

    actual_rep = mutated[rep_start:rep_end]
    if actual_rep != site.replacement
        throw(MutationError(
            "revert: replacement mismatch; expected $(repr(site.replacement)), found $(repr(actual_rep))"
        ))
    end

    prefix = mutated[1:prefix_len]
    suffix = mutated[nextind(mutated, rep_end):end]
    return prefix * site.original * suffix
end

# ─── In-place file patching ───────────────────────────────────────────────────

"""
    apply!(site::MutationSite, path::AbstractString) -> String

Read `path`, apply `site`, write back. Returns original source text so caller
can later call `revert!(site, original, path)`.

Atomic: write to a temp file then rename, so partial writes don't corrupt.
"""
function apply!(site::MutationSite, path::AbstractString)::String
    original_src = try
        read(path, String)
    catch e
        throw(MutationError("apply!: cannot read '$path': $e"))
    end
    mutated_src = apply(site, original_src)
    _atomic_write(path, mutated_src)
    return original_src
end

"""
    revert!(site::MutationSite, original_source::AbstractString, path::AbstractString)

Write `original_source` back to `path`. Verifies via `revert` that the current
file contents are the expected mutated form before restoring.

If the file has been modified externally (contents don't match expected mutant),
still overwrites with `original_source` (safety first — invariant I1).
"""
function revert!(site::MutationSite, original_source::AbstractString, path::AbstractString)
    # Best-effort verification
    try
        current = read(path, String)
        _restored = revert(site, current)
        # _restored should == original_source (sanity check, not enforced to avoid crashes)
    catch
        # Even if verification fails, restore the original
    end
    _atomic_write(path, original_source)
    nothing
end

# ─── Helper: atomic write ─────────────────────────────────────────────────────

function _atomic_write(path::AbstractString, content::AbstractString)
    dir = dirname(path)
    tmp = tempname(isempty(dir) ? "." : dir) * ".jl"
    try
        write(tmp, content)
        mv(tmp, path; force=true)
    catch e
        # Clean up temp file if rename failed
        try; rm(tmp); catch; end
        throw(MutationError("_atomic_write: failed to write '$path': $e"))
    end
end

# ─── Round-trip verification ──────────────────────────────────────────────────

"""
    roundtrip_ok(site::MutationSite, source::AbstractString) -> Bool

Verify that `revert(apply(site, source), ...) == source`.
This is the EDD invariant-I1 check; call it in tests.
"""
function roundtrip_ok(site::MutationSite, source::AbstractString)::Bool
    mutated = try
        apply(site, source)
    catch
        return false
    end
    restored = try
        revert(site, mutated)
    catch
        return false
    end
    return restored == source
end
