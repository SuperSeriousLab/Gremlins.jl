# JuliaTesting Org Pitch — Gremlins.jl

**DRAFT — post as a GitHub issue on JuliaTesting org AFTER ANN Discourse post**

---

## Issue title

> [Proposal] Add Gremlins.jl to JuliaTesting — mutation testing (Vimes replacement)

---

## Issue body

---

Hello,

I'd like to propose adding **Gremlins.jl** to the JuliaTesting organization.
Gremlins fills the only remaining large gap in Julia's testing toolchain: mutation
testing.

### What it is

Gremlins.jl is a mutation-testing package for Julia using JuliaSyntax for
byte-accurate AST mutations, a warm-worker pool (~5.77× faster than naive
process-per-mutant), and coverage-guided selection. 19 operators covering the
standard mutation classes (relational, boolean, arithmetic, boundary, return value,
statement deletion).

### The gap it fills

The community testing toolchain covers unit testing (`Test`), quality assurance
(`Aqua.jl`), static analysis (`JET.jl`), and property-based testing
(`Supposition.jl`, `PropCheck.jl`). The missing row: **mutation testing**.
Vimes.jl, the only prior attempt, has been dead since November 2019. Discourse
threads still point at it.

### Why JuliaTesting org makes sense

1. **Fills a fundamental gap** — coverage tells you which lines ran; mutation testing
   tells you whether tests *assert* anything. Both are needed for a complete testing
   story.

2. **Long-term maintenance signal** — JuliaTesting org membership signals to the
   community that the package will be maintained. This is exactly the problem that
   killed Vimes: single-author, no org, abandoned when the author moved on.

3. **Design consistency** — Gremlins is designed to compose with the existing
   JuliaTesting ecosystem: coverage data from `Coverage.jl`, test runner hooks for
   `TestItemRunner.jl` (future integration), CI recipes for GitHub Actions.

4. **Active development** — 0.1.0 with M0-M3 roadmap complete: operators,
   cold runner, warm-worker pool, CI CLI, General registry. Three planned releases
   to 1.0 with documented design.

### Design decisions that differ from convention

**One registered dependency** — `JuliaSyntax`, plus stdlib `SHA` and `Base64`.
Deliberate: heavy dependency trees in testing tools become maintenance
liabilities. The warm-worker protocol is a raw Julia subprocess + JSON-Lines
over stdio.

**No macro/struct/const mutations on warm path** — These fall back to cold per-process.
The fallback taxonomy is visible in every report so it's explicit, not silent.

**Honest about compile cost** — the README documents real benchmark numbers and
limitations rather than claiming "fast" and delivering slow.

### Maintenance commitment

I commit to:
- Maintaining and responding to issues for at least 24 months post-1.0.
- Breaking-change policy: no breaking changes before 1.0 without a deprecation
  period.
- Updating JuliaSyntax compat as the parser API evolves (the byte-range API is
  the stable core; the green tree API is stable since JuliaSyntax 0.4).

### What I'm asking for

- Review of the package for JuliaTesting org membership.
- Feedback on the API design before 1.0.
- If accepted: transfer of the GitHub repo to `JuliaTesting/Gremlins.jl`.

### Links

- GitHub: [link to be added]
- Discourse ANN: [link to be added]
- General registry PR: [link to be added]
- Documentation: [link to be added]

Thank you for your time.

---

**END OF DRAFT**
