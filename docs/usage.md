# Gremlins.jl — Full API Guide

## Overview

Gremlins exposes two layers:

- **High-level entry points** (`mutate`, `mutate_warm`) — discover + baseline + run
  in one call.
- **Low-level building blocks** — discover, baseline_run, run_mutations,
  run_mutations_warm — compose your own pipeline.

All public symbols are exported from the `Gremlins` module. See `src/Gremlins.jl`
for the full export list.

---

## Types

### `MutationSite`

Represents a single candidate mutation.

| Field | Type | Description |
|-------|------|-------------|
| `id` | `String` | 16-hex stable hash of `(relpath, byte_range, op_id)` |
| `relpath` | `String` | Path relative to discovery root (forward slash) |
| `byte_range` | `UnitRange{Int}` | 1-based codeunit range of the splice target |
| `op_id` | `Symbol` | Operator stable id (e.g. `:relop_lt_le`) |
| `op_name` | `String` | Human label |
| `original` | `String` | Original source text for the range |
| `replacement` | `String` | Mutated text to splice in |
| `line` | `Int` | 1-based source line |

### `MutantOutcome`

Enum: `killed`, `survived`, `timeout`, `no_coverage`, `error`.

### `MutantResult`

| Field | Type | Description |
|-------|------|-------------|
| `site` | `MutationSite` | The site that was mutated |
| `outcome` | `MutantOutcome` | Execution result |
| `elapsed` | `Float64` | Seconds for this mutant's execution |
| `error_msg` | `String` | Non-empty only for `outcome == error` |

### `RunResult`

| Field | Type | Description |
|-------|------|-------------|
| `pkgdir` | `String` | Absolute package directory |
| `sites` | `Vector{MutationSite}` | All sites (sorted) |
| `results` | `Vector{MutantResult}` | One per site, same order |
| `baseline_elapsed` | `Float64` | Seconds for baseline test run |
| `total_elapsed` | `Float64` | Wall time for entire run |

### `WarmMutantResult`

Wraps `MutantResult` with warm-path metadata:

| Field | Type | Description |
|-------|------|-------------|
| `base` | `MutantResult` | Underlying outcome |
| `fallback_reason` | `FallbackReason` | `warm_ok` = ran warm; else explains cold fallback |
| `warm_elapsed` | `Float64` | 0.0 if ran cold |
| `cold_elapsed` | `Float64` | 0.0 if ran warm |

### `WarmRunResult`

| Field | Type | Description |
|-------|------|-------------|
| `run` | `RunResult` | Base results (same outcome semantics as cold path) |
| `warm_results` | `Vector{WarmMutantResult}` | Per-mutant warm metadata |
| `fallback_taxonomy` | `Dict{FallbackReason, Int}` | Count per fallback reason |
| `i4_sample_count` | `Int` | Number of warm mutants sampled for I4 check |
| `i4_mismatches` | `Vector{String}` | Non-empty = warm/cold disagreement (hard error) |
| `cache_hits` | `Int` | Mutants served from cache |
| `worker_recycles` | `Int` | Worker restart count during run |

### `FallbackReason`

Enum:
- `warm_ok` — ran warm successfully
- `fallback_macro` — inside a macro definition
- `fallback_typedef` — inside struct/abstract/primitive type def
- `fallback_const` — inside a const global assignment
- `fallback_evalerr` — warm eval threw an exception (dynamic)
- `fallback_pollution` — reserved

### `MutantCache`

Opaque in-memory cache. Use `load_cache`, `save_cache`, `cache_get`, `cache_put!`.

---

## Discovery

### `discover(dir_or_file; operators=DEFAULT_OPERATORS, root=nothing) -> Vector{MutationSite}`

Discover mutation sites across all `.jl` files in a directory or a single file.
Skips `test/` and `tests/` directories.

```julia
sites = discover("src/")
sites = discover("src/foo.jl"; operators=[OP_LT_TO_LE, OP_GT_TO_GE])
```

**kwargs:**
- `operators` — subset of operators to apply (default: all `DEFAULT_OPERATORS`)
- `root` — path used as the base for computing relative paths in site IDs. Defaults
  to `dir_or_file`. Pass the package root for consistent IDs across sub-directory runs.

### `discover_file(path; root=dirname(path), operators=DEFAULT_OPERATORS) -> Vector{MutationSite}`

Discover sites in a single file. Results sorted by `(byte_start, op_id)`.

### `mutant_id(relpath, byte_range, op_id) -> String`

Compute the stable 16-hex-char mutant ID. Useful for caching and resumable runs.

---

## Coverage

### `baseline_run(pkgdir; test_dir="test", test_file="runtests.jl") -> (elapsed::Float64, cmap::CoverageMap)`

Run the test suite once with `--code-coverage=user` and build a line-to-test map.
Returns elapsed time and a `CoverageMap`.

```julia
elapsed, cmap = baseline_run("/path/to/MyPkg")
```

### `is_covered(cmap::CoverageMap, site::MutationSite) -> Bool`

Returns `true` if the site's source line has baseline coverage.

### `covered_lines(cmap::CoverageMap) -> Set{Tuple{String,Int}}`

All `(relpath, line)` pairs that have coverage.

---

## Cold runner (M1)

### `run_mutations(pkgdir, sites, cmap; ...) -> RunResult`

Process-per-mutant runner. For each site: check coverage, apply mutation, run tests,
revert. Source is always restored (try/finally).

**kwargs:**
- `test_dir="test"` — subdirectory containing test files
- `test_file="runtests.jl"` — test entry point
- `baseline_elapsed=nothing` — if provided, skips re-measuring baseline
- `timeout_multiplier=3.0` — mutant timeout = `baseline * multiplier`
- `verbose=false` — print per-mutant progress

```julia
elapsed, cmap = baseline_run(pkgdir)
sites = discover(joinpath(pkgdir, "src"); root=pkgdir)
result = run_mutations(pkgdir, sites, cmap; verbose=true)
```

### `mutate(pkgdir; ...) -> RunResult`

High-level cold-path entry point: discover + baseline + run.

**kwargs:** same as `run_mutations` plus:
- `src_dir="src"` — directory to discover in
- `operators=DEFAULT_OPERATORS`

```julia
result = mutate("/path/to/MyPkg"; verbose=true)
print_summary(result)
```

### `mutation_score(result::RunResult) -> Float64`

`killed / (total - no_coverage - error)`. Returns `NaN` if denominator is 0.

---

## Warm-worker pool (M2)

### `run_mutations_warm(pkgdir, sites, cmap; ...) -> WarmRunResult`

Warm-pool runner. Worker loads package once; per-mutant evals changed function,
runs tests in fresh Module, restores. Falls back to cold for ineligible sites.

**kwargs:** same as `run_mutations` plus:
- `n_workers=nothing` — accepted for API compatibility; warm path uses 1 worker
- `cache=nothing` — `MutantCache` for incremental results
- `pkg_name=nothing` — package name (inferred from `Project.toml` if not given)

```julia
cache = load_cache(pkgdir)
result = run_mutations_warm(pkgdir, sites, cmap; cache=cache, verbose=true)
save_cache(cache)
print_warm_summary(result)
```

### `mutate_warm(pkgdir; ...) -> WarmRunResult`

High-level warm-path entry point: discover + baseline + warm run + cache.

**kwargs:** same as `run_mutations_warm` plus:
- `src_dir="src"`
- `operators=DEFAULT_OPERATORS`
- `use_cache=true` — load/save `.gremlins_cache.json` in pkgdir
- `pkg_name=nothing`

```julia
result = mutate_warm("/path/to/MyPkg"; verbose=true)
print_warm_summary(result)
```

### `classify_warm_eligibility(site, pkgdir) -> WarmEligibility`

Static check: returns `WarmEligibility(eligible::Bool, reason::FallbackReason)`.

---

## Reports

### `report(result::RunResult; format=:markdown) -> String`

Generate a report string. `format` is `:markdown` (default) or `:json`.

```julia
md = report(result)                   # Markdown
js = report(result; format=:json)     # JSON (schema: gremlins-report-v1)
```

### `report_markdown(result::RunResult) -> String`

Markdown survival report: summary table, surviving mutants table, timeout/error tables.

### `report_json(result::RunResult) -> String`

JSON report. Schema: `gremlins-report-v1`.

### `print_summary(result::RunResult)`

Compact console summary.

### `print_warm_summary(wr::WarmRunResult)`

Compact warm-run summary including fallback taxonomy, cache hits, I4 results.

### `report_warm_markdown(wr::WarmRunResult) -> String`

Full Markdown warm report.

---

## Cache

### `load_cache(pkgdir) -> MutantCache`

Load `.gremlins_cache.json` from `pkgdir`. Returns empty cache if file absent or malformed.

### `save_cache(cache::MutantCache)`

Persist cache to disk (atomic write). No-op if not dirty.

### `cache_get(cache, src_content, mutant_id) -> Union{CachedResult, Nothing}`

Look up a cached result. `src_content` is the full source file text (used to compute
the content-hash portion of the key).

### `cache_put!(cache, src_content, mutant_id, outcome, elapsed)`

Store a result. Marks cache dirty.

### `cache_size(cache) -> Int`

Number of entries in the cache.

---

## Patching

These are used internally but are exported for tooling use.

### `apply(site::MutationSite, src::String) -> String`

Return the mutated source string. Does not write to disk. Throws `MutationError`
if `site.original` no longer matches at `site.byte_range` (stale site).

### `revert(site::MutationSite, mutated_src::String) -> String`

Return the original source string by splicing `site.original` back.

### `apply!(site, path) -> String`

Apply mutation in-place to the file at `path`. Returns original source. Atomic write.

### `revert!(site, original_src, path)`

Restore original source in-place. Atomic write.

### `roundtrip_ok(site, src) -> Bool`

Returns `true` if `revert(site, apply(site, src)) == src`.

---

## Operators

All exported operator constants: `OP_LT_TO_LE`, `OP_LE_TO_LT`, `OP_GT_TO_GE`,
`OP_GE_TO_GT`, `OP_EQ_TO_NEQ`, `OP_NEQ_TO_EQ`, `OP_AND_TO_OR`, `OP_OR_TO_AND`,
`OP_DELETE_NOT`, `OP_PLUS_TO_MINUS`, `OP_MINUS_TO_PLUS`, `OP_MUL_TO_DIV`,
`OP_DIV_TO_MUL`, `OP_INT_INCR`, `OP_INT_DECR`, `OP_TRUE_TO_FALSE`,
`OP_FALSE_TO_TRUE`, `OP_RETURN_NOTHING`, `OP_STMT_DELETE`.

`DEFAULT_OPERATORS` — all of the above.

### Custom operators

```julia
my_op = MutationOperator(
    :my_flip,
    "custom: foo → bar",
    (node, src) -> JuliaSyntax.is_leaf(node) && node.val === :foo,
    (node, src) -> "bar",
)
result = mutate_warm(pkgdir; operators=[my_op])
```

---

## Error handling

All library paths throw `MutationError` (not `error("...")`). Catch explicitly:

```julia
try
    apply!(site, path)
catch e::MutationError
    @warn "mutation failed" site=site msg=e.msg
end
```

---

## Examples

### Scope to changed files (CI use case)

```julia
changed_files = split(ENV["CHANGED_FILES"], ",")
sites = discover("src/")
filtered = filter(s -> any(f -> endswith(s.relpath, basename(f)), changed_files), sites)
elapsed, cmap = baseline_run(".")
result = run_mutations_warm(".", filtered, cmap; verbose=true)
print_warm_summary(result)
```

### Budget-capped run (exploratory)

```julia
# Discover all sites, run only first 50 (sorted by id = deterministic subset)
sites = discover("src/")
capped = first(sort(sites, by=s->s.id), 50)
elapsed, cmap = baseline_run(".")
result = run_mutations_warm(".", capped, cmap)
```

### JSON output for dashboards

```julia
result = mutate_warm(".")
open("mutation-report.json", "w") do io
    write(io, report(result.run; format=:json))
end
```
