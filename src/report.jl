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

Emit a human-readable Markdown survival report.
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

Print a compact summary to stdout.
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
