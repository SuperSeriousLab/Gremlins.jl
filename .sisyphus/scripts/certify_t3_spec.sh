#!/usr/bin/env bash
# Tier 3 (cheap-medium, ~30s): behavioural spec present.
#
# Requires a written behavioural specification for the chunk in
# .sisyphus/certified/<chunk_safe>.spec.md. The spec must contain
# a non-trivial "Behaviour" section that names what the code does
# in plain English. Without a spec, future certifications have no
# benchmark — what would "improvement" even mean?
#
# This tier doesn't auto-generate the spec — the agent must
# write it. The certify driver invokes the spec_request hook
# before running tier 3 so the next agent pass populates it.
#
# Output: PASS / FAIL <reason> on stdout.

set -uo pipefail

chunk="${1:?usage: certify_t3_spec.sh <file:path>}"
root="$(git rev-parse --show-toplevel)"
path="${chunk#file:}"
safe=$(echo "$path" | tr '/' '_')
spec="$root/.sisyphus/certified/${safe}.spec.md"

if [ ! -f "$spec" ]; then
  printf 'FAIL\tt3-spec\tno spec at %s\n' ".sisyphus/certified/${safe}.spec.md"
  exit 1
fi

# A spec must contain a non-empty Behaviour section with ≥ 80
# characters of actual prose (not just a heading).
body=$(awk '
  /^## Behaviour/ { inside=1; next }
  /^## / { inside=0 }
  inside { print }
' "$spec")
chars=$(echo -n "$body" | tr -d '[:space:]' | wc -c)
if [ "$chars" -lt 80 ]; then
  printf 'FAIL\tt3-spec\tBehaviour section under 80 chars (got %d)\n' "$chars"
  exit 1
fi

printf 'PASS\tt3-spec\tspec %d chars\n' "$chars"
exit 0
