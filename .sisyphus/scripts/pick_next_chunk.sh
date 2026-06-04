#!/usr/bin/env bash
# pick_next_chunk.sh — select the next chunk for the Sisyphus loop.
#
# Two-phase scheduler:
#
#   Phase 1 — Coverage:
#     Prefer UNVISITED chunks. Walk every Go source file in
#     debate/ + api/ + store/ + llm/ + auth/, skip files marked
#     done in .sisyphus/coverage.jsonl, pick the worst-scoring
#     remaining one.
#
#   Phase 2 — Done:
#     When every chunk has a "done" entry, print "NO_WORK" so the
#     loop can stop requesting passes.
#
# A chunk is marked done when any of:
#   - all 3 dim scores ≥ 0.80   (status: done-ceiling)
#   - last-pass delta < 0.05    (status: done-diminishing)
#   - visit count ≥ 3            (status: done-budget)
#   - agent judgment says skip  (status: lost-cause)
#
# Output format on stdout, single line:
#   <status>\t<chunk>\t<reason>
#
# Statuses:
#   PICK    — next chunk to work on (reason: "unvisited" | "worst-by-score")
#   NO_WORK — phase 2 reached (reason: "all chunks marked done")

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1091
. "$root/.sisyphus/config.sh"
cov="$root/.sisyphus/coverage.jsonl"
mkdir -p "$root/.sisyphus"
[ -f "$cov" ] || : > "$cov"

# Build the set of all source chunks via config helper.
all_chunks=$(sisyphus_list_chunks "$root")

# Build the set of done chunks from coverage.jsonl.
done_chunks=$(grep -E '"status":"done' "$cov" 2>/dev/null \
  | sed -E 's/.*"chunk":"file:([^"]+)".*/\1/' \
  | sort -u || true)

# Phase 1: any unvisited chunk?
visited=$(awk -F'"' '
  /"chunk":/ {
    for (i=1; i<=NF; i++) {
      if ($i == "chunk") {
        sub(/^file:/, "", $(i+2))
        print $(i+2)
      }
    }
  }
' "$cov" 2>/dev/null | sort -u || true)

unvisited=$(comm -23 <(echo "$all_chunks") <(echo "$visited"))

if [ -n "$unvisited" ]; then
  # Among unvisited, pick the one with the worst current complexity score.
  worst_chunk=""
  worst_score="2.0"
  while IFS= read -r chunk; do
    [ -z "$chunk" ] && continue
    result=$("$root/.sisyphus/scripts/score_complexity.sh" "file:$chunk" 2>/dev/null || true)
    score=$(echo "$result" | grep -oE '"score":[0-9.]+' | head -1 | cut -d: -f2)
    [ -z "$score" ] && score="0.0"
    if awk -v a="$score" -v b="$worst_score" 'BEGIN { exit !(a < b) }'; then
      worst_score="$score"
      worst_chunk="$chunk"
    fi
  done <<< "$unvisited"
  if [ -n "$worst_chunk" ]; then
    printf 'PICK\tfile:%s\tunvisited-worst-score=%s\n' "$worst_chunk" "$worst_score"
    exit 0
  fi
fi

# Phase 2: no unvisited chunks remain.
# If any chunks are visited-but-not-done, pick the worst.
visited_not_done=$(comm -23 <(echo "$visited") <(echo "$done_chunks"))

if [ -n "$visited_not_done" ]; then
  worst_chunk=""
  worst_score="2.0"
  while IFS= read -r chunk; do
    [ -z "$chunk" ] && continue
    result=$("$root/.sisyphus/scripts/score_complexity.sh" "file:$chunk" 2>/dev/null || true)
    score=$(echo "$result" | grep -oE '"score":[0-9.]+' | head -1 | cut -d: -f2)
    [ -z "$score" ] && score="0.0"
    if awk -v a="$score" -v b="$worst_score" 'BEGIN { exit !(a < b) }'; then
      worst_score="$score"
      worst_chunk="$chunk"
    fi
  done <<< "$visited_not_done"
  if [ -n "$worst_chunk" ]; then
    printf 'PICK\tfile:%s\tvisited-not-done-worst=%s\n' "$worst_chunk" "$worst_score"
    exit 0
  fi
fi

# Every chunk has at least one done entry.
printf 'NO_WORK\t-\tall-chunks-marked-done\n'
