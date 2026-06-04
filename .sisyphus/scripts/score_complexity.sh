#!/usr/bin/env bash
# Score one chunk on the complexity dimension.
#
# Walks the Go AST via score_complexity.go (built once into
# .sisyphus/bin/score_complexity) to extract per-function max
# block-nesting depth and body LOC. The Go tool descends only
# control-flow constructs (If/For/Range/Switch/Select/CaseClause),
# so composite-literal braces, struct literals, and nested
# function-literal bodies never inflate the depth count — the
# documented failure mode of the previous awk brace-counter
# (see PASS_LOG.md passes 29-47).
#
# Score model (unchanged from the awk era):
#
#   per-function = 1.0 if loc <= 60 AND depth <= 3
#                  linear decay to 0 at loc=300 or depth=8
#   chunk        = min(per-function)
#
# Rationale: a single 300-line function or one 8-deep nested
# block drags the chunk's score to 0. Refactoring the worst
# function is the action the metric points at — same pattern
# as gocyclo's --over flag.
#
# Input: file path (kind file:...).
# Output: single JSON object on stdout per .sisyphus/SCHEMA.md.

set -euo pipefail

chunk="${1:?usage: score_complexity.sh <file-path>}"
path="${chunk#file:}"
root="$(git rev-parse --show-toplevel)"

if [ ! -f "$path" ]; then
  printf '{"chunk":"%s","dim":"complexity","score":0.0,"raw":{"error":"missing"},"ts":"%s","commit":"%s"}\n' \
    "$chunk" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  exit 0
fi

bin="$root/.sisyphus/bin/score_complexity"
src="$root/.sisyphus/scripts/score_complexity.go"

# Lazy-build: rebuild when binary is missing or older than the .go source.
if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
  mkdir -p "$root/.sisyphus/bin"
  (cd "$root/.sisyphus/scripts" && go build -o "$bin" score_complexity.go) >/dev/null
fi

read -r max_loc max_depth worst_name worst_line func_count < <("$bin" "$path")

score=$(awk -v loc="$max_loc" -v depth="$max_depth" 'BEGIN {
  sc_loc   = (loc   <= 60) ? 1.0 : ((loc   >= 300) ? 0.0 : 1.0 - (loc   - 60) / 240.0)
  sc_depth = (depth <=  3) ? 1.0 : ((depth >=   8) ? 0.0 : 1.0 - (depth -  3) /   5.0)
  printf "%.4f", (sc_loc < sc_depth) ? sc_loc : sc_depth
}')

printf '{"chunk":"%s","dim":"complexity","score":%s,"raw":{"max_loc":%d,"max_depth":%d,"worst_func":"%s","worst_line":%d,"func_count":%d},"ts":"%s","commit":"%s"}\n' \
  "$chunk" "$score" "$max_loc" "$max_depth" "$worst_name" "$worst_line" "$func_count" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
