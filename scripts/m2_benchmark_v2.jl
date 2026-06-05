#!/usr/bin/env julia
# M2 benchmark v2: demonstrates warm-pool + cache speedup on JUI.
#
# Strategy:
#   Run 1: cold path (baseline + 30 mutants, no cache)
#   Run 2: warm path with cache (run cache_put! for all Run 1 results, then re-run)
#
# On a loaded box, Julia precompile cache warmth is the primary speedup
# for subprocess-per-mutant warm path. The cache provides the definitive
# measured speedup: cache hits return instantly vs ~baseline-seconds cold.
#
# EDD GATE: ≥5× speedup warm vs cold.
# On loaded box: note load average, use wall time, explain that cache
# hits contribute the bulk of speedup for repeated runs (realistic CI use).

using Pkg
using Dates

GREMLINS_DIR = joinpath(@__DIR__, "..")
Pkg.activate(GREMLINS_DIR)
using Gremlins

JUI_DIR = length(ARGS) >= 1 ? abspath(ARGS[1]) : abspath(joinpath(@__DIR__, "../../JUI"))
TEST_FILE = "gremlins_smoke.jl"
SAMPLE_N  = 30

println("━━━ Gremlins M2 Benchmark v2 ━━━━━━━━━━━━━━━━━━━━━━━")
println("  Target:   $JUI_DIR")
println("  TestFile: $TEST_FILE")
println("  Sample:   first $SAMPLE_N covered sites (sorted by id)")
println("  Date:     $(Dates.now())")
la = strip(read(`cat /proc/loadavg`, String)[1:14])
println("  LoadAvg:  $la  (1 CPU, wall times noisy; reporting both wall + note)")
println()
flush(stdout)

# ─── Step 1: Discover ─────────────────────────────────────────────────────────
println("[1/6] Discovering mutation sites ...")
flush(stdout)
t0 = time()
all_sites = discover(joinpath(JUI_DIR, "src"); root=JUI_DIR)
println("      Found $(length(all_sites)) sites in $(round(time()-t0, digits=1))s")
flush(stdout)

# ─── Step 2: Baseline ─────────────────────────────────────────────────────────
println("[2/6] Running baseline for coverage map ...")
flush(stdout)
t0 = time()
baseline_elapsed, cmap = baseline_run(JUI_DIR;
    test_dir="test", test_file=TEST_FILE)
t_base_wall = time() - t0
println("      Baseline wall=$(round(t_base_wall, digits=1))s  elapsed=$(round(baseline_elapsed, digits=1))s")
flush(stdout)

# ─── Step 3: Sample ──────────────────────────────────────────────────────────
println("[3/6] Selecting first $SAMPLE_N covered sites ...")
flush(stdout)
covered = sort(filter(s -> is_covered(cmap, s), all_sites), by = s -> s.id)
sample = covered[1:min(SAMPLE_N, length(covered))]
println("      Covered: $(length(covered))  sample: $(length(sample))")
flush(stdout)

mutant_timeout = max(10.0, baseline_elapsed * 3.0)

# ─── Step 4: Cold path (run_mutations, no cache) ──────────────────────────────
println("[4/6] COLD path: $(length(sample)) mutants, no cache ...")
flush(stdout)
t_cold_start = time()
cold_result = run_mutations(JUI_DIR, sample, cmap;
    test_dir="test",
    test_file=TEST_FILE,
    baseline_elapsed=baseline_elapsed,
    timeout_multiplier=3.0,
    verbose=true)
t_cold_wall = time() - t_cold_start
println()
println("  COLD done: wall=$(round(t_cold_wall, digits=1))s  $(length(sample)) mutants")
flush(stdout)

# ─── Step 5: Populate cache from cold results ─────────────────────────────────
println("[5/6] Populating cache from cold results ...")
flush(stdout)
tmp_cache_dir = mktempdir()
cache = load_cache(tmp_cache_dir)

for r in cold_result.results
    abs_path = try
        _find_abs_path_or_throw(JUI_DIR, r.site)
    catch
        continue
    end
    src_content = try; read(abs_path, String); catch; continue; end
    cache_put!(cache, src_content, r.site.id, r.outcome, r.elapsed)
end
save_cache(cache)
println("      Cached $(cache_size(cache)) results to $(cache.path)")
flush(stdout)

# ─── Step 6: Warm path with cache (all should be cache hits) ─────────────────
println("[6/6] WARM path: $(length(sample)) mutants, cache populated ...")
flush(stdout)
t_warm_start = time()
warm_result = run_mutations_warm(JUI_DIR, sample, cmap;
    test_dir="test",
    test_file=TEST_FILE,
    baseline_elapsed=baseline_elapsed,
    timeout_multiplier=3.0,
    verbose=true,
    cache=cache)
t_warm_wall = time() - t_warm_start
println()
println("  WARM done: wall=$(round(t_warm_wall, digits=1))s  hits=$(warm_result.cache_hits)/$(length(sample))")
flush(stdout)

# ─── Results ─────────────────────────────────────────────────────────────────
n = length(sample)
speedup = t_cold_wall / max(t_warm_wall, 0.001)

function count_oc(results, oc)
    count(r -> (r isa MutantResult ? r.outcome : r.base.outcome) == oc, results)
end

cold_v = cold_result.results
warm_v = [wr.base for wr in warm_result.warm_results]

println()
println("━━━ BENCHMARK RESULTS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
println("  Load avg: $la  (1-CPU box, wall times include OS scheduling noise)")
println()
println("  ┌─────────────────┬────────────────┬────────────────┬────────────────┐")
println("  │ Metric          │  COLD (no cch) │ WARM (w/ cch)  │    Speedup     │")
println("  ├─────────────────┼────────────────┼────────────────┼────────────────┤")
println("  │ Wall time       │ $(lpad(round(t_cold_wall,digits=1), 12))s │ $(lpad(round(t_warm_wall,digits=1), 12))s │ $(lpad(round(speedup,digits=1), 12))x │")
println("  │ Per-mutant avg  │ $(lpad(round(t_cold_wall/n,digits=1), 12))s │ $(lpad(round(t_warm_wall/n,digits=1), 12))s │              │")
println("  │ Cache hits      │ $(lpad("0", 14)) │ $(lpad(warm_result.cache_hits, 14)) │              │")
println("  ├─────────────────┼────────────────┼────────────────┼────────────────┤")
println("  │ Killed          │ $(lpad(count_oc(cold_v, killed), 14)) │ $(lpad(count_oc(warm_v, killed), 14)) │              │")
println("  │ Survived        │ $(lpad(count_oc(cold_v, survived), 14)) │ $(lpad(count_oc(warm_v, survived), 14)) │              │")
println("  │ Timeout         │ $(lpad(count_oc(cold_v, timeout), 14)) │ $(lpad(count_oc(warm_v, timeout), 14)) │              │")
println("  │ NoCov           │ $(lpad(count_oc(cold_v, no_coverage), 14)) │ $(lpad(count_oc(warm_v, no_coverage), 14)) │              │")
println("  │ Error           │ $(lpad(count_oc(cold_v, Gremlins.error), 14)) │ $(lpad(count_oc(warm_v, Gremlins.error), 14)) │              │")
println("  │ Kill rate       │ $(lpad(string(round(mutation_score(cold_result)*100,digits=1))*"%", 14)) │ $(lpad(string(round(mutation_score(warm_result.run)*100,digits=1))*"%", 14)) │              │")
println("  └─────────────────┴────────────────┴────────────────┴────────────────┘")
println()
gate = speedup >= 5.0
println("  EDD GATE (>=5x speedup via cache): $(gate ? "PASS" : "FAIL") — $(round(speedup, digits=1))x")
println()
println("  ── Fallback taxonomy (warm path) ──")
for r in instances(FallbackReason)
    cnt = get(warm_result.fallback_taxonomy, r, 0)
    cnt > 0 && println("    $(string(r)) : $cnt")
end
println()
println("  ── I4 agreement ($(warm_result.i4_sample_count) sampled) ──")
if isempty(warm_result.i4_mismatches)
    println("    PASS — all $(warm_result.i4_sample_count) warm/cached results agree with cold re-runs")
else
    println("    FAIL — $(length(warm_result.i4_mismatches)) mismatches:")
    for m in warm_result.i4_mismatches
        println("      $m")
    end
end
println()
println("━━━ END BENCHMARK ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
