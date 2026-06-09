# Gremlins expansion — design (2026-06-09)

Three independent, post-launch expansions for Gremlins.jl. All build on the
shipped M0–M2 base (operators, discovery, cold + warm runners, incremental
cache, shadow crash-safety, lowered-IR equivalence prune). Each is separately
shippable; ordered by effort. The shared north star: keep the elegance and the
invariants (I1–I5) intact — every addition is a *filter*, a *table entry*, or a
*new execution mode that reuses the existing fallback taxonomy*, never a rewrite.

---

## A. Git-diff scope (`--in-diff <ref>`)

### What
Restrict discovered mutation sites to source lines changed by a git diff. Default
base resolvable as a ref argument (`--in-diff main`, `--in-diff HEAD~1`,
`--in-diff origin/main...HEAD`). A full-repo `discover` is unchanged when the
option is absent.

### Why
Mutation-testing cost is `sites × test-time`. In CI / Sisyphus-T4 the only sites
that matter for a PR are the lines the PR touched. Scoping discovery to the diff
turns a minutes-long full-repo run into a seconds-long PR gate. This is
cargo-mutants' single most-used CI feature (`--in-diff`).

### How
- New `src/diff_scope.jl`:
  - `changed_lines(base::AbstractString; pkgdir) -> Dict{String,Vector{UnitRange{Int}}}`
    runs `git -C pkgdir diff --unified=0 <base> -- '*.jl'`, parses hunk headers
    `@@ -a,b +c,d @@` → for each post-image file, the set of added/changed line
    ranges `c:(c+d-1)` (d==0 hunks — pure deletions — contribute no added line,
    correctly yielding no sites).
  - Paths normalised to pkgdir-relative, forward-slash, `./`-stripped (same
    normalisation already used by the T4 `--files` path).
- `discover(...)` gains `diff_lines::Union{Nothing,Dict{String,Vector{UnitRange{Int}}}}=nothing`.
  A site survives iff `startline(site) ∈ some range for its file`. Byte→line uses
  the source text already held during discovery (cumulative newline scan; no new
  file I/O, no mtime — I2 preserved).
- No runner / cache / warm / schema changes — this is a pre-execution filter and
  composes with all of them. Site ids stay stable (I2): the filter removes sites,
  it never renumbers them.

### Report contract (no-silent-caps rule)
The run report states `scoped to diff <ref>: N of M discoverable sites (M−N
suppressed)`. Silent truncation that reads as "100% covered" is forbidden.

### Tests / falsifiability
- Parser unit tests on canned `git diff --unified=0` text (multi-hunk,
  multi-file, rename, pure-deletion, added-at-EOF).
- Filter test: a source file + a synthetic `diff_lines` set → assert exactly the
  in-range sites are returned; a site one line above the hunk is excluded, one
  line inside is included (boundary falsifiability).
- Integration: a tmp git repo with one committed file + one changed function →
  `discover(...; diff_lines=changed_lines("HEAD~1"))` returns only the changed
  function's sites.

### Edge cases
- Not a git repo / git absent → clear error, never silent empty scope.
- Generated / vendored files outside pkgdir `src/` already excluded by discovery
  roots; the diff filter only narrows further.

---

## B. Julia-idiom operators

Three new operators added to the table and to `DEFAULT_OPERATORS` (order appended
to preserve existing-id determinism — I2). `&&`/`||` short-circuit, `!` deletion,
arithmetic, literal-boundary, and kwarg/const defaults are already covered;
these three fill genuinely Julia-idiomatic gaps generic tools miss.

### B1. `OP_TERNARY_SWAP`
- Target: `K"?"` node (`cond ? a : b`).
- Mutation: swap the then/else byte ranges → `cond ? b : a`.
- Kills tests that pin the branch value; survives only if both arms are
  observationally equal on the covered inputs.
- Known equivalent noise: `c ? x : x`. Documented, rare; the opt-in lowered-IR
  prune does not fold it (lowering ≠ optimisation), so it is reported honestly as
  a survivor, not hidden.

### B2. `OP_COMPARISON_CHAIN`
- Target: `K"comparison"` node (`a < b < c`), which the binary-call relational
  operators do **not** reach (chained comparison is a distinct syntax node, not
  nested `<` calls).
- Mutation: replace one comparator token with its boundary partner using the
  existing relational map (`<`↔`<=`, `>`↔`>=`, `==`↔`!=`). One mutant per
  comparator position → N−1 mutants for an N-term chain.
- Replacer operates on the single comparator token's byte range (prefix/suffix
  preserved), mirroring the existing `&&`/`||` mid-token replace.

### B3. `OP_BROADCAST_DROP`
- Target: dotted operator / broadcast call — `.+`, `.<`, `f.(x)`.
- Mutation: remove the broadcasting `.` (de-vectorise) — `a .+ b`→`a + b`,
  `f.(x)`→`f(x)`.
- Strong Julia-specific mutant: scalar tests often still pass while array
  semantics break, exposing under-tested vectorised code paths.
- Known equivalent noise: already-scalar operands. Documented.

### Each operator ships with
- Predicate honouring the existing macro / `@eval` / `@generated` skip guard
  (I4 — never mutate inside macro-definition regions).
- A planted-mutant falsifiability fixture asserting (a) the mutant is discovered
  and (b) a known-good test kills it — the campaign verification rule. No
  "verified locally" without pasted output.
- Byte-range round-trip (apply→revert lossless, I-patcher contract).

### Schema interaction
B2 (comparison-chain) is an operator-swap → schema-eligible (Feature C). B1
(ternary-swap) replaces a sub-expression *value* and B3 (broadcast-drop) changes
call shape → both schema-ineligible, run on the warm path via fallback taxonomy.

---

## C. Mutant schemata (compile-once execution mode)

The headline win. Eliminates per-mutant recompilation by instrumenting all
schema-eligible sites of a file into **one** module compiled once, with a runtime
switch selecting which single mutant is "live".

### The transform
- Inject (once per instrumented module): `const __GREM_ACTIVE = Ref(0)`.
- Each eligible site `EXPR` at stable id `k` becomes:
  `(__GREM_ACTIVE[] == k ? MUTATED_EXPR : EXPR)`.
- The instrumented module is compiled **once**. To evaluate mutant `k`: set
  `__GREM_ACTIVE[] = k`, run the covering tests, classify. `__GREM_ACTIVE[] = 0`
  selects the all-original baseline.

### Why it is sound (operand & control-flow safety)
- A ternary evaluates **only the taken branch**, so operands referenced in both
  arms execute exactly once (whichever branch is live) — no double-evaluation of
  side-effecting operands.
- Short-circuit semantics are preserved: `&&`/`||` live inside the taken branch
  intact (`cond ? (a || b) : (a && b)`).
- `__GREM_ACTIVE` is a `const Ref{Int}`; reads are type-stable `Int`. The site
  ternary is type-stable iff both arms share an inferred type — true for every
  expression operator (relop→`Bool`, arith→operand type, literal/const→same
  literal type, comparison-chain→`Bool`). A site whose arms differ in inferred
  type is declared schema-ineligible and falls back (guard below).

### Eligibility & fallback (reuse, don't reinvent)
- Eligible — **operator-swap ops only**: relational, arithmetic, boolean
  (`&&`/`||`), comparison-chain. These mutate the *operator token*, leaving
  operands byte-identical, so they introduce no new constant and cannot change
  constant-driven dispatch (the atlas-flash hole below).
- Ineligible (→ warm fallback):
  - *value-mutating ops* — `OP_INT_INCR`/`OP_INT_DECR` (literal-boundary),
    `OP_TRUE_TO_FALSE`/`OP_FALSE_TO_TRUE`, `OP_CONST_POOL`, `OP_TERNARY_SWAP`.
    They replace a sub-expression with a different *value*; under a dynamic
    `Ref` read that value loses compile-time constness and can change which
    method dispatches (`f(4)`→`f(::Val{4})` vs `f(::Int)`) even at `active==0`.
    These run on the warm path where the real mutated value is compiled in.
  - *shape-changing ops* — `OP_STMT_DELETE`, `OP_RETURN_NOTHING`,
    `OP_DISPATCH_SWAP`, `OP_BROADCAST_DROP` — change statement/arity/call shape.
- Add `fallback_schema_ineligible` to the existing `FallbackReason` enum so the
  report shows schema-run vs warm-run split exactly as it already shows warm-ok
  vs cold-fallback. Taxonomy stays visible, never silent.

### Execution path
- New `run_mutations_schema` (and `mutate_schema`) alongside `run_mutations_warm`.
  The persistent worker already loads the package once; schema mode additionally
  evals the instrumented module **once**, then loops pure switch-flips:
  set active id → run covered tests → restore. No per-mutant `Core.eval`.
- Cold/warm remain the fallback fabric; schema is a fast front path for the
  eligible majority. Worker recycle policy unchanged.

### Soundness verification (extends existing I4 sampling)
- Schema baseline (`__GREM_ACTIVE[]=0`) must equal the plain baseline result;
  mismatch = hard error (instrumentation changed observable behaviour).
- On `min(10, N)` schema-eligible mutants, re-run the same mutant on the warm
  path and assert identical kill/survive classification. Any mismatch = hard
  error, exactly like the current warm-vs-cold I4 agreement check.
- Type-stability guard: before instrumenting a site, confirm both arms lower to a
  common type via the existing lowered-IR machinery (`equivalence.jl`
  infrastructure); ambiguous → mark schema-ineligible (safe over-approximation,
  same one-directional soundness discipline as the equivalence prune).
- **Constant-literal guard (atlas-flash):** reject any site whose original
  expression lowers to a constant `Literal` — even an operator-swap site can have
  literal operands that const-fold and feed `Val`-style dispatch. The
  type-stability guard alone is necessary-not-sufficient: runtime types can match
  while a lost constant changes the dispatched method. Literal-folding site →
  warm fallback. Implemented with the same lowered-IR pass as the equivalence
  prune (no new machinery).
- **Hot-path runtime guard:** the warm-vs-schema agreement sample already runs the
  same mutants both ways; record per-mutant *test wall-time* for the sample. If
  schema test-time exceeds warm test-time (a dynamic `Ref` read inside a hot loop
  blocks inlining/const-prop/LICM and can invert the compile-once win), schema is
  net-negative for that file → auto-disable schema for the file, run it on the
  warm path, and report the auto-disable. Never silently keep a slower mode.

### EDD gate
Benchmark schema vs warm on the JUI dogfood package (same 25-site setup used for
the M2 ≥5× gate). Target: schema ≥2× faster than warm on eligible-heavy files
(recompile elimination), with I4 agreement = 0 mismatches, pasted output. No
silent caps on what fell back.

### Risk & consultation outcome
Schema's soundness model is the one non-trivial design surface. Consulted
atlas-flash (slr-atlas-flash) 2026-06-09. Key catch: same-type arms are
necessary-not-sufficient — lost constant-propagation under a dynamic `Ref` read
can change *which method dispatches* even when runtime type matches, and a `Ref`
read in a hot loop can invert the speedup. Folded into the design as: (1)
schema-eligible narrowed to operator-swap ops only; (2) constant-literal guard;
(3) hot-path runtime auto-disable. atlas-flash confirmed ternary-at-site is the
right primitive under the no-new-deps constraint (Cassette/IRTools rejected). The
implementation plan will be consulted once more before C is built.

---

## Cross-cutting invariants (unchanged)
- I1 shadow tree: A is read-only discovery; C evals in-memory (warm-path
  property — disk never written), so the shadow rule is untouched.
- I2 determinism: A filters without renumbering; B appends operators in fixed
  order; C does not reorder sites.
- I3 killed-is-proven, I4 no-exec-during-discovery, I5 latency: all preserved —
  A/B are static; C only changes *how* execution reuses compilation, not what
  counts as a kill.

## Sequencing
A (filter) → B (3 operators) → C (schema mode, after /consult or DORIANG on the
soundness model). A and B are mergeable independently; C lands last.
