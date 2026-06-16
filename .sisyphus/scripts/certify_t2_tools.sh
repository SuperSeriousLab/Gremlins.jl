#!/usr/bin/env bash
# Tier 2 (cheap, ~seconds): external tool agreement.
#
# Runs go vet, gocyclo, ineffassign, staticcheck. Each tool was
# written for different reasons; their agreement is information
# that's hard to game from inside the protocol.
#
# Tools that aren't installed are skipped (logged but not failed).
# This keeps the gate runnable on developer machines without a
# full toolchain.
#
# Output: PASS / FAIL <reason> on stdout. Exit 0 on PASS, 1 on FAIL.

set -uo pipefail

# Pick up Go-installed binaries (gocyclo, staticcheck, ineffassign)
# from $GOPATH/bin since /usr/local/go/bin only has the Go tools.
if command -v go >/dev/null 2>&1; then
  export PATH="$(go env GOPATH)/bin:$PATH"
fi

chunk="${1:?usage: certify_t2_tools.sh <file:path>}"
root="$(git rev-parse --show-toplevel)"
path="${chunk#file:}"
abs="$root/$path"
pkg_dir="$(dirname "$abs")"

failures=()
ran=0

# Language guard: every tool in this tier (go vet / gocyclo / ineffassign /
# staticcheck) is Go-only. On a non-Go chunk `go vet ./dir/...` errors ("no Go
# files") and would spuriously FAIL the tier, gating out T3/T4. Soft-pass non-Go
# chunks — the language-agnostic tiers (size, spec, mutation, adversarial) carry
# the certification. (Julia static linting is out of scope for this harness.)
case "$path" in
  *.go) ;;
  *) printf 'PASS\tt2-tools\ttools=skipped (non-Go chunk: %s)\n' "$path"; exit 0;;
esac

# go vet — always present with the Go toolchain.
if command -v go >/dev/null 2>&1; then
  ran=$((ran+1))
  if ! (cd "$root" && go vet "./$(dirname "$path")/..." 2>&1) >/tmp/vet.out; then
    failures+=("go-vet: $(head -1 /tmp/vet.out)")
  fi
fi

# gocyclo — per-function cyclomatic complexity. Threshold 20 is
# the higher-tier line — above this signals genuinely complex
# functions (multi-branch switches, large state machines) that
# deserve attention. 16-19 is acceptable for handler bodies and
# large switch statements where the cyclomatic count reflects
# real domain branches, not code smell.
if command -v gocyclo >/dev/null 2>&1; then
  ran=$((ran+1))
  hits=$(gocyclo -over 20 "$abs" 2>/dev/null | head -3)
  if [ -n "$hits" ]; then
    failures+=("gocyclo: $(echo "$hits" | head -1)")
  fi
fi

# ineffassign — flags ineffective assignments.
if command -v ineffassign >/dev/null 2>&1; then
  ran=$((ran+1))
  if ineffassign "$abs" 2>&1 | grep -q .; then
    failures+=("ineffassign: hits in chunk")
  fi
fi

# staticcheck — broader semantic checker.
if command -v staticcheck >/dev/null 2>&1; then
  ran=$((ran+1))
  hits=$(cd "$root" && staticcheck "./$(dirname "$path")/..." 2>&1 | grep "$path" | head -3)
  if [ -n "$hits" ]; then
    failures+=("staticcheck: $(echo "$hits" | head -1)")
  fi
fi

if [ ${#failures[@]} -eq 0 ]; then
  printf 'PASS\tt2-tools\t%d tools clean\n' "$ran"
  exit 0
fi

printf 'FAIL\tt2-tools\t%s\n' "${failures[0]}"
exit 1
