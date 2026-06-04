# Sisyphus Certification

Cascading 5-tier gate that produces an artifact stating "no further
improvement available under the current measurement framework."
Certification is **defeasible** — anyone can challenge it by
submitting a refactor that improves a signal without worsening any
other. The artifact records what was tried and why each
counterproposal was rejected.

## The cascade

Tiers run in order, fail-fast — a tier returning non-zero stops the
cascade so cheap checks screen out chunks before expensive ones
run. Same shape as SLR's circuit breaker: cheap → expensive,
short-circuit on first failure.

| Tier | Cost     | What it checks                                                    |
|------|----------|-------------------------------------------------------------------|
| T1   | seconds  | Internal metric floor — all 3 dim scores ≥ 0.85                   |
| T2   | seconds  | External tools clean — go vet + gocyclo + ineffassign + staticcheck |
| T3   | ~30s     | Behavioural spec present + ≥ 80 chars of Behaviour prose          |
| T4   | minutes  | Coverage ≥ 80% + mutation killed ≥ 70% (gremlins.dev)             |
| T5   | 5-10 min | Adversarial review — ≥ 3 REJECTED proposals, 0 ACCEPTED           |

Each tier:

```
PASS\t<tier-id>\t<reason>     # exit 0, cascade continues
FAIL\t<tier-id>\t<reason>     # exit 1, cascade stops
```

## Tier soft-fail behaviour

- **T2**: tools that aren't installed are skipped (logged but not
  failed). Keeps the gate runnable on developer machines without
  the full toolchain. The certification card records which tools
  ran.
- **T4**: when no mutation tool is available, T4 soft-passes with
  a caveat in the card. The chunk is provisionally certified;
  re-running with gremlins.dev installed strengthens the gate.
- **T1, T3, T5**: hard-required. No soft-pass.

## Required artifacts

T3 reads `.sisyphus/certified/<chunk_safe>.spec.md`.
T5 reads `.sisyphus/certified/<chunk_safe>.adversarial.md`.

`chunk_safe` = the chunk path with `/` replaced by `_`. For
`debate/runner_unified.go` → `debate_runner_unified.go`.

### Spec template

```markdown
# Spec: debate/runner_unified.go

## Behaviour

<≥ 80 characters describing what the file does in plain English.
Name the entry-point function. Name the contract with callers.
Name failure modes. This is the benchmark — without it, future
"improvement" claims have nothing to compare against.>

## Invariants

- <named invariant 1>
- <named invariant 2>

## Contract

- Inputs: ...
- Outputs: ...
- Side effects: ...
```

### Adversarial template

```markdown
# Adversarial review: debate/runner_unified.go

Each numbered proposal records a refactor the reviewer considered.
A proposal is REJECTED when applying it would degrade ≥ 1 signal
without strictly improving any other (Pareto-frontier check).
A proposal is ACCEPTED when applying it WOULD improve the chunk —
in which case it should be applied, not certified around.

1. **REJECTED** — Inline buildReasonedSession into the entry function.
   - Would: save 1 function, save ~5 LOC
   - Cost: depth 3 → 4 in the entry function, breaks the snapshot
     pattern shared with finalizeReasonedDebate

2. **REJECTED** — Combine runReasonedPremise + runReasonedPosition.
   - Would: reduce function count by 1
   - Cost: phase-specific log labels stop matching; combined
     function's body would re-introduce the if-phase=premise split

3. **REJECTED** — Drop the cancelIfDone guards inside per-phase wrappers.
   - Would: ~6 LOC saved
   - Cost: cancellation propagation stops working — debate continues
     running phases after cancel, failing the contract with the user
```

## The card

When all 5 tiers pass, `certify_chunk.sh` writes
`.sisyphus/certified/<chunk_safe>.card.md`:

```markdown
# Certified: file:debate/runner_unified.go

**Commit:** <sha>
**Certified at:** <ts>

## Signal agreement

- PASS  t1-metrics      fs=1.0 cx=1.0 dc=1.0
- PASS  t2-tools        4 tools clean
- PASS  t3-spec         spec 312 chars
- PASS  t4-mutation     coverage=87% killed=81%
- PASS  t5-adversarial  5 proposals, 5 REJECTED, 0 ACCEPTED

## Behavioural spec
See `.sisyphus/certified/debate_runner_unified.go.spec.md`.

## Adversarial review
See `.sisyphus/certified/debate_runner_unified.go.adversarial.md`.

## Expiry
Any change to debate/runner_unified.go re-opens certification.
```

## When the cascade stops

Failed cascades write a `.progress.md` file documenting which
tier stopped + last results. The next agent pass reads the
progress file to know which artifact to populate or which refactor
to apply.

```markdown
# Certification progress: file:debate/runner_unified.go

**Last attempt:** <ts> @ <sha>
**Stopped at:** certify_t3_spec
**Reason:** FAIL  t3-spec  no spec at .sisyphus/certified/debate_runner_unified.go.spec.md

## Tier results so far
- PASS  t1-metrics      fs=1.0 cx=1.0 dc=1.0
- PASS  t2-tools        1 tools clean
- FAIL  t3-spec         no spec at ...
```

Next agent pass writes the spec + reruns the cascade.

## How certification interacts with the scheduler

| Scheduler status        | Certification eligible? |
|-------------------------|-------------------------|
| `unvisited`             | No — visit first        |
| `visited`               | Maybe — depends on dim scores |
| `done-ceiling`          | **Yes — top priority for certification** |
| `done-diminishing`      | Yes — cascade may surface improvements |
| `done-budget`           | No — visit budget exhausted |
| `lost-cause`            | No — agent's verdict respected |
| `certified`             | Already done             |

The scheduler picks unvisited chunks first; once those are
covered, it picks `done-ceiling` chunks for certification.

## Honest assessment

This protocol stops a chunk from being polished further. It does
not prove "no improvement exists" in any absolute sense. It
proves: "at this commit, with these tools, no reviewer found an
improvement that the metrics and tests would accept."

The "expiry on any change" rule means certification is a snapshot,
not a permanent badge. If the codebase changes, certification is
revoked.

The most honest framing: certification is a **falsifiable claim**.
A successful challenge becomes the next pass's work. That's the
artisan-craft answer to "cannot be improved further" — the boulder
is shaped by the climb; certification is a shape, not an end.
