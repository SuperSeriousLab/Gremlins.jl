---
type: design
applies_to: [workspace, oss-campaign]
status: draft
created: 2026-06-04
---

# Design: Julia Mutation-Testing Package (greenfield OSS)

## Problem

Julia has **zero maintained mutation-testing tools**. Vimes.jl (the only one ever)
is dead: last real commit Nov 2019, pinned to a defunct `CSTParser#location`
branch, Travis CI. Nothing replaced it. Verified 2026-06-04 (tooling-gap survey).

Two consumers motivate building it:

1. **Community** — recurring "what do I use for mutation testing" threads still
   point at dead Vimes. Quality-tooling gap acknowledged; JuliaTesting org is the
   natural home.
2. **Internal** — Sisyphus protocol T4 (mutation tier) is Go-only (gremlins).
   JUI, Igor, WIQ, MEROM are Julia and cannot run T4 today. This package wires
   the missing row of the language-adaptation matrix.

## Name

`MutationTesting.jl` (descriptive, safe) — working name. Alternatives to check
at registration time: `Mutate.jl`, `Mutant.jl` (verify collisions in General).
Naming policy: descriptive or biblical; no mythology names (Vimes precedent
irrelevant — Discworld, but we don't follow it).

## Prior art to mine

| Tool | Lesson |
|---|---|
| Vimes.jl | Patch-library design (generate source patches, apply, run, revert) is sound; parser layer is what rotted. ~50 commits of operator ideas. |
| cargo-mutants (Rust) | Process-per-mutant + build caching; `--in-place` vs copy-tree tradeoffs; timeout multipliers from baseline run. |
| mutmut (Python) | Coverage-guided test selection is THE speed lever; incremental cache keyed on (file-hash, mutant-id). |
| Stryker (JS) | Report UX standard: per-mutant status (killed / survived / timeout / no-coverage), HTML dashboard. |

## The hard problem: Julia's compile cost

Naive process-per-mutant = `julia --project -e 'Pkg.test()'` per mutant →
precompile + test-suite startup each time. For a package with a 60 s suite and
300 mutants that's 5+ hours. This killed casual interest in Vimes. The design
must attack it head-on:

1. **Coverage-guided test selection** (MVP): run baseline with
   `--code-coverage=user` once, build line→testfile map (needs per-testfile
   granularity: run test files individually or use TestItemRunner.jl items when
   present). Per mutant, run ONLY the covering tests. No coverage → mutant
   marked `no-coverage` (a finding in itself, not a kill).
2. **Warm-worker pool** (MVP): persistent Julia worker processes (Distributed
   or Malt.jl). Each worker loads the package once; per mutant, apply the
   mutation via `Revise`-style `eval`-into-module of only the mutated method's
   file (or `include` of the rewritten file into a fresh module namespace).
   Fragile cases (mutants in macros, type defs, const globals) fall back to
   cold process. Expect ~80 % of mutants on the warm path.
3. **Mutant schemata** (post-MVP): compile N mutants into one image behind
   runtime switches (`if MUTANT_ID == k`). Biggest speedup, biggest complexity;
   explicitly out of MVP.

## Architecture (MVP)

```
src/
  operators.jl     # AST mutation operators over JuliaSyntax trees
  discover.jl      # walk pkg source, enumerate mutation sites
  patch.jl         # apply/revert single mutation (source-text splice via byte ranges)
  coverage.jl      # baseline run, line→test map
  runner.jl        # worker pool, per-mutant execution, timeout = 3× baseline
  report.jl        # JSON + Markdown + exit-code policy (CI gate)
  MutationTesting.jl
```

- **Parser: JuliaSyntax.jl** (now ships with Julia; stable, byte-range-accurate
  green tree). Mutations operate on byte ranges in source text — splice, don't
  pretty-print, so untouched code keeps formatting (cargo-mutants approach).
- **Operator set v1** (small, high-signal; each = (matcher, replacement)):
  - relational flip: `<` ↔ `<=`, `>` ↔ `>=`, `==` ↔ `!=`
  - boolean: `&&` ↔ `||`, delete `!`
  - arithmetic: `+` ↔ `-`, `*` ↔ `/`
  - boundary: `x` → `x + 1` / `x - 1` on integer literals
  - return value: `return x` → `return nothing` (where type-plausible), bool
    literal flip
  - delete statement (guarded: not `return`, not last expr of function)
- **Type-stability pre-filter**: skip mutants that are trivially type-invalid
  (e.g. `*` → `/` on Int in indexing position) only when cheap to detect;
  otherwise let the run classify them (compile error = `unviable`, not killed —
  matches cargo-mutants taxonomy).
- **Determinism**: mutant enumeration sorted (file, byte-offset, operator-id);
  mutant-id = stable hash → resumable runs, incremental cache.

## API sketch

```julia
using MutationTesting
result = MutationTesting.run(pkgdir;
    operators = DEFAULT_OPERATORS,
    workers = Sys.CPU_THREADS ÷ 2,
    budget = nothing,            # or seconds cap → prioritized subset
    filter = nothing)            # file/function globs
# result.score, result.killed, result.survived::Vector{Mutant}, result.unviable
MutationTesting.report(result, format = :markdown)  # also :json
```

CLI wrapper (`mutationtest` via `comonicon` or plain script) for CI:
non-zero exit when score < threshold.

## Sisyphus T4 wiring (internal, after MVP)

`.sisyphus/lang/julia.toml`: T4 = `MutationTesting.run` on the chunk's package,
strong ≥ 0.80 kill-rate, acceptable ≥ 0.60, per-package result cache keyed on
package tree-hash (same policy as gremlins cache; no mtime invalidation —
learned that lesson).

## Milestones

| M | Deliverable | Effort |
|---|---|---|
| M0 | Operators + discovery + patcher on JuliaSyntax; mutate self, print sites | 3-4 d |
| M1 | Cold runner (process-per-mutant) + coverage-guided selection + JSON/MD report; dogfood on JUI or WIQ | 4-5 d |
| M2 | Warm-worker pool + incremental cache + timeout policy; benchmark vs M1 on a mid-size pkg (target ≥5× speedup) | 5-7 d |
| M3 | Polish: docs, ANN Discourse post, General registration, pitch JuliaTesting org adoption; CI GitHub Action recipe | 3-4 d |

Total ≈ 3-4 wk calendar at campaign pace. M0/M1 delegable as bounded tasks;
M2 design (worker protocol, fallback taxonomy) stays CTO-level.

## Risks

| Risk | Mitigation |
|---|---|
| Warm-path eval-into-module fragility (macros, consts, type defs) | Classified fallback to cold path; taxonomy in report so fragility is visible, not silent |
| Compile cost still dominates on heavy pkgs | budget cap + prioritization (public API files first); document honestly |
| Adoption (new pkgs die: Vimes, Lint.jl precedent) | JuliaTesting org pitch BEFORE 1.0; CI Action recipe; ANN with real kill-rate numbers from known packages (e.g. run on Aqua.jl itself) |
| JuliaSyntax API churn | pin compat; tree→byte-range API is the stable core |
| Test-suite side effects (mutants triggering network/fs writes) | run in tmp copy of package tree (cargo-mutants default); document `--in-place` as opt-in |

## Verification standard (campaign rule, learned 2026-06-04)

Every milestone's tests must include **falsifiability runs**: the runner's
kill-detection is itself verified by planting known-killable and
known-equivalent mutants and asserting classification. No "verified locally"
claims without pasted output.

## Open questions (resolve during M0)

1. TestItemRunner.jl integration depth — per-item coverage map vs per-file.
2. Malt.jl vs Distributed for workers (Malt = cleaner lifecycle, extra dep).
3. Equivalent-mutant heuristics — out of scope v1, document as known noise?
4. Minimum Julia version — 1.10 LTS (JuliaSyntax vendored) vs 1.11.
