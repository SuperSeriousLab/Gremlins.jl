#!/usr/bin/env bash
# Tier 5 (expensive, ~5-10 min): adversarial proposal round.
#
# Requires an adversarial-review artifact at
# .sisyphus/certified/<chunk_safe>.adversarial.md. The artifact
# must contain ≥ 3 numbered proposals, each with a REJECTED or
# ACCEPTED verdict. ACCEPTED proposals block certification —
# they describe known improvements not yet made.
#
# The adversarial pass is agent-driven: a separate agent (or
# the same agent with a "find improvements" prompt) reviews the
# chunk and proposes refactors. Each proposal is evaluated against
# the metric + tool gates; REJECTED proposals are recorded so
# future readers can see what was considered.
#
# Output: PASS / FAIL <reason> on stdout.

set -uo pipefail

chunk="${1:?usage: certify_t5_adversarial.sh <file:path>}"
root="$(git rev-parse --show-toplevel)"
path="${chunk#file:}"
safe=$(echo "$path" | tr '/' '_')
artifact="$root/.sisyphus/certified/${safe}.adversarial.md"

if [ ! -f "$artifact" ]; then
  printf 'FAIL\tt5-adversarial\tno artifact at %s\n' ".sisyphus/certified/${safe}.adversarial.md"
  exit 1
fi

proposals=$(grep -cE '^[0-9]+\.' "$artifact" 2>/dev/null | tr -d ' \n')
[ -z "$proposals" ] && proposals=0
accepted=$(grep -cE 'ACCEPTED' "$artifact" 2>/dev/null | tr -d ' \n')
[ -z "$accepted" ] && accepted=0
rejected=$(grep -cE 'REJECTED' "$artifact" 2>/dev/null | tr -d ' \n')
[ -z "$rejected" ] && rejected=0

if [ "$proposals" -lt 3 ]; then
  printf 'FAIL\tt5-adversarial\tonly %d proposals (need ≥3)\n' "$proposals"
  exit 1
fi
if [ "$accepted" -gt 0 ]; then
  printf 'FAIL\tt5-adversarial\t%d ACCEPTED proposals — apply them first\n' "$accepted"
  exit 1
fi
if [ "$rejected" -lt 3 ]; then
  printf 'FAIL\tt5-adversarial\tonly %d REJECTED verdicts (need ≥3)\n' "$rejected"
  exit 1
fi

printf 'PASS\tt5-adversarial\t%d proposals, %d REJECTED, 0 ACCEPTED\n' \
  "$proposals" "$rejected"
exit 0
