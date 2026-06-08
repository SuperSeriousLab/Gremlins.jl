# [ANN] Gremlins.jl — mutation testing for Julia

**DRAFT — post after General registry merge. Fill the two links first.**
Discourse category: Package Announcements.

---

Julia has had no working mutation-testing tool since Vimes.jl went dark in 2019 — the Discourse threads asking what to use still point at it. Gremlins.jl fills that gap.

It mutates the syntax tree through JuliaSyntax (byte-range splices, never regex over source), runs your suite once under coverage to skip unreachable mutants, then for each remaining mutation evals just the changed method into the already-loaded module and runs the covering tests in a fresh namespace before restoring the original. That warm path is 5.77× faster than spawning a process per mutant — 368s against 2121s on 25 sites of a real TUI package. Mutations never touch your working tree; the run happens in a disposable copy, so a Ctrl-C or an OOM kill can't leave a corrupted source file behind.

Mutations inside macros, type definitions, and const globals can't be eval'd safely, so they fall back to a cold subprocess — the report tells you which did. Julia's compile cost is still real on large suites; scope CI runs to changed files with `--files`.

```julia
using Gremlins
result = mutate_warm(".")
print_warm_summary(result)
```

MIT, Julia 1.10+. Feedback and operator suggestions welcome.

Repo: <link>
Docs: <link>
