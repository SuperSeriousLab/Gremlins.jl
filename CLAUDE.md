# CLAUDE.md — Gremlins

## Purpose

Julia mutation-testing package: JuliaSyntax-based AST mutation operators,
coverage-guided test selection, warm-worker execution, survival reports.
Fills the dead-Vimes community gap AND the Sisyphus T4 (mutation tier) row
for Julia projects (JUI, Igor, WIQ, MEROM). OSS-destined (General registry,
JuliaTesting org pitch at M3). Design: /home/js/eidos/docs/design-julia-mutation-testing.md

## Build & Test

```bash
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -e 'using Pkg; Pkg.test()'
# self-mutate smoke (M0 acceptance):
julia --project -e 'using Gremlins; Gremlins.discover("src") .|> println'
```

## Key Files

| File | Purpose |
|------|---------|
| `src/operators.jl` | Mutation operators (matcher, replacement) over JuliaSyntax trees |
| `src/discover.jl` | Walk package source, enumerate mutation sites (file, byte-range, op-id) |
| `src/patch.jl` | Apply/revert one mutation via byte-range source splice |
| `docs/INVARIANTS.md` | Never-violate invariants (see EDD) |

## Conventions

- Julia ≥ 1.10. JuliaSyntax for ALL parsing — never regex over source.
- Mutations splice byte ranges in original text; never pretty-print untouched code.
- Mutant id = stable hash of (relpath, byte-range, operator-id) — deterministic enumeration, sorted.
- Every operator ships with a falsifiability test: planted killable mutant must be classified killed; planted equivalent mutant documented.
- Error handling: throw typed errors (`MutationError`); no `error("...")` strings in library paths.

## What NOT to Do

- No `eval` of mutated code into Main during discovery (M0 is static only).
- No mtime-based caching (Sisyphus lesson — git checkout refreshes mtimes).
- Don't claim "verified" without pasted runnable output (campaign rule 2026-06-04).
- No mutation of `test/` files — source dirs only.
