# config.sh — sourced by sweep_all.sh, pick_next_chunk.sh, build_dashboard.sh.
#
# Edit this file when scaffolding the protocol into a new project. The defaults
# assume a Go project with packages at the repo root; adjust for monorepos or
# non-Go languages.

# Space-separated list of source directories to walk. Paths are relative to
# the repo root. Each .go file (or matching pattern) under -maxdepth 1 of
# these directories is a chunk.
SISYPHUS_PACKAGES="${SISYPHUS_PACKAGES:-src test}"

# Glob pattern for source files. Defaults to Go non-test files.
# Examples:
#   Rust:       SISYPHUS_PATTERN="*.rs"
#   Python:     SISYPHUS_PATTERN="*.py"  (and exclude __init__.py)
#   TypeScript: SISYPHUS_PATTERN="*.ts"  (and exclude *.test.ts via SISYPHUS_EXCLUDE)
SISYPHUS_PATTERN="${SISYPHUS_PATTERN:-*.jl}"

# Glob pattern for files to exclude. Defaults to Go test files.
SISYPHUS_EXCLUDE="${SISYPHUS_EXCLUDE:-*_test.jl}"

# Done-ceiling for the coverage-first scheduler. Visited chunks whose worst
# dimension score is at or above this value are considered "good enough" and
# the picker stops returning them. Lower this for stricter cycles.
SISYPHUS_DONE_CEILING="${SISYPHUS_DONE_CEILING:-0.80}"

# Helper used by the three path-walking scripts. Echoes a single sorted list
# of chunk paths (relative to the repo root) one per line.
sisyphus_list_chunks() {
  local root="${1:?sisyphus_list_chunks needs <root>}"
  local args=()
  local pkg
  for pkg in $SISYPHUS_PACKAGES; do
    if [ -d "$root/$pkg" ]; then
      args+=("$root/$pkg")
    fi
  done
  if [ ${#args[@]} -eq 0 ]; then
    return
  fi
  find "${args[@]}" -maxdepth 1 -name "$SISYPHUS_PATTERN" -not -name "$SISYPHUS_EXCLUDE" 2>/dev/null \
    | sed "s|^$root/||" | sort
}
