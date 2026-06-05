# shadow.jl — Shadow-copy helper for crash-safe execution (I1)
#
# Design rationale:
#   In-process try/finally restore is not crash-safe: SIGKILL and OOM-killer
#   bypass finally. Production incident 2026-06-04: an M1 cold runner left live
#   mutants in a sibling project's working tree overnight after its driver process
#   was SIGKILLed mid-mutant.
#
#   The fix: mutations are applied inside a disposable shadow copy of the package
#   directory (under mktempdir). The REAL package tree is NEVER written. A leaked
#   tmpdir on SIGKILL is harmless garbage in /tmp — correctness failure (corrupted
#   source) vs. noise (orphaned tmp dir) is the asymmetry that makes this safe.
#
# Public API:
#   _make_shadow(pkgdir) -> shadow_dir
#   _shadow_relpath(pkgdir, shadow_dir, real_abs_path) -> shadow_abs_path
#   _remap_cmap_to_real(shadow_cmap, pkgdir, shadow_dir) -> CoverageMap

"""
    _make_shadow(pkgdir) -> shadow_dir::String

Create a disposable shadow copy of the package directory in mktempdir().

Copies all files recursively, EXCLUDING:
  - `.git/`        — repo metadata (large, irrelevant to test execution)
  - `.gremlins_cache.json` — cache stays real-side; shadow reads nothing
  - Any top-level dot-directories (`.sisyphus`, `.github`, etc.)

Symlinks: followed (cp copies the target content, not the link). Broken
symlinks are skipped silently.

Returns the shadow directory path. The CALLER is responsible for cleanup
via `rm(shadow_dir; recursive=true, force=true)` in a try/finally block.
A leaked tmpdir on SIGKILL is harmless garbage in /tmp — this is intentional
and is the entire safety property: real source corruption vs. orphaned tmp copy.
"""
function _make_shadow(pkgdir::AbstractString)::String
    pkgdir = abspath(pkgdir)
    shadow = mktempdir()   # unique dir under /tmp (or system temp)

    for (dirpath, dirs, files) in walkdir(pkgdir; follow_symlinks=false)
        # Compute path relative to pkgdir
        rel_dir = relpath(dirpath, pkgdir)

        # Skip excluded directories at any depth
        if _shadow_skip_dir(rel_dir)
            # Also prune dirs so walkdir doesn't descend into them
            empty!(dirs)  # mutate in-place to prevent descent
            continue
        end

        # Create corresponding directory in shadow
        shadow_subdir = joinpath(shadow, rel_dir == "." ? "" : rel_dir)
        isdir(shadow_subdir) || mkpath(shadow_subdir)

        # Prune excluded subdirs from descent
        filter!(dirs) do d
            subrel = rel_dir == "." ? d : joinpath(rel_dir, d)
            !_shadow_skip_dir(subrel)
        end

        for fn in files
            # Skip cache file at package root level
            if rel_dir == "." && fn == ".gremlins_cache.json"
                continue
            end

            src_path = joinpath(dirpath, fn)
            dst_path = shadow_subdir == "" ?
                       joinpath(shadow, fn) :
                       joinpath(shadow_subdir, fn)

            # Resolve symlinks: cp follows by default; skip broken ones
            if islink(src_path) && !isfile(src_path) && !isdir(src_path)
                continue  # broken symlink — skip
            end

            try
                cp(src_path, dst_path; force=true, follow_symlinks=true)
            catch e
                @warn "[gremlins/shadow] Failed to copy file; skipping" src=src_path err=e
            end
        end
    end

    return shadow
end

"""
    _shadow_skip_dir(rel_dir::AbstractString) -> Bool

Return true if this directory path should be excluded from the shadow copy.

Excluded:
  - `.git` or anything under it
  - Any top-level dot-directory (`.sisyphus`, `.github`, `.gremlins_*`, etc.)
"""
function _shadow_skip_dir(rel_dir::AbstractString)::Bool
    rel_dir == "." && return false   # root itself: never skip
    parts = splitpath(rel_dir)
    # Top-level component is parts[1]
    top = parts[1]
    # Exclude .git at any nesting level
    ".git" in parts && return true
    # Exclude top-level dot-directories
    startswith(top, ".") && return true
    return false
end

"""
    _shadow_abs_path(pkgdir, shadow_dir, real_abs_path) -> String

Translate a real absolute path into its shadow counterpart.

Example:
  pkgdir    = "/home/user/MyPkg"
  shadow_dir = "/tmp/jl_abc123"
  real_abs   = "/home/user/MyPkg/src/foo.jl"
  → returns   "/tmp/jl_abc123/src/foo.jl"

Throws `MutationError` if `real_abs_path` is not under `pkgdir`.
"""
function _shadow_abs_path(
    pkgdir::AbstractString,
    shadow_dir::AbstractString,
    real_abs_path::AbstractString,
)::String
    pkgdir   = abspath(pkgdir)
    real_abs = abspath(real_abs_path)
    rel = relpath(real_abs, pkgdir)
    # relpath returns something starting with ".." if outside pkgdir
    if startswith(rel, "..")
        throw(MutationError(
            "_shadow_abs_path: real_abs_path '$real_abs' is not under pkgdir '$pkgdir'"
        ))
    end
    return joinpath(shadow_dir, rel)
end

# Note: _remap_cmap_to_real is defined in coverage.jl (after CoverageMap is declared)
