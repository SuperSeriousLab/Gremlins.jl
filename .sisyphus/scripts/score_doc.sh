#!/usr/bin/env bash
# Score one chunk on the doc-accuracy dimension.
#
# Score model: ratio of exported Go symbols that have a doc comment
# immediately preceding their declaration to total exported symbols in
# the chunk. Exported = starts with an upper-case letter. Doc comment
# = the line directly above the declaration is `//`-style or `/*…*/`
# block.
#
# This is the strict version of "godoc presence" — it does not check
# comment quality, only that one is there. A future dim could grade
# the content; for now presence is the floor.
#
# Input: file path (chunk id of kind file:...).
# Output: single JSON object on stdout.

set -euo pipefail

chunk="${1:?usage: score_doc.sh <file-path>}"
path="${chunk#file:}"

if [ ! -f "$path" ]; then
  printf '{"chunk":"%s","dim":"doc_accuracy","score":0.0,"raw":{"error":"missing"},"ts":"%s","commit":"%s"}\n' \
    "$chunk" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  exit 0
fi

# awk pass:
#   - track the previous non-empty source line
#   - when we see an exported func/type/const/var declaration, check
#     whether the previous line was a //-style doc comment (block
#     comments are rare in this repo and we accept anything that ends
#     with */ on the immediately preceding line)
exported=0
documented=0
read -r exported documented < <(awk '
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*\/\// { last_line = $0; doc_line = NR; next }
  /\*\/[[:space:]]*$/ { last_line = $0; doc_line = NR; next }
  /^func [A-Z]|^type [A-Z]|^const [A-Z]|^var [A-Z]/ {
    exported++
    if (doc_line == NR - 1) documented++
    last_line = $0; doc_line = 0; next
  }
  { last_line = $0; doc_line = 0 }
  END { printf "%d %d\n", exported, documented }
' "$path")

if [ "$exported" -eq 0 ]; then
  score="1.0"   # no exported symbols → vacuously documented
else
  score=$(awk -v d="$documented" -v e="$exported" 'BEGIN { printf "%.4f", d/e }')
fi

printf '{"chunk":"%s","dim":"doc_accuracy","score":%s,"raw":{"exported":%d,"documented":%d},"ts":"%s","commit":"%s"}\n' \
  "$chunk" "$score" "$exported" "$documented" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
