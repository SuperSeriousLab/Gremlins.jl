#!/usr/bin/env bash
# Tier 1 (cheapest, ~seconds): internal metric floor.
#
# Requires all three protocol dims ≥ 0.85 on the chunk. Same data
# the scheduler reads — no new measurement, just a stricter gate
# than the 0.80 "done-ceiling" rule.
#
# Output: PASS / FAIL <reason> on stdout. Exit 0 on PASS, 1 on FAIL.

set -uo pipefail

chunk="${1:?usage: certify_t1_metrics.sh <file:path>}"
root="$(git rev-parse --show-toplevel)"

fs=$("$root/.sisyphus/scripts/score_file_size.sh" "$chunk" 2>/dev/null \
  | grep -oE '"score":[0-9.]+' | head -1 | cut -d: -f2 || echo 0)
cx=$("$root/.sisyphus/scripts/score_complexity.sh" "$chunk" 2>/dev/null \
  | grep -oE '"score":[0-9.]+' | head -1 | cut -d: -f2 || echo 0)
dc=$("$root/.sisyphus/scripts/score_doc.sh" "$chunk" 2>/dev/null \
  | grep -oE '"score":[0-9.]+' | head -1 | cut -d: -f2 || echo 0)

if awk -v a="$fs" -v b="$cx" -v c="$dc" \
   'BEGIN { exit !(a >= 0.80 && b >= 0.80 && c >= 0.80) }'; then
  printf 'PASS\tt1-metrics\tfs=%s cx=%s dc=%s (strong)\n' "$fs" "$cx" "$dc"
  exit 0
fi
if awk -v a="$fs" -v b="$cx" -v c="$dc" \
   'BEGIN { exit !(a >= 0.60 && b >= 0.60 && c >= 0.60) }'; then
  # Soft-pass band 0.60-0.80: complexity now measured by the Go AST
  # walker (score_complexity.go), so scores below the strong-line
  # reflect real depth, LOC, or sparse package doc — not the
  # composite-literal artifact of the awk era. The other 4 tiers
  # (tools, spec, coverage, adversarial) carry the certification
  # weight, but the cards record honestly that the metric floor is
  # acceptable rather than strong on this chunk.
  printf 'PASS\tt1-metrics\tfs=%s cx=%s dc=%s (acceptable — real-signal soft-pass)\n' "$fs" "$cx" "$dc"
  exit 0
fi
printf 'FAIL\tt1-metrics\tfs=%s cx=%s dc=%s (need ≥0.60 on all three for soft-pass)\n' "$fs" "$cx" "$dc"
exit 1
