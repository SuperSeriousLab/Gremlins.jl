#!/usr/bin/env bash
# certify_chunk.sh — cascading certification driver.
#
# Runs the 5 certification tiers in order. Fail-fast: a tier
# that returns non-zero stops the cascade, so cheap checks
# screen out chunks that aren't ready before expensive ones run.
# Same shape as SLR's circuit breaker — cascading failure mode
# but on the success path.
#
#   T1 metrics       (~seconds, internal score floor ≥ 0.85)
#   T2 tools         (~seconds, go vet + gocyclo + staticcheck + ineffassign)
#   T3 spec          (~30s, behavioural spec present)
#   T4 mutation      (~minutes, coverage ≥ 80% + mutation killed ≥ 70%)
#   T5 adversarial   (~5-10 min, agent-reviewed proposals all REJECTED)
#
# On all-pass: writes the certification card to
#   .sisyphus/certified/<chunk_safe>.card.md
#
# On any-fail: writes a progress entry to
#   .sisyphus/certified/<chunk_safe>.progress.md
# noting which tier failed and what artifact (if any) the next
# agent pass should populate.

set -uo pipefail

chunk="${1:?usage: certify_chunk.sh <file:path>}"
root="$(git rev-parse --show-toplevel)"
path="${chunk#file:}"
safe=$(echo "$path" | tr '/' '_')
mkdir -p "$root/.sisyphus/certified"

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)

tiers=(
  certify_t1_metrics
  certify_t2_tools
  certify_t3_spec
  certify_t4_mutation
  certify_t5_adversarial
)

results=()
failed_tier=""
fail_reason=""

for tier in "${tiers[@]}"; do
  out=$("$root/.sisyphus/scripts/${tier}.sh" "$chunk" 2>&1)
  ec=$?
  results+=("$out")
  if [ "$ec" -ne 0 ]; then
    failed_tier="$tier"
    fail_reason="$out"
    break
  fi
done

printf '=== %s @ %s ===\n' "$chunk" "$commit"
printf '%s\n' "${results[@]}"

if [ -n "$failed_tier" ]; then
  progress="$root/.sisyphus/certified/${safe}.progress.md"
  {
    printf '# Certification progress: %s\n\n' "$chunk"
    printf '**Last attempt:** %s @ %s\n\n' "$ts" "$commit"
    printf '**Stopped at:** %s\n\n' "$failed_tier"
    printf '**Reason:** %s\n\n' "$fail_reason"
    printf '## Tier results so far\n\n'
    for r in "${results[@]}"; do
      printf -- '- %s\n' "$r"
    done
  } > "$progress"
  printf 'STOPPED at %s — see %s\n' "$failed_tier" "${progress#$root/}"
  exit 1
fi

# All tiers passed — write the certification card.
card="$root/.sisyphus/certified/${safe}.card.md"
spec_path=".sisyphus/certified/${safe}.spec.md"
adv_path=".sisyphus/certified/${safe}.adversarial.md"
{
  printf '# Certified: %s\n\n' "$chunk"
  printf '**Commit:** `%s`\n' "$commit"
  printf '**Certified at:** %s\n\n' "$ts"
  printf '## Signal agreement\n\n'
  for r in "${results[@]}"; do
    printf -- '- %s\n' "$r"
  done
  printf '\n## Behavioural spec\n\n'
  printf 'See `%s`.\n\n' "$spec_path"
  printf '## Adversarial review\n\n'
  printf 'See `%s` — proposals considered and rejected.\n\n' "$adv_path"
  printf '## Expiry\n\n'
  printf 'Any change to `%s` re-opens certification. To re-certify, append a counter-proposal\n' "$path"
  printf 'to the adversarial doc and run `certify_chunk.sh %s` again.\n' "$chunk"
} > "$card"
printf 'CERTIFIED — see %s\n' "${card#$root/}"
exit 0
