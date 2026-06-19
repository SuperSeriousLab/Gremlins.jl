# [ANN] Gremlins.jl — mutation testing for Julia

**POSTED 2026-06-09:** https://discourse.julialang.org/t/ann-gremlins-jl-mutation-testing-for-julia/137506
Operator voice (no bullets — deliberate, bullets read LLM-y). Screen with `ceresis --type announcement`.

---

Hello there, I've been putting together Gremlins.jl, a mutation-testing package for Julia, and I'd love for people to try it and tell me where it falls over.

Mutation testing checks whether your tests would actually notice a bug: it makes a small edit to your source — flip a `<` to `<=`, a `+` to `-` — and reports which edits your suite catches and which slip through. Tmk Julia hasn't really had a maintained tool for this since Vimes.jl, so I wanted to take a run at it.

How Gremlins work,
parses with JuliaSyntax and splices byte ranges (no regex over source)
uses coverage to skip mutants on lines your tests never reach
runs each surviving mutant through a warm worker that evals the changed method into the already-loaded module instead of starting a fresh process — on a 25-site run of one of my own packages that came out roughly 5–6× faster than process-per-mutant
mutates a throwaway copy of the package; an interrupted run never touches your source

It's early (v0.1.1) and there are rough edges.

For CI, there's a `--files` flag to keep runs scoped to changed files.

```julia
using Gremlins
result = mutate_warm(".")
print_summary(result)
```

testing and testing of testing has become my sort-of-passion

very much open to "this is missing X" and other requests in kind

no AI was warmed during the development but it was used, especially for the documentation
