# Survivor-Coverage Blame — Design Spec (DRAFT — brainstorm in progress)

**Date:** 2026-06-17
**Status:** DRAFT — design presented, **crux open** (per-test-file coverage acquisition). NOT yet approved; do not start implementation.
**Feature:** 2 of 3 (dispatch mutation ✅ shipped → **this** → runtime value injection)
**Consulted:** atlas-flash + atlas-pro (2026-06-17). atlas-pro proposed this framing ("D"); both consults' repo-fact assumptions were corrected against the code (see §6).

## 1. Goal

For each **surviving** source mutant (Gremlins survivors are already *covered-but-not-killed*), name the **test file(s) that execute its line** → "this test ran the mutated code and its assertions didn't catch the change; strengthen it." Turns the flat survivor list into a per-test to-do list. Complementary to source mutation, not a superset.

## 2. Why this framing (vs alternatives, all rejected)

- **A′ (corrupt-and-rerun on test assertions):** cheap, standalone, but only finds a narrow pathological class (flaky/side-effecting/tautological asserts). For a deterministic genuine assertion, oracle-negation always flips pass→fail (always "killed"), so survivors are rare pathologies — not weak coverage. Rejected as low-ROI.
- **C (per-mutant kill attribution):** record which @test killed each mutant. Heavy + noisy (one `Pkg.test()` process, nested @testsets, shared-state pollution, mutants can crash the suite before the responsible test runs). Rejected.
- **D (this):** mine existing survivors + per-test coverage. Chosen 2026-06-17 ("build D properly", its own milestone).

## 3. Pipeline (additive — runs after a normal source-mutation campaign)

1. Take `survived` mutants from the existing `MutationResult` (each carries `relpath` + `line`).
2. Build a **per-test-file source-coverage map**: `Dict{src_relpath ⇒ Dict{line ⇒ Set{testfile}}}` — which test files execute each source line. (Acquisition = §4, the open crux.)
3. **Blame join:** survivor at `(src, line)` → test files covering that line = blamed tests.
4. **Report lens** (`report.jl`): new "Survivors by responsible test" section — per test file, the survivors it covers but never kills. Deterministic, sorted.

## 4. CRUX (OPEN — this is what to refine next) — per-test-file coverage acquisition

Julia `--code-coverage` is **whole-process cumulative**; you cannot attribute a line-hit to a test file within one run. `coverage.jl` is deliberately **whole-suite only** (docstring: *"Per-testfile granularity is not available without per-test runners; M1 uses whole-suite coverage"*). So attribution needs **N isolated coverage runs** (N = #test files). The hard part: many suites' test files are **not independently runnable** (shared helpers/setup defined in `runtests.jl`; e.g. Gremlins' own `runtests.jl` defines `sites_for`/`_eval_in_fresh_module` inline and runs M0 inline before `include`-ing sub-files).

**Candidate acquisition approaches (decide here):**
- **(i) Isolated-include with detected prelude [leading candidate]:** per test file `Ti`, run a driver `include(<prelude>); include(<Ti>)` under `--code-coverage=user`, reusing the existing shadow-copy + `baseline_run` infra. Prelude = the lines of `runtests.jl` outside any `include("test_*.jl")`. Limitation: prelude detection is heuristic; inline-run tests (Gremlins M0) get attributed to the prelude, not a file.
- **(ii) runtests-include-pruning via byte-splice:** for each `include("test_X.jl")` line in `runtests.jl`, byte-splice a variant that keeps only `Ti`'s include (reuse `patch.jl`), run with coverage. Cleaner reuse of mutation infra, but changes suite semantics (skips setup other files might establish) and doesn't handle inline tests.
- **(iii) Config-declared test units + prelude hook:** user/config declares the independently-runnable units + a shared prelude path. Most robust, least magic, but needs config surface.

**One-directional honesty (non-negotiable):** a test file that errors under the focused driver → logged + its survivors marked **"unattributed"** (fall back to whole-suite). **Never falsely blame.**

**Cost:** N×baseline. Opt-in deep report, NOT the default campaign. Whole-suite coverage stays the cheap default.

## 5. Falsifiability (per the project rule)

Fixture with: (a) a **weak** test file that *calls* `f` but only `@test true`, plus a source mutant in `f` that survives → D must **blame** that file; (b) a **strong** test file that covers+kills the mutant → must **NOT** be blamed; (c) a test file that doesn't run `f` at all → not blamed. Plus an "unattributed" case: a non-independently-runnable test file → its survivors marked unattributed, never mis-blamed.

## 6. Consult corrections (repo facts both models missed)

- atlas-pro claimed D is "mostly free, reuses existing runs." **False here:** per-test attribution needs N coverage runs (the per-test-runner granularity M1 explicitly punted).
- atlas-pro's "free slice" (covered-vs-uncovered survivor triage) **already ships**: the runner classifies `survived` (covered, not killed) vs `no_coverage` (uncovered). D's genuine new value = *naming the culpable test*, at per-test-coverage cost.
- atlas-flash's A′ "reuse full source operators on tests" is unsound (mutates inputs, not just oracles) — moot now that D is chosen.

## 7. OPEN QUESTIONS (the refine-D agenda)

1. **Pick the §4 acquisition approach** (i / ii / iii or hybrid). This is the gating decision.
2. Attribution granularity: test **file** (atlas-pro's framing) vs `@testset` — file is achievable; testset needs more. Confirm file-level for v1.
3. Where does D live — extend `coverage.jl` (per-test mode) + new `blame.jl`, or fold into `runner.jl`? Keep whole-suite default untouched.
4. Opt-in surface: CLI flag (`--blame`?) + public API entry point.
5. Does the existing shadow-copy infra support N parallel/sequential focused runs cleanly, or need a new driver?

**Next action:** resolve §4 + §7, finish the brainstorm, get approval, then writing-plans → subagent-driven execution (per the eidos-wide flow).
