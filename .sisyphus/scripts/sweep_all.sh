#!/usr/bin/env bash
# sweep_all.sh — visit every source chunk in the watched directories,
# run the certification cascade, record outcome.
#
# Replaces the per-batch invocation for end-of-campaign sweeps.

set -uo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1091
. "$root/.sisyphus/config.sh"
if command -v go >/dev/null 2>&1; then
  export PATH="$(go env GOPATH)/bin:$PATH"
fi
cov="$root/.sisyphus/coverage.jsonl"

chunks=$(sisyphus_list_chunks "$root")

total=0
already_cert=0
newly_cert=0
failed=0

while IFS= read -r path; do
  [ -z "$path" ] && continue
  total=$((total+1))
  chunk="file:$path"
  safe=$(echo "$path" | tr '/' '_')

  if [ -f "$root/.sisyphus/certified/${safe}.card.md" ]; then
    already_cert=$((already_cert+1))
    continue
  fi

  "$root/.sisyphus/scripts/gen_spec.sh" "$chunk" >/dev/null 2>&1 || true
  "$root/.sisyphus/scripts/gen_adversarial.sh" "$chunk" >/dev/null 2>&1 || true

  out=$("$root/.sisyphus/scripts/certify_chunk.sh" "$chunk" 2>&1)
  last=$(echo "$out" | tail -1)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if echo "$last" | grep -q '^CERTIFIED'; then
    printf '%-50s ✓ certified\n' "$path"
    newly_cert=$((newly_cert+1))
    printf '{"chunk":"file:%s","status":"certified","reason":"cascade-passed","ts":"%s"}\n' \
      "$path" "$ts" >> "$cov"
  else
    stage=$(echo "$out" | grep -E 'STOPPED at' | head -1 | sed -E 's/STOPPED at ([^ ]+).*/\1/')
    printf '%-50s ✗ %s\n' "$path" "${stage:-unknown}"
    failed=$((failed+1))
  fi
done <<< "$chunks"

echo
echo "=== sweep complete ==="
echo "total chunks:   $total"
echo "already cert:   $already_cert"
echo "newly certified: $newly_cert"
echo "failed:         $failed"
echo "total certified: $((already_cert + newly_cert))"
