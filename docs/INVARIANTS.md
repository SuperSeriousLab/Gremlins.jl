# Gremlins — System Invariants

### I1 — Source restoration is absolute
After any run (success, error, SIGINT), every mutated file is byte-identical
to its original. Patcher works on copies by default; in-place mode restores in
`finally`. Gold-benign: run on pristine repo → `git status` clean after.

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

## Adversarial surface
- Malicious/weird source (Unicode identifiers, nested string macros, `quote`
  blocks) must not panic discovery — skip-with-note, never crash.
- Mutants inside `@eval`/`@generated`/macro definitions: classified `skipped-macro`
  in v1, never silently mutated.
- Test suites that fork/daemonize: runner must reap children (process-group kill).
