# Sisyphus Scheduler

Two-phase chunk picker introduced **post-pass-47** to fix the
metric-chasing drift recorded in the retrospective at the end of
pass 47. Replaces the implicit "pick worst chunk by score" with a
coverage-first rule that lets the protocol terminate.

## The escape clause

A chunk is **marked done** and skipped in future rotations when any
of the following holds:

| Condition                              | Status              |
|----------------------------------------|---------------------|
| All 3 dim scores ≥ 0.80                | `done-ceiling`      |
| Last-pass score delta < 0.05           | `done-diminishing`  |
| Visit count ≥ 3                        | `done-budget`       |
| Agent records "lost cause" in PASS_LOG | `lost-cause`        |

`0.80` is the "good enough" line. The protocol stops sinking
work into a chunk that already meets the bar.

## Two phases

### Phase 1 — Coverage

Walk every Go source file in `debate/`, `api/`, `store/`, `llm/`,
`auth/`. **Prefer unvisited chunks** over visited ones, even when
the visited chunks score lower. The loop covers the codebase
once before re-touching anything.

### Phase 2 — Done

Picker emits `NO_WORK` when every chunk has at least one done
entry. The `/loop` stops requesting new passes. User can opt in
to additional polish ("push every 0.80 to 1.0") via a follow-up
manual run, but the default is acceptance.

## Files

- **`.sisyphus/coverage.jsonl`** — append-only ledger of
  `{chunk, status, reason, scores, visit_count, ts}` entries. One
  line per chunk-visit. The latest entry per chunk wins.
- **`.sisyphus/scripts/pick_next_chunk.sh`** — reads coverage +
  walks the file tree, prints the next chunk to work on, or
  `NO_WORK` when phase 2 reached.
- **`.sisyphus/scripts/bootstrap_coverage.sh`** — one-shot seed
  from the existing ledger entries. Run once after introducing
  the scheduler.

## Pick output format

Single line on stdout, tab-separated:

```
<status>\t<chunk>\t<reason>
```

Statuses: `PICK` | `NO_WORK`.

## Loop integration

Update the `/loop`-driven prompt to consult the picker first:

```bash
result=$(.sisyphus/scripts/pick_next_chunk.sh)
status=$(echo "$result" | cut -f1)
case "$status" in
  PICK)     chunk=$(echo "$result" | cut -f2); proceed with chunk ;;
  NO_WORK)  exit cleanly — protocol terminal state ;;
esac
```

Each pass appends one entry to `coverage.jsonl` recording the
chunk it touched + the resulting status. The next pick consults
the updated coverage.

## Per-pass entry shape

```json
{
  "chunk": "file:debate/integrity.go",
  "status": "done-ceiling",
  "reason": "all-dims-at-or-above-0.80",
  "file_size": 1.0,
  "complexity": 1.0,
  "doc_accuracy": 1.0,
  "visit_count": 1,
  "ts": "2026-05-30T10:43:47Z"
}
```

## Honesty about the scheduler

The two-phase rule guarantees the protocol terminates in finite
loop fires. The 0.80 ceiling captures "good enough" without
chasing literal-counting artifacts (see passes 29-47). The
visit-count budget protects against unbounded polish loops on
genuinely-hard chunks.

What it doesn't do: detect that a metric is itself broken. The
`score_complexity.sh` brace-counting issue documented across
passes 29-47 still requires the script-side fix that's queued
but not yet shipped. The scheduler stops over-polishing under
the current metric; it doesn't replace the metric.
