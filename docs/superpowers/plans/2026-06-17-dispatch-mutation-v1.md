# Dispatch Mutation v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two map-free, stateless dispatch-mutation operators — `OP_UNION_DROP` (drop a `Union` member from a signature param) and `OP_WHERE_RELAX` (drop a `where T<:Bound` constraint) — that surface untested union branches and untested parametric bounds.

**Architecture:** Both operators are pure static byte-range edits over JuliaSyntax trees, matching the existing stateless `MutationOperator((node,src)->Bool, (node,src)->String|Vector{String})` model. They plug into the existing per-file `_walk!` discovery with no architectural change. A new `where`-aware signature-param helper (`_is_dispatch_sig_param`) gates both — it is a superset of the existing `_is_signature_param` that also accepts methods carrying a `where` clause. Schema exclusion is automatic (these op_ids are absent from `_SCHEMA_ELIGIBLE_OPS`, so they route to the warm path).

**Tech Stack:** Julia ≥ 1.10, JuliaSyntax (`SyntaxNode` API: `kind`, `children`, `is_leaf`, `byte_range`, `K"..."` macro).

## Global Constraints

- Julia ≥ 1.10. JuliaSyntax for ALL parsing — never regex over source.
- Mutations splice byte ranges in original text; never pretty-print untouched code.
- Mutant id = stable hash of (relpath, byte-range, operator-id); multi-replacement folds the replacement text into the id (existing `mutant_id(...; replacement=...)`).
- Both operators are **opt-in** — NOT added to `DEFAULT_OPERATORS`.
- Throw typed `MutationError`; no `error("...")` strings in library paths.
- No mutation of `test/` files — source dirs only (already enforced by `discover`).
- Every operator ships a falsifiability test: a planted killable mutant classified killed; any planted equivalent documented.
- Do NOT modify `OP_DISPATCH_SWAP` or `_is_signature_param` (certified; its `where`-blindness is a documented out-of-scope follow-up).

---

### Task 1: `where`-aware signature-param helper

**Files:**
- Modify: `src/operators.jl` (add helper directly above the `OP_DISPATCH_SWAP` block near line 404)
- Test: `test/test_dispatch_operators.jl` (new file)
- Modify: `test/runtests.jl` (add `include` at end)

**Interfaces:**
- Produces: `_is_dispatch_sig_param(node::JuliaSyntax.SyntaxNode)::Bool` — true iff `node` is a `name::Type` annotation in a method-signature positional-parameter position, in long-form, short-form, OR `where`-clause methods.

**Tree facts (verified against JuliaSyntax):** for a param `x::T`, the `::` node has `kind == K"::"`, is non-leaf, has 2 children with `children[1]` a leaf (the name). Its parent is the signature `K"call"`. The call's parent (grandparent of `::`) is `K"function"` for plain long/short form, or `K"where"` (whose own parent is `K"function"`) when the method has a `where` clause. Typed locals (`y::Int = 3`) have the `::`'s parent as `K"="` (not a call) → excluded. Return-type annotations (`h(x)::Int`) have the `::`'s child[1] as a `K"call"` (not a leaf) and parent `K"function"` (not a call) → excluded.

- [ ] **Step 1: Create the new test file with a failing helper-behavior test**

Create `test/test_dispatch_operators.jl`:

```julia
# test_dispatch_operators.jl — dispatch-mutation operators (v1: union-drop, where-relax)
using Test
using Gremlins
using JuliaSyntax
using JuliaSyntax: @K_str, kind, children, is_leaf

# Reuse the same fresh-module eval helper shape as runtests.jl.
function _eval_fresh(src::String, fname::Symbol)
    m = Module()
    Core.eval(m, Meta.parse(src))
    return Core.eval(m, fname)
end

# Collect sites for a snippet under a single operator (mirrors runtests.jl helpers).
function _sites(src::String, op::MutationOperator)
    mktempdir() do dir
        path = joinpath(dir, "snip.jl")
        write(path, src)
        discover_file(path; root=dir, operators=[op])
    end
end

@testset "Dispatch operators (v1)" begin

# ── Helper: _is_dispatch_sig_param accepts where-methods, rejects non-params ──
@testset "_is_dispatch_sig_param — where-aware" begin
    # Find the `x::T` :: node in a snippet and run the helper on it.
    function _param_node(code)
        t = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, code; ignore_errors=true)
        found = Ref{Any}(nothing)
        walk(n) = begin
            if kind(n) == K"::" && !is_leaf(n) && children(n) !== nothing &&
               length(children(n)) == 2 && is_leaf(children(n)[1]) &&
               children(n)[1].val === :x
                found[] = n
            end
            cs = children(n); cs === nothing || foreach(walk, cs)
        end
        walk(t)
        found[]
    end
    f = Gremlins._is_dispatch_sig_param
    @test f(_param_node("g(x::Int) = x")) == true                       # short-form
    @test f(_param_node("function g(x::Int); x; end")) == true          # long-form
    @test f(_param_node("g(x::T) where T<:Real = x")) == true           # short where
    @test f(_param_node("function g(x::T) where T<:Real; x; end")) == true  # long where
    @test f(_param_node("g() = (x::Int = 3; x)")) == false              # typed local
end

end  # @testset
```

- [ ] **Step 2: Wire the new test file into the suite**

In `test/runtests.jl`, add at the very end (after the `include("test_schema.jl")` line):

```julia
# ─── Feature D: dispatch-mutation operators (v1) ──────────────────────────────
include("test_dispatch_operators.jl")
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30`
Expected: FAIL — `UndefVarError: _is_dispatch_sig_param` (helper not defined yet).

- [ ] **Step 4: Implement the helper**

In `src/operators.jl`, immediately ABOVE the line `"""True iff \`node\` is a \`name::Type\` annotation...` (the `_is_signature_param` docstring, ~line 404), insert:

```julia
"""True iff `node` is a `name::Type` annotation in a method-signature
positional-parameter position. Superset of `_is_signature_param`: also matches
methods carrying a `where` clause, where the `::`'s grandparent is `K"where"`
(whose own parent is the `K"function"` def) rather than `K"function"` directly.
Used by the dispatch operators (union-drop, where-relax)."""
function _is_dispatch_sig_param(node::JuliaSyntax.SyntaxNode)::Bool
    JuliaSyntax.kind(node) == JuliaSyntax.K"::" || return false
    JuliaSyntax.is_leaf(node) && return false
    cs = JuliaSyntax.children(node)
    (!isnothing(cs) && length(cs) == 2 && JuliaSyntax.is_leaf(cs[1])) || return false
    p = node.parent
    (!isnothing(p) && JuliaSyntax.kind(p) == JuliaSyntax.K"call") || return false
    gp = p.parent
    isnothing(gp) && return false
    k = JuliaSyntax.kind(gp)
    k == JuliaSyntax.K"function" && return true
    if k == JuliaSyntax.K"where"
        ggp = gp.parent
        return !isnothing(ggp) && JuliaSyntax.kind(ggp) == JuliaSyntax.K"function"
    end
    return false
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30`
Expected: PASS for the `_is_dispatch_sig_param — where-aware` testset.

- [ ] **Step 6: Commit**

```bash
git add src/operators.jl test/test_dispatch_operators.jl test/runtests.jl
git commit -m "feat(operators): where-aware dispatch signature-param helper"
```

---

### Task 2: `OP_UNION_DROP`

**Files:**
- Modify: `src/operators.jl` (add operator after the `OP_DISPATCH_SWAP` block, before the `# ─── 10. Comparison-chain` section)
- Modify: `src/Gremlins.jl` (export, near line 43 where `OP_DISPATCH_SWAP` is exported)
- Test: `test/test_dispatch_operators.jl`

**Interfaces:**
- Consumes: `_is_dispatch_sig_param` (Task 1), `node_text` (existing helper).
- Produces: `const OP_UNION_DROP::MutationOperator` with `id = :union_drop`. Matcher fires on a `K"curly"` Union type in a signature param. Replacer returns `Vector{String}` — one entry per union member (each member's source text), yielding one mutant per member dropped.

**Tree facts (verified):** `x::Union{Int,String}` → the type is a `K"curly"` node whose `children[1]` is a leaf Identifier with `val === :Union` and `children[2:end]` are the member type nodes. The curly's parent is the `K"::"` param node.

- [ ] **Step 1: Write the failing falsifiability + enumeration test**

Append inside the `@testset "Dispatch operators (v1)"` block in `test/test_dispatch_operators.jl` (before its closing `end  # @testset`):

```julia
# ── OP_UNION_DROP ──
@testset "OP_UNION_DROP — enumeration + falsifiability" begin
    src = "fu(x::Union{Int,String}) = x isa Int ? 1 : 2\n"
    sites = _sites(src, OP_UNION_DROP)
    # One mutant per dropped member → 2 sites (→Int, →String).
    @test length(sites) == 2
    @test Set(s.replacement for s in sites) == Set(["Int", "String"])
    @test all(s -> s.op_id == :union_drop, sites)
    @test all(s -> s.original == "Union{Int,String}", sites)
    # Distinct ids despite identical (range, op_id) — replacement disambiguates.
    @test length(unique(s -> s.id, sites)) == 2
    # Round-trip safety for every emitted mutant.
    for s in sites
        @test revert(s, apply(s, src)) == src
    end

    # Falsifiability: dropping `String` leaves `fu(x::Int)`; fu("a") no longer
    # dispatches → MethodError → any test calling fu(::String) fails → killed.
    drop_to_int = first(s for s in sites if s.replacement == "Int")
    mutated = apply(drop_to_int, src)
    f_orig = _eval_fresh(src, :fu)
    f_mut  = _eval_fresh(mutated, :fu)
    @test f_orig("a") == 2
    @test f_orig(3)   == 1
    @test_throws MethodError f_mut("a")   # String branch dropped → killed
    @test f_mut(3) == 1                    # surviving member still works
end

# ── OP_UNION_DROP must NOT fire on non-signature unions ──
@testset "OP_UNION_DROP — negative cases" begin
    # Union as a value in the body, not a signature param type.
    @test isempty(_sites("g() = Union{Int,String}\n", OP_UNION_DROP))
    # Single-member curly is degenerate → no mutant.
    @test isempty(_sites("h(x::Union{Int}) = x\n", OP_UNION_DROP))
    # Non-Union curly (parametric type) → no mutant.
    @test isempty(_sites("k(x::Vector{Int}) = x\n", OP_UNION_DROP))
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30`
Expected: FAIL — `UndefVarError: OP_UNION_DROP`.

- [ ] **Step 3: Implement `OP_UNION_DROP`**

In `src/operators.jl`, after the closing `)` of the `OP_DISPATCH_SWAP` definition and before `# ─── 10. Comparison-chain operator`, insert:

```julia
# ─── 9b. Union-member drop ────────────────────────────────────────────────────
# JULIA-UNIQUE dispatch mutation. `f(x::Union{A,B})` accepts both A and B. Drop
# one member → `f(x::A)`: calls typed as the dropped member stop dispatching here
# (MethodError, or redirect to another method). A SURVIVING mutant means that
# union branch is never exercised — a dispatch-coverage gap. Static + falsifiable;
# opt-in. One mutant per member (Vector{String}; replacement disambiguates ids).

"""True iff `node` is a `Union{...}` type (`K"curly"` led by `Union`) in a
method-signature parameter position, with at least two members."""
function _is_signature_union(node::JuliaSyntax.SyntaxNode)::Bool
    JuliaSyntax.kind(node) == JuliaSyntax.K"curly" || return false
    cs = JuliaSyntax.children(node)
    (!isnothing(cs) && length(cs) >= 3) || return false          # Union + ≥2 members
    (JuliaSyntax.is_leaf(cs[1]) && cs[1].val === :Union) || return false
    p = node.parent
    (!isnothing(p) && JuliaSyntax.kind(p) == JuliaSyntax.K"::") || return false
    _is_dispatch_sig_param(p)
end

const OP_UNION_DROP = MutationOperator(
    :union_drop,
    "dispatch: drop a Union member",
    (node, src) -> _is_signature_union(node) && !_is_inside_macro_def(node),
    (node, src) -> begin
        cs = JuliaSyntax.children(node)
        # children[2:end] are the union members; one mutant per member.
        return String[node_text(m, src) for m in cs[2:end]]
    end,
)
```

- [ ] **Step 4: Export it**

In `src/Gremlins.jl`, change the line `export OP_DISPATCH_SWAP` to:

```julia
export OP_DISPATCH_SWAP
export OP_UNION_DROP
```

- [ ] **Step 5: Run to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30`
Expected: PASS for both `OP_UNION_DROP` testsets.

- [ ] **Step 6: Commit**

```bash
git add src/operators.jl src/Gremlins.jl test/test_dispatch_operators.jl
git commit -m "feat(operators): OP_UNION_DROP — drop a Union member from a signature param"
```

---

### Task 3: `OP_WHERE_RELAX`

**Files:**
- Modify: `src/operators.jl` (add operator after the `OP_UNION_DROP` block)
- Modify: `src/Gremlins.jl` (export, after `OP_UNION_DROP`)
- Test: `test/test_dispatch_operators.jl`

**Interfaces:**
- Consumes: `node_text` (existing helper). (Does NOT use `_is_dispatch_sig_param` — it gates on the `where`-clause structure directly.)
- Produces: `const OP_WHERE_RELAX::MutationOperator` with `id = :where_relax`. Matcher fires on a `K"<:"` constraint node inside a method-signature `where` clause. Replacer returns a single `String`: the constraint variable text (`T<:Real` → `T`).

**Tree facts (verified):** `f(x::T) where T<:Real = x` → the `where` node has `children == [call, <:]`; the `<:` node has `children == [T, Real]` (both leaves here). The `<:`'s parent is the `K"where"`, whose parent is the `K"function"` def (true for both short- and long-form). For `where {T<:Real, N}`, the `<:` sits inside a `K"braces"` whose parent is the `K"where"`. Only upper-bound `<:` is handled in v1; lower-bound `>:` and nested `where` are out of scope (documented).

- [ ] **Step 1: Write the failing falsifiability + enumeration test**

Append inside the `@testset "Dispatch operators (v1)"` block in `test/test_dispatch_operators.jl` (before its closing `end  # @testset`):

```julia
# ── OP_WHERE_RELAX ──
@testset "OP_WHERE_RELAX — enumeration + falsifiability" begin
    src = "gwr(v::AbstractVector{T}) where T<:Integer = sum(v)\n"
    sites = _sites(src, OP_WHERE_RELAX)
    @test length(sites) == 1
    s = sites[1]
    @test s.op_id == :where_relax
    @test s.original    == "T<:Integer"
    @test s.replacement == "T"
    @test revert(s, apply(s, src)) == src

    # Falsifiability: original rejects floats (Integer bound); relaxed accepts
    # them → a `@test_throws MethodError` on floats no longer throws → killed.
    mutated = apply(s, src)
    g_orig = _eval_fresh(src, :gwr)
    g_mut  = _eval_fresh(mutated, :gwr)
    @test g_orig([1, 2]) == 3
    @test_throws MethodError g_orig([1.0, 2.0])
    @test g_mut([1.0, 2.0]) == 3.0   # bound dropped → now dispatches → killed
end

# ── OP_WHERE_RELAX — multi-param where + negative cases ──
@testset "OP_WHERE_RELAX — braces + negatives" begin
    # `where {T<:Real, N}`: the one bounded param yields one site.
    multi = _sites("fm(x::T, y::Val{N}) where {T<:Real, N} = x\n", OP_WHERE_RELAX)
    @test length(multi) == 1
    @test multi[1].original == "T<:Real"
    @test multi[1].replacement == "T"
    # A `where` in a non-method (type-alias) position must NOT match.
    @test isempty(_sites("const V = Vector{T} where T<:Real\n", OP_WHERE_RELAX))
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30`
Expected: FAIL — `UndefVarError: OP_WHERE_RELAX`.

- [ ] **Step 3: Implement `OP_WHERE_RELAX`**

In `src/operators.jl`, after the `OP_UNION_DROP` definition and before `# ─── 10. Comparison-chain operator`, insert:

```julia
# ─── 9c. Where-bound relax ────────────────────────────────────────────────────
# JULIA-UNIQUE dispatch mutation. `f(x::T) where T<:Real` constrains the type
# parameter. Drop the bound (`where T`) → the method accepts any T. A SURVIVING
# mutant means the parametric bound is never exercised — a dispatch-coverage gap.
# v1 handles upper-bound `<:` only; lower-bound `>:` and nested `where` are out of
# scope. Static + falsifiable; opt-in.

"""True iff `node` is a `<:` upper-bound constraint inside a method-signature
`where` clause — either directly (`where T<:Real`) or inside the brace list
(`where {T<:Real, ...}`). The enclosing `where`'s parent must be the
`K"function"` def, so non-method `where` (type aliases, struct params) is excluded."""
function _is_signature_where_bound(node::JuliaSyntax.SyntaxNode)::Bool
    JuliaSyntax.kind(node) == JuliaSyntax.K"<:" || return false
    cs = JuliaSyntax.children(node)
    (!isnothing(cs) && length(cs) == 2) || return false
    p = node.parent
    isnothing(p) && return false
    if JuliaSyntax.kind(p) == JuliaSyntax.K"where"
        gp = p.parent
        return !isnothing(gp) && JuliaSyntax.kind(gp) == JuliaSyntax.K"function"
    elseif JuliaSyntax.kind(p) == JuliaSyntax.K"braces"
        gp = p.parent
        (!isnothing(gp) && JuliaSyntax.kind(gp) == JuliaSyntax.K"where") || return false
        ggp = gp.parent
        return !isnothing(ggp) && JuliaSyntax.kind(ggp) == JuliaSyntax.K"function"
    end
    return false
end

const OP_WHERE_RELAX = MutationOperator(
    :where_relax,
    "dispatch: drop a where-bound",
    (node, src) -> _is_signature_where_bound(node) && !_is_inside_macro_def(node),
    # `T<:Real` → `T` (the constraint variable, children[1]).
    (node, src) -> node_text(JuliaSyntax.children(node)[1], src),
)
```

- [ ] **Step 4: Export it**

In `src/Gremlins.jl`, after the `export OP_UNION_DROP` line added in Task 2, add:

```julia
export OP_WHERE_RELAX
```

- [ ] **Step 5: Run to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -30`
Expected: PASS for both `OP_WHERE_RELAX` testsets.

- [ ] **Step 6: Commit**

```bash
git add src/operators.jl src/Gremlins.jl test/test_dispatch_operators.jl
git commit -m "feat(operators): OP_WHERE_RELAX — drop a where-clause type bound"
```

---

### Task 4: Determinism guard + full-suite green + docs

**Files:**
- Test: `test/test_dispatch_operators.jl` (determinism testset)
- Modify: `docs/INVARIANTS.md` (note dispatch ops are warm-path only)
- Modify: `CLAUDE.md` (operator table mention — optional, keep terse)

**Interfaces:**
- Consumes: `OP_UNION_DROP`, `OP_WHERE_RELAX` (Tasks 2-3).

- [ ] **Step 1: Add a determinism test**

Append inside the `@testset "Dispatch operators (v1)"` block (before its closing `end  # @testset`):

```julia
# ── Determinism (invariant I2) ──
@testset "Dispatch ops — deterministic enumeration" begin
    src = "fu(x::Union{Int,String,Float64}) = 1\ngw(y::T) where T<:Real = y\n"
    ops = [OP_UNION_DROP, OP_WHERE_RELAX]
    run1 = mktempdir() do d; p=joinpath(d,"a.jl"); write(p,src); discover_file(p; root=d, operators=ops); end
    run2 = mktempdir() do d; p=joinpath(d,"a.jl"); write(p,src); discover_file(p; root=d, operators=ops); end
    @test length(run1) == 4   # 3 union members + 1 where-bound
    @test [s.op_id for s in run1] == [s.op_id for s in run2]
    @test [s.replacement for s in run1] == [s.replacement for s in run2]
end
```

- [ ] **Step 2: Run the FULL suite to verify nothing regressed**

Run: `julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tail -40`
Expected: PASS — all pre-existing testsets (including the `Self-mutate smoke test (EDD GATE: >50 sites)`) plus the new `Dispatch operators (v1)` set. Note: `DEFAULT_OPERATORS` is unchanged, so the smoke-test count is unaffected.

- [ ] **Step 3: Document the warm-path invariant**

In `docs/INVARIANTS.md`, add one line under the appropriate section (search for the schema/warm invariant; if none, append to the invariant list):

```markdown
- Dispatch operators (`:dispatch_type_swap`, `:union_drop`, `:where_relax`) are
  warm-path only: they are absent from `_SCHEMA_ELIGIBLE_OPS`, so `schema_eligible`
  routes them to the warm runner. A changed signature / dropped bound is resolved at
  definition+dispatch time and cannot be expressed as a schema runtime branch.
```

- [ ] **Step 4: Commit**

```bash
git add test/test_dispatch_operators.jl docs/INVARIANTS.md
git commit -m "test(dispatch): determinism guard + document warm-path invariant"
```

---

## Self-Review

**1. Spec coverage (v1 portion):**
- `OP_UNION_DROP` → Task 2. ✓
- `OP_WHERE_RELAX` → Task 3. ✓
- `where`-aware helper (fixes the §2 finding-3 gap) → Task 1. ✓
- Schema exclusion (automatic via allowlist) → verified, documented in Task 4 Step 3. ✓
- Falsifiability test per operator → Task 2 Step 1, Task 3 Step 1. ✓
- Determinism (I2) → Task 4 Step 1. ✓
- Opt-in (not in `DEFAULT_OPERATORS`) → no task adds them to the default set; smoke-test count unaffected (Task 4 Step 2). ✓
- v1.1 ops (`OP_SIG_WIDEN`, `OP_METHOD_DELETE`) → deliberately deferred, out of this plan's scope. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code. ✓

**3. Type consistency:** `_is_dispatch_sig_param` (Task 1) consumed by `_is_signature_union` (Task 2). `node_text` is the existing exported-internal helper used by both replacers. op_ids `:union_drop`, `:where_relax` consistent across operator defs, tests, and the invariant note. Exports in `src/Gremlins.jl` match the `const` names. ✓
