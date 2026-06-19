# CLAUDE.md — Gremlins

## Purpose

Julia mutation-testing package: JuliaSyntax-based AST mutation operators,
coverage-guided test selection, warm-worker execution, survival reports.
Fills the dead-Vimes community gap AND the Sisyphus T4 (mutation tier) row
for Julia projects (JUI, Igor, WIQ, MEROM). OSS-destined (General registry,
JuliaTesting org pitch at M3). Design: docs/DESIGN.md (moved from eidos docs/ 2026-06-05)

## Build & Test

```bash
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -e 'using Pkg; Pkg.test()'
# adaptive subset (DEV SPEED ONLY — never a release gate; CI runs full):
# pass filename fragments to run only matching test files (M0 always runs).
julia --project --check-bounds=no test/runtests.jl schema blame
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

## Workflow

- **Develop on Forgejo.** Feature work: branch, implement, merge to `master` locally
  (no Forgejo PR — solo repo, the PR ritual is theatre), push `master` to the
  `forgejo` remote as the canonical dev mirror.
- **Release via GitHub.** When a new version is ready to submit, push to the `github`
  remote (`SuperSeriousLab/Gremlins.jl`) — that triggers the auto-merge / registry
  registration flow. GitHub push = release, not routine dev. Don't push to `github`
  for in-progress work.
- Registration (Julia General registry) is a deliberate, explicit release step — see
  the General-registry note in workspace memory; never trigger it just to finish a branch.
