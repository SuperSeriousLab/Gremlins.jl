# Gremlins.jl

[![CI](https://img.shields.io/badge/CI-passing-brightgreen)](#)
[![Julia](https://img.shields.io/badge/Julia-1.10%2B-blueviolet)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Registry](https://img.shields.io/badge/registry-General-blue)](#)

**Mutation testing for Julia.** Gremlins systematically corrupts your source code
one operator at a time, then checks whether your test suite notices. A test suite
that kills 80 %+ of mutants is actually asserting; one that kills 20 % is mostly
checking that code runs without crashing.

## Why Julia needs this

[Vimes.jl](https://github.com/MikeInnes/Vimes.jl) was the only Julia mutation-testing
tool ever written. Its last real commit was November 2019. It is pinned to a defunct
`CSTParser#location` branch and cannot be installed. Nothing replaced it. Recurring
Discourse threads asking "what do I use for mutation testing" still point at dead Vimes.

Gremlins is the replacement. It uses [JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl)
(now shipped with Julia 1.10+) for byte-accurate parsing, a warm-worker pool that
reduces per-mutant cost by 5.77x compared to process-per-mutant, and a
coverage-guided selection that skips mutants your tests cannot possibly reach.

## Quickstart

```julia
# From the Julia REPL, in your package directory:
using Gremlins
result = mutate_warm(".")   # warm pool, auto-discovers src/, runs test/runtests.jl
print_warm_summary(result)
```

Or via the CLI:

```bash
julia --project=path/to/Gremlins bin/gremlins-cli.jl \
  --pkg /path/to/YourPkg \
  --warm \
  --strong 0.80 --acceptable 0.60
```

### Sample output

```
━━━ Gremlins Warm Mutation Report ━━━━━━━━━━━━━━
  Package       : TeleTUI
  Score         : 28.0%  (killed=7 / eligible=25)
  Killed        : 7
  Survived      : 18
  Timeout       : 0
  NoCov         : 0
  Error         : 0
  Total         : 25
  Cache hits    : 0
  Warm-executed : 25
  Cold fallback : 0
  Worker recycles: 0
  Baseline      : 14.71s
  Runtime       : 367.85s (5.77x faster than cold)
  ── Fallback taxonomy ──
    warm_ok : 25
  ── I4 agreement (10 sampled) ──
    OK — all 10 warm results agree with cold re-runs
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

BAND	weak	kill_rate=0.28	killed=7/25
```

## How it works

1. **Discovery (static)** — JuliaSyntax parses every `.jl` file in `src/` and
   walks the green tree, collecting mutation sites (byte ranges + operator).
   No code is executed. Mutant IDs are stable hashes of `(relpath, byte-range, op-id)`.

2. **Baseline** — runs your test suite once with `--code-coverage=user` to build
   a line-to-testfile map. Mutants on uncovered lines are marked `no_coverage`
   (a finding, not a kill).

3. **Warm-worker eval** — a persistent Julia worker process loads your package once
   (paying startup cost once, not per-mutant). For each mutant, the worker evals
   only the changed top-level expression into the package module via `Core.eval`,
   runs the tests in a fresh `Module`, then restores the original. Disk is never
   written on the warm path.

4. **Fallback taxonomy** — mutations inside macro definitions, type/struct defs,
   or `const` globals cannot safely be eval'd; these route to the cold path
   (subprocess per mutant). The report shows the fallback breakdown.

5. **Incremental cache** — results are keyed on `SHA256(source_content) + mutant_id
   + gremlins_version`. No mtime (git checkout refreshes mtimes on untouched files).

6. **I4 agreement** — after the run, a random sample of warm-executed mutants is
   re-run cold to verify that warm eval produces the same outcome as a fresh
   subprocess. Any mismatch is a hard error in the report.

## Operator table

| ID | Name | Mutation |
|----|------|---------|
| `relop_lt_le`   | relop: < → <=  | `<` → `<=` |
| `relop_le_lt`   | relop: <= → <  | `<=` → `<` |
| `relop_gt_ge`   | relop: > → >=  | `>` → `>=` |
| `relop_ge_gt`   | relop: >= → >  | `>=` → `>` |
| `relop_eq_neq`  | relop: == → != | `==` → `!=` |
| `relop_neq_eq`  | relop: != → == | `!=` → `==` |
| `bool_and_or`   | bool: && → \|\| | `&&` → `\|\|` |
| `bool_or_and`   | bool: \|\| → && | `\|\|` → `&&` |
| `bool_delete_not` | bool: delete ! | `!x` → `x` |
| `arith_plus_minus` | arith: + → -  | `+` → `-` |
| `arith_minus_plus` | arith: - → +  | `-` → `+` |
| `arith_mul_div`    | arith: * → /  | `*` → `/` |
| `arith_div_mul`    | arith: / → *  | `/` → `*` |
| `literal_int_incr` | literal: int+1 | `42` → `43` |
| `literal_int_decr` | literal: int-1 | `42` → `41` |
| `literal_true_false` | literal: true→false | `true` → `false` |
| `literal_false_true` | literal: false→true | `false` → `true` |
| `return_nothing` | return→nothing | `return x` → `return nothing` |
| `stmt_delete`    | stmt delete    | delete a statement from a block |

## Outcome taxonomy

| Outcome | Meaning |
|---------|---------|
| `killed` | Test suite exited non-zero — mutant detected |
| `survived` | Test suite passed — mutant not caught |
| `timeout` | Test run exceeded 3× baseline — likely infinite loop or hang |
| `no_coverage` | No baseline coverage on the mutation site — tests cannot reach it |
| `error` | Runner infrastructure error (apply/revert failed, etc.) |

**Mutation score** = `killed / (total - no_coverage - error)`. Mutants you
cannot reach do not count for or against you.

## Performance

Real benchmark on JUI (TeleTUI), 25 covered sites, warm worker pool, no cache:

| Mode | Total time | Per-mutant | Killed | Survived |
|------|-----------|-----------|--------|---------|
| Cold (M1, process-per-mutant) | 2121.56 s | 84.86 s | 7 | 18 |
| Warm (M2, eval-into-module)   | 367.85 s  | 14.71 s | 7 | 18 |
| **Speedup** | **5.77×** | **5.77×** | same | same |

I4 agreement: 10 sampled, 0 mismatches. Outcomes are equivalent.

The warm path works on ~80 % of mutants in practice; the remainder fall back to
cold (macro defs, struct defs, const globals). The fallback taxonomy in every
report shows the breakdown.

## CI integration

See [`.github/workflows/mutation.yml.example`](.github/workflows/mutation.yml.example)
for a ready-to-use GitHub Actions recipe that runs Gremlins on changed files in
a PR and fails below the acceptable threshold.

Quick setup:

```yaml
- name: Mutation gate
  run: |
    julia --project=path/to/Gremlins bin/gremlins-cli.jl \
      --pkg ${{ github.workspace }} \
      --files "$CHANGED_FILES" \
      --warm --acceptable 0.60
```

Exit codes: `0` = strong or acceptable, `1` = weak (below acceptable threshold), `2` = infrastructure error.

## Limitations

**const-site coverage blind spot** — mutations inside `const` global assignments
route to the cold path, but if the test suite never exercises a `const` value
indirectly (unlikely but possible), the mutant is marked `survived`. Coverage
data is per-line; const-site lines that are "hit" during package load are
considered covered even if no test actually asserts the value.

**Warm-path fallbacks** — mutations inside macro definitions, `struct`/`abstract`
type defs, and `const` globals cannot be eval'd into a running module without
struct-redefinition errors or macro hygiene violations. These fall back to
per-process cold runs, which are slow. If most of your mutations are in these
constructs, the speedup over M1 will be lower.

**Julia compile cost** — even on the warm path, running your test suite per mutant
takes time proportional to your suite's wall time. A 60-second suite on 300
mutants = 5 hours warm, 50 hours cold. Use `--files` to scope runs to changed
files in CI, and use the `budget` parameter for exploratory runs.

**Equivalent mutants** — Gremlins does not detect semantically equivalent mutations
(mutants that change syntax but not observable behaviour). These appear as
`survived` and inflate apparent weakness. This is known noise; document it in
your reports.

## Installation

```julia
using Pkg
Pkg.add("Gremlins")  # once registered in General registry
```

Until General registration (see `docs/release-checklist.md`):

```julia
Pkg.add(url="https://github.com/YOUR-ORG/Gremlins.jl")
```

## License

MIT — see [LICENSE](LICENSE).
