# Experience Driven Development (EDD)

> **Type:** Software Development Methodology
> **Author:** John + Claude
> **Date:** 2026-03-14 (v0.1), 2026-03-21 (v0.3), 2026-04-11 (v0.4)
> **Status:** v0.4 — Feature Fragility Principle

---

## The Problem With How We Test

Testing methodologies answer progressively better questions:

| Methodology | Question | Discovers |
|-------------|----------|-----------|
| Unit testing | Does this function work? | Logic errors |
| Integration testing | Do these parts work together? | Interface errors |
| TDD | Does the code meet the spec? | Spec violations |
| BDD | Does the code behave as expected? | Behavior mismatches |
| Manual QA | Does a human notice anything wrong? | Obvious UX issues |
| Exploratory testing | What breaks when a human tries weird things? | Edge cases a script wouldn't try |

None of them answer: **What happens when a real person uses this system over time, under real conditions, with real psychology?**

A real user doesn't execute one action in isolation. They build up state over sessions. They develop habits. They get interrupted. They come back after a week and can't remember what they were doing. They try something that worked yesterday and it fails today because the system state changed. They get frustrated and start doing things fast and sloppy. They find workarounds that technically work but corrupt the data model. They use the system in ways the developer never imagined — not because they're creative, but because they misunderstood something on day one and built all their habits on that misunderstanding.

**The gap:** Testing validates correctness. But correctness is necessary and not sufficient. The thing that kills products is the accumulated experience of using them — the friction that builds up, the edge cases that only appear after 50 interactions, the state explosions that only happen when real usage patterns intersect with real failure conditions.

Manual exploratory testing tries to fill this gap but doesn't scale. A human can simulate maybe 30 minutes of use per test session. Real usage patterns emerge over weeks. The math doesn't work.

---

## The EDD Thesis

**Test durability, not just correctness.**

EDD tests whether a system remains correct, responsive, and internally consistent across the full space of possible user trajectories — sequences of actions, over time, under varying conditions, including failure. It does this by evolving simulated user sessions through natural selection, rewarding sessions that discover interesting system states.

**What EDD actually tests:** state-space robustness under evolved action sequences. Data integrity. Performance stability. Recovery after failure. Invariant preservation across thousands of usage paths.

**What EDD does NOT test:** subjective experience. Whether an error message is confusing. Whether the UI is intuitive. Whether the learning curve is acceptable. These require human judgment. EDD replaces the *mechanical* part of exploratory testing (trying lots of action sequences), not the *perceptual* part (evaluating quality of the result). Reduced manual testing, not zero.

The core mechanism: **evolutionary user simulation**. Instead of scripting test cases, you evolve them. Start with random user behavior, define fitness functions that reward "interesting" discoveries (crashes, data inconsistencies, performance cliffs, impossible states), and let natural selection find the edge cases that no human would think to test.

**Time dilation is the key advantage.** One hour of simulation can cover what would take weeks of real usage. Not because the simulation is faster than real-time (it can be), but because it runs thousands of sessions in parallel, each exploring a different trajectory through the system's state space.

### Prior Art and Lineage

| Technique | Origin | What EDD Takes From It |
|-----------|--------|----------------------|
| **Search-based software testing (SBST)** | McMinn 2004, EvoSuite | Evolutionary optimization of test inputs; fitness-guided exploration |
| **Model-based testing** | Erlang QuickCheck, state machine testing | State models, valid/invalid transition coverage, property checking |
| **Grammar-based fuzzing** | AFL, Peach Fuzzer, libFuzzer | Guided input mutation, coverage-tracked evolution |
| **Chaos engineering** | Netflix Simian Army, Chaos Monkey | Fault injection as a first-class testing activity |
| **Session-based test management** | Bach, SBTM | Structured exploratory testing with charter, time-box, and debrief |
| **Property-based testing** | QuickCheck, Hypothesis | Invariant-driven correctness checking, shrinking/minimization |
| **Static call graph analysis** | golang.org/x/tools, Soot, WALA | Structural map of reachable code paths *(v0.2)* |
| **Coverage-guided testing** | AFL, libFuzzer, go-fuzz | Runtime feedback steering exploration toward new paths *(v0.2)* |
| **Lamarckian evolution** | CereBRO nightly loop | Verified findings feed back into generation — acquired traits inherited *(v0.3)* |

**EDD's specific contribution** is the combination: evolving *sessions* (not individual inputs), with *temporal structure* (not single-shot), including *chaos events as genes* (not a separate layer), against *system invariants* (not expected outputs), with *the ratchet* (invariants only grow), guided by *structural intelligence* (not blind — v0.2), validated by *oracle cross-verification* (not self-assessed — v0.3).

### Non-Deterministic Systems

**Fitness noise:** The same chromosome produces different fitness scores. Mitigation: for critical evaluations, run 2-3 times, use median. For routine evolution, accept the noise.

**Flaky findings:** Replay 5 times. Reproduces >=2/5 = confirmed. 1/5 = quarantined. 0/5 = discarded.

**Reproduction confidence:** Every finding gets a reproduction rate in its metadata. 5/5 > 2/5 in severity.

---

## Core Concepts

### 1. The User Genome

A simulated user session is a **chromosome** — an ordered sequence of **genes**, where each gene is one user action.

```
Gene {
    action:    enum    — what the user does (type, click, navigate, wait, etc.)
    payload:   any     — the content of the action (text typed, button clicked, etc.)
    timing:    duration — how long before executing this action
    condition: predicate — optional: only execute if system state matches
}

Chromosome = Gene[]  — a complete user session
Population = Chromosome[]  — many sessions running in parallel
```

The chromosome doesn't encode a test case. It encodes a *usage pattern*. A test case verifies a specific expectation. A usage pattern explores a trajectory without predetermined expectations.

### 2. Fitness Functions (What Makes a Session "Interesting")

EDD tests for **interestingness** — conditions that reveal something about the system not known before.

**Multi-objective fitness function:**

| Objective | Weight | Measures |
|-----------|--------|----------|
| **Invariant violations** | 5.0 | Data consistency rules broken |
| **Recovery failures** | 4.0 | System fails to recover after chaos |
| **State coverage** | 3.0 | Unique system states reached |
| **Code path coverage** *(v0.2)* | 3.0 | New functions reached in the structural map |
| **Target hits** *(v0.2)* | 2.5 | P1/P2 target map functions triggered |
| **Oracle-confirmed findings** *(v0.3)* | 2.5 | Findings that pass external verification |
| **Error diversity** | 2.0 | Unique error types encountered |
| **Performance anomalies** | 2.0 | Response times exceeding baseline by >2sigma |
| **Temporal degradation** | 1.5 | Decline over session length |
| **False positive penalty** *(v0.3)* | -2.0 | Findings rejected by oracle (negative weight) |

The fitness function is the most important design decision. A bad one evolves sessions that are "interesting" in ways that don't matter. A good one finds production incidents before they happen.

**Adaptive weighting** *(v0.2)*: Early generations weight broad exploration (state coverage, code paths) higher. As coverage plateaus, shift weight toward invariant violations and frontier targets. This is a manual knob adjusted at stagnation checkpoints — not a continuous gradient. Automatic reweighting adds complexity without proven benefit.

**False positive penalty** *(v0.3)*: When an oracle is present, findings that the oracle rejects must carry negative fitness weight. Without this, evolution optimizes for detector activation — not for *correct* detector activation. A detector with perfect recall and zero precision will dominate the fitness landscape, and evolution will amplify the wrong signal. The penalty must be strong enough that a chromosome producing 10 unverified findings scores lower than one producing 1 verified finding.

### 3. Evolutionary Operators

**Selection:** Tournament, k=N. Balances exploration with exploitation.

**Crossover:** Single-point. Offspring explores path A leading into path B. Accept incoherent offspring (let selection kill them) in v0, or implement state-aware crossover if premature convergence is a problem.

**Mutation operators:**

| Operator | What It Does | What It Finds |
|----------|-------------|---------------|
| **Action swap** | Change action type | Incorrect handling, missing validation |
| **Payload mutation** | Modify action data | Parsing bugs, encoding, injection |
| **Timing shift** | Change delays | Race conditions, timeouts, queue overflow |
| **Action insertion** | Add random action | Unexpected mid-flow actions |
| **Action deletion** | Remove action | Skipped steps |
| **Chaos injection** | Insert disruption | Resilience, recovery, data integrity |
| **Persona shift** | Change input "personality" | Input diversity |
| **Sequence reversal** | Reverse subsequence | Order-dependent bugs |
| **Duplication** | Repeat same action | Idempotency, duplicate handling |
| **Targeted insertion** *(v0.2)* | Insert sequence aimed at unreached path | Deep code paths missed by organic evolution |

**On "adaptive mutation rates":** v0.1 used a uniform mutation rate across all genes. An appealing v0.2 improvement is *selective* mutation — lower rates for genes on known paths to frontier nodes, higher for genes in saturated regions. This is sound in principle but requires per-gene coverage attribution (execute the chromosome with and without each gene, compare coverage), which costs O(genes) additional executions per chromosome evaluated. For a 50-gene chromosome that's 50x overhead. **Recommendation for v0.2:** Don't implement per-gene adaptive rates. Instead, apply a simpler heuristic: when a chromosome reaches a new frontier node, mark the chromosome as "productive" and apply lower mutation to the whole chromosome in the next generation. This costs nothing extra and preserves productive paths without the attribution overhead.

### 4. System Invariants (The Oracle Problem)

**Data invariants** — structural correctness (valid phases, monotonic transitions, no orphans, consistent counts).

**Behavioral invariants** — the system does what it claims (every action produces expected record, context stays within budget).

**Experience invariants** — interaction quality holds (response time bounded, no empty responses to valid input, no data loss across restarts, no dead ends).

When a session violates an invariant, the chromosome is preserved for reproduction — its genes found something interesting.

### 5. Oracle Design *(New in v0.3)*

An **oracle** is any external verifier that judges whether a finding is real. The system's own detectors/invariant checkers are *internal* judges. An oracle is an *independent* judge — a second opinion from a different frame of reference.

**Why oracles matter:** Internal detectors can be confidently wrong. A contradiction detector that flags rhetorical complexity as logical contradiction is not broken — it's doing exactly what its heuristics say. But the finding is false. Without an oracle, evolution rewards the false finding, breeding more sessions that trigger the same false detector pattern, and the entire pipeline converges on noise.

**Oracle types:**

| Oracle | Cost | Fidelity | Use When |
|--------|------|----------|----------|
| **LLM cross-verification** | Low-medium | Medium | Findings require semantic judgment |
| **Human review** | High | High | Critical findings, ambiguous cases |
| **Differential oracle** | Low | High | Two implementations exist (compare outputs) |
| **Ground truth dataset** | Zero (after construction) | High | Known-good/known-bad examples available |
| **Property oracle** | Low | Variable | Mathematical properties can be checked (e.g., idempotency) |

**Oracle design rules:**

1. **Preserve all evidence.** The verification context sent to the oracle must include every piece of information the detector used to make its claim. If the detector flagged "same-speaker contradiction," the oracle must see speaker attribution. If the detector flagged "circular reasoning across turns 3-7," the oracle must see turns 3-7 in full, with turn boundaries intact. Stripping, truncating, or reformatting evidence between detector and oracle is a guaranteed source of false negatives — the oracle rejects correct findings because it cannot see the evidence.

2. **Match frames of reference.** The detector and the oracle must agree on what constitutes a finding. If the detector defines "contradiction" as "negation of a prior claim by the same speaker" but the oracle interprets "contradiction" as "logically inconsistent argument," they will disagree on nearly everything. **Document the operational definition** shared between detector and oracle. When they disagree persistently, the definition is wrong — fix the definition, not the detector.

3. **Measure oracle agreement rate.** Track the percentage of detector findings the oracle confirms. Below 10% sustained = the detector is broken or the oracle is miscalibrated or (most likely) the frames don't match. Above 80% = the oracle is rubber-stamping, possibly too lenient. Healthy range: 20-60%, depending on detector aggressiveness.

4. **Oracle fallibility.** Oracles are not ground truth. LLM oracles hallucinate. Human oracles have bad days. Differential oracles assume the reference implementation is correct. Every oracle has a false-negative rate (real findings it rejects) and a false-positive rate (fake findings it accepts). Design for this: quarantine findings where detector and oracle disagree strongly, rather than auto-discarding.

### 6. Chaos Engineering Integration

Environmental disruptions as first-class genes. LLM timeout, garbage, refusal. DB latency, full disk. Process kill/restart. Clock skew. Concurrent access. Chaos genes mutate and crossover like user actions. Evolution discovers which chaos + action combinations produce violations.

### 7. The Experience Timeline

Sessions as timelines — sequences with gaps simulating days/weeks.

```
Timeline {
    sessions: [
        { actions: [...], duration: 10min },
        // gap: 4 hours
        { actions: [...], duration: 5min },
        // gap: 2 days
        { actions: [...], duration: 20min },
    ]
}
```

Catches: accumulated state, context loss, data growth, stale state, degradation at session 100 vs session 1.

### 8. Chromosome Shrinking *(New in v0.2)*

When a chromosome violates an invariant, the raw chromosome may be 50-100 genes. A human cannot analyze 100 actions to find the root cause. **Shrinking reduces a violation-producing chromosome to the minimal subsequence that still triggers the violation.**

This is the same principle as QuickCheck/Hypothesis shrinking for property-based testing, adapted to sequential gene execution.

**Algorithm:**

```
Shrink(chromosome, invariant_violated):
    minimal = chromosome
    for i in range(len(minimal)):
        candidate = minimal.without(gene[i])
        reset_system()
        result = execute(candidate)
        if result.violates(invariant_violated):
            minimal = candidate  // gene[i] wasn't necessary
            // restart loop with shorter chromosome

    // Second pass: try removing contiguous blocks (2, 4, 8 genes)
    for block_size in [2, 4, 8]:
        for start in range(0, len(minimal) - block_size):
            candidate = minimal.without(genes[start:start+block_size])
            reset_system()
            result = execute(candidate)
            if result.violates(invariant_violated):
                minimal = candidate
                break  // restart with shorter

    return minimal
```

**Cost:** Shrinking one chromosome costs O(N^2) executions in the worst case (N = chromosome length). For a 50-gene chromosome against a fast system (~100ms per gene), that's ~25 minutes. For a slow system, it's hours. **Shrink only confirmed findings (reproduction rate >= 2/5), not every raw violation.** And shrink *after* the evolutionary run completes, not inline — shrinking is for human analysis, not for evolution.

**Why this matters:** A 50-gene finding that shrinks to 4 genes goes from "undecipherable" to "obviously a race condition between actions 2 and 3 when preceded by action 1 under chaos condition 4." The HARDEN phase's "30-60 minutes per critical finding" budget depends on this.

### 9. Feature Maturity States *(New in v0.4)*

Every feature in the system under test exists in one of three maturity states: **Fragile**, **Hardened**, or **Proven**. This distinction matters for EDD because the harness must calibrate its trust in the system's surface area.

- A **Fragile** feature is newly implemented. It compiles and may pass unit tests, but has not been exercised at scale, under composition with other features, or in production conditions. Most features spend far longer in this state than developers assume.
- A **Hardened** feature has survived integration testing at production scale with intermediate state inspection. Failures have been diagnosed and fixed.
- A **Proven** feature has survived multiple production cycles without regression.

**Why this matters for EDD:** When the harness discovers no violations in a code region, there are two interpretations: (a) the code is robust, or (b) the code is fragile and the harness hasn't exercised it under the conditions that would expose its fragility. Tracking feature maturity disambiguates: if the code region is FRAGILE, interpretation (b) is more likely, and the harness should increase evolutionary pressure on that region — specifically testing it at scale, in composition, and with intermediate state inspection. See "The Feature Fragility Principle" section and Lesson 10 for the full framework and actionable protocol.

---

## Structurally-Guided Evolution (v0.2)

### The Problem With Blind Evolution

EDD v0.1 discovers code paths through behavioral exploration — random mutations lead to new states, fitness rewards novelty, selection breeds the explorers. This works, but has a fundamental limitation: **the GA doesn't know what it doesn't know.**

If a code path requires a specific precondition sequence — inject 3 problems of different categories, triage all to "incubate," wait past a timeout, then trigger a batch review — the probability of random mutation discovering that exact sequence is vanishingly small. The GA will churn through millions of generations without reaching that code. A human reading the source for 5 minutes would say "oh, you need to set up the incubation batch first."

v0.1 explores a dark cave with only a fitness sensor: you know when you find something interesting but don't know what you're missing. v0.2 adds a map: you know what rooms exist, which you haven't entered, and roughly how to reach them.

### The Structural Map

A machine-readable representation of the codebase's function call graph, annotated with priority and coverage status.

```
 StructuralMap {
    nodes: map[FuncID]Node
    edges: []Edge{caller, callee}

    Node {
        id:        string
        name:      string      — human-readable
        file:      string
        line:      int
        tag:       enum        — PUBLIC_API | CRITICAL_PATH | ERROR_HANDLER |
                                  BUSINESS_LOGIC | STATE_MUTATION | INTERNAL_HELPER |
                                  BOILERPLATE
        priority:  enum        — P1 | P2 | P3 | SKIP
        visited:   bool        — has ANY session triggered this?
        visit_gen: int         — generation when first visited (-1 if never)
    }
}
```

**Construction tools by language:**

| Language | Tool | Fidelity | Blind Spots |
|----------|------|----------|-------------|
| Go | `golang.org/x/tools/go/callgraph` (RTA) | High | Interface dispatch, reflection, `go generate` |
| Python | `pyan3`, `pyreverse` | Medium | Dynamic dispatch, decorators, metaclasses, `getattr` |
| JS/TS | `madge` | Low (module-level) | Dynamic imports, `eval`, prototype chains |
| Rust | `cargo-call-stack` | High | `dyn` dispatch, unsafe blocks |
| Java | Soot, WALA | High | Reflection, dynamic proxies |

**Critical honesty about fidelity:** For statically-typed languages, the call graph is reasonably complete. For dynamic languages, it's an approximation with significant gaps. **Document which regions the map misses. Those are the highest-risk unknowns — code that neither the map nor the GA can see.**

If tooling fails: skip to manual entry-point mapping. EDD degrades to v0.1. Still functional, just slower to converge.

### Node Classification

| Tag | Priority | Rationale |
|-----|----------|-----------|
| `PUBLIC_API` | P1 | The attack surface — externally callable |
| `CRITICAL_PATH` | P1 | Between public API and persistent state — where corruption happens |
| `ERROR_HANDLER` | P1 | Catch/recover/fallback — almost never tested |
| `BUSINESS_LOGIC` | P2 | Domain computation/validation |
| `STATE_MUTATION` | P2 | Writes to DB/file/cache — side effects = risk |
| `INTERNAL_HELPER` | P3 | Utility, formatting, logging |
| `BOILERPLATE` | SKIP | Generated, trivial getters/setters |

Classification can be automated heuristically and refined by LLM analysis or human review.

### The Target Map (Pre-Hunt Analysis)

Before evolution begins, analyze the codebase for where bugs are *likely* to live. A prioritized hit list with reasoning.

**Sources of targeting intelligence:**

1. **Structural analysis:** Unvisited P1/P2 nodes with no test coverage.
2. **Complexity metrics:** High cyclomatic complexity, deep nesting. Complexity correlates with defect density (imperfectly, but the signal is real).
3. **Change recency:** `git log` — recently modified functions harbour fresh bugs.
4. **LLM code review:** Feed source to LLM: "Identify functions with subtle edge cases, unenforced invariants, or error handling gaps." Produces weakness analysis with reasoning.
5. **Dependency fan-in/fan-out:** Functions touching multiple state sources. Coordination bugs live at boundaries.

```
Target {
    function:       string
    reason:         string
    estimated_path: []string    — call chain leading here
    priority:       P1 | P2
    preconditions:  []string    — state required before execution
    source:         string      — static | complexity | llm | git | boundary
}
```

**LLM target generation — and its limits:** Expect 30-50% genuinely valuable, 20-30% plausible but uninteresting, 20-40% hallucinated (wrong function names, non-existent paths). **Validation is mandatory.** Cross-reference every LLM target against the structural map. Function not in call graph = discard. The LLM is an unreliable cartographer — valuable for spotting things humans miss, but its output needs surveying.

### LLM-Synthesized Seeds

When an LLM has the structural map AND target map, it can generate *strategic* seed chromosomes — sequences designed to reach specific functions.

**Prompt pattern:**

```
System: Generate test sequences for a software system. Produce a JSON
array of actions that causes execution of the target function.

Context:
- Target: validatePaymentGateway(ctx, amount)
- Path: POST /payments -> processStripe() -> validateGatewayConfig() -> TARGET
- Preconditions: Payment method registered. Amount > 0.
- Available actions: [gene type list with schemas]
- Example valid chromosome: [one complete, valid example]

Generate 3 chromosomes (JSON arrays of genes) that should trigger the target.
```

**Prompt quality matters more than quantity.** The difference between 20% and 60% validation pass rate is usually: (a) including a complete valid example chromosome, (b) including the exact JSON schema with types, not a prose description, (c) including the actual function signature with parameter types. Vague prompts produce hallucinated responses.

**Three-gate validation:**

| Gate | Checks | Fail Action |
|------|--------|-------------|
| **Schema** | Valid action types? Payload well-formed? Timing in bounds? | Discard |
| **Structural** | Referenced endpoints exist in call graph? Sequence logically coherent? | Discard |
| **Smoke** | Execute once. Infrastructure error? | Discard. App error = pass. Hang = discard. |

Application errors (400, validation rejection, business rule violation) are NOT rejection criteria. The GA *wants* error-provoking seeds. Only infrastructure failures indicate a bad seed.

**Expected success rate:** 30-60% pass all gates. Retry failed targets 3x. All fail = mark "LLM-unreachable" — the GA must discover it organically.

### Generation-Detection Alignment *(New in v0.3)*

Seed synthesis and detection are coupled — a generated chromosome only has value if it activates the detectors/fitness evaluators it was designed to trigger. This coupling is non-obvious and is a dominant source of pipeline failure.

**The alignment problem:** A prompt that says "generate a conversation with CIRCULAR_REASONING" produces syntactically valid output, but unless the generator knows the detector's *activation conditions* — required speaker roles, keyword patterns, structural features, minimum turn count — the generated data will pass through the detector without triggering it. The generator and detector are speaking different languages about the same concept.

**Alignment protocol:**

1. **Export detector activation specs.** For each detector/fitness evaluator, document the concrete conditions under which it fires: required data format, field names it inspects, thresholds, structural patterns. This is not optional documentation — it is a machine-readable contract.

2. **Include activation specs in generation prompts.** When synthesizing seeds that target a specific detector, the prompt must include the detector's activation spec. "Generate a conversation that triggers the contradiction detector" fails. "Generate a conversation where speaker=='assistant' makes claim X in turn N and negates X in turn M, with M > N + 2" succeeds — because it matches what the detector actually checks.

3. **Validate activation before evolution.** After seed synthesis, execute each seed through the target detector in isolation. If the seed doesn't activate the detector, it's useless for that objective — mark it as such before wasting evolutionary cycles on it.

4. **Close the loop.** When detectors change (thresholds adjusted, new heuristics), regenerate affected seeds. Stale seeds that targeted the old detector behavior will silently stop working.

### Stagnation Escape via Re-Targeting

v0.1's stagnation response: increase mutation rate, inject fresh randoms. Undirected.

v0.2 adds *directed* escape: detect plateau -> analyze frontier -> re-target with LLM (include context of what's been tried) -> validate -> inject -> resume.

This breaks plateaus that random mutation would take thousands of generations to cross. Not guaranteed — the LLM's reasoning about execution paths is approximate — but when it works, it's transformative.

### Harness Self-Testing *(v0.2, expanded in v0.3)*

The EDD harness is software. It can have bugs. A buggy invariant checker produces false positives. A buggy fitness function wastes evolution on irrelevant objectives. **Before trusting harness output, validate the harness itself:**

1. **Invariant checker validation:** Construct a known-bad system state (manually corrupt the DB). Verify the invariant checker catches it. Construct a known-good state. Verify no false positives.
2. **Fitness sanity check:** Execute a known chromosome (e.g., a happy-path seed). Verify the fitness score is positive and in expected range. Execute an empty chromosome. Verify score is near zero.
3. **Reset verification:** Run a chaos gene that corrupts state. Run ResetSystem(). Verify the system is actually clean — query the DB, check process state, verify health endpoint.
4. **Coverage feedback verification:** Execute a chromosome that calls a known function. Verify the coverage delta includes that function.
5. **Build freshness verification** *(v0.3)*: Before any evolutionary run, verify the system-under-test binary was compiled from the current source. Compare binary mtime against source mtime, or embed a build hash. A stale binary means every finding and every non-finding is invalid — you are testing old code. In nightly/automated loops, always rebuild unconditionally. "Rebuild only if missing" is an anti-pattern; "rebuild if source changed" is minimum; "rebuild always" is safest.
6. **Data format compatibility** *(v0.3)*: Verify that generated test data (seeds, synthetic inputs) actually reaches the detectors in the format the detectors expect. Execute a known-triggering input through the full pipeline and confirm the detector fires. Common failure mode: the generator produces data with field names, speaker labels, or structural conventions that the detector doesn't recognize — the data silently bypasses the system under test. This is the harness-level equivalent of plugging a USB cable into an ethernet port: physically connected, electrically invisible.
7. **Verification text fidelity** *(v0.3)*: When findings are forwarded to an oracle for cross-verification, confirm that the oracle receives the same evidence the detector used. Specifically: speaker attribution intact, full relevant context (not truncated below the detector's window), structural markers preserved. Test this by sending a known-good finding to the oracle and verifying the oracle can see the evidence cited in the finding. If the oracle pipeline strips, truncates, or reformats, fix the pipeline before running evolution.

These checks take minutes and prevent hours of wasted evolution against a broken harness.

---

## The EDD Cycle (v0.3)

```
+---------------------------------------------------------------+
|                      EDD CYCLE v0.3                           |
|                                                               |
|  0. MAP                                                       |
|     Build structural map (call graph + classification)        |
|     Generate target map (static + complexity + LLM)           |
|     Instrument binary for runtime coverage                    |
|     |                                                         |
|  1. MODEL                                                     |
|     Define user actions, system invariants,                   |
|     fitness functions (state + structural + oracle penalty),  |
|     chaos events, oracle configuration                        |
|     |                                                         |
|  2. VALIDATE HARNESS                                          |
|     Test invariant checker, fitness function, reset,          |
|     coverage feedback against known states                    |
|     + build freshness, data format compat,                    |
|       verification text fidelity (v0.3)                       |
|     |                                                         |
|  3. SEED                                                      |
|     Random + happy-path + adversarial + chaos                 |
|     + LLM-synthesized targeted seeds (validated)              |
|     + generation-detection alignment check (v0.3)             |
|     |                                                         |
|  4. EVOLVE                                                    |
|     Select, crossover, mutate                                 |
|     Execute against instrumented system                       |
|     Evaluate fitness (state + structural + invariant)         |
|     Coverage feedback -> frontier -> weight adjustment         |
|     Sensor channel management (enable/disable) (v0.3)        |
|     |                                                         |
|  5. VERIFY (v0.3)                                             |
|     Submit findings to oracle                                 |
|     Confirmed -> high-fitness, preserved                      |
|     Rejected -> negative fitness penalty                      |
|     Disagreement -> quarantine for human review               |
|     |                                                         |
|  6. DISCOVER                                                  |
|     Cluster, replay, shrink (minimal reproducer),             |
|     classify (verified vs. unverified)                        |
|     |                                                         |
|  7. HARDEN                                                    |
|     Fix. New invariant (ratchet). Preserve chromosomes.       |
|     Rebuild binary. Update detector specs.                    |
|     |                                                         |
|  8. EXPAND / RE-TARGET                                        |
|     New feature? -> New actions, invariants, targets          |
|     Stagnated? -> LLM re-targeting of frontier nodes          |
|     Sensor channels to revisit? -> Re-enable with new specs   |
|     -> Return to EVOLVE                                       |
+---------------------------------------------------------------+
```

### The Ratchet Effect

Every finding -> new invariant. Invariant set only grows. System gets harder to break. Evolution forced toward increasingly subtle issues. The ratchet only tightens.

**The ratchet is not free.** Converting finding -> good invariant requires human analysis. Budget 30-60 minutes per critical finding — but only because shrinking reduces the chromosome to a minimal reproducer first. Without shrinking, budget 2-4 hours.

---

## Cost Model

### Compute

| Configuration | Genes/generation | Approx time (local, no LLM) |
|---------------|-----------------|------------------------------|
| 30 x 20 | 600 | ~30 seconds |
| 50 x 50 | 2,500 | ~2 minutes |
| 100 x 100 | 10,000 | ~8 minutes |

Plus: structural map construction (one-time, minutes), coverage query per generation (milliseconds), shrinking per confirmed finding (minutes to hours depending on system speed), oracle verification per finding (seconds to minutes depending on oracle type — v0.3).

### LLM Cost (v0.2)

**With local LLM (Ollama on LAN):** Zero token cost. Constraint is throughput (~30s per call).

**With API LLM:** ~$0.01-0.05 per synthesis call depending on model. Budget: N targets x 3 attempts x $0.03 = ~$1-5 for initial seeding. Re-targeting adds ~$0.50 per escape attempt. Total LLM synthesis cost for a full run: $5-20.

| Activity | LLM calls | Frequency |
|----------|-----------|-----------|
| Target map | 1 per source file (batched) | Once |
| Seed synthesis | 3 per P1/P2 target | Once per target |
| Re-targeting | 3-5 per escape | Rare |
| **Oracle verification** *(v0.3)* | 1 per confirmed finding | Per finding |

### Human Analysis

~2 hours/week for active development. Shrinking reduces per-finding analysis time. The structural map provides immediate context for where in the codebase the violation originates.

---

## Environment Isolation

Chaos events have side effects that survive the session. If generation N corrupts the DB and the reset doesn't fully clean up, generation N+1's findings are tainted.

### What Resets vs. What Persists

**Reset between every generation:**
- System-under-test state (DB, files, caches, config)
- Active chaos effects (disk limits, network injection, killed processes)
- System processes (kill and restart fresh)

**Persists across resets (cumulative over the entire run):**
- The `visited` bitset (which functions have been reached)
- The structural map and target map
- The finding log
- The seed population (elite chromosomes survive across generations)
- Fitness history and convergence metrics
- Sensor channel state (enabled/disabled detectors) *(v0.3)*

### Reset Protocol

Define explicitly for each system. Example for daemon + SQLite:

```
ResetSystem():
1. SIGKILL daemon (if running), wait for exit
2. Delete database file
3. Remove disk limits, network injection
4. Restart dependencies (LLM server, etc.)
5. Start daemon fresh
6. Wait for health check
7. Verify: DB empty, stats report zeros, daemon responds
```

Abort generation if any step fails. Never run against tainted state.

### Build Integrity *(New in v0.3)*

**The stale binary problem:** Automated loops (nightly runs, CI pipelines) often skip rebuilding the system-under-test binary for speed. This means fixes, regressions, and new code paths are invisible to the harness. Hours of evolution run against code that no longer exists in the source tree.

**Protocol:**

```
EnsureFreshBuild():
1. Hash all source files: sha256sum(src/**)
2. Compare against stored hash from last build
3. If different OR no stored hash: rebuild, store new hash
4. If same: skip rebuild (safe)
5. In nightly/unattended mode: ALWAYS rebuild regardless of hash
```

Step 5 is the critical rule. In attended development, hash-checking is fine. In unattended loops, the cost of a redundant rebuild (minutes) is negligible compared to the cost of investigating findings against a stale binary (hours). Always rebuild in automation.

---

## Convergence and Stagnation (v0.3)

| Signal | Indicates | Response |
|--------|-----------|----------|
| Findings = 0 for 20+ gens | May be robust | Expand actions, chaos |
| State coverage plateau | Mutation can't reach new states | Increase mutation, fresh randoms |
| **Code path plateau** *(v0.2)* | GA can't reach new functions | **LLM re-targeting** |
| Mean fitness decreasing | Ratchet working | Continue |
| Diversity < 0.3 | Premature convergence | Mutation up, elitism down |
| **Frontier stuck on P1** *(v0.2)* | Critical code unreached | **Re-targeting + human review** |
| **Oracle rejection rate > 90%** *(v0.3)* | Detectors miscalibrated | **Disable + recalibrate** |
| **Corpus too small for sweep** *(v0.3)* | Statistical noise dominates | **Defer optimization, grow corpus** |

### Sensor Channel Management *(New in v0.3)*

A **sensor channel** is any detector, invariant checker, or fitness evaluator that contributes to the fitness function. In production EDD systems, not all channels are equally reliable. Some have high precision (findings are real), some have high recall but low precision (catch everything, including noise), and some are broken.

**The disable-and-focus strategy:** When multiple sensor channels have wildly different precision, the winning strategy is not to weight them differently — it is to **disable low-precision channels entirely**, focus evolutionary pressure on high-precision channels, build corpus volume with verified findings, and revisit broken channels later with better heuristics.

This is counterintuitive. The instinct is to keep all channels active and tune weights. But a channel with 0% precision and high activation rate will dominate the fitness landscape regardless of its weight — because it fires on everything, it correlates with every chromosome, and selection cannot distinguish signal from noise. Disabling it is not giving up. It is focusing resources on channels that produce actionable information.

**Channel lifecycle:**

```
ChannelState = ACTIVE | DISABLED | CALIBRATING

ACTIVE:      Channel contributes to fitness. Oracle confirms >= 10% of findings.
DISABLED:    Channel excluded from fitness. Re-enable when heuristics improved.
CALIBRATING: Channel runs but does not contribute to fitness. Findings logged
             for offline analysis. Used when testing new detector heuristics.
```

**When to disable:** Oracle confirmation rate below 5% for 3+ consecutive runs. The channel is not finding real things.

**When to re-enable:** After heuristic revision, run in CALIBRATING mode for 1-2 runs. If oracle confirmation rate exceeds 10%, promote to ACTIVE.

### Minimum Corpus Size for Parameter Optimization *(New in v0.3)*

Parameter sweeps (threshold tuning, weight optimization, detector calibration) require a statistically meaningful corpus. Running a sweep on 3 entries produces meaningless results — F1=0 everywhere, or a single lucky hit produces F1=1.0 that collapses on the next run.

**Minimum corpus rules:**

| Optimization type | Minimum corpus | Rationale |
|------------------|---------------|-----------|
| Binary threshold (fire/no-fire) | 30 positive + 30 negative | Binomial confidence interval narrowing |
| Multi-class detector | 20 per class minimum | Per-class precision requires per-class samples |
| Weight optimization across channels | 50 verified findings total | Cross-channel correlation needs volume |
| Full parameter sweep (grid/random) | 100+ verified findings | Combinatorial parameter space needs density |

If you don't have enough corpus: **don't sweep.** Use informed defaults, gather more data, sweep later. Premature optimization of detector parameters on tiny corpora produces overfitted thresholds that fail on the next batch.

### When to Stop

1. **Budget exhaustion.**
2. **Structural convergence** *(v0.2)*: Frontier = only P3/SKIP. All P1/P2 exercised. Zero findings for 3 consecutive full runs. Strongest automated signal.
3. **Manual override** with documented justification.

---

## Metrics (v0.3)

| Metric | What It Measures | Health Signal |
|--------|-----------------|---------------|
| **State coverage %** | Behavioral states reached | Increasing = good |
| **Code path coverage %** *(v0.2)* | Structural map functions reached | Target: >90% P1/P2 |
| **Frontier size** *(v0.2)* | Unreached P1/P2 remaining | Decreasing -> 0 |
| **LLM seed success rate** *(v0.2)* | Passing three-gate validation | <30% = improve prompts |
| **Oracle confirmation rate** *(v0.3)* | Findings confirmed by oracle | <10% = detector problem |
| **Channel precision** *(v0.3)* | Per-detector confirmation rate | <5% = disable channel |
| **Verification yield** *(v0.3)* | Verified findings per evolutionary run | Primary throughput metric |
| **Invariant violation rate** | Violations per gen | Decreasing = ratchet |
| **Mean fitness** | Average | Increasing = harder bugs |
| **Fitness diversity** | Variance | Low = convergence problem |
| **Unique findings per gen** | Discoveries | Decreasing non-zero = healthy |
| **Severity distribution** | Critical / major / minor | Shifting minor = maturing |
| **Shrink ratio** | Raw genes / minimal genes per finding | Lower = more focused findings |

---

## Implementation Architecture (v0.3)

```
edd/
+-- structural/
|   +-- callgraph.go       -- call graph construction + parsing
|   +-- classifier.go      -- node priority classification
|   +-- frontier.go        -- frontier engine
|   +-- coverage.go        -- runtime coverage query + delta
+-- targeting/
|   +-- targets.go         -- target map construction
|   +-- synthesizer.go     -- LLM seed synthesis
|   +-- validator.go       -- three-gate validation
|   +-- alignment.go       -- generation-detection alignment (v0.3)
+-- genome/
|   +-- gene.go
|   +-- chromosome.go
|   +-- timeline.go
|   +-- shrink.go          -- chromosome minimization (v0.2)
|   +-- population.go
+-- evolution/
|   +-- selection.go
|   +-- crossover.go
|   +-- mutation.go
|   +-- engine.go
+-- fitness/
|   +-- invariants.go
|   +-- coverage.go        -- state coverage
|   +-- structural.go      -- code path coverage (v0.2)
|   +-- performance.go
|   +-- scorer.go
|   +-- channels.go        -- sensor channel management (v0.3)
+-- oracle/                -- (v0.3)
|   +-- oracle.go          -- oracle interface + dispatch
|   +-- llm_oracle.go      -- LLM cross-verification
|   +-- diff_oracle.go     -- differential oracle
|   +-- evidence.go        -- evidence preservation + fidelity checks
+-- execution/
|   +-- runner.go
|   +-- client.go
|   +-- observer.go
|   +-- chaos.go
|   +-- build.go           -- build freshness verification (v0.3)
+-- analysis/
|   +-- findings.go
|   +-- clusters.go
|   +-- reports.go
|   +-- regression.go
+-- validation/
|   +-- harness_test.go    -- harness self-tests (v0.2, expanded v0.3)
|   +-- format_test.go     -- data format compatibility tests (v0.3)
|   +-- fidelity_test.go   -- verification text fidelity tests (v0.3)
+-- seeds/
|   +-- random.go
|   +-- patterns.go
|   +-- adversarial.go
|   +-- targeted.go        -- LLM-synthesized (v0.2)
+-- cmd/
    +-- edd/
        +-- main.go
```

---

## Philosophical Notes

**EDD's worldview:** Software fails not because the code is wrong, but because the code doesn't anticipate how people actually use it over time. The gap between "works correctly" and "works durably" is the survivability gap.

**"Experience" is aspirational, not literal.** The simulation tests *system durability*, not *subjective experience*.

**The evolutionary metaphor is literal, not decorative.** EDD evolves usage patterns that survive the system's defenses. The patterns that survive are the ones that break things — and breaking things is the test's job.

**EDD treats bugs as prey, not as failures.** A found bug is a success. An unfound bug is a failure.

**The human stays in the loop** — at the analysis stage, not the execution stage.

**"Structurally-guided" does not mean "structurally-complete."** *(v0.2)* The call graph is an approximation of reality. Dynamic dispatch, reflection, runtime code generation, and framework magic all create paths static analysis cannot see. The map reduces the dark territory; it does not eliminate it. There are always unknown unknowns. Epistemic humility remains non-negotiable.

**"Oracle-verified" does not mean "ground truth."** *(v0.3)* An oracle is a second opinion, not an authority. It reduces false positives but introduces its own biases. The stack — detector, oracle, human — is a chain of progressively more expensive and more accurate filters. Each layer exists because the previous one is insufficient alone.

---

## Lessons from Production (v0.3)

The following lessons were learned from CereBRO's nightly Lamarckian loop — the largest real-world EDD-adjacent pipeline in this workspace. The loop generates synthetic conversations (SEED), processes them through a 5-layer cognitive pipeline with fuzzy-logic detectors (EVOLVE/DETECT), cross-verifies findings with an external LLM (VERIFY), consolidates verified findings into a training corpus (HARDEN), and sweeps detector parameters for optimization (EXPAND). It was not designed using EDD vocabulary, but it implements EDD's core cycle. These lessons are now formal methodology.

### Lesson 1: The Verification Oracle Gap

**What happened:** Detectors (fuzzy-logic heuristics) produced findings with 2% verification yield for weeks. The detectors were correct within their own frame — word-overlap and negation patterns did indicate surface-level contradiction. But the verification oracle (Grok) evaluated findings against a different standard: logical inconsistency in the argument's substance. The frames never aligned.

**Methodology addition:** EDD v0.2's "System Invariants" section assumes invariants can be defined clearly and that violations are self-evident. In practice, the gap between "what the detector thinks is interesting" and "what the oracle agrees is interesting" is the dominant failure mode. This is not a detector bug or an oracle bug — it is a *frame alignment* bug. The new Oracle Design section (Core Concept 5) addresses this with explicit frame documentation and agreement rate tracking.

**Rule:** Before any evolutionary run with oracle verification, write down the operational definition of each finding type. Have both the detector logic and the oracle prompt reference the same definition document. If they can't agree on a definition, the pipeline will not converge.

### Lesson 2: Data Format Bypass

**What happened:** Generated synthetic conversations used speaker names (A, B, Philon, Grace). The pipeline's detectors gated on `speaker=="assistant"`. The entire detector surface was invisible to generated data — every conversation passed through without triggering a single detector, not because the conversations were clean, but because the speaker field never matched.

**Methodology addition:** This is a harness-level bug that would have been caught by harness self-testing if v0.2 had included data format compatibility checks. It has been added as Harness Self-Test item 6 (Data Format Compatibility). The failure mode is: generator and detector are connected in the pipeline graph but disconnected in the data schema. Everything runs, nothing works, no errors appear.

**Rule:** After seed synthesis, execute one known-triggering seed through the full detection pipeline. If the detector does not fire, the format is wrong. Do this before evolution, not after.

### Lesson 3: Stale Binary in Automated Loops

**What happened:** The nightly loop ran a binary built before the latest detector fix because the loop script only rebuilt when the binary was missing, not when source files had changed. Hours of investigation into "why isn't the fix working?" before realizing the fix was never compiled.

**Methodology addition:** Build freshness verification is now Harness Self-Test item 5 and has its own section under Environment Isolation (Build Integrity). The rule is simple: in unattended automation, always rebuild. The cost of a redundant rebuild is minutes; the cost of investigating a stale binary is hours.

**Rule:** `make build` (or equivalent) runs unconditionally at the start of every automated loop iteration. No conditional rebuilds in automation.

### Lesson 4: Precision-Recall Inversion

**What happened:** The contradiction detector had perfect recall (flagged everything that could conceivably be a contradiction) and 0% precision (nothing it flagged was actually a contradiction). Word-overlap + negation heuristics flagged rhetorical complexity — philosophical exploration, argument refinement, thesis-antithesis structure — as contradiction. Without a false-positive penalty in the fitness function, evolution rewarded chromosomes that triggered the detector maximally, amplifying exactly the wrong signal.

**Methodology addition:** The fitness function now includes an explicit false positive penalty (Fitness Functions, new row). Sensor Channel Management (new Convergence subsection) provides the strategy for handling detectors that cannot be fixed immediately: disable them, focus on what works, revisit later. The fitness function table adds a -2.0 weight for oracle-rejected findings.

**Rule:** A detector with high recall and near-zero precision is worse than no detector. It does not contribute noise — it *actively misdirects evolution*. Disable it immediately. Re-enable only after heuristic revision and CALIBRATING-mode validation.

### Lesson 5: Evidence Truncation

**What happened:** When findings were sent to the verification oracle, conversation text was stripped of speaker attribution and truncated to 5 turns / 2000 characters. The oracle couldn't verify claims about "same-speaker contradiction" because it couldn't see who said what. It couldn't verify "circular reasoning across turns 3-12" because it could only see turns 1-5.

**Methodology addition:** Oracle Design Rule 1 (Preserve all evidence) and Harness Self-Test item 7 (Verification text fidelity) directly address this. The principle: the verification context must be a superset of the evidence the detector used, never a subset.

**Rule:** The oracle context construction function must be tested independently: given a finding that references specific evidence, verify the constructed context contains that evidence verbatim. Truncation and formatting are bugs, not optimizations.

### Lesson 6: Disable-and-Focus as Convergence Strategy

**What happened:** With 5 detector channels active, 4 had <5% oracle confirmation rate. Keeping all 5 active meant 95% of evolutionary pressure was wasted on noise. Disabling 4 and focusing on the 1 working channel immediately raised verification yield from 2% to 40%+ for that channel. Corpus volume grew. Parameter sweeps became meaningful. The disabled channels were revisited weeks later with revised heuristics.

**Methodology addition:** Sensor Channel Management (new Convergence subsection) formalizes the channel lifecycle: ACTIVE -> DISABLED -> CALIBRATING -> ACTIVE. EDD v0.2's adaptive weighting section only described shifting fitness weights — it did not describe disabling entire channels as a legitimate strategy. It is now the *recommended* strategy when channel precision is below 5%.

**Rule:** Do not spend evolutionary cycles on broken detectors. Disable, focus, produce results, fix broken detectors offline, re-enable in CALIBRATING mode.

### Lesson 7: Generation-Detection Coupling

**What happened:** Prompts saying "generate a conversation exhibiting CIRCULAR_REASONING" produced conversations that a human would call circular — but the circular reasoning detector required specific structural features (repeated claim patterns across turns with specific speaker roles) that the generator didn't know about. The generated data was semantically circular but structurally invisible to the detector.

**Methodology addition:** Generation-Detection Alignment (new subsection under Structurally-Guided Evolution) formalizes the coupling between generators and detectors. Detector activation specs must be exported and included in generation prompts. This is the generation-side equivalent of the v0.2 principle that LLM seed prompts must include exact JSON schemas — but applied to the semantic level, not just the syntactic level.

**Rule:** Every detector must publish its activation contract. Every generator must consume it. "Generate something that triggers detector X" is not a valid prompt. "Generate something matching detector X's activation spec" is.

### Lesson 8: Minimum Corpus for Parameter Sweeps

**What happened:** Running a Forge parameter sweep (threshold optimization) on 3 verified entries produced F1=0.000 across all parameter combinations. The sweep was statistically meaningless — there weren't enough data points for any threshold to demonstrate precision-recall tradeoff. Time was wasted analyzing empty results.

**Methodology addition:** Minimum Corpus Size for Parameter Optimization (new Convergence subsection) provides concrete minimums: 30+ for binary thresholds, 100+ for full sweeps. The rule: if you don't have enough corpus, don't sweep. Use informed defaults and grow the corpus first.

**Rule:** Before any parameter sweep, check corpus size against the minimum table. If below threshold, skip the sweep and log "deferred — insufficient corpus." This is not a failure; it is correct methodology.

### Lesson 9: Recognize and Retrofit

**What happened:** CereBRO's nightly Lamarckian loop implements the full EDD cycle — generate (SEED), process (EVOLVE), verify (VERIFY, new in v0.3), consolidate (HARDEN), sweep (EXPAND) — but was designed independently, without EDD vocabulary. The mapping was only recognized after 3 weeks of operation.

**Methodology observation:** Many real systems implement EDD patterns without knowing it. Any pipeline that generates test inputs, evaluates them against heuristic quality measures, and feeds results back into the next generation is performing evolutionary testing. The vocabulary doesn't matter. The structure does.

**Retrofit checklist** — for identifying EDD patterns in existing systems:

| EDD Concept | Look For | If Missing |
|-------------|----------|------------|
| Chromosome | Structured test input (conversation, request sequence, scenario) | Define the gene/chromosome mapping |
| Fitness function | Quality score, acceptance criteria, pass/fail heuristics | Make scoring explicit and multi-objective |
| Selection | "Keep the good ones" logic (elite preservation, top-N) | Add tournament or rank selection |
| Mutation | Parameter variation, prompt perturbation, noise injection | Add mutation operators to the generation step |
| Oracle | External verification step (LLM review, human review, differential test) | Add one — self-assessment is insufficient |
| Ratchet | "Never regress" rule, growing test suite, accumulating corpus | Add invariant preservation after each verified finding |
| Sensor channels | Multiple detectors/evaluators with different reliability | Add channel management (enable/disable/calibrate) |
| Build integrity | Rebuild step in automation loop | Add unconditional rebuild |

If an existing system maps to 5+ of these concepts, it is an EDD instance. Apply the methodology's lessons rather than redesigning from scratch.

### Lesson 10: Feature Fragility (The Implementation-to-Production Gap)

**What happened:** Four independent bugs in PATMOS (evolutionary GPU computation) shared the same failure pattern: features that compiled, appeared to work in limited testing, and silently failed under production conditions. Each was "implemented" for days or weeks before the failure was discovered.

1. **Crossover field destruction:** `genome_crossover()` used `memset(child, 0, ...)` then manually copied selected fields — but thought programs, broadcast wiring, meta-modulation, and consolidation fields were silently zeroed. Unit tests never exercised crossover paths. Every generation for weeks destroyed heritable thought programs. Only discovered when inspecting genomes at C=720 scale.

2. **Type overflow at scale:** `inter_tgt` was `uint8_t`. At C<=255, everything worked perfectly. At C=512+, targets silently wrapped to `target % 256` — the upper half of the brain was unreachable. Invisible until someone asked *why* C=512 was stuck, not just *whether* it was stuck.

3. **Scope visibility bug:** External memory code was "already implemented" — flag parsing, buffer allocation, kernel logic all existed. But a critical variable was local to `main()` yet used in helper functions. It never compiled. Nobody noticed because `--ext-mem` was never tested on GPU.

4. **Process tree assumption:** Worker preemption logic used `$!` after `bash script | tee log &` — capturing tee's PID, not bash's. The worker logged "PREEMPTING" but SIGTERM never reached the actual compute process. The log said it worked. It did not.

**Methodology addition:** The Feature Fragility Principle (Core Concept 9) formalizes three maturity states for every feature: Fragile, Hardened, Proven. The gap between "compiles and passes tests" and "works at scale in production" is where the most expensive bugs live. Dev tests are necessary but never sufficient — they validate the feature in isolation, under ideal conditions, at toy scale. The bugs above all share a common property: they require *composition* (crossover + field propagation), *scale* (C>255), *real execution* (GPU compilation), or *realistic process topology* (pipeline vs single process) to manifest.

**Rule:** Every newly implemented feature starts as FRAGILE. Do not treat "implemented" as "working." Require explicit promotion through scale testing, composition testing, and intermediate state inspection before marking a feature as HARDENED. Track maturity state in ROADMAP.yaml or equivalent.

---

## The Feature Fragility Principle *(New in v0.4)*

A feature transitions through three maturity states:

| State | Definition | Evidence Required |
|-------|-----------|-------------------|
| **Fragile** | Compiles. May pass unit tests. Has NOT been exercised at scale, under composition with other features, or in production conditions. | Code exists, basic tests pass |
| **Hardened** | Has been exercised at scale, under realistic conditions. Integration failures diagnosed and fixed. Intermediate state inspected, not just final output. | Scale test logs, composition test results, intermediate state dumps |
| **Proven** | Has survived multiple production cycles without regression. Data proves it works across the full operating range. | Production run history, no regressions across N cycles |

**Treat as "probably broken in ways you can't predict"** until proven otherwise. The bugs that survive longest are the ones that pass all the tests you thought to write.

### Common Fragile Failure Modes

| Failure Mode | Mechanism | Detection Strategy |
|-------------|-----------|-------------------|
| **Missing field propagation** | `memset` + selective copy; new struct fields not added to copy/clone/crossover/serialize paths | Dump full struct before and after every operation that creates a new instance. Diff the fields. |
| **Type overflow at scale** | `uint8_t` holding values that exceed 255 at production scale but not at test scale | Test at 2x the maximum intended scale. Grep for narrower-than-necessary integer types in fields that scale with system size. |
| **Scope/visibility bugs** | Variable declared in wrong scope, function signature mismatch, ifdef-excluded code | Compile and execute with ALL optional features enabled simultaneously. A feature that is never compiled is never tested. |
| **Process tree assumptions** | `$!` captures wrong PID in pipelines; signals sent to wrapper not worker; log says "done" but process still running | After every process management operation, verify the target process actually changed state. `kill -0` the PID. Check `/proc`. Never trust log messages alone. |
| **Composition blindness** | Feature A works. Feature B works. A+B fails because A's output is B's input and the interface was never tested together. | Explicitly test every pairwise feature combination that shares state. Crossover is composition. Serialization is composition. Config parsing + kernel launch is composition. |

### Actionable Protocol

1. **Mark maturity in tracking.** When a feature is implemented, mark it as `fragile` in ROADMAP.yaml or the task tracker. Do not mark it `done` or `complete` — mark it `implemented (fragile)`.

2. **Require scale-test for promotion.** A feature moves from Fragile to Hardened only after:
   - Execution at production scale (not toy scale)
   - Execution in composition with related features (not in isolation)
   - Inspection of intermediate state (not just final output)
   - At least one failure mode from the table above explicitly checked

3. **Inspect intermediate state, not just output.** The crossover bug produced correct *output* (the child genome existed, had valid structure, passed fitness evaluation). The *intermediate state* was wrong (thought programs were zeroed). Output-only testing misses propagation failures. Dump and diff internal state at every transformation boundary.

4. **Compile with all flags.** If a feature is behind a flag, compile and run with that flag enabled in CI or the automated test loop. Code that is never compiled is guaranteed fragile.

5. **Test at 2x intended scale.** If the system targets C=720, test new features at C=1440 or at least verify type widths accommodate it. Scale bugs hide below the overflow threshold.

6. **Verify process management end-to-end.** After kill/restart/preempt operations, confirm the target process actually died and the new one actually started. Log messages are claims, not evidence.

---

## Changelog

| Version | Date | Summary |
|---------|------|---------|
| v0.1 | 2026-03-14 | Core thesis, evolutionary operators, fitness functions, chaos integration, convergence |
| v0.2 | 2026-03-14 | Structural guidance (call graph, target map, LLM seeds), chromosome shrinking, harness self-testing, coverage-guided evolution |
| v0.3 | 2026-03-21 | Oracle design, sensor channel management, build integrity, generation-detection alignment, minimum corpus rules, 9 production lessons from CereBRO Lamarckian loop, false positive penalty in fitness, expanded harness self-testing, recognize-and-retrofit guide |
| v0.4 | 2026-04-11 | Feature Fragility Principle — three maturity states (Fragile/Hardened/Proven), common fragile failure modes, actionable protocol for promotion. Production lesson 10 from PATMOS evolutionary GPU pipeline (crossover field destruction, type overflow at scale, scope visibility bugs, process tree assumptions) |
