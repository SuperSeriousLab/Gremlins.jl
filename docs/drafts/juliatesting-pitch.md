# JuliaTesting org pitch — Gremlins.jl

**DRAFT — open as a GitHub issue on the JuliaTesting org after the ANN post. Fill links first.**
Issue title: Proposal: add Gremlins.jl (mutation testing) to JuliaTesting

---

I'd like to propose Gremlins.jl for the JuliaTesting organization. It covers the one large gap left in the testing toolchain — mutation testing. The only prior tool, Vimes.jl, has been dead since 2019, and threads asking for a replacement still point at it.

Gremlins mutates the syntax tree through JuliaSyntax, selects mutants by coverage, and runs them through a warm worker that evals each changed method into the loaded module instead of spawning a process per mutant — 5.77× faster on a real 25-site benchmark. The run works on a disposable copy of the package, so a crash can't corrupt your source. Nineteen operators cover the standard classes: relational, boolean, arithmetic, boundary, return value, statement deletion.

Why the org rather than a personal repo: the thing that killed Vimes was single-author abandonment. Org membership is the signal to users that the tool will outlive one person's interest. I'll commit to maintaining it and keeping JuliaSyntax compat current — the byte-range core is stable — and I'd want design feedback before tagging 1.0.

What I'm asking: a review for membership, feedback on the API, and, if accepted, transfer of the repo to JuliaTesting.

Repo: https://github.com/SuperSeriousLab/Gremlins.jl
Docs: https://github.com/SuperSeriousLab/Gremlins.jl/blob/main/docs/usage.md
Discourse ANN: <link>
