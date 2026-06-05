#!/usr/bin/env julia
# M2 benchmark: cold path vs warm path on JUI, first 30 covered mutation sites.
# Spec: ≥5× speedup warm vs cold (wall time).
# Run: julia --project scripts/m2_benchmark.jl /path/to/JUI
#
# The benchmark samples the first 30 mutation sites (sorted by mutant id)
# that are covered by the gremlins_smoke.jl baseline.
# It runs:
#   1. Cold path (run_mutations) on the 30-site sample
#   2. Warm path (run_mutations_warm) on the same 30-site sample
# Then reports wall + CPU time, kill-rate, and fallback taxonomy.

using Pkg
using Dates

# Load Gremlins from its project
GREMLINS_DIR = joinpath(@__DIR__, "..")
Pkg.activate(GREMLINS_DIR)
using Gremlins

JUI_DIR = length(ARGS) >= 1 ? abspath(ARGS[1]) : abspath(joinpath(@__DIR__, "../../JUI"))
TEST_FILE = "gremlins_smoke.jl"
SAMPLE_N  = 30

println("━━━ Gremlins M2 Benchmark ━━━━━━━━━━━━━━━━━━━━━━━━")
println("  Target:   $JUI_DIR")
println("  TestFile: $TEST_FILE")
println("  Sample:   first $SAMPLE_N covered sites (sorted by id)")
println("  Date:     $(Dates.now())")
println()
flush(stdout)

# ─── Step 1: Discover + Baseline ──────────────────────────────────────────────

println("[1/5] Discovering mutation sites in JUI/src ...")
flush(stdout)
t_disc0 = time()
all_sites = discover(joinpath(JUI_DIR, "src"); root=JUI_DIR)
t_disc = time() - t_disc0
println("      Found $(length(all_sites)) sites in $(round(t_disc, digits=1))s")
flush(stdout)

println("[2/5] Running baseline (gremlins_smoke.jl) for coverage + time ...")
flush(stdout)
t_base0 = time()
baseline_elapsed, cmap = baseline_run(JUI_DIR;
    test_dir="test", test_file=TEST_FILE)
t_base_wall = time() - t_base0
println("      Baseline wall: $(round(t_base_wall, digits=2))s  elapsed: $(round(baseline_elapsed, digits=2))s")
flush(stdout)

# ─── Step 2: Select first 30 covered sites ───────────────────────────────────

println("[3/5] Selecting first $SAMPLE_N covered sites by id ...")
flush(stdout)
covered_sorted = sort(filter(s -> is_covered(cmap, s), all_sites), by = s -> s.id)
n_covered = length(covered_sorted)
sample_sites = covered_sorted[1:min(SAMPLE_N, n_covered)]
println("      Total covered: $n_covered  sample: $(length(sample_sites)) sites")
flush(stdout)

for (i, s) in enumerate(sample_sites)
    println("      [$i] $(s.id[1:8]) $(s.relpath):$(s.line) [$(s.op_name)] $(repr(s.original))→$(repr(s.replacement))")
end
println()
flush(stdout)

mutant_timeout = max(10.0, baseline_elapsed * 3.0)

# ─── Step 3: Cold path run ────────────────────────────────────────────────────

println("[4/5] COLD path: running $(length(sample_sites)) mutants sequentially ...")
flush(stdout)

t_cold0 = time()
cold_result = run_mutations(JUI_DIR, sample_sites, cmap;
    test_dir="test",
    test_file=TEST_FILE,
    baseline_elapsed=baseline_elapsed,
    timeout_multiplier=3.0,
    verbose=true)
t_cold_wall = time() - t_cold0

println()
println("  COLD wall: $(round(t_cold_wall, digits=2))s")
flush(stdout)

# ─── Step 4: Warm path run ────────────────────────────────────────────────────

println("[5/5] WARM path: running $(length(sample_sites)) mutants (warm pool) ...")
flush(stdout)

# Pre-warm the Julia precompile cache by running the test once briefly
t_warm0 = time()
warm_result = run_mutations_warm(JUI_DIR, sample_sites, cmap;
    test_dir="test",
    test_file=TEST_FILE,
    baseline_elapsed=baseline_elapsed,
    timeout_multiplier=3.0,
    verbose=true,
    use_cache=false)
t_warm_wall = time() - t_warm0

println()
println("  WARM wall: $(round(t_warm_wall, digits=2))s")
flush(stdout)

# ─── Results ─────────────────────────────────────────────────────────────────

println()
println("━━━ BENCHMARK RESULTS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
println()

n = length(sample_sites)

function count_outcome(results, oc)
    count(r -> (r isa MutantResult ? r.outcome : r.base.outcome) == oc, results)
end

cold_results_v = cold_result.results
warm_results_v = [wr.base for wr in warm_result.warm_results]

println("  Sample size   : $n sites")
println("  Baseline      : $(round(baseline_elapsed, digits=2))s")
println()
println("  NOTE: CPU time not independently measured; wall time used. Load avg at start: $(strip(read(`cat /proc/loadavg`, String)[1:14]))")
println()
println("  ┌─────────────┬────────────┬────────────┬────────────┐")
println("  │ Metric      │   COLD     │   WARM     │  Speedup   │")
println("  ├─────────────┼────────────┼────────────┼────────────┤")
println("  │ Wall time   │ $(lpad(round(t_cold_wall, digits=1), 8))s │ $(lpad(round(t_warm_wall, digits=1), 8))s │ $(lpad(round(t_cold_wall / max(t_warm_wall, 0.01), digits=2), 8))x │")
println("  │ Per-mutant  │ $(lpad(round(t_cold_wall/n, digits=1), 8))s │ $(lpad(round(t_warm_wall/n, digits=1), 8))s │ $(lpad("-", 8))  │")
println("  ├─────────────┼────────────┼────────────┼────────────┤")
println("  │ Killed      │ $(lpad(count_outcome(cold_results_v, killed), 10)) │ $(lpad(count_outcome(warm_results_v, killed), 10)) │            │")
println("  │ Survived    │ $(lpad(count_outcome(cold_results_v, survived), 10)) │ $(lpad(count_outcome(warm_results_v, survived), 10)) │            │")
println("  │ Timeout     │ $(lpad(count_outcome(cold_results_v, timeout), 10)) │ $(lpad(count_outcome(warm_results_v, timeout), 10)) │            │")
println("  │ NoCov       │ $(lpad(count_outcome(cold_results_v, no_coverage), 10)) │ $(lpad(count_outcome(warm_results_v, no_coverage), 10)) │            │")
println("  │ Error       │ $(lpad(count_outcome(cold_results_v, Gremlins.error), 10)) │ $(lpad(count_outcome(warm_results_v, Gremlins.error), 10)) │            │")
println("  ├─────────────┼────────────┼────────────┼────────────┤")
println("  │ Kill rate   │ $(lpad(round(mutation_score(cold_result)*100, digits=1), 8))% │ $(lpad(round(mutation_score(warm_result.run)*100, digits=1), 8))% │            │")
println("  └─────────────┴────────────┴────────────┴────────────┘")
println()

speedup = t_cold_wall / max(t_warm_wall, 0.01)
gate_pass = speedup >= 5.0
println("  EDD GATE (>=5x speedup): $(gate_pass ? "PASS" : "FAIL") — $(round(speedup, digits=2))x")
println()

println("  ── Fallback taxonomy (warm) ──")
for r in instances(FallbackReason)
    cnt = get(warm_result.fallback_taxonomy, r, 0)
    cnt > 0 && println("    $(string(r)) : $cnt")
end
println()

println("  ── I4 agreement ($(warm_result.i4_sample_count) sampled) ──")
if isempty(warm_result.i4_mismatches)
    println("    PASS — all $(warm_result.i4_sample_count) warm results agree with cold re-runs")
else
    println("    FAIL — $(length(warm_result.i4_mismatches)) mismatches:")
    for m in warm_result.i4_mismatches
        println("      $m")
    end
end
println()

println("  ── Kill-rate report (combined) ──")
print_summary(cold_result)
println()
print_warm_summary(warm_result)

println()
println("━━━ END BENCHMARK ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
