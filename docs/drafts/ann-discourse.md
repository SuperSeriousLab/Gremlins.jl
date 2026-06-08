# [ANN] Gremlins.jl — mutation testing for Julia

**DRAFT — paste into discourse.julialang.org, category: Package Announcements.**
Register: humble/community (modeled on real [ANN] posts). Screen with `ceresis --type announcement`.

---

Hi all — I've been putting together Gremlins.jl, a mutation-testing package for Julia, and I'd love for people to try it and tell me where it falls over.

Mutation testing checks whether your tests would actually notice a bug: it makes a small edit to your source — flip a `<` to `<=`, a `+` to `-` — and reports which edits your suite catches and which slip through. Julia hasn't really had a maintained tool for this since Vimes.jl, so I wanted to take a run at it.

How it works, briefly:
- parses with JuliaSyntax and splices byte ranges (no regex over source)
- uses coverage to skip mutants on lines your tests never reach
- runs each surviving mutant through a warm worker that evals the changed method into the already-loaded module instead of starting a fresh process — on a 25-site run of one of my own packages that came out roughly 5–6× faster than process-per-mutant, though Julia's compile cost is still very real on large suites
- mutates a throwaway copy of the package; an interrupted run never touches your source

It's early (v0.1.1) and there are rough edges I'll flag honestly: mutations inside macros, type definitions, and const globals fall back to a slower per-process path, and the operator set is the standard relational/boolean/arithmetic/boundary/return one for now. There's a `--files` flag to keep CI runs scoped to changed files.

```julia
using Gremlins
result = mutate_warm(".")
print_warm_summary(result)
```

I'd really appreciate people running it on their own packages — bug reports, rough edges, and "this is missing X" are all very welcome. Thanks for reading!

MIT, Julia 1.10+.

Repo: https://github.com/SuperSeriousLab/Gremlins.jl
Docs: https://github.com/SuperSeriousLab/Gremlins.jl/blob/main/docs/usage.md
