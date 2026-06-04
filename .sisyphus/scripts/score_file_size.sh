#!/usr/bin/env bash
# Score one chunk on the file-size dimension.
#
# Score model: 1.0 when LOC <= the discipline ceiling (400, per
# CLAUDE.md). Linearly decreases to 0.0 at twice the ceiling. Past
# that, score stays at 0.0 — a 2000-line file is no worse for this
# purpose than a 1000-line file; both fail the dimension entirely and
# need splitting before any refinement matters.
#
# Input: file path (chunk id of kind file:...).
# Output: single JSON object on stdout, per .sisyphus/SCHEMA.md.

set -euo pipefail

chunk="${1:?usage: score_file_size.sh <file-path>}"

# Strip optional "file:" prefix from chunk id.
path="${chunk#file:}"

if [ ! -f "$path" ]; then
  printf '{"chunk":"%s","dim":"file_size","score":0.0,"raw":{"error":"missing"},"ts":"%s","commit":"%s"}\n' \
    "$chunk" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  exit 0
fi

ceiling=400
loc=$(wc -l < "$path")

if [ "$loc" -le "$ceiling" ]; then
  score="1.0"
elif [ "$loc" -ge $((ceiling * 2)) ]; then
  score="0.0"
else
  # Linear interpolation between ceiling and 2× ceiling.
  score=$(awk -v loc="$loc" -v ceil="$ceiling" 'BEGIN { printf "%.4f", 1 - (loc - ceil) / ceil }')
fi

printf '{"chunk":"%s","dim":"file_size","score":%s,"raw":{"loc":%d,"ceiling":%d},"ts":"%s","commit":"%s"}\n' \
  "$chunk" "$score" "$loc" "$ceiling" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
