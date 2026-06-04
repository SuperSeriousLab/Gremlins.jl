#!/usr/bin/env bash
# bootstrap_coverage.sh — seed coverage.jsonl from the existing
# ledger entries so already-polished chunks aren't revisited.
#
# Walks each .sisyphus/ledger/file_*.jsonl file, reads the most
# recent score per dimension, and emits a coverage entry:
#
#   - status=done-ceiling when all 3 dims ≥ 0.80
#   - status=visited     otherwise (the chunk has been touched
#                                   but doesn't meet the ceiling)
#
# Run once after introducing the coverage scheduler. Idempotent —
# re-running overwrites the file with current state.

set -uo pipefail

root="$(git rev-parse --show-toplevel)"
ledger_dir="$root/.sisyphus/ledger"
cov="$root/.sisyphus/coverage.jsonl"

mkdir -p "$(dirname "$cov")"
: > "$cov"

shopt -s nullglob
for f in "$ledger_dir"/file_*.jsonl; do
  # Convert the ledger filename back to the chunk path.
  # file_debate_socrates_phases.go.jsonl → debate/socrates_phases.go
  base=$(basename "$f" .jsonl)
  chunk_path=$(echo "${base#file_}" | sed 's|_|/|')
  chunk="file:$chunk_path"

  # Read the most recent score for each dim from this ledger.
  fs=$(grep -oE '"dim":"file_size","score":[0-9.]+' "$f" | tail -1 | grep -oE '[0-9.]+$' || echo 0)
  cx=$(grep -oE '"dim":"complexity","score":[0-9.]+' "$f" | tail -1 | grep -oE '[0-9.]+$' || echo 0)
  dc=$(grep -oE '"dim":"doc_accuracy","score":[0-9.]+' "$f" | tail -1 | grep -oE '[0-9.]+$' || echo 0)
  visits=$(grep -c '"dim":"complexity"' "$f" 2>/dev/null | tr -d ' \n')
  [ -z "$visits" ] && visits=0

  # Decide status.
  if awk -v a="$fs" -v b="$cx" -v c="$dc" 'BEGIN { exit !(a >= 0.80 && b >= 0.80 && c >= 0.80) }'; then
    status="done-ceiling"
    reason="all-dims-at-or-above-0.80"
  else
    status="visited"
    reason="not-at-ceiling"
  fi

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"chunk":"%s","status":"%s","reason":"%s","file_size":%s,"complexity":%s,"doc_accuracy":%s,"visit_count":%d,"ts":"%s"}\n' \
    "$chunk" "$status" "$reason" "$fs" "$cx" "$dc" "$visits" "$ts" >> "$cov"
done

count=$(wc -l < "$cov")
done_count=$(grep -c '"status":"done-' "$cov" || echo 0)
visited_count=$(grep -c '"status":"visited"' "$cov" || echo 0)
echo "bootstrap: $count chunks seeded ($done_count done, $visited_count visited)"
