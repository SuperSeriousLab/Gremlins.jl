# Dispatch Mutation — Design Spec (v1)

**Date:** 2026-06-17
**Status:** approved, pre-implementation
**Sub-project:** 1 of 3 (dispatch mutation → pseudo-test hunt → runtime value injection)
**Consulted:** atlas-pro (slr-atlas-pro), 2026-06-17 — design hardened on its pushback (see §7)

## 1. Goal

Add a new operator class that mutates Julia's **multiple dispatch**, surfacing test
gaps that classic relational/arithmetic/literal/statement operators cannot reach:
untested *specializations*, untested *type constraints*, untested *union branches*,
untested *parametric bounds*. No mutation tool on any language targets dispatch — this
is Gremlins' differentiating OSS pitch and the Sisyphus-T4 value-add for Julia.

All operators are **pure static byte-range edits over JuliaSyntax trees**. No `eval`,
no runtime method-table reflection (honours the M0 static-only rule).

## 2. Scope

Four new opt-in operators, ranked by signal-per-implementation-cost:

| # | Operator | Edit | Catches |
|---|----------|------|---------|
| 1 | `OP_UNION_DROP` | `::Union{A,B,...}` → `::A` (one mutant per dropped member) | union branch never separately tested |
| 2 | `OP_SIG_WIDEN` | `x::T` → `x` (drop annotation), **guarded** | type constraint asserted nowhere |
| 3 | `OP_WHERE_RELAX` | `where T<:Bound` → `where T` (drop bound) | parametric bound never tested |
| 4 | `OP_METHOD_DELETE` | delete whole method def (sibling-only, cross-file) | fallback dispatch path never asserted |

All four:
- **opt-in** — NOT in `DEFAULT_OPERATORS` (same convention as `OP_INT_INCR`); enabled
  by passing them explicitly in the operator vector.
- **warm-path only** — excluded from `--schema` instrumentation (§5).
- **deterministic id** — `hash(relpath, byte-range, op-id)`, sorted enumeration.
- ship a **falsifiability test** — a planted killable mutant classified killed; any
  planted equivalent documented.

Out of scope for v1 (deferred): arg-type swap to a sibling's type; narrowing
untyped→concrete; kwarg↔positional; mutating default-value expressions in signatures.

## 3. Shared pre-pass: whole-project method map

Before mutant generation, parse **all tracked source files** (Gremlins already walks
the package source in `discover.jl`) and build:

```
MethodMap = Dict{Symbol, Vector{MethodDef}}        # function name → its method defs
struct MethodDef
    relpath::String
    byte_range::UnitRange{Int}                       # whole def, for METHOD_DELETE splice
    sig_node::JuliaSyntax.SyntaxNode                 # the signature `call` node
    arg_types::Vector{Union{Nothing,SyntaxNode}}     # per positional arg: type syntax or nothing (untyped)
    where_bounds::Vector{SyntaxNode}                  # `where` clause nodes (empty if none)
end
```

This map is **whole-project, not per-file** — Julia routinely spreads a function's
methods across files; per-file grouping would miss most real dispatch hierarchies
(atlas-pro §7.2). Building it is pure AST work, zero reflection. It feeds both
`OP_METHOD_DELETE` (sibling search) and the `OP_SIG_WIDEN` collision guard.

**Method-def detection:** a `K"function"` node, or a `K"="` whose LHS is a `K"call"`
(short-form `f(args) = body`). Function name = the call's first child (an identifier;
qualified names `Mod.f` and operator defs handled by taking the resolved name symbol).
Anonymous functions and call-overload `(obj::T)(x)` forms are skipped in v1.

**Signature-vs-body discrimination** (critical for SIG_WIDEN / UNION_DROP matchers):
a `::` or `Union` node counts only when it is a positional argument of a *signature*
`call` node — i.e. its ancestor `call` is the LHS of a `=` method def or the signature
child of a `function`. This excludes body type-asserts (`x::Int` as an expression),
return-type annotations (`function f()::T`), and `::` inside default-value expressions.

## 4. Operators in detail

### 4.1 OP_UNION_DROP (flagship — cheapest, no map needed for the edit)
- **Match:** a `Union{...}` type expression that is the type of a positional signature arg.
- **Generate:** one mutant per union member — splice `Union{A,B,C}` → the text of a
  single member (`A`, or `B`, …). Dropping to a single member means calls typed as the
  other members no longer dispatch here.
- **Survives ⇒** that union branch is never exercised by a test that depends on this method.
- No sibling analysis, no map dependency for the edit itself. Single child-node splice.
- Edge: `Union{T, Nothing}` (the common optional pattern) → dropping `Nothing` is high
  signal (does anything test the `nothing` path?).

### 4.2 OP_SIG_WIDEN (guarded)
- **Match:** a `K"::"` node that is a positional signature arg (ancestry check above).
- **Generate:** splice `x::T` → `x`.
- **GUARD (mandatory, atlas-pro §7.1):** consult the method map. Skip the mutant if the
  widened signature would be **identical** to any existing method def of the same
  function (→ would cause silent method *redefinition* — body swap, failures
  unattributable to the type-loss), or would create a **static dispatch ambiguity** with
  any remaining method (→ MethodError at call time = killed for the wrong reason, or
  never hit = falsely survives). Static ambiguity check = compare the widened signature
  against siblings using the supertype table; if two signatures become mutually
  non-more-specific on overlapping arg types, suppress.
- **Survives ⇒** the type constraint is asserted nowhere.

### 4.3 OP_WHERE_RELAX
- **Match:** a `where T <: Bound` clause in a method signature.
- **Generate:** splice `where T <: Bound` → `where T` (drop the bound, → `T<:Any`).
- **Survives ⇒** the parametric bound is never tested.
- v1 does only *drop*; bound *swap* (`Real`→`Integer`) deferred.

### 4.4 OP_METHOD_DELETE (sibling-only, cross-file)
- **Candidate test:** a method `m` of function `f` is a delete candidate **only if** the
  map contains another method `m'` of `f` that is **more general** — at every positional
  arg position, `m'`'s syntactic type is untyped / `Any` / a known supertype of `m`'s
  type per the hardcoded supertype table. (Same pattern already used by `operators.jl`'s
  widening/numeric tables.)
- **Generate:** splice the whole method-def byte range → empty.
- **Survives ⇒** the fallback (`m'`) produces test-indistinguishable behaviour — i.e. the
  specialization `m` is redundant *or* untested on its distinguishing inputs.
- Cross-file via the whole-project map.

## 5. Execution constraints

- **Schema-excluded.** A deleted method or changed signature is resolved at
  definition+dispatch time and cannot hide behind schema's runtime branch-selector.
  When `--schema` is active these operators are **silently skipped with a log line**;
  they run only on the warm/classic path. Declared as an invariant.
- **Patch/runner unchanged.** All four reduce to a single byte-range splice (or
  range→empty for METHOD_DELETE), which `patch.jl` already does reversibly. No new
  execution machinery.

## 6. Testing (falsifiability — one per operator, project rule)

- **UNION_DROP:** `f(x::Union{Int,String}) = x isa Int ? 1 : 2`; tests assert both
  `f(3)==1` and `f("a")==2`. Drop `String` → `f("a")` MethodErrors → killed. Drop `Int`
  symmetric. Planted equivalent: a union member never constructed in any test → survives,
  documented.
- **SIG_WIDEN:** `h(x::Integer) = x ÷ 2`; test `@test_throws MethodError h(3.0)`. Widen
  `::Integer`→untyped → no throw → killed. Guard test: a fixture where widening would
  collide with an existing method → assert NO mutant generated at that site.
- **WHERE_RELAX:** `g(v::AbstractVector{T}) where T<:Integer = sum(v)`; test
  `@test_throws MethodError g([1.0,2.0])`. Drop bound → accepts floats → killed.
- **METHOD_DELETE:** `area(s::Square)=s.side^2` + `area(s::Shape)=0`, `Square<:Shape`;
  `@test area(Square(2))==4`. Delete Square method → falls to Shape → returns 0 → killed.
  Planted redundant specialization (Square method returns same as Shape fallback) →
  survives, documented equivalent.

## 7. Consultation record (atlas-pro, 2026-06-17)

1. **SIG_WIDEN unsound as first drafted** — silent redefinition / call-time ambiguity
   produce mislabelled kills/survivals. → added the mandatory collision+ambiguity guard
   (§4.2). **Position updated.**
2. **Within-file grouping was wrong** — conflated runtime method-table (reflection,
   banned) with static method *definitions in source* (already parsed). → whole-project
   map (§3). **Position updated.**
3. **Missing higher-value static ops** — `OP_UNION_DROP` and `OP_WHERE_RELAX` are cheaper
   than METHOD_DELETE (no sibling analysis) and high signal. → promoted UNION_DROP to
   flagship, added WHERE_RELAX. **Reordered.**

## 8. Known limitations (documented, not hidden)

- Supertype table is a hardcoded Base subset; unknown user-defined type hierarchies →
  METHOD_DELETE generates no mutant at that site (conservative — no false high-signal).
  Future: optional runtime-assisted pass (out of static scope, separate milestone).
- Anonymous functions, `(obj::T)(x)` call-overloads, generated functions: skipped in v1.
- Macro-generated methods are invisible to static parsing (no source byte range) — out
  of scope by construction.

## 9. Acceptance

- `using Gremlins; discover` with the four operators enabled enumerates dispatch sites
  on a fixture deterministically (sorted, stable ids).
- Four falsifiability tests pass (planted killable → killed).
- SIG_WIDEN guard test passes (collision site → no mutant).
- `--schema` run logs the dispatch-op skip and does not crash.
- No mutation of `test/` files; source dirs only.
