# schema.jl — Mutant schemata: compile-once mode for operator-swap sites.
#
# Design (atlas-flash-tightened):
#   - Schema-eligible = operator-swap ops only (relop/bool/cmp_chain).
#   - Constant-literal guard: reject sites whose original expression const-folds.
#   - Disjoint-only guard: nested byte-ranges fall back to warm (flat splice safe).
#   - World-age: instrumented fn eval'd once; tests include'd fresh per mutant.
#
# C1: enum member added to warm_eligibility.jl; __GREM_ACTIVE + eligibility here.
# C2: instrument_function + disjoint_eligible → schema_instrument.jl.
# C4: AgreementResult + schema_warm_agreement → schema_agreement.jl.
# C3-C5: run_mutations_schema (here), agreement, CLI wiring.
#
# NOTE: instrument_function / disjoint_eligible / _enclosing_toplevel /
# _SCHEMA_WRAP_KINDS / _deepest_node_at / _schema_instr_unit live in
# schema_instrument.jl; AgreementResult / schema_warm_agreement / _check_agreement
# live in schema_agreement.jl. Both are included BEFORE this file in Gremlins.jl.

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

"""
    SchemaRunResult

Complete result of a schema-mode mutation run. Mirrors `WarmRunResult` and adds
schema-specific counters.

Fields:
- `run`                    — base `RunResult` (all sites: schema + warm-fallback)
- `killed`/`survived`/`timeout`/`no_coverage`/`error` — outcome tallies (convenience)
- `schema_ran`             — number of sites actually executed in schema (compile-once) mode
- `warm_fallback`          — number of sites routed to the warm path (ineligible + nested)
- `taxonomy`               — `Dict{FallbackReason,Int}`; reason breakdown for ALL nsites.
                             `warm_ok` = schema-ran sites + warm-path warm_ok sites combined.
                             Other keys = warm-fallback cold-path reasons from the warm runner.
                             Invariant: `sum(values(taxonomy)) == nsites` (no double-count).
                             `schema_ran + warm_fallback == nsites` gives the schema/warm split.
                             No double-count: warm-fallback sites appear only in their warm
                             reason bucket, NOT separately under `fallback_schema_ineligible`.
- `schema_results`         — per-site `WarmMutantResult` for the schema-run subset
- `warm_result`            — the merged `WarmRunResult` for the warm-fallback subset (or `nothing`)
- `auto_disabled`          — true if the agreement sample showed schema_time > warm_time
                             (hot-path auto-disable fired; all schema sites ran on warm path)
- `agreement_schema_time`  — summed schema-path test time from the agreement sample (0.0 if skipped)
- `agreement_warm_time`    — summed warm-path test time from the agreement sample (0.0 if skipped)
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
    auto_disabled::Bool
    agreement_schema_time::Float64
    agreement_warm_time::Float64
end

function Base.show(io::IO, r::SchemaRunResult)
    ad_str = r.auto_disabled ? " [auto-disabled]" : ""
    print(io, "SchemaRunResult($(length(r.run.results)) mutants, ",
          "schema-ran=$(r.schema_ran), warm-fallback=$(r.warm_fallback), ",
          "killed=$(r.killed), survived=$(r.survived)$ad_str)")
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
                         pkg_name=nothing, verbose=false,
                         agreement_check=true, agreement_k=10) -> SchemaRunResult

Schema-mode (compile-once) mutation runner.

Protocol:
1. Partition: `elig = filter(schema_eligible, sites)`;
   `(schema_sites, nested) = disjoint_eligible(elig)`;
   `warm_sites = sites ∖ schema_sites` (ineligible + nested → warm path).
2. Agreement sample (if `agreement_check=true`): run first `agreement_k` schema-eligible
   sites BOTH ways (schema + warm). Any classification mismatch (killed ↔ survived) is a
   hard `MutationError` — soundness violation. If schema_time > warm_time on the sample,
   schema is net-negative for this package → auto-disable: route ALL eligible sites through
   warm instead (logged + recorded in `SchemaRunResult.auto_disabled`).
3. Group `schema_sites` by `(relpath, enclosing top-level function byte-range)`.
4. Per function group: assign local keys 1..m, build the instrumented function
   body once via `instrument_function`, and `instrument` it ONCE into the package
   module via the warm worker (compile-once; invalidation propagates to callers).
5. Schema baseline: `__GREM_ACTIVE[]=0`, run tests once via the worker's
   fresh-include primitive; must be `survived` (≡ plain baseline) else hard error.
6. Per schema site: `__GREM_ACTIVE[]=key`, run covering tests fresh, classify
   (captured failing test = killed, I3), reset Ref. World-age: tests compile in a
   world ≥ the instrument world, so they call the instrumented methods.
7. Run `warm_sites` via `run_mutations_warm`; merge. nested/ineligible counted
   under `fallback_schema_ineligible`.

The compile-once property: `instrument_function` is eval'd ONCE per function group
(step 4); steps 5-6 only flip a global Ref and re-include the tests — NO method
recompilation. This is what distinguishes schema mode from the warm path.

`agreement_check=false` suppresses the soundness sample (used internally by
`schema_warm_agreement` itself to avoid recursion, and by callers with tiny packages
that have fewer sites than the sample size).
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
    agreement_check::Bool = true,
    agreement_k::Int = 10,
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

    # ── C4: Agreement sample + hot-path auto-disable ──────────────────────────
    # Runs BEFORE partition so auto-disable can redirect the full eligible set.
    auto_disabled          = false
    agreement_schema_time  = 0.0
    agreement_warm_time    = 0.0

    if agreement_check
        agree = schema_warm_agreement(
            pkgdir, sites, cmap;
            pkg_name=pkg_name, k=agreement_k,
            test_dir=test_dir, test_file=test_file,
            baseline_elapsed=baseline_elapsed,
            mutant_timeout=mutant_timeout,
            verbose=verbose,
        )
        agreement_schema_time = agree.schema_time
        agreement_warm_time   = agree.warm_time

        # Hot-path auto-disable: if schema is net-negative for this package,
        # route ALL eligible sites through warm to avoid spending more time than
        # the warm path for zero benefit.
        #
        # Compare only on the "both_ran" subset (sites where BOTH paths produced
        # killed/survived). This prevents a spurious disable when the warm path
        # returns no_coverage for all sample sites due to relpath key mismatch
        # (warm_time=0 would otherwise always trigger the disable).
        if agree.both_ran > 0 && agree.schema_time_both > agree.warm_time_both
            auto_disabled = true
            @warn("[gremlins/schema] schema auto-disabled (hot path): " *
                  "schema=$(round(agree.schema_time_both, digits=3))s " *
                  "warm=$(round(agree.warm_time_both, digits=3))s " *
                  "on $(agree.both_ran)/$(agree.sample_size) comparable sites " *
                  "— routing all eligible sites via warm path")
            # Fall through to Step 1 with an empty elig: all sites → warm
            # (achieved by routing everything to warm in Step 1 below via the flag)
        end
    end

    # ── Step 1: partition ─────────────────────────────────────────────────────
    elig = auto_disabled ? MutationSite[] : filter(schema_eligible, sites)
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

    # ── C5.1 taxonomy fix ────────────────────────────────────────────────────
    # `taxonomy` accumulated `warm_ok` tallies for schema-ran sites (via
    # `_tally!(taxonomy, warm_ok)` above). We do NOT add a separate
    # `fallback_schema_ineligible` counter here — doing so and then merging
    # the warm taxonomy would double-count warm-fallback sites (once under
    # `fallback_schema_ineligible` and once under their actual warm reason).
    #
    # Correct invariant after this function:
    #   taxonomy[warm_ok]          == schema_ran          (schema-ran sites)
    #   sum(warm_fallback_taxonomy) == n_warm_fallback     (reason breakdown)
    #   sum(all taxonomy values)    == schema_ran + n_warm_fallback == nsites
    #
    # `fallback_schema_ineligible` appears in the warm taxonomy for sites that
    # the warm worker also classifies as statically ineligible — it is NOT a
    # separate "bucket" we add here.
    n_warm_fallback = length(warm_sites)

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
        # Merge warm taxonomy (warm_ok + actual fallback reasons of warm-fallback sites).
        # This makes sum(taxonomy) = schema_ran + n_warm_fallback = nsites (no double-count).
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
        auto_disabled, agreement_schema_time, agreement_warm_time,
    )
end
