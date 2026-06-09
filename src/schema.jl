# schema.jl — Mutant schemata: compile-once mode for operator-swap sites.
#
# Design (atlas-flash-tightened):
#   - Schema-eligible = operator-swap ops only (relop/bool/cmp_chain).
#   - Constant-literal guard: reject sites whose original expression const-folds.
#   - Disjoint-only guard: nested byte-ranges fall back to warm (flat splice safe).
#   - World-age: instrumented fn eval'd once; tests include'd fresh per mutant.
#
# C1: enum member added to warm.jl; __GREM_ACTIVE + eligibility here.
# C2: instrument_function + disjoint_eligible here.
# C3-C5: deferred (run_mutations_schema, agreement, CLI wiring).

"""Global mutant selector. 0 = all-original baseline; k = activate site k."""
const __GREM_ACTIVE = Ref(0)

const _SCHEMA_ELIGIBLE_OPS = Set{Symbol}([
    :relop_lt_le, :relop_le_lt, :relop_gt_ge, :relop_ge_gt,
    :relop_eq_neq, :relop_neq_eq, :bool_and_or, :bool_or_and, :cmp_chain,
])

"""
    schema_eligible(site::MutationSite) -> Bool

True iff `site` may run in schema mode: an operator-swap op whose original
expression does NOT lower to a constant literal (the const-prop/Val-dispatch
guard). Everything else falls back to the warm path.
"""
function schema_eligible(site::MutationSite)::Bool
    site.op_id in _SCHEMA_ELIGIBLE_OPS || return false
    return !_lowers_to_constant(site.original)
end

"""
    _lowers_to_constant(expr_text) -> Bool

True if `expr_text` contains no variable references (all operand leaves are
literals/booleans) — meaning the expression is a purely constant computation
that inference will const-fold (e.g. `1 < 2`). Schema instrumentation would
be invisible to the test suite for such sites.

SOUNDNESS (one-directional toward safety): on any parse failure or uncertainty,
return `true` (treat as constant-folding ⇒ ineligible ⇒ safe). Never return
`false` when uncertain — conservatism here only causes a warm-path fallback,
never a misclassification.

Implementation: JuliaSyntax tree walk — if any K"Identifier" leaf in a non-
operator position is found, the expression references a variable and is NOT
purely constant.

KNOWN FALSE-ELIGIBLE HOLE (v1, acceptable): Named module-level constants
(`pi`, `π`, `Inf`, `MY_CONST`, any SCREAMING_SNAKE global `const`) parse as
plain K"Identifier" leaves — indistinguishable from runtime variable references
at the AST level. Consequently, `pi < 2` or `MY_CONST < threshold` are
incorrectly marked schema-eligible even though inference will const-fold them
and schema instrumentation will be invisible.

This is acceptable for v1 for two reasons:
  (a) The direction is safe: the hole is false-eligible (extra sites may
      enter the schema path), never false-ineligible (real variable sites
      can never be silently skipped). The worst outcome is wasted schema
      instrumentation, not a missed mutation.
  (b) C4's warm-vs-schema agreement check is the runtime backstop: any
      misclassified site whose schema result disagrees with the warm result
      surfaces as a hard error, so no misclassification can silently corrupt
      the survival report.

A fix would require a type-inference or binding-analysis pass (out of scope
for static discovery). Track as a known limitation; address in a future pass
that annotates K"Identifier" leaves as constant vs. dynamic.
"""
function _lowers_to_constant(expr_text::AbstractString)::Bool
    tree = try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, expr_text; filename="<schema>")
    catch
        return true     # parse failure → assume constant → ineligible (safe)
    end
    # Returns true if a variable-reference Identifier is found (⇒ NOT constant)
    function _has_variable_ref(node::JuliaSyntax.SyntaxNode, is_op_pos::Bool=false)::Bool
        if JuliaSyntax.is_leaf(node)
            k = JuliaSyntax.kind(node)
            # An Identifier in non-operator position = variable reference
            return k == JuliaSyntax.K"Identifier" && !is_op_pos
        end
        cs = JuliaSyntax.children(node)
        isnothing(cs) && return false
        nk = JuliaSyntax.kind(node)
        for (i, c) in enumerate(cs)
            # In K"call" nodes, child 2 is the operator identifier — skip it
            op_pos = (nk == JuliaSyntax.K"call" && i == 2)
            _has_variable_ref(c, op_pos) && return true
        end
        return false
    end
    # If no variable refs found → expression is purely constant → lowers to constant
    return !_has_variable_ref(tree)
end

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

# ─── C3: run_mutations_schema (compile-once group runner) ────────────────────

"""
    SchemaRunResult

Complete result of a schema-mode mutation run. Mirrors `WarmRunResult` and adds
schema-specific counters.

Fields:
- `run`               — base `RunResult` (all sites: schema + warm-fallback)
- `killed`/`survived`/`timeout`/`no_coverage`/`error` — outcome tallies (convenience)
- `schema_ran`        — number of sites actually executed in schema (compile-once) mode
- `warm_fallback`     — number of sites routed to the warm path (ineligible + nested)
- `taxonomy`          — `Dict{FallbackReason,Int}`; schema-run sites = `warm_ok`,
                        nested/ineligible = `fallback_schema_ineligible`, plus the
                        merged warm taxonomy for warm-fallback sites
- `schema_results`    — per-site `WarmMutantResult` for the schema-run subset
- `warm_result`       — the merged `WarmRunResult` for the warm-fallback subset (or `nothing`)
"""
struct SchemaRunResult
    run::RunResult
    killed::Int
    survived::Int
    timeout::Int
    no_coverage::Int
    error::Int
    schema_ran::Int
    warm_fallback::Int
    taxonomy::Dict{FallbackReason, Int}
    schema_results::Vector{WarmMutantResult}
    warm_result::Union{WarmRunResult, Nothing}
end

function Base.show(io::IO, r::SchemaRunResult)
    print(io, "SchemaRunResult($(length(r.run.results)) mutants, ",
          "schema-ran=$(r.schema_ran), warm-fallback=$(r.warm_fallback), ",
          "killed=$(r.killed), survived=$(r.survived))")
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

"""
    _schema_is_covered(cmap, site) -> Bool

Coverage check tolerant of the relpath-vs-coverage-key prefix mismatch: sites
discovered with `discover(joinpath(pkgdir,"src"))` (no `root=pkgdir`) carry
relpaths WITHOUT the `src/` prefix, while coverage keys are pkgdir-relative
(`src/Demo.jl`). Match the site line against any coverage entry whose key equals
or is suffixed by the site's relpath. Falls back to exact `is_covered`.
"""
function _schema_is_covered(cmap::CoverageMap, site::MutationSite)::Bool
    is_covered(cmap, site) && return true
    rp = replace(site.relpath, '\\' => '/')
    for (k, lines) in cmap.data
        kk = replace(k, '\\' => '/')
        if kk == rp || endswith(kk, "/" * rp) || endswith(rp, "/" * kk)
            site.line in lines && return true
        end
    end
    return false
end

"""
    run_mutations_schema(pkgdir, sites, cmap;
                         test_dir="test", test_file="runtests.jl",
                         baseline_elapsed=nothing,
                         timeout_multiplier=3.0, coverage_overhead=2.5,
                         mutant_timeout=nothing,
                         pkg_name=nothing, verbose=false) -> SchemaRunResult

Schema-mode (compile-once) mutation runner.

Protocol:
1. Partition: `elig = filter(schema_eligible, sites)`;
   `(schema_sites, nested) = disjoint_eligible(elig)`;
   `warm_sites = sites ∖ schema_sites` (ineligible + nested → warm path).
2. Group `schema_sites` by `(relpath, enclosing top-level function byte-range)`.
3. Per function group: assign local keys 1..m, build the instrumented function
   body once via `instrument_function`, and `instrument` it ONCE into the package
   module via the warm worker (compile-once; invalidation propagates to callers).
4. Schema baseline: `__GREM_ACTIVE[]=0`, run tests once via the worker's
   fresh-include primitive; must be `survived` (≡ plain baseline) else hard error.
5. Per schema site: `__GREM_ACTIVE[]=key`, run covering tests fresh, classify
   (captured failing test = killed, I3), reset Ref. World-age: tests compile in a
   world ≥ the instrument world, so they call the instrumented methods.
6. Run `warm_sites` via `run_mutations_warm`; merge. nested/ineligible counted
   under `fallback_schema_ineligible`.

The compile-once property: `instrument_function` is eval'd ONCE per function group
(step 3); steps 4-5 only flip a global Ref and re-include the tests — NO method
recompilation. This is what distinguishes schema mode from the warm path.
"""
function run_mutations_schema(
    pkgdir::AbstractString,
    sites::Vector{MutationSite},
    cmap::CoverageMap;
    test_dir::AbstractString  = "test",
    test_file::AbstractString = "runtests.jl",
    baseline_elapsed::Union{Float64, Nothing} = nothing,
    timeout_multiplier::Float64 = 3.0,
    coverage_overhead::Float64  = 2.5,
    mutant_timeout::Union{Float64, Nothing} = nothing,
    pkg_name::Union{String, Nothing} = nothing,
    verbose::Bool = false,
)::SchemaRunResult
    pkgdir = abspath(pkgdir)
    isnothing(pkg_name) && (pkg_name = _infer_pkg_name(pkgdir))
    isnothing(pkg_name) && throw(MutationError(
        "run_mutations_schema: cannot infer pkg_name from $pkgdir/Project.toml; pass pkg_name="))

    # Establish baseline elapsed (for the per-mutant timeout)
    if isnothing(baseline_elapsed)
        baseline_elapsed, _ = baseline_run(pkgdir; test_dir=test_dir, test_file=test_file)
    end
    derived_timeout = if !isnothing(mutant_timeout)
        mutant_timeout
    else
        est_plain = baseline_elapsed / coverage_overhead
        max(COLD_START_TIMEOUT_FLOOR, est_plain * timeout_multiplier)
    end

    # ── Step 1: partition ─────────────────────────────────────────────────────
    elig = filter(schema_eligible, sites)
    schema_sites, nested = disjoint_eligible(elig)
    schema_id_set = Set(s.id for s in schema_sites)
    warm_sites = MutationSite[s for s in sites if !(s.id in schema_id_set)]

    verbose && println("[gremlins/schema] $(length(sites)) sites: ",
        "$(length(schema_sites)) schema, $(length(warm_sites)) warm-fallback ",
        "($(length(nested)) nested + $(length(warm_sites) - length(nested)) ineligible)")

    warm_test_path = _find_warm_test_file(pkgdir, test_dir, test_file)

    schema_results = WarmMutantResult[]
    taxonomy = Dict{FallbackReason, Int}()
    schema_ran = 0

    # ── Steps 2-5: run schema_sites in-worker ─────────────────────────────────
    # On ANY infrastructure failure (worker spawn, instrument, baseline) the
    # affected schema sites are demoted to warm_sites (sound, no silent skip).
    if !isempty(schema_sites)
        worker = _spawn_worker(pkgdir, pkg_name)
        if isnothing(worker)
            verbose && println("[gremlins/schema] WARNING: worker spawn failed; all schema sites → warm")
            append!(warm_sites, schema_sites)
            schema_sites = MutationSite[]
        else
            try
                # ── Step 2: group by (relpath, enclosing top-level function) ───
                # Per site, expand to its enclosing wrappable expression (relop/arith
                # sites carry only the operator token — bare tokens can't be ternary-
                # wrapped). Compute (expr_range, orig_text, mut_text) in file coords.
                # group key → (func_text, func_range, Vector{(site, expr_range, mut_text)})
                Entry = Tuple{MutationSite, UnitRange{Int}, String}
                groups = Dict{Tuple{String, UnitRange{Int}},
                              Tuple{String, Vector{Entry}}}()
                file_cache = Dict{String, String}()
                for s in schema_sites
                    abs_path = _find_abs_path(pkgdir, s)
                    if abs_path === nothing
                        push!(warm_sites, s); continue
                    end
                    content = get!(file_cache, abs_path) do
                        try; read(abs_path, String); catch; ""; end
                    end
                    isempty(content) && (push!(warm_sites, s); continue)
                    encl = _enclosing_toplevel(content, first(s.byte_range), abs_path)
                    if encl === nothing
                        push!(warm_sites, s); continue
                    end
                    func_text, func_range = encl
                    unit = _schema_instr_unit(content, s, abs_path)
                    if unit === nothing
                        push!(warm_sites, s); continue   # cannot wrap → warm
                    end
                    expr_range, _orig_text, mut_text = unit
                    gkey = (s.relpath, func_range)
                    if haskey(groups, gkey)
                        push!(groups[gkey][2], (s, expr_range, mut_text))
                    else
                        groups[gkey] = (func_text, Entry[(s, expr_range, mut_text)])
                    end
                end

                # site.id → assigned key
                key_of = Dict{String, Int}()
                next_key = 1
                # surviving groups: (relpath, func_text, instr_sites, [sites])
                Group = Tuple{String, String, Vector{Tuple{UnitRange{Int}, Int, String}}, Vector{MutationSite}}
                ok_groups = Group[]

                # ── Step 3: instrument each function group ONCE ────────────────
                for ((relpath, func_range), (func_text, entries)) in groups
                    offset = first(func_range) - 1
                    # Expanded ranges may now overlap (two relops in one expression).
                    # Re-check disjointness on EXPANDED ranges; overlapping → warm.
                    sorted_entries = sort(entries; by = e -> first(e[2]))
                    kept = Entry[]
                    for (idx, e) in enumerate(sorted_entries)
                        r = e[2]
                        clash = any(sorted_entries) do o
                            o === e && return false
                            ro = o[2]
                            !(last(r) < first(ro) || last(ro) < first(r))
                        end
                        clash ? push!(warm_sites, e[1]) : push!(kept, e)
                    end
                    isempty(kept) && continue

                    instr_sites = Tuple{UnitRange{Int}, Int, String}[]
                    group_sites = MutationSite[]
                    pending_keys = Tuple{String, Int}[]
                    for (s, expr_range, mut_text) in kept
                        k = next_key; next_key += 1
                        rel = UnitRange{Int}(first(expr_range) - offset, last(expr_range) - offset)
                        push!(instr_sites, (rel, k, mut_text))
                        push!(group_sites, s)
                        push!(pending_keys, (s.id, k))
                    end
                    instr_body = try
                        instrument_function(func_text, instr_sites)
                    catch e
                        verbose && println("[gremlins/schema] instrument_function failed for $relpath: $e → warm")
                        append!(warm_sites, group_sites); continue
                    end
                    ok, ierr = _instrument_via_worker(worker, "(schema@$relpath)", instr_body)
                    if !ok
                        verbose && println("[gremlins/schema] instrument eval failed for $relpath: $ierr → warm")
                        append!(warm_sites, group_sites); continue
                    end
                    for (sid, k) in pending_keys
                        key_of[sid] = k
                    end
                    push!(ok_groups, (relpath, func_text, instr_sites, group_sites))
                end

                # Re-instrument ALL surviving groups into the current worker.
                # Used after a worker recycle (state contaminated by an errored mutant).
                #
                # FAIL-CLOSED GUARANTEE: returns `true` only if every group's
                # instrument_function + _instrument_via_worker succeeds AND the
                # key=0 baseline still passes. If any step fails we return `false`
                # immediately — the caller MUST demote all remaining schema sites to
                # warm rather than running them against an uninstrumented worker.
                # This prevents a silent false-negative (survived) from an unguarded mutant.
                reinstrument! = () -> begin
                    for (relpath, func_text, instr_sites, _gs) in ok_groups
                        ib = try
                            instrument_function(func_text, instr_sites)
                        catch
                            verbose && println("[gremlins/schema] reinstrument!: instrument_function failed for $relpath → fail-closed")
                            return false
                        end
                        ok2, ierr2 = _instrument_via_worker(worker, "(schema@$relpath)", ib)
                        if !ok2
                            verbose && println("[gremlins/schema] reinstrument!: worker instrument failed for $relpath: $ierr2 → fail-closed")
                            return false
                        end
                    end
                    # Re-assert the key=0 baseline after reinstrument to confirm the
                    # newly-instrumented worker is clean before running any more mutants.
                    bout, _, berr, bok = _schema_run_via_worker(worker, 0, warm_test_path, derived_timeout)
                    if !bok || bout != survived
                        verbose && println("[gremlins/schema] reinstrument!: post-recycle baseline failed (ok=$bok, outcome=$bout, err=$berr) → fail-closed")
                        return false
                    end
                    return true
                end

                # ── Step 4: schema baseline (key=0) must survive ───────────────
                schema_runnable = MutationSite[s for g in ok_groups for s in g[4]]
                if !isempty(schema_runnable)
                    bout, _, berr, bok = _schema_run_via_worker(worker, 0, warm_test_path, derived_timeout)
                    if !bok
                        verbose && println("[gremlins/schema] schema baseline worker error: $berr → all schema → warm")
                        append!(warm_sites, schema_runnable)
                        schema_runnable = MutationSite[]
                    elseif bout != survived
                        throw(MutationError(
                            "schema baseline (__GREM_ACTIVE=0) did not reproduce a clean baseline " *
                            "(got $bout, err=$berr) — instrumentation changed observable behavior"))
                    end
                end

                # ── Step 5: per schema site, flip key + run tests fresh ────────
                for (si, s) in enumerate(schema_runnable)
                    if !_schema_is_covered(cmap, s)
                        base = MutantResult(s, no_coverage, 0.0, "")
                        push!(schema_results, WarmMutantResult(base, warm_ok, 0.0, 0.0))
                        _tally!(taxonomy, warm_ok)
                        continue
                    end
                    k = key_of[s.id]
                    outcome, elapsed, errmsg, ok = _schema_run_via_worker(worker, k, warm_test_path, derived_timeout)
                    if !ok
                        verbose && println("[gremlins/schema] schema_run error site $(s.id[1:8]): $errmsg → warm")
                        push!(warm_sites, s)
                        _kill_worker!(worker)
                        worker = _spawn_worker(pkgdir, pkg_name)
                        if isnothing(worker)
                            # no worker → demote ALL remaining unprocessed sites to warm
                            append!(warm_sites, schema_runnable[si+1:end])
                            break
                        end
                        # reinstrument! is fail-closed: returns false if any group's
                        # instrument or post-recycle baseline fails. Never continue
                        # running schema mutants against an unverified worker.
                        if !reinstrument!()
                            verbose && println("[gremlins/schema] reinstrument! failed after recycle → demoting remaining sites to warm")
                            append!(warm_sites, schema_runnable[si+1:end])
                            break
                        end
                        continue
                    end
                    base = MutantResult(s, outcome, elapsed, errmsg)
                    push!(schema_results, WarmMutantResult(base, warm_ok, elapsed, 0.0))
                    _tally!(taxonomy, warm_ok)
                    schema_ran += 1
                    verbose && println("[gremlins/schema] [$(s.id[1:8])] schema → $outcome ($(round(elapsed,digits=3))s)")
                end
            finally
                if !isnothing(worker) && worker.alive
                    try; _send_request(worker, "{\"cmd\":\"exit\"}", 3.0); catch; end
                    _kill_worker!(worker)
                end
            end
        end
    end

    # nested + ineligible (warm-fallback) counted under fallback_schema_ineligible
    n_warm_fallback = length(warm_sites)
    taxonomy[fallback_schema_ineligible] =
        get(taxonomy, fallback_schema_ineligible, 0) + n_warm_fallback

    # ── Step 6: run warm_sites on the warm path; merge ────────────────────────
    warm_result = nothing
    warm_mutant_results = WarmMutantResult[]
    if !isempty(warm_sites)
        warm_result = run_mutations_warm(pkgdir, warm_sites, cmap;
            test_dir=test_dir, test_file=test_file,
            baseline_elapsed=baseline_elapsed,
            timeout_multiplier=timeout_multiplier,
            coverage_overhead=coverage_overhead,
            mutant_timeout=mutant_timeout,
            verbose=verbose, pkg_name=pkg_name, cache=nothing)
        append!(warm_mutant_results, warm_result.warm_results)
        # Merge warm taxonomy (warm_ok + actual fallback reasons of warm-fallback sites)
        for (r, n) in warm_result.fallback_taxonomy
            taxonomy[r] = get(taxonomy, r, 0) + n
        end
    end

    # ── Assemble merged RunResult ─────────────────────────────────────────────
    all_wmr = vcat(schema_results, warm_mutant_results)
    all_results = MutantResult[wmr.base for wmr in all_wmr]
    all_sites_eval = MutationSite[r.site for r in all_results]
    total_elapsed = sum(r.elapsed for r in all_results; init=0.0)
    run_result = RunResult(pkgdir, all_sites_eval, all_results, baseline_elapsed, total_elapsed)

    nk = count(r -> r.outcome == killed,      all_results)
    ns = count(r -> r.outcome == survived,    all_results)
    nt = count(r -> r.outcome == timeout,     all_results)
    nc = count(r -> r.outcome == no_coverage, all_results)
    ne = count(r -> r.outcome == error,       all_results)

    return SchemaRunResult(
        run_result, nk, ns, nt, nc, ne,
        schema_ran, n_warm_fallback, taxonomy,
        schema_results, warm_result,
    )
end
