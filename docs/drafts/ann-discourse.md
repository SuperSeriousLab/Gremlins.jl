# [ANN] Gremlins.jl — Mutation testing for Julia (Vimes replacement)

**DRAFT — do not post until after General registry AutoMerge confirms**

---

## Post target

Discourse category: `Announcements` or `Packages & Tools`

---

## Post body

---

**TL;DR**: Julia now has a working mutation-testing package. It uses JuliaSyntax for
byte-accurate AST mutations, a warm-worker pool that is 5.77× faster than
process-per-mutant, and coverage-guided selection that skips unreachable mutants.
Kill ~80 % of mutants with a good test suite; kill 20 % and your tests are mostly
smoke tests.

---

### Why mutation testing?

Coverage tells you which lines were reached. Mutation testing tells you whether
your tests actually *assert* anything. A test suite that kills 80 %+ of artificially
injected bugs is asserting; one that kills 20 % is mostly checking the code runs
without crashing.

### Vimes.jl is dead

The only previous Julia mutation-testing tool was Vimes.jl (last real commit
November 2019, pinned to a defunct CSTParser branch, Travis CI green never again).
Numerous Discourse threads asking "what do I use for mutation testing in Julia"
still point at dead Vimes. There has been nothing to fill the gap for six years.

### What Gremlins.jl does

- **JuliaSyntax-based operators** — parses source via JuliaSyntax, mutates byte
  ranges directly. No regex over source, no pretty-printing untouched code.
- **19 operators** covering relational flips (`<`↔`<=` etc.), boolean flips
  (`&&`↔`||`, `!` deletion), arithmetic (`+`↔`-`, `*`↔`/`), integer literal
  boundary (`42`→`43`/`41`), bool literal flip, `return x`→`return nothing`,
  and statement deletion.
- **Coverage-guided selection** — runs your suite once with `--code-coverage=user`,
  builds a line-to-test map. Mutants on uncovered lines are marked `no_coverage`
  (a signal, not a kill). Only covered mutants run.
- **Warm-worker pool** — a persistent Julia worker loads your package ONCE. Per
  mutant, `Core.eval` replaces only the changed function, tests run in a fresh
  anonymous `Module`, then the original is restored. Disk is never written on the
  warm path.
- **5.77× speedup** on real code: JUI (TeleTUI), 25 sites, warm vs cold:

  | Mode | Total | Per-mutant | Killed | Survived |
  |------|-------|-----------|--------|---------|
  | Cold (process-per-mutant) | 2121 s | 84.9 s | 7 | 18 |
  | Warm (eval-into-module)   | 368 s  | 14.7 s | 7 | 18 |
  | **Speedup** | **5.77×** | **5.77×** | same | same |

  I4 agreement check (warm vs cold on 10 sampled mutants): 0 mismatches.

- **Incremental cache** keyed on `SHA256(file_content) + mutant_id + gremlins_version`.
  No mtime (git checkout refreshes mtimes).
- **CI CLI** (`bin/gremlins-cli.jl`) with `--files` scoping, threshold bands
  (strong ≥ 0.80, acceptable ≥ 0.60), JSON output, and exit codes for CI gates.

### Honest limitations

The warm path works on ~80 % of mutants. Mutations inside macro definitions,
`struct`/`abstract` type defs, and `const` globals cannot be eval'd without
struct-redefinition errors — these fall back to cold (one subprocess per mutant).

Julia's compile cost is still real. A 60-second test suite on 300 mutants = ~5 hours
warm, ~28 hours cold. Use `--files` to scope CI runs to changed files; budget
cap and prioritization come in a future release.

Equivalent mutants (syntactically different, semantically identical) appear as
`survived`. This is known noise documented in every report.

### Quickstart

```julia
using Pkg; Pkg.add("Gremlins")   # after General registry merge

using Gremlins
result = mutate_warm(".")        # warm pool, src/, runtests.jl
print_warm_summary(result)
```

Or via the CLI in CI:

```bash
julia --project=.gremlins .gremlins/bin/gremlins-cli.jl \
  --pkg . --files "src/mychangedfile.jl" --warm --acceptable 0.60
```

### Links

- Package: [link to be added after GitHub push]
- Documentation: [link to be added]
- Issue tracker: [link to be added]
- General registry PR: [link to be added after AutoMerge]

### Design decisions / future work

I'd be happy to discuss design tradeoffs:
- Malt.jl vs Distributed for workers (Malt = cleaner lifecycle, extra dep; went with
  raw Julia subprocess + JSON-Lines to stay zero-dep)
- TestItemRunner.jl integration for per-item coverage maps (open question)
- Mutant schemata (compile N mutants behind `if MUTANT_ID == k` switches — biggest
  speedup, biggest complexity; explicitly out of MVP)

---

*Gremlins.jl v0.1.0. MIT license. Julia 1.10+. 457 tests.*

---

**END OF DRAFT**
