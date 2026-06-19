# report.jl — JSON and Markdown survival report for Gremlins.jl
#
# Public API:
#   report(result::RunResult; format=:markdown) -> String
#   report_json(result::RunResult)              -> String
#   report_markdown(result::RunResult)          -> String
#   print_summary(result::RunResult)            — print to stdout

# ─── JSON serialisation ────────────────────────────────────────────────────────

"""
    report_json(result::RunResult) -> String

Emit a structured JSON report of the mutation run.
"""
function report_json(result::RunResult)::String
    score = mutation_score(result)
    score_pct = isnan(score) ? "null" : string(round(score * 100, digits=2))

    n_killed   = count(x -> x.outcome == killed,      result.results)
    n_survived = count(x -> x.outcome == survived,    result.results)
    n_timeout  = count(x -> x.outcome == timeout,     result.results)
    n_nocov    = count(x -> x.outcome == no_coverage,  result.results)
    n_error    = count(x -> x.outcome == error,        result.results)

    mutants_json = join([_mutant_json(r) for r in result.results], ",\n    ")

    """
{
  "schema": "gremlins-report-v1",
  "pkgdir": $(JSON_str(result.pkgdir)),
  "summary": {
    "total": $(length(result.results)),
    "killed": $n_killed,
    "survived": $n_survived,
    "timeout": $n_timeout,
    "no_coverage": $n_nocov,
    "error": $n_error,
    "mutation_score_pct": $score_pct
  },
  "baseline_elapsed_s": $(round(result.baseline_elapsed, digits=3)),
  "total_elapsed_s": $(round(result.total_elapsed, digits=3)),
  "mutants": [
    $mutants_json
  ]
}"""
end

function _mutant_json(r::MutantResult)::String
    s = r.site
    """{
      "id": $(JSON_str(s.id)),
      "relpath": $(JSON_str(s.relpath)),
      "line": $(s.line),
      "op_id": $(JSON_str(string(s.op_id))),
      "op_name": $(JSON_str(s.op_name)),
      "original": $(JSON_str(s.original)),
      "replacement": $(JSON_str(s.replacement)),
      "outcome": $(JSON_str(string(r.outcome))),
      "elapsed_s": $(round(r.elapsed, digits=3)),
      "error_msg": $(JSON_str(r.error_msg))
    }"""
end

# Minimal JSON string escape (no external dep)
function JSON_str(s::AbstractString)::String
    buf = IOBuffer()
    write(buf, '"')
    for c in s
        if c == '"'
            write(buf, "\\\"")
        elseif c == '\\'
            write(buf, "\\\\")
        elseif c == '\n'
            write(buf, "\\n")
        elseif c == '\r'
            write(buf, "\\r")
        elseif c == '\t'
            write(buf, "\\t")
        elseif codepoint(c) < 0x20
            write(buf, "\\u$(lpad(string(codepoint(c), base=16), 4, '0'))")
        else
            write(buf, c)
        end
    end
    write(buf, '"')
    String(take!(buf))
end

# ─── Markdown report ──────────────────────────────────────────────────────────

"""
    report_markdown(result::RunResult) -> String
    report_markdown(wr::WarmRunResult) -> String
    report_markdown(sr::SchemaRunResult) -> String

Emit a human-readable Markdown survival report. The `WarmRunResult` method adds
warm-fallback taxonomy and I4 results; the `SchemaRunResult` method adds the
schema/warm split and taxonomy.
"""
function report_markdown(result::RunResult)::String
    score = mutation_score(result)
    score_str = isnan(score) ? "N/A" : "$(round(score * 100, digits=1))%"

    n_killed   = count(x -> x.outcome == killed,      result.results)
    n_survived = count(x -> x.outcome == survived,    result.results)
    n_timeout  = count(x -> x.outcome == timeout,     result.results)
    n_nocov    = count(x -> x.outcome == no_coverage,  result.results)
    n_error    = count(x -> x.outcome == error,        result.results)

    lines = String[]
    push!(lines, "# Gremlins Mutation Report")
    push!(lines, "")
    push!(lines, "**Package:** `$(basename(result.pkgdir))`  ")
    push!(lines, "**Mutation Score:** $score_str  ")
    push!(lines, "**Baseline:** $(round(result.baseline_elapsed, digits=2))s  ")
    push!(lines, "**Total runtime:** $(round(result.total_elapsed, digits=2))s  ")
    push!(lines, "")
    push!(lines, "## Summary")
    push!(lines, "")
    push!(lines, "| Outcome       | Count |")
    push!(lines, "|---------------|-------|")
    push!(lines, "| Killed        | $n_killed |")
    push!(lines, "| Survived      | $n_survived |")
    push!(lines, "| Timeout       | $n_timeout |")
    push!(lines, "| No coverage   | $n_nocov |")
    push!(lines, "| Error         | $n_error |")
    push!(lines, "| **Total**     | **$(length(result.results))** |")
    push!(lines, "")

    survived_results = filter(r -> r.outcome == survived, result.results)
    if !isempty(survived_results)
        push!(lines, "## Surviving Mutants")
        push!(lines, "")
        push!(lines, "These mutations were NOT caught by your test suite:")
        push!(lines, "")
        push!(lines, "| ID | File | Line | Operator | Original → Replacement |")
        push!(lines, "|----|------|------|----------|------------------------|")
        for r in survived_results
            s = r.site
            push!(lines, "| `$(s.id[1:8])` | `$(s.relpath)` | $(s.line) | $(s.op_name) | `$(repr(s.original))` → `$(repr(s.replacement))` |")
        end
        push!(lines, "")
    end

    timeout_results = filter(r -> r.outcome == timeout, result.results)
    if !isempty(timeout_results)
        push!(lines, "## Timed-Out Mutants")
        push!(lines, "")
        push!(lines, "| ID | File | Line | Operator |")
        push!(lines, "|----|------|------|----------|")
        for r in timeout_results
            s = r.site
            push!(lines, "| `$(s.id[1:8])` | `$(s.relpath)` | $(s.line) | $(s.op_name) |")
        end
        push!(lines, "")
    end

    error_results = filter(r -> r.outcome == error, result.results)
    if !isempty(error_results)
        push!(lines, "## Errored Mutants")
        push!(lines, "")
        push!(lines, "| ID | File | Line | Error |")
        push!(lines, "|----|------|------|-------|")
        for r in error_results
            s = r.site
            short_err = length(r.error_msg) > 80 ? r.error_msg[1:80] * "…" : r.error_msg
            push!(lines, "| `$(s.id[1:8])` | `$(s.relpath)` | $(s.line) | $(short_err) |")
        end
        push!(lines, "")
    end

    return join(lines, "\n")
end

# ─── Dispatch ─────────────────────────────────────────────────────────────────

"""
    report(result::RunResult; format::Symbol=:markdown) -> String

Generate a report in `:markdown` or `:json` format.
"""
function report(result::RunResult; format::Symbol=:markdown)::String
    if format == :markdown
        return report_markdown(result)
    elseif format == :json
        return report_json(result)
    else
        throw(MutationError("report: unknown format $(repr(format)); use :markdown or :json"))
    end
end

# ─── Console summary ──────────────────────────────────────────────────────────

"""
    print_summary(result::RunResult)
    print_summary(wr::WarmRunResult)
    print_summary(sr::SchemaRunResult)

Print a compact summary to stdout. The `WarmRunResult` method adds the warm-run
fallback taxonomy, cache hits, and I4 results; the `SchemaRunResult` method adds
the schema/warm split and (when auto-disabled) a visible auto-disable line.
"""
function print_summary(result::RunResult)
    score = mutation_score(result)
    score_str = isnan(score) ? "N/A" : "$(round(score * 100, digits=1))%"

    n_killed   = count(x -> x.outcome == killed,      result.results)
    n_survived = count(x -> x.outcome == survived,    result.results)
    n_timeout  = count(x -> x.outcome == timeout,     result.results)
    n_nocov    = count(x -> x.outcome == no_coverage,  result.results)
    n_error    = count(x -> x.outcome == error,        result.results)
    n_total    = length(result.results)

    println("━━━ Gremlins Mutation Report ━━━━━━━━━━━━━━━━━━")
    println("  Package  : $(basename(result.pkgdir))")
    println("  Score    : $score_str  (killed=$n_killed / eligible=$(n_total - n_nocov - n_error))")
    println("  Killed   : $n_killed")
    println("  Survived : $n_survived")
    println("  Timeout  : $n_timeout")
    println("  NoCov    : $n_nocov")
    println("  Error    : $n_error")
    println("  Total    : $n_total")
    println("  Baseline : $(round(result.baseline_elapsed, digits=2))s")
    println("  Runtime  : $(round(result.total_elapsed, digits=2))s")
    println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
end

# ─── Warm run report (M2) ─────────────────────────────────────────────────────

function print_summary(wr::WarmRunResult)
    run = wr.run
    score = mutation_score(run)
    score_str = isnan(score) ? "N/A" : "$(round(score * 100, digits=1))%"

    n_killed   = count(x -> x.outcome == killed,      run.results)
    n_survived = count(x -> x.outcome == survived,    run.results)
    n_timeout  = count(x -> x.outcome == timeout,     run.results)
    n_nocov    = count(x -> x.outcome == no_coverage,  run.results)
    n_error    = count(x -> x.outcome == error,        run.results)
    n_total    = length(run.results)

    n_warm = get(wr.fallback_taxonomy, warm_ok, 0)
    n_cold = n_total - n_warm

    println("━━━ Gremlins Warm Mutation Report ━━━━━━━━━━━━━━")
    println("  Package       : $(basename(run.pkgdir))")
    println("  Score         : $score_str  (killed=$n_killed / eligible=$(n_total - n_nocov - n_error))")
    println("  Killed        : $n_killed")
    println("  Survived      : $n_survived")
    println("  Timeout       : $n_timeout")
    println("  NoCov         : $n_nocov")
    println("  Error         : $n_error")
    println("  Total         : $n_total")
    println("  Cache hits    : $(wr.cache_hits)")
    println("  Warm-executed : $n_warm")
    println("  Cold fallback : $(n_total - n_warm)")
    println("  Worker recycles: $(wr.worker_recycles)")
    println("  Baseline      : $(round(run.baseline_elapsed, digits=2))s")
    println("  Runtime       : $(round(run.total_elapsed, digits=2))s")
    println("  ── Fallback taxonomy ──")
    for r in instances(FallbackReason)
        cnt = get(wr.fallback_taxonomy, r, 0)
        cnt > 0 && println("    $(string(r)) : $cnt")
    end
    println("  ── I4 agreement ($(wr.i4_sample_count) sampled) ──")
    if isempty(wr.i4_mismatches)
        println("    OK — all $(wr.i4_sample_count) warm results agree with cold re-runs")
    else
        println("    FAIL — $(length(wr.i4_mismatches)) mismatches:")
        for m in wr.i4_mismatches
            println("      $m")
        end
    end
    println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
end

function report_markdown(wr::WarmRunResult)::String
    run = wr.run
    score = mutation_score(run)
    score_str = isnan(score) ? "N/A" : "$(round(score * 100, digits=1))%"

    n_killed   = count(x -> x.outcome == killed,      run.results)
    n_survived = count(x -> x.outcome == survived,    run.results)
    n_timeout  = count(x -> x.outcome == timeout,     run.results)
    n_nocov    = count(x -> x.outcome == no_coverage,  run.results)
    n_error    = count(x -> x.outcome == error,        run.results)

    lines = String[]
    push!(lines, "# Gremlins Warm Mutation Report (M2)")
    push!(lines, "")
    push!(lines, "**Package:** `$(basename(run.pkgdir))`  ")
    push!(lines, "**Mutation Score:** $score_str  ")
    push!(lines, "**Baseline:** $(round(run.baseline_elapsed, digits=2))s  ")
    push!(lines, "**Total runtime:** $(round(run.total_elapsed, digits=2))s  ")
    push!(lines, "**Cache hits:** $(wr.cache_hits)  ")
    push!(lines, "**Worker recycles:** $(wr.worker_recycles)  ")
    push!(lines, "")
    push!(lines, "## Summary")
    push!(lines, "")
    push!(lines, "| Outcome       | Count |")
    push!(lines, "|---------------|-------|")
    push!(lines, "| Killed        | $n_killed |")
    push!(lines, "| Survived      | $n_survived |")
    push!(lines, "| Timeout       | $n_timeout |")
    push!(lines, "| No coverage   | $n_nocov |")
    push!(lines, "| Error         | $n_error |")
    push!(lines, "| **Total**     | **$(length(run.results))** |")
    push!(lines, "")
    push!(lines, "## Fallback Taxonomy")
    push!(lines, "")
    push!(lines, "| Reason | Count |")
    push!(lines, "|--------|-------|")
    for r in instances(FallbackReason)
        cnt = get(wr.fallback_taxonomy, r, 0)
        push!(lines, "| $(string(r)) | $cnt |")
    end
    push!(lines, "")
    push!(lines, "## I4 Agreement Check ($(wr.i4_sample_count) sampled)")
    push!(lines, "")
    if isempty(wr.i4_mismatches)
        push!(lines, "All $(wr.i4_sample_count) warm results agree with cold re-runs. PASS.")
    else
        push!(lines, "**FAIL** — $(length(wr.i4_mismatches)) warm/cold outcome mismatches:")
        push!(lines, "")
        for m in wr.i4_mismatches
            push!(lines, "- $m")
        end
    end
    push!(lines, "")
    return join(lines, "\n")
end

# ─── Schema run report (C5) ──────────────────────────────────────────────────

function print_summary(sr::SchemaRunResult)
    run = sr.run
    score = mutation_score(run)
    score_str = isnan(score) ? "N/A" : "$(round(score * 100, digits=1))%"

    n_total = length(run.results)

    println("━━━ Gremlins Schema Mutation Report ━━━━━━━━━━━━")
    println("  Package      : $(basename(run.pkgdir))")
    println("  Score        : $score_str  (killed=$(sr.killed) / eligible=$(n_total - sr.no_coverage - sr.error))")
    println("  Killed       : $(sr.killed)")
    println("  Survived     : $(sr.survived)")
    println("  Timeout      : $(sr.timeout)")
    println("  NoCov        : $(sr.no_coverage)")
    println("  Error        : $(sr.error)")
    println("  Total        : $n_total")
    println("  schema-ran   : $(sr.schema_ran)   warm-fallback: $(sr.warm_fallback)")
    if sr.auto_disabled
        st = round(sr.agreement_schema_time, digits=3)
        wt = round(sr.agreement_warm_time, digits=3)
        println("  schema auto-disabled (hot path): schema=$(st)s warm=$(wt)s — ran all eligible on warm")
    end
    println("  ── Fallback reason breakdown (warm-fallback=$(sr.warm_fallback)) ──")
    for r in instances(FallbackReason)
        cnt = get(sr.taxonomy, r, 0)
        cnt > 0 && println("    $(string(r)) : $cnt")
    end
    println("  Baseline     : $(round(run.baseline_elapsed, digits=2))s")
    println("  Runtime      : $(round(run.total_elapsed, digits=2))s")
    println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
end

function report_markdown(sr::SchemaRunResult)::String
    run = sr.run
    score = mutation_score(run)
    score_str = isnan(score) ? "N/A" : "$(round(score * 100, digits=1))%"

    lines = String[]
    push!(lines, "# Gremlins Schema Mutation Report (C5)")
    push!(lines, "")
    push!(lines, "**Package:** `$(basename(run.pkgdir))`  ")
    push!(lines, "**Mutation Score:** $score_str  ")
    push!(lines, "**Baseline:** $(round(run.baseline_elapsed, digits=2))s  ")
    push!(lines, "**Total runtime:** $(round(run.total_elapsed, digits=2))s  ")
    push!(lines, "**schema-ran:** $(sr.schema_ran)   **warm-fallback:** $(sr.warm_fallback)  ")
    if sr.auto_disabled
        st = round(sr.agreement_schema_time, digits=3)
        wt = round(sr.agreement_warm_time, digits=3)
        push!(lines, "**schema auto-disabled (hot path):** schema=$(st)s warm=$(wt)s — ran all eligible on warm  ")
    end
    push!(lines, "")
    push!(lines, "## Summary")
    push!(lines, "")
    push!(lines, "| Outcome       | Count |")
    push!(lines, "|---------------|-------|")
    push!(lines, "| Killed        | $(sr.killed) |")
    push!(lines, "| Survived      | $(sr.survived) |")
    push!(lines, "| Timeout       | $(sr.timeout) |")
    push!(lines, "| No coverage   | $(sr.no_coverage) |")
    push!(lines, "| Error         | $(sr.error) |")
    push!(lines, "| **Total**     | **$(length(run.results))** |")
    push!(lines, "")
    push!(lines, "## Schema/Warm Split")
    push!(lines, "")
    push!(lines, "| Path          | Count |")
    push!(lines, "|---------------|-------|")
    push!(lines, "| schema-ran    | $(sr.schema_ran) |")
    push!(lines, "| warm-fallback | $(sr.warm_fallback) |")
    push!(lines, "")
    push!(lines, "## Fallback Reason Breakdown (warm-fallback=$(sr.warm_fallback))")
    push!(lines, "")
    push!(lines, "| Reason | Count |")
    push!(lines, "|--------|-------|")
    for r in instances(FallbackReason)
        cnt = get(sr.taxonomy, r, 0)
        push!(lines, "| $(string(r)) | $cnt |")
    end
    push!(lines, "")
    return join(lines, "\n")
end

# ─── Unified diff per surviving mutant (Issue #4, Vimes parity) ───────────────

"""
    render_survivor_diffs(result::RunResult, pkgdir::String) -> String

For each surviving mutant (sorted by relpath, line, id), render a minimal
unified diff hunk showing the changed line.

Format per hunk:
    --- a/<relpath>
    +++ b/<relpath>
    @@ -<line> +<line> @@
    -<original line>
    +<mutated line>

The mutated line is derived by splicing `site.replacement` over `site.byte_range`
in the source file, then extracting the affected line.  Source files are resolved
relative to `pkgdir` (falling back to `joinpath(pkgdir, "src", relpath)` if the
direct join doesn't exist, matching discover.jl conventions).

Returns an empty string when there are no survivors.
"""
function render_survivor_diffs(result::RunResult, pkgdir::String)::String
    survivors = filter(r -> r.outcome == survived, result.results)
    isempty(survivors) && return ""

    # Sort deterministically: (relpath, line, id) — same order as report_markdown
    sort!(survivors; by = r -> (r.site.relpath, r.site.line, r.site.id))

    buf = IOBuffer()
    for r in survivors
        s = r.site
        # Resolve source file path
        direct = joinpath(pkgdir, s.relpath)
        src_path = if isfile(direct)
            direct
        else
            fallback = joinpath(pkgdir, "src", s.relpath)
            isfile(fallback) ? fallback : direct   # keep direct so error is clear
        end

        src_text = try
            read(src_path, String)
        catch e
            throw(MutationError("render_survivor_diffs: cannot read $(src_path): $e"))
        end

        # Produce the mutated source via byte-range splice (reuse apply logic)
        mutated_text = apply(s, src_text)

        # Extract the affected line from original and mutated text
        orig_line = _line_at(src_text, s.line)
        mut_line  = _line_at(mutated_text, s.line)

        # Emit hunk
        println(buf, "--- a/$(s.relpath)")
        println(buf, "+++ b/$(s.relpath)")
        println(buf, "@@ -$(s.line) +$(s.line) @@")
        println(buf, "-$(orig_line)")
        println(buf, "+$(mut_line)")
    end
    return String(take!(buf))
end

"""
    _line_at(src::String, n::Int) -> String

Return the n-th line (1-based) of `src`, without the trailing newline.
Throws `MutationError` if `n` is out of range.
"""
function _line_at(src::String, n::Int)::String
    lines = split(src, '\n'; keepempty=true)
    # split on '\n' for a file ending in '\n' yields an empty string at end — fine
    if n < 1 || n > length(lines)
        throw(MutationError("_line_at: line $n out of range (file has $(length(lines)) lines after split)"))
    end
    return lines[n]
end

# Export
export render_survivor_diffs
