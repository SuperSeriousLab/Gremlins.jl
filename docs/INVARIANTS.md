# Gremlins — System Invariants

### I1 — The real package tree is NEVER written by mutation runs
All mutation execution happens inside a disposable shadow copy of the package
directory (created via `mktempdir()` once per run). The real source tree is
read-only from the runner's perspective — no apply!/revert! ever touches it.

**Why not try/finally restore?** In-process try/finally is not crash-safe:
SIGKILL and OOM-killer bypass finally blocks entirely. Production incident
2026-06-04: an M1 cold runner left live mutants in a sibling project's working
tree overnight after its driver process was SIGKILLed mid-mutant.

**The shadow asymmetry:** a leaked shadow tmpdir on SIGKILL is harmless garbage
in /tmp. A corrupted real source tree is a correctness failure. The shadow design
converts the latter to the former.

**Cache stays real-side:** `.gremlins_cache.json` is read and written in the real
pkgdir. Content hashes are computed from real files (unchanged since shadow is
byte-identical). The cache is never mutated by the runner.

**Warm path:** the M2b warm worker already evals in-memory (disk never written).
Shadow applies to cold execution paths only (run_mutations, _run_cold_single,
baseline_run).

Gold-benign: run on pristine repo → `git status` clean after (real tree
untouched, shadow cleaned up in finally — SIGKILL leaves harmless tmp orphan).

### I2 — Mutant enumeration is deterministic
Same source tree → identical ordered mutant list (ids stable across runs and
machines). No randomness, no dict-order dependence, no mtime input.

### I3 — A killed mutant is provably killed
"Killed" requires a captured failing-test identity, not a nonzero exit alone
(distinguish: test failure = killed; compile error = unviable; timeout = timeout;
no covering test = no-coverage). Misclassification of unviable as killed inflates
scores — unacceptable.

### I4 — The tool never executes mutated code during discovery
Discovery/patching is purely static. Execution happens only in the runner with
explicit user invocation (mutants can trigger arbitrary side effects; default
runs in a tmp copy of the package tree).

### I5 — Latency bound
Discovery on a 10kLOC package completes < 10 s (static parse only). Runner
overhead per mutant (excluding test time) < 2 s on the warm path.

### I6 — Schema baseline ≡ plain baseline or hard error
The schema-instrumented baseline (`__GREM_ACTIVE[]=0`) must produce the same
observable outcome as the un-instrumented plain baseline. If the instrumented
function (with all mutation branches dormant) causes any test to fail that the
plain baseline passes, `run_mutations_schema` throws `MutationError` immediately.

**Why:** Schema instrumentation wraps expressions in ternaries:
`__GREM_ACTIVE[] == k ? mut : orig`. With key=0, the `orig` branch fires and
the function should be observationally identical to its un-instrumented form.
Any divergence means the instrumentation itself changed behavior (e.g. side
effects in the mutated expression, type instability changing dispatch). This
is a correctness failure that must be surfaced loudly rather than silently
producing false-survived results.

**Implementation:** Step 4 of `run_mutations_schema` runs the test suite with
`__GREM_ACTIVE[]=0` immediately after instrumenting each function group. Outcome
must be `survived`. Any other outcome (killed, timeout, error) triggers the
hard error — the affected schema sites are NOT silently demoted to warm.

**Gold-benign:** a plain package with no instrumentation-visible side effects
will always pass I6. Failure indicates a real instrumentation correctness problem
requiring investigation (not a production incident to paper over).

## Adversarial surface
- Malicious/weird source (Unicode identifiers, nested string macros, `quote`
  blocks) must not panic discovery — skip-with-note, never crash.
- Mutants inside `@eval`/`@generated`/macro definitions: classified `skipped-macro`
  in v1, never silently mutated.
- Test suites that fork/daemonize: runner must reap children (process-group kill).
