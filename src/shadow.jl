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

# ─── Test-dep augmentation ────────────────────────────────────────────────────

"""
    _drop_unsupported_source_deps!(deps, sources, julia_version) -> Vector{String}

`[sources]` (path/url deps) is a Julia 1.11+ feature; older Pkg ignores the table
and would resolve a path dep from a registry (a hard failure). On `julia_version <
1.11`, remove every source-backed dep from both `deps` and `sources` and return the
names dropped (sorted, for a deterministic warning). On 1.11+ this is a no-op and
returns an empty vector. Mutates both dicts in place.
"""
function _drop_unsupported_source_deps!(
    deps::AbstractDict,
    sources::AbstractDict,
    julia_version::VersionNumber,
)::Vector{String}
    (julia_version >= v"1.11" || isempty(sources)) && return String[]
    dropped = sort!(collect(keys(sources)))
    for name in dropped
        delete!(deps, name)
    end
    empty!(sources)
    return dropped
end

"""
    _augment_shadow_with_test_deps(pkgdir, shadow_dir) -> Bool

Merge non-stdlib test-only deps into the shadow's Project.toml so that
`julia --project=<shadow>` can load them (fixing GitHub #2/#3).

`Pkg.test()` resolves a *combined* environment: package deps + test/Project.toml
deps together. Plain `julia --project=<shadow>` only sees the package's main
Project.toml, so any dep declared only in `test/Project.toml` is missing.

Sources checked (in priority order):
  1. `<pkgdir>/test/Project.toml` — modern style (`[deps]`, optional `[sources]`,
     optional `[compat]`).
  2. `<pkgdir>/Project.toml` legacy `[extras]` + `[targets]` — deps listed under
     the `test` target are also merged.

Only non-stdlib, non-self deps are merged (stdlib packages are always on the
LOAD_PATH and do not need to appear in the shadow's Project.toml).

After merging, runs `Pkg.resolve()` + `Pkg.instantiate()` with the shadow as the
active project so the shadow Manifest gains the test deps.  This may trigger a
one-time network fetch (e.g. downloading `Example.jl`) — acceptable at setup
time; subsequent runs re-use the global package cache.

Returns `true` if any deps were added (i.e. the shadow Project.toml was
modified), `false` if the package has no non-stdlib test-only deps (no-op fast
path: no Pkg activation, no Manifest churn).

The augmentation is idempotent: deps already present in the shadow Project.toml
are never duplicated.  The shadow is disposable, so merging test deps into its
Project.toml is always safe.

Throws `MutationError` (typed) if the shadow's Project.toml is missing or
unreadable (should never happen — `_make_shadow` always copies it).
"""
function _augment_shadow_with_test_deps(
    pkgdir::AbstractString,
    shadow_dir::AbstractString,
)::Bool
    pkgdir     = abspath(pkgdir)
    shadow_dir = abspath(shadow_dir)

    shadow_proj_path = joinpath(shadow_dir, "Project.toml")
    isfile(shadow_proj_path) || throw(MutationError(
        "_augment_shadow_with_test_deps: shadow Project.toml not found at '$shadow_proj_path'"
    ))

    shadow_proj = try
        TOML.parsefile(shadow_proj_path)
    catch e
        throw(MutationError(
            "_augment_shadow_with_test_deps: cannot parse shadow Project.toml: $e"
        ))
    end

    pkg_uuid = get(shadow_proj, "uuid", "")

    # Build the set of stdlib UUIDs dynamically (version-agnostic).
    stdlib_uuids = _stdlib_uuids()

    # ── Collect test deps from test/Project.toml (modern style) ──────────────
    new_deps    = Dict{String, String}()   # name → uuid
    new_sources = Dict{String, Any}()     # name → source spec (path/url/rev)
    new_compat  = Dict{String, Any}()     # key  → version spec

    test_proj_path = joinpath(pkgdir, "test", "Project.toml")
    if isfile(test_proj_path)
        test_proj = try
            TOML.parsefile(test_proj_path)
        catch e
            @warn "Failed to parse test/Project.toml; test-only deps will not be merged into shadow" path=test_proj_path exception=e
            Dict{String, Any}()
        end

        for (name, uuid) in get(test_proj, "deps", Dict{String, Any}())
            uuid isa String || continue
            uuid in stdlib_uuids && continue   # stdlib — always available
            uuid == pkg_uuid    && continue   # self-dep — already the project
            new_deps[name] = uuid
        end

        # [sources] — Julia 1.11+ path/url-based deps (hermetic local packages)
        for (name, spec) in get(test_proj, "sources", Dict{String, Any}())
            new_sources[name] = spec
        end

        # [compat] — non-conflicting entries only
        for (k, v) in get(test_proj, "compat", Dict{String, Any}())
            new_compat[k] = v
        end
    end

    # ── Collect test deps from legacy [extras] + [targets] ───────────────────
    # (present in the MAIN Project.toml, not test/)
    main_proj_path = joinpath(pkgdir, "Project.toml")
    if isfile(main_proj_path)
        main_proj = try
            TOML.parsefile(main_proj_path)
        catch
            Dict{String, Any}()
        end
        extras  = get(main_proj, "extras",  Dict{String, Any}())
        targets = get(main_proj, "targets", Dict{String, Any}())
        test_target_names = Set{String}(get(targets, "test", String[]))
        for (name, uuid) in extras
            name in test_target_names || continue
            uuid isa String || continue
            uuid in stdlib_uuids && continue
            uuid == pkg_uuid    && continue
            new_deps[name] = uuid
        end
    end

    # ── Drop source-backed deps the running Julia can't resolve ───────────────
    # [sources] (path/url deps) is a Julia 1.11+ Project.toml feature. On older
    # Julia, Pkg ignores the table and tries to resolve the dep from a registry,
    # which throws. Drop those deps + sources so the rest still merges.
    dropped = _drop_unsupported_source_deps!(new_deps, new_sources, VERSION)
    isempty(dropped) || @warn "test/Project.toml [sources] requires Julia ≥ 1.11; \
        skipping source-backed test deps — they will be unavailable to the shadow" julia=VERSION deps=dropped

    # ── Fast-path: nothing to add ─────────────────────────────────────────────
    isempty(new_deps) && isempty(new_sources) && return false

    # ── Merge into shadow Project.toml ────────────────────────────────────────
    existing_deps    = get(shadow_proj, "deps",    Dict{String, Any}())
    existing_sources = get(shadow_proj, "sources", Dict{String, Any}())
    existing_compat  = get(shadow_proj, "compat",  Dict{String, Any}())

    actually_added = false

    for (name, uuid) in new_deps
        if !haskey(existing_deps, name)
            existing_deps[name] = uuid
            actually_added = true
        end
    end
    if !isempty(existing_deps)
        shadow_proj["deps"] = existing_deps
    end

    for (name, spec) in new_sources
        if !haskey(existing_sources, name)
            existing_sources[name] = spec
            actually_added = true
        end
    end
    if !isempty(existing_sources)
        shadow_proj["sources"] = existing_sources
    end

    for (k, v) in new_compat
        !haskey(existing_compat, k) && (existing_compat[k] = v)
    end
    if !isempty(existing_compat)
        shadow_proj["compat"] = existing_compat
    end

    actually_added || return false  # all were already present — skip Pkg work

    open(shadow_proj_path, "w") do io
        TOML.print(io, shadow_proj)
    end

    # ── Resolve + instantiate so shadow Manifest gains the new deps ───────────
    prev_active = Base.active_project()
    try
        Pkg.activate(shadow_dir; io=devnull)
        Pkg.resolve(;     io=devnull)
        Pkg.instantiate(; io=devnull)
    catch e
        throw(MutationError(
            "_augment_shadow_with_test_deps: Pkg.resolve/instantiate failed " *
            "while merging test deps into shadow — $e"
        ))
    finally
        # Restore caller's active project (defensive: Pkg.activate is process-global).
        # When prev_active is nothing the caller had no active project — activate the
        # default (stdlib) environment rather than passing nothing to Pkg.activate,
        # which would be a no-op and leave the shadow as the active project.
        if prev_active === nothing
            Pkg.activate(; io=devnull)
        else
            Pkg.activate(prev_active; io=devnull)
        end
    end

    return true
end

"""
    _stdlib_uuids() -> Set{String}

Return the set of UUIDs for all Julia standard-library packages.
Uses `Sys.STDLIB` (version-agnostic) to scan each stdlib's Project.toml.
Result is computed once; callers may cache externally if performance matters.
"""
function _stdlib_uuids()::Set{String}
    uuids = Set{String}()
    for name in readdir(Sys.STDLIB)
        p = joinpath(Sys.STDLIB, name, "Project.toml")
        isfile(p) || continue
        d = try TOML.parsefile(p) catch; continue end
        uuid = get(d, "uuid", nothing)
        uuid isa String && push!(uuids, uuid)
    end
    return uuids
end

# Note: _remap_cmap_to_real is defined in coverage.jl (after CoverageMap is declared)
