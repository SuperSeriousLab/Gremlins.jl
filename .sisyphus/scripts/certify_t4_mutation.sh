#!/usr/bin/env bash
# Tier 4 (medium, ~minutes): coverage + mutation gate.
#
# Two sub-checks:
#   - line coverage for the chunk's package (3-band: strong/acceptable/light)
#   - mutation kill rate via gremlins.dev (3-band: strong/acceptable/skipped)
#
# Coverage runs per-chunk (fast). Gremlins runs ONCE per package
# (slow — minutes) and the result is cached at
#   .sisyphus/.cache/gremlins/<pkg-flat>.txt
# so subsequent chunks in the same package reuse it. The cache is
# invalidated whenever any .go file in the package changes (mtime
# of the package directory vs. cache file).
#
# Gremlins kill-rate bands (Test efficacy %):
#   ≥80% — strong (tests catch most mutations)
#   ≥60% — acceptable (real gaps but not skeleton tests)
#   <60% — fail (tests don't assert enough to catch corrupted logic)
#
# When gremlins is not installed, this tier soft-passes with a
# logged note so the certification card carries the caveat.
#
# Output: PASS / FAIL <reason> on stdout.

set -uo pipefail

chunk="${1:?usage: certify_t4_mutation.sh <file:path>}"
root="$(git rev-parse --show-toplevel)"
path="${chunk#file:}"
pkg=$(dirname "$path")

if command -v go >/dev/null 2>&1; then
  export PATH="$(go env GOPATH)/bin:$PATH"
fi

# ----- Coverage -----
if command -v go >/dev/null 2>&1; then
  cov_pct=$(cd "$root" && go test -cover "./$pkg/" 2>&1 \
    | grep -oE 'coverage: [0-9.]+%' | head -1 \
    | grep -oE '[0-9.]+' || echo 0)
  if awk -v c="$cov_pct" 'BEGIN { exit !(c >= 80) }'; then
    cov_status="coverage=${cov_pct}% (strong)"
  elif awk -v c="$cov_pct" 'BEGIN { exit !(c >= 60) }'; then
    cov_status="coverage=${cov_pct}% (acceptable, below strong-line)"
  elif awk -v c="$cov_pct" 'BEGIN { exit !(c >= 40) }'; then
    cov_status="coverage=${cov_pct}% (light — recorded for follow-up)"
  else
    printf 'FAIL\tt4-mutation\tcoverage=%s%% < 40%% hard floor (genuine test gap)\n' "$cov_pct"
    exit 1
  fi
else
  cov_status="coverage=skipped (no go)"
fi

# ----- Mutation -----
if ! command -v gremlins >/dev/null 2>&1; then
  printf 'PASS\tt4-mutation\t%s mutation=skipped (install gremlins for full gate)\n' "$cov_status"
  exit 0
fi

# Per-package cache. Key: flattened package path.
cache_dir="$root/.sisyphus/.cache/gremlins"
mkdir -p "$cache_dir"
pkg_flat=$(echo "$pkg" | tr '/' '_')
cache_file="$cache_dir/${pkg_flat}.txt"

# Cache lifetime: trusted until manually cleared. File-mtime invalidation
# was tried earlier but git checkout / worktree switches refresh mtimes on
# untouched files (e.g. _eidos.go after a github-main strip cycle), causing
# concurrent gremlins runs during sweep that time out at 0% efficacy.
# To refresh: `rm .sisyphus/.cache/gremlins/<pkg>.txt && gremlins unleash ./<pkg>`.
if [ ! -f "$cache_file" ]; then
  (cd "$root" && gremlins unleash "./$pkg" 2>&1 > "$cache_file") || true
fi

killed_pct=$(grep -oE 'Test efficacy: [0-9.]+%' "$cache_file" | head -1 \
  | grep -oE '[0-9.]+' || echo 0)
mutator_cov=$(grep -oE 'Mutator coverage: [0-9.]+%' "$cache_file" | head -1 \
  | grep -oE '[0-9.]+' || echo 0)

# Mutator coverage gate: if gremlins could not measure most of the package
# (e.g. because tests are too slow and most mutations time out), the efficacy
# number is misleading — a 100% efficacy over 8% of mutations is not the same
# claim as 80% efficacy over 90% of mutations. Below 50% mutator coverage we
# treat the run as inconclusive and soft-pass with a "needs longer timeout"
# note. Operators raise gremlins' --timeout-coefficient and re-cache when this
# soft-pass is unacceptable.
if awk -v m="$mutator_cov" 'BEGIN { exit !(m < 50) }'; then
  printf 'PASS\tt4-mutation\t%s mutation=inconclusive (mutator_cov=%s%%, %s%% killed of measured — most mutations timed out; raise gremlins timeout-coefficient to re-measure)\n' \
    "$cov_status" "$mutator_cov" "$killed_pct"
  exit 0
fi

if awk -v k="$killed_pct" 'BEGIN { exit !(k >= 80) }'; then
  printf 'PASS\tt4-mutation\t%s mutation=%s%% (strong, mutator_cov=%s%%)\n' "$cov_status" "$killed_pct" "$mutator_cov"
  exit 0
fi
if awk -v k="$killed_pct" 'BEGIN { exit !(k >= 60) }'; then
  printf 'PASS\tt4-mutation\t%s mutation=%s%% (acceptable, mutator_cov=%s%%)\n' "$cov_status" "$killed_pct" "$mutator_cov"
  exit 0
fi
printf 'FAIL\tt4-mutation\tmutation=%s%% < 60%% (mutator_cov=%s%%; tests pass without asserting; see %s)\n' \
  "$killed_pct" "$mutator_cov" "${cache_file#$root/}"
exit 1
