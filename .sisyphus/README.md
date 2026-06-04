# Sisyphus — Per-Chunk Certification (Project Install)

Drop-in copy of the Sisyphus polishing protocol. Reference doc:
`/home/js/eidos/docs/methodology/SISYPHUS_PROTOCOL.md`. Battle-tested
reference implementation: `/home/js/eidos/DORIANG/.sisyphus/`.

## What this is

A 5-tier cascading certification protocol for every source chunk in the
project. Each chunk earns a falsifiable cert (`.card.md`) with a written
spec (`.spec.md`) and adversarial proposals (`.adversarial.md`). Certs
expire the moment the chunk changes.

Tiers run cheapest-first; expensive tiers don't fire when cheap ones fail.

## 5-minute setup

1. Copy this directory into your project:
   ```bash
   cp -r /home/js/eidos/project-scaffold/templates/sisyphus .sisyphus
   ```
2. Edit `.sisyphus/config.sh` — set `SISYPHUS_PACKAGES` to the source
   directories you want to certify. Defaults: `cmd internal pkg`.
3. (Optional, Go) Install the external tools T2 looks for:
   ```bash
   go install honnef.co/go/tools/cmd/staticcheck@latest
   go install github.com/fzipp/gocyclo/cmd/gocyclo@latest
   go install github.com/gordonklaus/ineffassign@latest
   ```
4. (Optional, Go) Install gremlins for T4 mutation:
   ```bash
   go install github.com/go-gremlins/gremlins/cmd/gremlins@latest
   ```
5. Bootstrap:
   ```bash
   .sisyphus/scripts/bootstrap_coverage.sh
   .sisyphus/scripts/sweep_all.sh
   ```
6. Open `.sisyphus/dashboard.html` — every cell that lights gold is
   certified.

Tools that aren't installed are soft-passed with a recorded note. The
protocol degrades gracefully — never blocks on missing infrastructure.

## Daily loop

```bash
# Pick the worst-scoring unvisited chunk; falls back to worst visited.
chunk=$(.sisyphus/scripts/pick_next_chunk.sh)
[ "$chunk" = "NO_WORK" ] && echo "all caught up" || \
  .sisyphus/scripts/certify_chunk.sh "$chunk"
```

When `pick_next_chunk.sh` emits `NO_WORK`, the coverage-first scheduler
has run out of chunks under the done-ceiling. The boulder is at rest.

## Layout

```
.sisyphus/
├── config.sh                   # CONFIGURE THIS — paths, thresholds
├── CERTIFICATION.md            # Cascade reference (T1-T5 details)
├── SCHEDULER.md                # Coverage-first picker spec
├── SCHEMA.md                   # Score record format
├── CAMPAIGN.md                 # Phase A/B/C workflow
├── scripts/
│   ├── pick_next_chunk.sh      # Scheduler
│   ├── certify_chunk.sh        # Cascade driver
│   ├── certify_t1_metrics.sh   # T1: internal score floor
│   ├── certify_t2_tools.sh     # T2: external tool agreement
│   ├── certify_t3_spec.sh      # T3: behavioural spec present
│   ├── certify_t4_mutation.sh  # T4: coverage + mutation
│   ├── certify_t5_adversarial.sh   # T5: adversarial proposals rejected
│   ├── score_file_size.sh      # T1 dim
│   ├── score_complexity.sh     # T1 dim (AST-backed)
│   ├── score_complexity.go     # AST walker (lazy-built)
│   ├── score_doc.sh            # T1 dim
│   ├── gen_spec.sh             # Auto-generate spec.md
│   ├── gen_adversarial.sh      # Auto-generate adversarial.md
│   ├── sweep_all.sh            # Run the full cascade across all chunks
│   ├── batch_certify.sh        # Run on a chunk list
│   ├── bootstrap_coverage.sh   # Seed coverage.jsonl from existing cards
│   └── build_dashboard.sh      # Defrag-style HTML dashboard
├── certified/                  # <chunk>.card.md + .spec.md + .adversarial.md
├── coverage.jsonl              # Append-only ledger (auto-created)
└── dashboard.html              # Generated visual (auto-created)
```

Gitignored automatically by `.sisyphus/.gitignore`: `bin/` (lazy-built AST
binary), `.cache/` (gremlins per-package cache), `archive_*` (audit dumps).

## Non-Go projects

The protocol is portable — see the workspace doc's language matrix. Out
of the box, T1+T3+T5 are language-agnostic. T2 (tools) and T4 (coverage
+ mutation) are Go-specific. To adapt:

- **T2:** edit `scripts/certify_t2_tools.sh` to call your language's
  lint suite (clippy, ruff, eslint, etc.). Soft-pass on absent tools.
- **T4:** edit `scripts/certify_t4_mutation.sh` to call your language's
  coverage + mutation tools (cargo-llvm-cov + cargo-mutants for Rust,
  coverage.py + mutmut for Python, c8 + stryker for TS).

Set `SISYPHUS_PATTERN` / `SISYPHUS_EXCLUDE` in `config.sh` to the right
file glob.

## When to commit certified/ to git

Yes. The cards are the audit trail. The next refactor invalidates them
automatically (cert references a commit hash); fresh certs replace the
old ones on the next sweep. Commit the gold; let the ledger grow.

## See also

- Protocol reference: `/home/js/eidos/docs/methodology/SISYPHUS_PROTOCOL.md`
- Self-cert experiment: `/home/js/eidos/docs/methodology/SISYPHUS_PROTOCOL_SELF_CERT.md`
- Reference implementation (DORIANG): `/home/js/eidos/DORIANG/.sisyphus/`
