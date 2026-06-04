#!/usr/bin/env bash
# Run one Sisyphus pass: pick the weakest (chunk, dim) from current
# ledger state, run the score script, append to the ledger, and report
# the result on stdout.
#
# This script does not modify code. It only measures and records. The
# loop iteration that calls it decides whether to act on the result.
#
# Usage:
#   .sisyphus/scripts/run_pass.sh                  # auto-pick
#   .sisyphus/scripts/run_pass.sh <chunk> <dim>    # explicit
#
# Dimensions currently implemented: file_size, vet, doc_accuracy.
# (correctness, coverage, allocation, readability — todo.)

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

mkdir -p .sisyphus/ledger

dim="${2:-}"
chunk="${1:-}"

if [ -z "$chunk" ] || [ -z "$dim" ]; then
  # Auto-pick: cheapest implementation that demonstrates rotation.
  # Pick the production .go file with the highest LOC that has not yet
  # been measured on the file_size dim. This biases toward the chunks
  # that the file-size discipline would flag first.
  chunk="file:$(find . -name '*.go' -not -name '*_test.go' \
    -not -path './.claude/*' -not -path './.git/*' \
    -print0 | xargs -0 wc -l | grep -v ' total$' | sort -rn | head -1 | awk '{print $2}' | sed 's|^\./||')"
  dim="file_size"
fi

script=".sisyphus/scripts/score_${dim}.sh"
if [ ! -x "$script" ]; then
  echo "no score script for dim=$dim ($script)" >&2
  exit 64
fi

result=$("$script" "$chunk")
ledger_id=$(printf "%s" "$chunk" | tr '/:#' '___')
ledger_file=".sisyphus/ledger/${ledger_id}.jsonl"
printf "%s\n" "$result" >> "$ledger_file"

echo "$result"
echo "appended to: $ledger_file" >&2
