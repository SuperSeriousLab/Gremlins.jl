#!/usr/bin/env bash
# batch_certify.sh — run the certification cascade against every
# chunk in a given list. For each chunk:
#   1. gen_spec.sh   (no-op if hand-written spec exists)
#   2. gen_adversarial.sh (no-op if hand-written adv exists)
#   3. certify_chunk.sh — run the 5-tier cascade
#   4. Record outcome in coverage.jsonl
#
# Usage:
#   batch_certify.sh                         # all done-ceiling chunks
#   batch_certify.sh debate/X.go api/Y.go     # specific chunks
#
# Output: progress per chunk on stdout.

set -uo pipefail

root="$(git rev-parse --show-toplevel)"
export PATH="$(go env GOPATH)/bin:$PATH"

cov="$root/.sisyphus/coverage.jsonl"

# Build the chunk list.
chunks=()
if [ "$#" -eq 0 ]; then
  # All done-ceiling chunks not yet certified.
  while IFS= read -r line; do
    c=$(echo "$line" | grep -oE '"chunk":"file:[^"]+"' | sed -E 's/.*file:([^"]+)"/\1/')
    s=$(echo "$line" | grep -oE '"status":"[^"]+"' | head -1 | cut -d'"' -f4)
    [ "$s" = "done-ceiling" ] || continue
    safe=$(echo "$c" | tr '/' '_')
    [ -f "$root/.sisyphus/certified/${safe}.card.md" ] && continue
    chunks+=("$c")
  done < "$cov"
else
  for c in "$@"; do
    chunks+=("$c")
  done
fi

if [ ${#chunks[@]} -eq 0 ]; then
  echo "no chunks to certify"
  exit 0
fi

certified=0
failed=0

for path in "${chunks[@]}"; do
  chunk="file:$path"
  echo
  echo "--- $chunk ---"

  "$root/.sisyphus/scripts/gen_spec.sh" "$chunk" >/dev/null 2>&1 || true
  "$root/.sisyphus/scripts/gen_adversarial.sh" "$chunk" >/dev/null 2>&1 || true

  out=$("$root/.sisyphus/scripts/certify_chunk.sh" "$chunk" 2>&1)
  last=$(echo "$out" | tail -1)
  echo "$last"

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if echo "$last" | grep -q '^CERTIFIED'; then
    certified=$((certified+1))
    printf '{"chunk":"file:%s","status":"certified","reason":"cascade-passed","ts":"%s"}\n' \
      "$path" "$ts" >> "$cov"
  else
    failed=$((failed+1))
  fi
done

echo
echo "batch complete: ${certified} certified, ${failed} failed"
