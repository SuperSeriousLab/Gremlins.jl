#!/usr/bin/env bash
# Score one chunk on the vet-clean dimension.
#
# Score model: 1.0 if `go vet` and `go vet -tags eidos` both come back
# clean for the package containing the chunk; 0.0 if either reports
# anything. Binary by design — vet warnings are rare enough that a
# fractional score would be over-engineered.
#
# Input: file path inside a Go package, OR a `pkg:` chunk id.
# Output: single JSON object on stdout.

set -euo pipefail

chunk="${1:?usage: score_vet.sh <chunk-id>}"

case "$chunk" in
  pkg:*)
    pkg="${chunk#pkg:}"
    ;;
  file:*)
    path="${chunk#file:}"
    pkg="./$(dirname "$path")"
    ;;
  *)
    if [ -f "$chunk" ]; then
      pkg="./$(dirname "$chunk")"
    else
      pkg="$chunk"
    fi
    ;;
esac

raw_default=$(go vet "$pkg" 2>&1 || true)
raw_eidos=$(go vet -tags eidos "$pkg" 2>&1 || true)

# `go vet` writes diagnostics to stderr; a clean run yields zero bytes
# of output. Anything non-empty (after the conventional comment header
# packages sometimes print) means it found something to report.
default_clean=1
eidos_clean=1
[ -n "$(printf "%s" "$raw_default" | sed '/^#/d')" ] && default_clean=0
[ -n "$(printf "%s" "$raw_eidos" | sed '/^#/d')" ] && eidos_clean=0

if [ "$default_clean" = 1 ] && [ "$eidos_clean" = 1 ]; then
  score="1.0"
else
  score="0.0"
fi

# Escape raw output as JSON strings; here we sanitise to one line per tag.
default_escaped=$(printf "%s" "$raw_default" | sed '/^$/d' | head -c 200 | tr '\n' ' ' | sed 's/"/\\"/g')
eidos_escaped=$(printf "%s" "$raw_eidos" | sed '/^$/d' | head -c 200 | tr '\n' ' ' | sed 's/"/\\"/g')

printf '{"chunk":"%s","dim":"vet","score":%s,"raw":{"default_clean":%s,"eidos_clean":%s,"default_msg":"%s","eidos_msg":"%s"},"ts":"%s","commit":"%s"}\n' \
  "$chunk" "$score" "$default_clean" "$eidos_clean" "$default_escaped" "$eidos_escaped" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
