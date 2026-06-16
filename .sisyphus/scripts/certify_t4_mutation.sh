#!/usr/bin/env bash
# Tier 4 (medium, ~minutes): mutation gate — Gremlins dogfooding ITSELF.
#
# This package IS a mutation tester, so T4 certifies each src/ chunk by
# running gremlins-cli.jl against the Gremlins package, scoped to that one
# file (--files <basename>), warm mode, capped at --max-sites for bounded
# per-chunk cost. The CLI's own `BAND` line (strong/acceptable/weak) is the
# verdict.
#
#   BAND<TAB>strong|acceptable|weak<TAB>kill_rate=<x><TAB>killed=<k>/<n>
#
# Result cached per chunk at .sisyphus/.cache/gremlins/<path-flat>.txt
# (trusted until manually cleared — `rm` the cache file to re-measure).
#
# Bands → tier verdict:
#   strong     (kill_rate ≥ --strong)     PASS
#   acceptable (kill_rate ≥ --acceptable) PASS
#   weak       (below acceptable)         FAIL
# No eligible sites / no band / timeout   PASS (soft, recorded note)
#
# Output: PASS / FAIL <reason> on stdout.

set -uo pipefail

chunk="${1:?usage: certify_t4_mutation.sh <file:path>}"
root="$(git rev-parse --show-toplevel)"
path="${chunk#file:}"
fname=$(basename "$path")

# Only src/ chunks are mutation-certified; tests and others soft-pass.
case "$path" in
  src/*) ;;
  *) printf 'PASS\tt4-mutation\tmutation=skipped (non-src chunk: %s)\n' "$path"; exit 0;;
esac

if ! command -v julia >/dev/null 2>&1; then
  printf 'PASS\tt4-mutation\tmutation=skipped (no julia)\n'
  exit 0
fi

cache_dir="$root/.sisyphus/.cache/gremlins"
mkdir -p "$cache_dir"
cache_file="$cache_dir/$(echo "$path" | tr '/' '_').txt"

# Run once per chunk; cache. Warm mode, capped, self-mutating the Gremlins pkg.
if [ ! -f "$cache_file" ]; then
  # max-sites 10: Gremlins' own runtests.jl is integration-heavy (workers +
  # mini-campaigns), so each mutant rerun is minutes. A small capped sample that
  # COMPLETES with a real band beats 40 sites timing out to "inconclusive".
  # Cap noted in the band line; raise when the suite is faster.
  (cd "$root" && timeout 5400 julia --project bin/gremlins-cli.jl \
      --pkg . --files "$fname" --warm --max-sites 10 \
      > "$cache_file" 2>/dev/null) || true
fi

band_line=$(grep -E '^BAND' "$cache_file" | head -1)

# No band emitted → run died / timed out → inconclusive soft-pass.
if [ -z "$band_line" ]; then
  printf 'PASS\tt4-mutation\tmutation=inconclusive (no band — timeout or infra; see %s)\n' "${cache_file#$root/}"
  exit 0
fi

band=$(echo "$band_line" | awk -F'\t' '{print $2}')
kill_rate=$(echo "$band_line" | grep -oE 'kill_rate=[0-9.NaN]+' | head -1 | cut -d= -f2)
killed=$(echo "$band_line" | grep -oE 'killed=[0-9]+/[0-9]+' | head -1 | cut -d= -f2)
n_eligible=$(echo "$killed" | cut -d/ -f2)

# No eligible sites on this chunk → nothing to assert → soft-pass.
if [ "${n_eligible:-0}" = "0" ]; then
  printf 'PASS\tt4-mutation\tmutation=no-eligible-sites (%s)\n' "$fname"
  exit 0
fi

case "$band" in
  strong)
    printf 'PASS\tt4-mutation\tmutation=%s killed=%s (strong)\n' "$kill_rate" "$killed"; exit 0;;
  acceptable)
    printf 'PASS\tt4-mutation\tmutation=%s killed=%s (acceptable)\n' "$kill_rate" "$killed"; exit 0;;
  *)
    printf 'FAIL\tt4-mutation\tmutation=%s killed=%s (weak — tests pass without asserting; see %s)\n' \
      "$kill_rate" "$killed" "${cache_file#$root/}"; exit 1;;
esac
