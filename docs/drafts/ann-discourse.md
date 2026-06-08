# [ANN] Gremlins.jl — mutation testing for Julia

**DRAFT — post after General registry merge. Fill the two links first.**
Discourse category: Package Announcements.

---

Julia has had no working mutation-testing tool since Vimes.jl went dark in 2019 — the Discourse threads asking what to use still point at it. Gremlins.jl fills that gap.

It mutates the syntax tree through JuliaSyntax (byte-range splices, never regex over source), runs your suite once under coverage to skip unreachable mutants, then for each remaining mutation evals just the changed method into the already-loaded module and runs the covering tests in a fresh namespace before restoring the original. That warm path is 5.77× faster than spawning a process per mutant — 368s against 2121s on 25 sites of a real TUI package. Mutations run on a disposable copy of your package; the working tree is never written, and a Ctrl-C or OOM leaves no corrupted source behind.

Mutations inside macros, type definitions, and const globals can't be eval'd safely and fall back to a cold subprocess — the report tells you which did. Julia's compile cost is still real on large suites; scope CI runs to changed files with `--files`.

```julia
using Gremlins
result = mutate_warm(".")
print_warm_summary(result)
```

MIT, Julia 1.10+. Feedback and operator suggestions welcome.

Repo: https://github.com/SuperSeriousLab/Gremlins.jl
Docs: https://github.com/SuperSeriousLab/Gremlins.jl/blob/main/docs/usage.md
