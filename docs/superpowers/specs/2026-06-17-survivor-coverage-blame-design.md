# Survivor-Coverage Blame — Design Spec (DRAFT — brainstorm in progress)

**Date:** 2026-06-17
**Status:** DRAFT — design presented, **crux RESOLVED** (per-test-file coverage acquisition = approach (i) refined; see §4). §7 resolved. Awaiting approval; do not start implementation.
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

## 4. CRUX (RESOLVED) — per-test-file coverage acquisition = approach (i) refined

Julia `--code-coverage` is **whole-process cumulative**; you cannot attribute a line-hit to a test file within one run. `coverage.jl` is deliberately **whole-suite only**. So attribution needs **N isolated coverage runs** (N = #test units). There is no cheaper floor — confirmed (Coverage.jl is also whole-process). The hard part: test files are **not independently runnable** (shared helpers/setup live in `runtests.jl`).

### Decision: (i) Isolated-include with **JuliaSyntax-parsed prelude**

**Soundness key (why (i) is provably correct, not heuristic):** in a normal `runtests.jl`, `include("test_X.jl")` runs in `Main`'s **top-level scope**. A subfile can therefore only depend on **top-level definitions** (the prelude) — never on `@testset`-local bindings (testset bodies are local scopes). So a prelude built from *all top-level statements minus the testfile-includes minus the `@testset` blocks* is **sufficient** for any subfile that runs correctly in the real suite. (Verified against Gremlins: `sites_for`/`sites_for_op` are top-level → captured; `_eval_in_fresh_module` is testset-nested and used only inside M0 → correctly excluded, no subfile needs it.)

**Mechanism (JuliaSyntax — project rule, no regex over source):**
1. Parse `runtests.jl` top-level nodes. Classify each:
   - `include("test_*.jl")` (string-literal arg matching the suite's test files) → a **unit** `Ti`.
   - `@testset ...` macrocall at top level → an **inline-tests** node (not prelude).
   - everything else (`using`/`import`/`const`/`function`/`struct`/assignment) → **prelude**.
2. Units = each testfile-include **plus** one synthetic `runtests.jl (inline)` unit = the prelude + the inline `@testset` blocks (i.e. runtests with all testfile-includes stripped). For Gremlins: 8 includes + 1 inline = **9 units**.
3. Per unit, generate a driver inside the shadow `test/` dir: `<prelude source>` then `include("test_X.jl")` (or, for the inline unit, prelude + the inline blocks). Run `julia --project=<shadow> --code-coverage=user <driver>`.
4. Parse `.cov` → `CoverageMap` for that unit → `Dict{unit ⇒ CoverageMap}`.

**Why not (ii) byte-splice pruning:** still executes the inline `@testset` blocks on every unit run → M0 coverage pollutes every unit's map → can't attribute. Strictly worse. Rejected.
**Why not (iii) config-declared units:** the JuliaSyntax prelude extraction auto-handles the common case; config is speculative surface (YAGNI). Keep as a *documented escape hatch only if* auto-detection proves insufficient on a real target — the "unattributed" fallback already covers detection failure honestly. Not built in v1.

**One-directional honesty (non-negotiable):** a unit whose driver errors / times out → logged + its would-be-blamed survivors fall back to **"unattributed"** (whole-suite covered, no named culprit). **Never falsely blame.**

**Cost:** N×(startup+load) — Julia compile/load dominates each run; per-unit test time is smaller. Sequential, opt-in deep report, NOT the default campaign. Whole-suite `baseline_run` stays the cheap untouched default.

## 5. Falsifiability (per the project rule)

Fixture with: (a) a **weak** test file that *calls* `f` but only `@test true`, plus a source mutant in `f` that survives → D must **blame** that file; (b) a **strong** test file that covers+kills the mutant → must **NOT** be blamed; (c) a test file that doesn't run `f` at all → not blamed. Plus an "unattributed" case: a non-independently-runnable test file → its survivors marked unattributed, never mis-blamed.

## 6. Consult corrections (repo facts both models missed)

- atlas-pro claimed D is "mostly free, reuses existing runs." **False here:** per-test attribution needs N coverage runs (the per-test-runner granularity M1 explicitly punted).
- atlas-pro's "free slice" (covered-vs-uncovered survivor triage) **already ships**: the runner classifies `survived` (covered, not killed) vs `no_coverage` (uncovered). D's genuine new value = *naming the culpable test*, at per-test-coverage cost.
- atlas-flash's A′ "reuse full source operators on tests" is unsound (mutates inputs, not just oracles) — moot now that D is chosen.

## 7. RESOLVED QUESTIONS

1. **§4 approach** → (i) refined (JuliaSyntax prelude). See §4. ✅
2. **Granularity** → test **file / unit** for v1 (one synthetic inline unit for runtests' own `@testset`s). `@testset`-level attribution is future work. ✅
3. **Where it lives** → new `src/coverage.jl` helper `per_unit_coverage(pkgdir; timeout) -> Dict{unit ⇒ CoverageMap}` (reuses `_make_shadow`/`_run_with_timeout`/`_collect_coverage`/`_remap_cmap_to_real`) + new `src/blame.jl` (unit-detection via JuliaSyntax, the survivor→unit join, the report section). Whole-suite `baseline_run` **untouched**. ✅
4. **Opt-in surface** → public API `blame_survivors(result::MutationResult, pkgdir) -> BlameReport` + CLI flag `--blame` (runs a normal campaign then the blame pass). Default campaign unchanged. ✅
5. **Shadow infra** → reuse **one** shadow for all N units, run drivers **sequentially**. Critical: Julia writes `<src>.jl.<pid>.cov` and `_collect_coverage` **unions** all `.cov` it finds → must **delete all `.cov` in the shadow between units** or maps go cumulative. Parallel runs skipped v1 (cov-file collisions; YAGNI). ✅

## 8. Module shape (v1)

- `src/coverage.jl` (+): `per_unit_coverage(pkgdir; test_dir, test_file, timeout)` → `Dict{String ⇒ CoverageMap}` keyed by unit label (`"test_X.jl"`, `"runtests.jl (inline)"`). Errors per-unit captured, not thrown — unit map omitted, surfaced to blame as unattributed.
- `src/blame.jl` (new): `detect_units(runtests_path)` (JuliaSyntax) → prelude source + unit list; `blame_survivors(result, pkgdir)` → join survivors `(relpath,line)` against per-unit coverage → `BlameReport`; `render_blame(io, report)` report section ("Survivors by responsible test", sorted, deterministic; an "Unattributed survivors" tail).
- `src/report.jl` / CLI (`--blame`): wire the new section behind the opt-in flag.

**Next action:** brainstorm complete pending user OK → `superpowers:writing-plans` → subagent-driven execution (eidos-wide flow: no execution-mode choice).
