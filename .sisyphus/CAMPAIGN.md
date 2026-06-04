# Sisyphus Coverage Campaign

Replaces the recurring `/loop` with a deliberate sweep that runs
the certification cascade against every chunk in the codebase.

## Loop status

**Cancelled** — `/loop 15m do another polish round` (job `d7b69eb8`)
deleted 2026-05-30. Reasoning recorded in
`.sisyphus/PASS_LOG.md` § retrospective post-pass-47.

The recurring loop served well through passes 1-30. After that,
diminishing returns set in (documented across the literal-artifact
calibration passes). The certification protocol gives us a real
"done" signal; running it deliberately, chunk by chunk, replaces
the time-based cadence with a quality-based one.

## Current state

| Bucket                    | Count |
|---------------------------|-------|
| Total source chunks       | 135   |
| In coverage ledger        |  58   |
| `done-ceiling` (≥0.80 all)|  37   |
| `visited` not done        |  21   |
| **Unvisited (frontier)**  | **77** |

## Campaign phases

### Phase A — Maze coverage

Goal: every chunk in the repo has a `coverage.jsonl` entry.

For each unvisited chunk surfaced by `pick_next_chunk.sh`:

1. Run the three scorers (`score_file_size.sh`, `score_complexity.sh`,
   `score_doc.sh`)
2. If all three ≥ 0.80, append `done-ceiling` to coverage; move on
3. Otherwise apply one focused refactor pass; re-measure; record
   the resulting status

Expected throughput: 5-15 minutes per chunk. 77 chunks → ~10-20
hours of agent time spread across sessions.

Exit condition: picker returns `NO_WORK` or all unvisited chunks
have been visited at least once.

### Phase B — Certification sweep

Goal: every `done-ceiling` chunk earns a `card.md` via the 5-tier
cascade.

For each chunk with `done-ceiling` status:

1. Run `certify_chunk.sh <chunk>`
2. If the cascade stops at T3, write the `<chunk>.spec.md` from
   the template + the actual function-level behaviour summary;
   re-run
3. If the cascade stops at T5, write the `<chunk>.adversarial.md`
   with ≥ 3 proposals + REJECTED verdicts; re-run
4. On all-pass, the card lands; chunk is certified

Expected throughput: 10-30 minutes per chunk depending on tier
complexity. ~37 chunks → roughly 10-15 hours of agent time.

Exit condition: every chunk in the repo has a `card.md`.

### Phase C — Hardening pass

Goal: any chunk whose certification falters under scrutiny gets
re-opened.

Mechanism: pick a sample of cards (e.g. 5 oldest) per session
and run an adversarial agent against them. Successful challenges
land as new ACCEPTED proposals → cards expire → chunks re-enter
the pipeline.

## Session protocol

Each session starts with:

```bash
.sisyphus/scripts/pick_next_chunk.sh       # which chunk?
.sisyphus/scripts/certify_chunk.sh <chunk> # how far does cascade go?
```

Then the agent does one focused action:
- Phase A unvisited: refactor or accept
- Phase B done-ceiling: write spec OR adversarial OR run certify
- Phase C certified: challenge

Append one line to `coverage.jsonl` recording the action +
resulting state. Append one PASS_LOG entry recording the
reasoning. Commit + push.

No clock. No cadence. Each session is one named step in the
campaign with one named output artifact.

## Tracking

Per-session: append-only `.sisyphus/coverage.jsonl`. Each line is
one (chunk, action, status) triple.

Per chunk: progress lives in `.sisyphus/certified/<chunk>.*.md`
files. The progress file is the agent's working memory between
sessions.

Per-pass narrative: `.sisyphus/PASS_LOG.md` continues with the
"campaign" entries instead of "polish-round" entries.

## When does the campaign end?

When every chunk in `find debate api store llm auth -maxdepth 1
-name '*.go' -not -name '*_test.go'` has a `.card.md` in
`.sisyphus/certified/`, AND no recent challenge has invalidated
a certification.

Honest estimate: 20-40 hours of agent time across multiple
sessions. Maybe more if mutation testing surfaces real bugs.

The campaign produces something the polish loop never did: a
written, signed-off claim about every file in the codebase, with
recorded reasoning for each rejection of "could be better."
