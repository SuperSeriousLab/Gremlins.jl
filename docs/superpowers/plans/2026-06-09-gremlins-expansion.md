# Gremlins Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three independent expansions to Gremlins.jl — git-diff site scoping, three Julia-idiom operators, and a compile-once "schemata" execution mode.

**Architecture:** A is a pure post-discovery line filter (no walker change — `MutationSite.line` already exists). B adds three operators to the existing `MutationOperator` table. C adds a new execution mode that instruments all operator-swap sites of a function into one compile-once module switched by a global `Ref`, falling back to the warm path for ineligible sites via the existing fallback taxonomy.

**Tech Stack:** Julia ≥ 1.10, JuliaSyntax (parsing — never regex over source), existing Gremlins runner/warm/equivalence machinery.

**Spec:** `docs/superpowers/specs/2026-06-09-gremlins-expansion-design.md`

**Campaign rules (non-negotiable):**
- Every operator ships a planted-mutant falsifiability test (killable mutant classified killed) with pasted output. No "verified locally" without runnable output.
- No `error("...")` strings in library paths — throw `MutationError`.
- All parsing via JuliaSyntax. Byte-range splices only; never pretty-print untouched code.
- Determinism (I2): sites sorted by `(relpath, byte-start, op_id string)`; new operators append to `DEFAULT_OPERATORS` (never reorder).
- Soundness is one-directional (I3): a kill needs a captured failing test; any uncertainty keeps the mutant / falls back. Never silently misclassify.

---

## Feature A — Git-diff scope (`--in-diff <ref>`)

### File Structure
- Create: `src/diff_scope.jl` — git-diff hunk parsing + site filtering.
- Modify: `src/Gremlins.jl` — `include("diff_scope.jl")` + exports.
- Modify: `src/discover.jl:243` — add `diff_lines` kwarg to `discover`.
- Test: `test/test_diff_scope.jl`.
- Modify: `test/runtests.jl` — include the new test file.

### Task A1: Parse `git diff --unified=0` hunk headers

**Files:**
- Create: `src/diff_scope.jl`
- Test: `test/test_diff_scope.jl`

- [ ] **Step 1: Write the failing test**

```julia
# test/test_diff_scope.jl
using Test, Gremlins

@testset "parse_diff_hunks" begin
    diff = """
    diff --git a/src/foo.jl b/src/foo.jl
    index 1111111..2222222 100644
    --- a/src/foo.jl
    +++ b/src/foo.jl
    @@ -10,0 +11,3 @@ function g()
    +    a = 1
    +    b = 2
    +    c = 3
    @@ -20,2 +24,1 @@
    +    x = 9
    diff --git a/src/bar.jl b/src/bar.jl
    --- a/src/bar.jl
    +++ b/src/bar.jl
    @@ -5,1 +5,1 @@
    +    changed = true
    """
    ranges = Gremlins.parse_diff_hunks(diff)
    @test ranges["src/foo.jl"] == [11:13, 24:24]
    @test ranges["src/bar.jl"] == [5:5]
    # pure deletion hunk (+a,0) contributes no added line
    @test !haskey(ranges, "src/nonexistent.jl")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()' ` (or run just this file via the test harness)
Expected: FAIL — `parse_diff_hunks` not defined.

- [ ] **Step 3: Write minimal implementation**

```julia
# src/diff_scope.jl
# Git-diff scoping: restrict mutation sites to lines a diff added/changed.
# Pure pre-execution filter — composes with cache/warm/schema unchanged.

"""
    parse_diff_hunks(diff::AbstractString) -> Dict{String,Vector{UnitRange{Int}}}

Parse `git diff --unified=0` output. Returns post-image (new file) path →
added/changed line ranges. Pure-deletion hunks (`+c,0`) contribute nothing.
Paths are the `+++ b/<path>` path with the leading `b/` stripped.
"""
function parse_diff_hunks(diff::AbstractString)::Dict{String,Vector{UnitRange{Int}}}
    out = Dict{String,Vector{UnitRange{Int}}}()
    curfile = ""
    for line in eachline(IOBuffer(diff))
        if startswith(line, "+++ ")
            p = strip(line[5:end])
            p = startswith(p, "b/") ? p[3:end] : p
            curfile = p
        elseif startswith(line, "@@")
            # @@ -a,b +c,d @@  — capture c,d
            m = match(r"\+(\d+)(?:,(\d+))?", line)
            m === nothing && continue
            c = parse(Int, m.captures[1])
            d = m.captures[2] === nothing ? 1 : parse(Int, m.captures[2])
            d == 0 && continue            # pure deletion: no added line
            isempty(curfile) && continue
            push!(get!(out, curfile, UnitRange{Int}[]), c:(c + d - 1))
        end
    end
    return out
end
```

- [ ] **Step 4: Add include + export**

In `src/Gremlins.jl` add `include("diff_scope.jl")` (after `discover.jl`) and `export changed_lines, scope_to_diff`. Add `include("test_diff_scope.jl")` to `test/runtests.jl`.

- [ ] **Step 5: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/diff_scope.jl src/Gremlins.jl test/test_diff_scope.jl test/runtests.jl
git commit -m "feat(diff-scope): parse git diff --unified=0 hunk headers"
```

### Task A2: `changed_lines` shells git; `scope_to_diff` filters sites

**Files:**
- Modify: `src/diff_scope.jl`
- Test: `test/test_diff_scope.jl`

- [ ] **Step 1: Write the failing test**

```julia
@testset "scope_to_diff" begin
    # MutationSite positional fields: id, relpath, byte_range, op_id, op_name, original, replacement, line
    mk(relpath, line) = Gremlins.MutationSite("id$line", relpath, 1:1, :relop_lt_le,
                                              "x", "y", "<", "<=", line)
    sites = [mk("src/foo.jl", 12), mk("src/foo.jl", 99), mk("src/bar.jl", 5)]
    diff_lines = Dict("src/foo.jl" => [11:13], "src/bar.jl" => [5:5])
    kept, suppressed = Gremlins.scope_to_diff(sites, diff_lines)
    @test [s.line for s in kept] == [12, 5]   # 99 excluded (outside 11:13)
    @test suppressed == 1
    # boundary falsifiability: line one above/below the hunk
    @test isempty(Gremlins.scope_to_diff([mk("src/foo.jl", 10)], diff_lines)[1])
    @test length(Gremlins.scope_to_diff([mk("src/foo.jl", 13)], diff_lines)[1]) == 1
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `scope_to_diff` not defined.

- [ ] **Step 3: Write minimal implementation**

```julia
# append to src/diff_scope.jl

"""
    scope_to_diff(sites, diff_lines) -> (kept::Vector{MutationSite}, suppressed::Int)

Keep only sites whose `.line` falls in a changed range for `.relpath`.
Returns kept sites and the count suppressed (for the no-silent-caps report line).
"""
function scope_to_diff(sites::Vector{MutationSite},
                       diff_lines::Dict{String,Vector{UnitRange{Int}}})
    kept = MutationSite[]
    for s in sites
        ranges = get(diff_lines, s.relpath, nothing)
        if ranges !== nothing && any(r -> s.line in r, ranges)
            push!(kept, s)
        end
    end
    return kept, length(sites) - length(kept)
end

"""
    changed_lines(base; pkgdir=".") -> Dict{String,Vector{UnitRange{Int}}}

Run `git -C pkgdir diff --unified=0 <base> -- '*.jl'` and parse it.
Throws MutationError if git fails (e.g. not a repo) — never a silent empty scope.
"""
function changed_lines(base::AbstractString; pkgdir::AbstractString=".")
    cmd = `git -C $pkgdir diff --unified=0 $base -- "*.jl"`
    out = try
        read(cmd, String)
    catch e
        throw(MutationError("changed_lines: git diff failed for base=$(repr(base)) in $(pkgdir): $e"))
    end
    return parse_diff_hunks(out)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diff_scope.jl
git commit -m "feat(diff-scope): changed_lines (git shell) + scope_to_diff filter"
```

### Task A3: `discover(...; diff_lines=nothing)` post-filters

**Files:**
- Modify: `src/discover.jl:243-281`
- Test: `test/test_diff_scope.jl`

- [ ] **Step 1: Write the failing test**

```julia
@testset "discover with diff_lines" begin
    mktempdir() do dir
        src = joinpath(dir, "src"); mkpath(src)
        write(joinpath(src, "m.jl"), """
        function f(a, b)
            if a < b      # line 2
                return 1
            end
            return a > b  # line 5
        end
        """)
        all_sites = Gremlins.discover(src)
        # restrict to line 2 only
        dl = Dict("m.jl" => [2:2])
        scoped = Gremlins.discover(src; diff_lines = dl)
        @test !isempty(scoped)
        @test all(s -> s.line == 2, scoped)
        @test length(scoped) < length(all_sites)
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `discover` has no `diff_lines` kwarg (MethodError).

- [ ] **Step 3: Implement**

In `src/discover.jl`, add the kwarg to `discover` (line 243) signature:

```julia
function discover(
    dir_or_file::AbstractString;
    operators::Vector{MutationOperator} = DEFAULT_OPERATORS,
    root::Union{AbstractString, Nothing} = nothing,
    prune_equivalent::Bool = false,
    diff_lines::Union{Dict{String,Vector{UnitRange{Int}}}, Nothing} = nothing,
)::Vector{MutationSite}
```

At the end of `discover`, just before `return all_sites`, replace `return all_sites` with:

```julia
    if diff_lines !== nothing
        all_sites, _suppressed = scope_to_diff(all_sites, diff_lines)
    end
    return all_sites
```

(Note: `scope_to_diff` is defined in `diff_scope.jl`, included after `discover.jl` — at call time the function exists since `discover` runs after module load. If load order errors, move the `include("diff_scope.jl")` above `include("discover.jl")` in `Gremlins.jl`; both are pure definitions.)

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/discover.jl
git commit -m "feat(diff-scope): discover accepts diff_lines kwarg (post-filter)"
```

### Task A4: CLI `--in-diff` + no-silent-caps report line

**Files:**
- Modify: `gremlins-cli.jl` (repo-root CLI used by Sisyphus T4)
- Test: manual integration (pasted output — campaign rule)

- [ ] **Step 1: Read the CLI arg-parsing block**

Run: `grep -n "in-diff\|--files\|--max-sites\|ARGS\|diff_lines" gremlins-cli.jl`
Locate where flags are parsed and where `discover(...)` is called.

- [ ] **Step 2: Add `--in-diff <ref>` flag**

Parse `--in-diff <ref>` into `indiff_ref::Union{String,Nothing}`. Before discovery:

```julia
diff_lines = indiff_ref === nothing ? nothing :
    Gremlins.changed_lines(indiff_ref; pkgdir = pkgdir)
sites_all = Gremlins.discover(src_dir; operators = ops)
sites = diff_lines === nothing ? sites_all : first(Gremlins.scope_to_diff(sites_all, diff_lines))
if diff_lines !== nothing
    n, m = length(sites), length(sites_all)
    println(stderr, "scoped to diff $(indiff_ref): $n of $m discoverable sites ($(m-n) suppressed)")
end
```

(Use `scope_to_diff` directly here — not the `discover` kwarg — so the suppressed count is available for the report line. Do not pass `diff_lines` to `discover` in the CLI path; that would double-filter and lose the count.)

- [ ] **Step 3: Integration verify (pasted output required)**

```bash
cd /home/js/eidos/Gremlins
# make a throwaway change on a branch, then:
julia --project gremlins-cli.jl --in-diff HEAD~1 --max-sites 10 src
```
Expected: a `scoped to diff HEAD~1: N of M ...` line on stderr, and only changed-line sites mutated. Paste the output into the commit body.

- [ ] **Step 4: Commit**

```bash
git add gremlins-cli.jl
git commit -m "feat(diff-scope): --in-diff <ref> CLI flag with suppressed-count report

<pasted run output here>"
```

---

## Feature B — Julia-idiom operators

### File Structure
- Modify: `src/operators.jl` — three operators + append to `DEFAULT_OPERATORS`.
- Modify: `src/Gremlins.jl` — exports.
- Test: `test/test_idiom_operators.jl` (planted-mutant falsifiability per operator).
- Modify: `test/runtests.jl` — include it.

Confirmed node shapes (probed 2026-06-09):
- `a < b < c` → `K"comparison"`, children `[a, <, b, <, c]` (operators at even indices, Identifier leaves).
- `cond ? x : y` → `K"?"`, children `[cond, then, else]`.
- `a .+ b` / `a .< b` → `K"dotcall"`, children `[a, op, b]` (op is operator Identifier leaf at index 2).

**Multibyte hardening (atlas-flash plan review):** the replacers below index the
node text by JuliaSyntax byte offsets (`full[lo:hi]`). For ASCII operators on
ASCII operands this is codeunit-safe, but multibyte operands (e.g. `α < β < γ`)
can throw `StringIndexError` if an offset lands mid-char. If any replacer throws,
switch its extraction to `String(codeunits(full)[lo:hi])` (the pattern
`discover.jl` already uses). Task B5 adds a multibyte regression test that
exercises this path.

### Task B1: `OP_COMPARISON_CHAIN`

**Files:**
- Modify: `src/operators.jl`
- Test: `test/test_idiom_operators.jl`

- [ ] **Step 1: Write the failing test**

```julia
# test/test_idiom_operators.jl
using Test, Gremlins, JuliaSyntax

# helper: discover sites in an inline source string via a tmp file
function sites_for(code::String; ops=Gremlins.DEFAULT_OPERATORS)
    mktempdir() do d
        f = joinpath(d, "x.jl"); write(f, code)
        Gremlins.discover_file(f; root=d, operators=ops)
    end
end

@testset "OP_COMPARISON_CHAIN" begin
    code = "h(a,b,c) = a < b < c\n"
    sites = sites_for(code; ops=[Gremlins.OP_COMPARISON_CHAIN])
    # two swappable operator positions → two mutants
    @test length(sites) == 2
    muts = sort([s.replacement for s in sites])
    @test "a <= b < c" in muts
    @test "a < b <= c" in muts
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `OP_COMPARISON_CHAIN` not defined.

- [ ] **Step 3: Implement**

```julia
# src/operators.jl — after the boolean operators section

# ─── Comparison-chain operator ────────────────────────────────────────────────
# `a < b < c` parses as K"comparison" with children [a, <, b, <, c]; the binary
# relational ops (K"call") never reach it. Swap one comparator per mutant.

const _RELCHAIN_MAP = Dict{Symbol,String}(
    :<   => "<=", :<= => "<", :>  => ">=", :>= => ">",
    :(==) => "!=", :!= => "==",
)

const OP_COMPARISON_CHAIN = MutationOperator(
    :cmp_chain,
    "comparison-chain: swap one comparator",
    (node, src) -> JuliaSyntax.kind(node) == JuliaSyntax.K"comparison" &&
                   !JuliaSyntax.is_leaf(node) &&
                   !_is_inside_macro_def(node),
    (node, src) -> begin
        full = node_text(node, src)
        nstart = first(JuliaSyntax.byte_range(node))
        cs = JuliaSyntax.children(node)
        outs = String[]
        # operators sit at even indices 2,4,...
        for i in 2:2:length(cs)-1
            opnode = cs[i]
            (JuliaSyntax.is_leaf(opnode) && opnode.val isa Symbol) || continue
            to = get(_RELCHAIN_MAP, opnode.val, nothing)
            to === nothing && continue
            br = JuliaSyntax.byte_range(opnode)
            lo = first(br) - nstart + 1
            hi = last(br)  - nstart + 1
            push!(outs, full[1:lo-1] * to * full[hi+1:end])
        end
        return outs            # Vector{String}: multi-replacement (distinct ids)
    end,
)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 5: Falsifiability test (campaign rule)**

```julia
@testset "OP_COMPARISON_CHAIN falsifiability" begin
    # a planted killable mutant must be killed by a discriminating test
    f(a,b,c) = a < b < c
    @test f(1,2,3) == true
    # mutant `a <= b < c` changes f(1,1,3): orig false, mutant true → killable
    @test f(1,1,3) == false
end
```

Run + paste output. Commit:

```bash
git add src/operators.jl test/test_idiom_operators.jl test/runtests.jl
git commit -m "feat(operators): OP_COMPARISON_CHAIN — swap one comparator in a<b<c

<pasted test output>"
```

### Task B2: `OP_TERNARY_SWAP`

**Files:**
- Modify: `src/operators.jl`
- Test: `test/test_idiom_operators.jl`

- [ ] **Step 1: Write the failing test**

```julia
@testset "OP_TERNARY_SWAP" begin
    code = "t(c,x,y) = c ? x : y\n"
    sites = sites_for(code; ops=[Gremlins.OP_TERNARY_SWAP])
    @test length(sites) == 1
    @test sites[1].replacement == "c ? y : x"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `OP_TERNARY_SWAP` not defined.

- [ ] **Step 3: Implement**

```julia
# src/operators.jl

# ─── Ternary-swap operator ────────────────────────────────────────────────────
# `cond ? then : else` is K"?" with children [cond, then, else].
# Swap the then/else byte spans, preserving cond / `?` / `:` / whitespace exactly.

const OP_TERNARY_SWAP = MutationOperator(
    :ternary_swap,
    "ternary: swap then/else",
    (node, src) -> JuliaSyntax.kind(node) == JuliaSyntax.K"?" &&
                   !JuliaSyntax.is_leaf(node) &&
                   !_is_inside_macro_def(node),
    (node, src) -> begin
        cs = JuliaSyntax.children(node)
        (isnothing(cs) || length(cs) != 3) &&
            throw(MutationError("OP_TERNARY_SWAP: expected 3 children, got $(isnothing(cs) ? 0 : length(cs))"))
        full = node_text(node, src)
        nstart = first(JuliaSyntax.byte_range(node))
        tbr = JuliaSyntax.byte_range(cs[2]); ebr = JuliaSyntax.byte_range(cs[3])
        ts = first(tbr) - nstart + 1; te = last(tbr) - nstart + 1
        es = first(ebr) - nstart + 1; ee = last(ebr) - nstart + 1
        then_txt = full[ts:te]; else_txt = full[es:ee]
        between  = full[te+1:es-1]      # the " : "
        return full[1:ts-1] * else_txt * between * then_txt * full[ee+1:end]
    end,
)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 5: Falsifiability + equivalent-noise note**

```julia
@testset "OP_TERNARY_SWAP falsifiability" begin
    t(c,x,y) = c ? x : y
    @test t(true, 1, 2) == 1          # mutant `c ? y : x` gives 2 → killable
    # documented equivalent noise: `c ? z : z` swap is observationally identical.
end
```

Commit:

```bash
git add src/operators.jl test/test_idiom_operators.jl
git commit -m "feat(operators): OP_TERNARY_SWAP — swap then/else branches

<pasted test output>"
```

### Task B3: `OP_BROADCAST_DROP`

**Files:**
- Modify: `src/operators.jl`
- Test: `test/test_idiom_operators.jl`

- [ ] **Step 1: Write the failing test**

```julia
@testset "OP_BROADCAST_DROP" begin
    s1 = sites_for("g(a,b) = a .+ b\n"; ops=[Gremlins.OP_BROADCAST_DROP])
    @test length(s1) == 1
    @test s1[1].replacement == "a + b"
    s2 = sites_for("g(a,b) = a .< b\n"; ops=[Gremlins.OP_BROADCAST_DROP])
    @test s2[1].replacement == "a < b"
    # f.(x) prefix broadcast is out of scope v1 → no site
    s3 = sites_for("g(f,x) = f.(x)\n"; ops=[Gremlins.OP_BROADCAST_DROP])
    @test isempty(s3)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `OP_BROADCAST_DROP` not defined.

- [ ] **Step 3: Implement**

```julia
# src/operators.jl

# ─── Broadcast-drop operator ──────────────────────────────────────────────────
# De-vectorize an infix dotted operator: `a .+ b` → `a + b`, `a .< b` → `a < b`.
# K"dotcall" with an operator Identifier leaf at child 2. The broadcasting `.`
# sits immediately before that operator in the source. v1 scope: infix dotted
# operators only (prefix `f.(x)` deferred — different splice geometry).

const OP_BROADCAST_DROP = MutationOperator(
    :broadcast_drop,
    "broadcast: drop the . (de-vectorize)",
    (node, src) -> begin
        JuliaSyntax.kind(node) == JuliaSyntax.K"dotcall" || return false
        _is_inside_macro_def(node) && return false
        cs = JuliaSyntax.children(node)
        (!isnothing(cs) && length(cs) == 3 &&
         JuliaSyntax.is_leaf(cs[2]) && cs[2].val isa Symbol) || return false
        # the operator's source text must be preceded by a '.' (infix dotted op)
        opbr = JuliaSyntax.byte_range(cs[2])
        first(opbr) > 1 && codeunit(src, first(opbr) - 1) == UInt8('.')
    end,
    (node, src) -> begin
        full = node_text(node, src)
        nstart = first(JuliaSyntax.byte_range(node))
        cs = JuliaSyntax.children(node)
        opbr = JuliaSyntax.byte_range(cs[2])
        dot_off = first(opbr) - 1 - nstart + 1     # 1-based offset of '.' in full
        return full[1:dot_off-1] * full[dot_off+1:end]
    end,
)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 5: Falsifiability + equivalent-noise note**

```julia
@testset "OP_BROADCAST_DROP falsifiability" begin
    g(a,b) = a .+ b
    @test g([1,2],[3,4]) == [4,6]    # mutant `a + b` on vectors → MethodError/diff → killable
    # documented equivalent noise: already-scalar operands (a .+ b == a + b).
end
```

Commit:

```bash
git add src/operators.jl test/test_idiom_operators.jl
git commit -m "feat(operators): OP_BROADCAST_DROP — de-vectorize infix dotted ops

<pasted test output>"
```

### Task B5: Multibyte-source regression (atlas-flash hardening)

**Files:**
- Test: `test/test_idiom_operators.jl`

- [ ] **Step 1: Write the test** (must pass once replacers are codeunit-safe)

```julia
@testset "operators on multibyte source" begin
    # α/β/γ are 2-byte UTF-8 — byte offsets diverge from char indices here.
    s = sites_for("h(α,β,γ) = α < β < γ\n"; ops=[Gremlins.OP_COMPARISON_CHAIN])
    @test length(s) == 2
    @test "α <= β < γ" in [x.replacement for x in s]
    # ternary + broadcast on multibyte operands must not throw
    @test !isempty(sites_for("t(λ,x,y)= λ ? x : y\n"; ops=[Gremlins.OP_TERNARY_SWAP]))
    @test !isempty(sites_for("g(ψ,φ)= ψ .+ φ\n"; ops=[Gremlins.OP_BROADCAST_DROP]))
end
```

- [ ] **Step 2: Run; if any replacer throws `StringIndexError`**, change its slice
extractions from `full[lo:hi]` to `String(codeunits(full)[lo:hi])` (and operand
offsets likewise). Re-run until green.

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/test_idiom_operators.jl src/operators.jl
git commit -m "test(operators): multibyte-source regression; codeunit-safe splicing"
```

### Task B4: Register operators + exports

**Files:**
- Modify: `src/operators.jl:431` (`DEFAULT_OPERATORS`)
- Modify: `src/Gremlins.jl` (exports)

- [ ] **Step 1: Append to `DEFAULT_OPERATORS`** (after `OP_STMT_DELETE`, preserving order — I2):

```julia
    OP_STMT_DELETE,
    OP_COMPARISON_CHAIN,
    OP_TERNARY_SWAP,
    OP_BROADCAST_DROP,
]
```

- [ ] **Step 2: Export** in `src/Gremlins.jl`:

```julia
export OP_COMPARISON_CHAIN, OP_TERNARY_SWAP, OP_BROADCAST_DROP
```

- [ ] **Step 3: Determinism regression — self-discovery still stable**

Run: `julia --project -e 'using Gremlins; s1=Gremlins.discover("src"); s2=Gremlins.discover("src"); @assert [x.id for x in s1]==[x.id for x in s2]; println("sites=", length(s1), " deterministic OK")'`
Expected: prints a stable site count, no assertion error.

- [ ] **Step 4: Full suite**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS (all prior + new idiom tests).

- [ ] **Step 5: Commit**

```bash
git add src/operators.jl src/Gremlins.jl
git commit -m "feat(operators): register comparison-chain/ternary/broadcast in DEFAULT_OPERATORS"
```

---

## Feature C — Mutant schemata (compile-once mode)

> **GATE:** The implementation plan for C is consulted with atlas-flash before C is built (per the user's instruction + autopilot protocol). Do NOT start C tasks until that consult is folded in.

### File Structure
- Modify: `src/warm.jl` — add `fallback_schema_ineligible` to `FallbackReason`; add `__GREM_ACTIVE` const to the module.
- Create: `src/schema.jl` — eligibility (`schema_eligible`), instrumentation codegen (`instrument_function`), schema runner (`run_mutations_schema`).
- Modify: `src/Gremlins.jl` — `include("schema.jl")` + exports.
- Test: `test/test_schema.jl`.

### Design recap (from spec, atlas-flash-tightened — DESIGN + PLAN reviews)
- Schema-eligible = **operator-swap ops only**: `:relop_lt_le`, `:relop_le_lt`, `:relop_gt_ge`, `:relop_ge_gt`, `:relop_eq_neq`, `:relop_neq_eq`, `:bool_and_or`, `:bool_or_and`, `:cmp_chain`. Value-mutating ops (literal/bool/const-pool/ternary) and shape-changing ops (stmt-delete/return-nothing/dispatch-swap/broadcast-drop) → warm fallback.
- **Constant-literal guard:** reject a site whose original expression lowers to a constant `Literal` (reuses `equivalence.jl` lowered-IR pass) — closes the const-propagation/`Val`-dispatch hole atlas-flash flagged.
- **Disjoint-only guard (atlas-flash PLAN review, bug 1):** operator-swap sites
  *nest* — in `(a<b) && (c>d)` the `&&` site's byte-range contains both relop
  sites. A flat byte-splice would corrupt offsets. v1 fix (YAGNI + sound): a site
  is schema-run only if its byte-range is **disjoint** from every other eligible
  site in the same function; any eligible site that contains or is contained by
  another → warm fallback (`fallback_schema_ineligible`, taxonomy-visible).
  `instrument_function` stays the simple flat right-to-left splice, now provably
  disjoint (defensive assert). Structural tree-render of nested sites is deferred.
- **World-age (atlas-flash PLAN review, bug 2):** instrumented functions are
  eval'd **once** at setup (their invalidation propagates to callers on next
  call). Per-mutant test execution **reuses the warm worker's fresh-include
  primitive** — tests are include'd fresh each mutant, compiled in a world ≥ the
  instrumentation world, so they call the instrumented methods and read
  `__GREM_ACTIVE` at runtime. Schema does NOT compile tests once and re-invoke
  (that would call stale methods). The C3 e2e test asserts a planted mutant is
  actually **killed ≥ 1** — this fails loudly if world-age silently breaks.
- Transform: site `EXPR` (id k local to file) → `(Main.__GREM_ACTIVE[] == k ? (MUT) : (EXPR))`. Module compiles once; flip `Main.__GREM_ACTIVE[]=k` per mutant.
- **Soundness checks:** (1) schema baseline (`=0`) ≡ plain baseline else hard error; (2) warm-vs-schema agreement on `min(10,N)` sample, mismatch = hard error; (3) hot-path runtime auto-disable if schema test-time > warm test-time on the sample.

### Task C1: enum + active Ref + eligibility predicate

**Files:**
- Modify: `src/warm.jl:51` (enum), module top (const)
- Create: `src/schema.jl`
- Test: `test/test_schema.jl`

- [ ] **Step 1: Write the failing test**

```julia
# test/test_schema.jl
using Test, Gremlins

@testset "schema_eligible" begin
    # operator-swap op on variable operands → eligible
    mk(opid, orig) = Gremlins.MutationSite("i", "x.jl", 1:length(orig), opid,
                                           "n", orig, "z", "<=", 1)
    @test Gremlins.schema_eligible(mk(:relop_lt_le, "a < b"))      # operator swap, vars
    @test !Gremlins.schema_eligible(mk(:int_incr, "0"))           # value-mutating
    @test !Gremlins.schema_eligible(mk(:stmt_delete, "f()"))      # shape-changing
    @test !Gremlins.schema_eligible(mk(:ternary_swap, "c ? x : y")) # value-mutating
    # constant-literal guard: operator swap on literal operands that const-fold
    @test !Gremlins.schema_eligible(mk(:relop_lt_le, "1 < 2"))    # folds → ineligible
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `schema_eligible` not defined.

- [ ] **Step 3: Implement enum + const + eligibility**

In `src/warm.jl`, add to the `@enum FallbackReason` block (line ~51, append — never reorder existing):

```julia
    fallback_schema_ineligible
```

At the Gremlins module level (in `src/schema.jl`, included into the module):

```julia
# src/schema.jl
# Mutant schemata: compile a function's operator-swap sites once behind a global
# switch; flip the switch per mutant. No per-mutant recompile. atlas-flash-
# tightened: operator-swap ops only + constant-literal guard + hot-path auto-off.

"""Global mutant selector. 0 = all-original baseline; k = activate site k."""
const __GREM_ACTIVE = Ref(0)

const _SCHEMA_ELIGIBLE_OPS = Set{Symbol}([
    :relop_lt_le, :relop_le_lt, :relop_gt_ge, :relop_ge_gt,
    :relop_eq_neq, :relop_neq_eq, :bool_and_or, :bool_or_and, :cmp_chain,
])

"""
    schema_eligible(site::MutationSite) -> Bool

True iff `site` may run in schema mode: an operator-swap op whose original
expression does NOT lower to a constant literal (the const-prop/Val-dispatch
guard). Everything else falls back to the warm path.
"""
function schema_eligible(site::MutationSite)::Bool
    site.op_id in _SCHEMA_ELIGIBLE_OPS || return false
    return !_lowers_to_constant(site.original)
end

"""
    _lowers_to_constant(expr_text) -> Bool

True if `expr_text` parses and lowers to a constant value (e.g. `1 < 2`).
Conservative: on any parse/lower failure return `false` (keep eligible only when
we are NOT sure it folds — wait: soundness is one-directional toward SAFETY, so
uncertainty must make the site INELIGIBLE). Therefore: return `true` (=> treat as
folding => ineligible) on uncertainty.
"""
function _lowers_to_constant(expr_text::AbstractString)::Bool
    ex = try
        Meta.parse(expr_text)
    catch
        return true     # cannot analyze → assume folds → ineligible (safe)
    end
    lowered = try
        Meta.lower(Main, ex)
    catch
        return true
    end
    # A constant-folded expression lowers to `return <constant>` with no SSA ops.
    if lowered isa Expr && lowered.head === :thunk
        code = lowered.args[1].code
        # single `return <literal/constant>` body → folded
        return length(code) == 1 && code[1] isa Core.ReturnNode &&
               !(code[1].val isa Core.SSAValue || code[1].val isa Expr)
    end
    return !(lowered isa Expr)   # bare literal → folded
end
```

- [ ] **Step 4: include + run test**

Add `include("schema.jl")` to `src/Gremlins.jl` (after `equivalence.jl`); `export schema_eligible`. Add `include("test_schema.jl")` to `test/runtests.jl`.

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/warm.jl src/schema.jl src/Gremlins.jl test/test_schema.jl test/runtests.jl
git commit -m "feat(schema): FallbackReason.fallback_schema_ineligible + schema_eligible guard"
```

### Task C2: `instrument_function` — multi-site guarded splice

**Files:**
- Modify: `src/schema.jl`
- Test: `test/test_schema.jl`

The crux. Given a function's source text, its node, and the eligible sites within it (each with a local key `k` and a replacement), produce ONE instrumented source where each site `EXPR` becomes `(Main.__GREM_ACTIVE[] == k ? (MUT) : (EXPR))`. Splice right-to-left by byte offset so earlier offsets stay valid.

- [ ] **Step 1: Write the failing test**

```julia
@testset "instrument_function" begin
    # function body with two operator-swap sites at known byte ranges
    src = "f(a,b) = a < b && a > 0"
    #      123456789...                byte offsets (1-based)
    # site1: "a < b"  → key 1, mutated "a <= b"
    # site2: "a > 0"  → key 2, mutated "a >= 0"
    r1 = findfirst("a < b", src); r2 = findfirst("a > 0", src)
    sites = [(UnitRange{Int}(r1), 1, "a <= b"),
             (UnitRange{Int}(r2), 2, "a >= 0")]
    out = Gremlins.instrument_function(src, sites)
    @test occursin("Main.__GREM_ACTIVE[] == 1 ? (a <= b) : (a < b)", out)
    @test occursin("Main.__GREM_ACTIVE[] == 2 ? (a >= 0) : (a > 0)", out)
    # original tail/head bytes preserved
    @test startswith(out, "f(a,b) = ")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `instrument_function` not defined.

- [ ] **Step 3: Implement**

```julia
# src/schema.jl

"""
    instrument_function(src, sites) -> String

`sites :: Vector{Tuple{UnitRange{Int}, Int, String}}` — (byte_range, key, mutated_text)
relative to `src` (1-based). Ranges MUST be pairwise disjoint (the disjoint-only
guard in `run_mutations_schema` enforces this; nested sites fall back to warm).
Returns `src` with each site's bytes replaced by
`(Main.__GREM_ACTIVE[] == key ? (mutated) : (original))`, splicing right-to-left
so earlier offsets stay valid.
"""
function instrument_function(src::AbstractString,
        sites::Vector{Tuple{UnitRange{Int},Int,String}})::String
    # Defensive: disjointness is a precondition (atlas-flash bug 1). Verify.
    ranges = sort([s[1] for s in sites]; by = first)
    for i in 2:length(ranges)
        first(ranges[i]) <= last(ranges[i-1]) &&
            throw(MutationError("instrument_function: overlapping sites $(ranges[i-1]) / $(ranges[i]) — nested sites must route to warm fallback"))
    end
    ordered = sort(sites; by = s -> first(s[1]), rev = true)
    buf = String(src)
    for (br, key, mut) in ordered
        orig = buf[br]
        guarded = "(Main.__GREM_ACTIVE[] == $key ? ($mut) : ($orig))"
        buf = buf[1:first(br)-1] * guarded * buf[last(br)+1:end]
    end
    return buf
end

"""
    disjoint_eligible(sites) -> (schema::Vector, nested::Vector)

Partition eligible sites: a site is schema-runnable only if its byte-range is
disjoint from every other eligible site in the SAME file. Containing/contained
sites go to `nested` (→ warm fallback). O(n²) is fine — n is per-function small.
"""
function disjoint_eligible(sites::Vector{MutationSite})
    schema = MutationSite[]; nested = MutationSite[]
    for (i, s) in enumerate(sites)
        overlaps = any(enumerate(sites)) do (j, t)
            j != i && s.relpath == t.relpath &&
                !(last(s.byte_range) < first(t.byte_range) ||
                  last(t.byte_range) < first(s.byte_range))
        end
        push!(overlaps ? nested : schema, s)
    end
    return schema, nested
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 5: Round-trip-at-baseline test (soundness)**

```julia
@testset "instrument baseline is observationally original" begin
    src = "ff(a,b) = a < b"
    r = UnitRange{Int}(findfirst("a < b", src))
    out = Gremlins.instrument_function(src, [(r, 1, "a <= b")])
    Gremlins.__GREM_ACTIVE[] = 0
    @eval Main begin $(Meta.parse(out)) end
    @test Base.invokelatest(Main.ff, 1, 2) == true     # active=0 → original `<`
    @test Base.invokelatest(Main.ff, 2, 2) == false
    Gremlins.__GREM_ACTIVE[] = 1
    @test Base.invokelatest(Main.ff, 2, 2) == true     # active=1 → mutated `<=`
    Gremlins.__GREM_ACTIVE[] = 0
end
```

- [ ] **Step 6: Nested-sites partition test (atlas-flash bug 1)**

```julia
@testset "disjoint_eligible routes nested sites to warm" begin
    # (a < b) && (c > d): the && site contains both relop sites → all nest
    sites = filter(Gremlins.schema_eligible,
                   sites_for("q(a,b,c,d) = (a < b) && (c > d)\n"))
    schema, nested = Gremlins.disjoint_eligible(sites)
    @test !isempty(nested)               # at least the && (or its children) fall back
    # disjoint case: two independent comparisons → both schema-runnable
    s2 = filter(Gremlins.schema_eligible,
                sites_for("r(a,b,c,d) = (a < b, c > d)\n"))
    sc2, ne2 = Gremlins.disjoint_eligible(s2)
    @test isempty(ne2) && length(sc2) == 2
end
```

Run + commit:

```bash
git add src/schema.jl test/test_schema.jl
git commit -m "feat(schema): instrument_function (disjoint splice) + disjoint_eligible partition

<pasted test output>"
```

### Task C3: `run_mutations_schema` — group by function, compile once, flip

**Files:**
- Modify: `src/schema.jl`
- Test: `test/test_schema.jl`

Builds on the existing warm worker pattern (`worker_main.jl` `_extract_toplevel_at_byte`, eval-into-package-module). Schema groups eligible sites by their enclosing top-level function, instruments each function once, evals each instrumented function once into the package module, then loops: set `__GREM_ACTIVE[]=k`, run the covering tests for site k, classify (reuse the warm classifier — killed needs a captured failing test, I3).

- [ ] **Step 1: Write the failing test** (small in-process package)

```julia
@testset "run_mutations_schema end-to-end" begin
    mktempdir() do dir
        # minimal package with one eligible site + a discriminating test
        # (full scaffold: Project.toml, src/Demo.jl with `gt(a,b)=a<b`, test/runtests.jl)
        # ... build via helper build_demo_pkg(dir) defined in test/test_schema.jl ...
        # build_demo_pkg plants a KILLABLE mutant: src has `gt(a,b)=a<b` and the
        # test asserts gt(1,2)==true && gt(2,2)==false (the `<`→`<=` mutant flips
        # gt(2,2) → killed). This is the world-age falsifiability check.
        pkgdir = build_demo_pkg(dir)
        sites = filter(Gremlins.schema_eligible, Gremlins.discover(joinpath(pkgdir,"src")))
        cmap  = Gremlins.baseline_run(pkgdir)
        res   = Gremlins.run_mutations_schema(pkgdir, sites, cmap; pkg_name="Demo")
        @test res.killed + res.survived == length(sites)
        @test res.schema_ran >= 1                 # at least one ran in schema mode
        @test res.killed >= 1                      # WORLD-AGE GUARD (atlas-flash bug 2):
                                                   # if instrumented fn invisible to tests,
                                                   # the planted mutant survives → this fails.
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `run_mutations_schema` not defined.

- [ ] **Step 3: Implement** the runner. Signature mirrors `run_mutations_warm`:

```julia
function run_mutations_schema(
    pkgdir::AbstractString,
    sites::Vector{MutationSite},
    cmap::CoverageMap;
    test_dir::AbstractString  = "test",
    test_file::AbstractString = "runtests.jl",
    baseline_elapsed::Union{Float64,Nothing} = nothing,
    pkg_name::Union{String,Nothing} = nothing,
    verbose::Bool = false,
)::SchemaRunResult
    # 1. Partition: elig = filter(schema_eligible, sites).
    #    schema_sites, nested = disjoint_eligible(elig)   # atlas-flash bug 1
    #    warm_sites = (sites not in elig) ∪ nested        # all fall back to warm
    # 2. Group schema_sites by (relpath, enclosing top-level function byte-range)
    #    using the JuliaSyntax tree (reuse worker_main.jl _extract_toplevel_at_byte
    #    to find each site's enclosing function node).
    # 3. For each function group: assign local keys 1..m, instrument_function(...),
    #    eval the instrumented function ONCE into the package module (invalidation
    #    propagates to callers on next call — atlas-flash bug 2).
    # 4. Soundness — schema baseline: set __GREM_ACTIVE[]=0, run tests once via the
    #    WARM WORKER'S FRESH-INCLUDE primitive; assert result == plain baseline
    #    (cmap baseline). Mismatch → throw MutationError.
    # 5. Per site k: __GREM_ACTIVE[] = k; run covering tests (cmap[site.line]) via
    #    the SAME fresh-include primitive (tests compiled in a world ≥ instrument
    #    world → call instrumented methods, read the Ref at runtime); classify via
    #    the warm classifier (captured failing test = killed, I3); reset Ref = 0.
    # 6. Run warm_sites on the warm path (run_mutations_warm); merge results.
    #    nested/ineligible counted under fallback_schema_ineligible in taxonomy.
    # Returns SchemaRunResult{killed, survived, timeout, no_coverage,
    #   schema_ran, warm_fallback, taxonomy}.
end
```

Define `struct SchemaRunResult` alongside (mirror `WarmRunResult` fields + `schema_ran::Int`, `warm_fallback::Int`). Reuse `run_mutations_warm` for step 6 by passing the ineligible subset.

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/schema.jl test/test_schema.jl
git commit -m "feat(schema): run_mutations_schema — compile-once group runner

<pasted test output>"
```

### Task C4: soundness — agreement sample + hot-path auto-disable

**Files:**
- Modify: `src/schema.jl`
- Test: `test/test_schema.jl`

- [ ] **Step 1: Write the failing test**

```julia
@testset "schema/warm agreement + hot-path guard" begin
    mktempdir() do dir
        pkgdir = build_demo_pkg(dir)
        sites = filter(Gremlins.schema_eligible, Gremlins.discover(joinpath(pkgdir,"src")))
        cmap  = Gremlins.baseline_run(pkgdir)
        # agreement: schema classification == warm classification on the sample
        agree = Gremlins.schema_warm_agreement(pkgdir, sites, cmap; pkg_name="Demo", k=min(10,length(sites)))
        @test agree.mismatches == 0
        @test agree.schema_time > 0 && agree.warm_time > 0
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `schema_warm_agreement` not defined.

- [ ] **Step 3: Implement** `schema_warm_agreement(pkgdir, sites, cmap; pkg_name, k)` → `(mismatches::Int, schema_time::Float64, warm_time::Float64)`: run the first `k` eligible sites both ways, assert identical kill/survive (mismatch = hard `MutationError` in the runner; here count for the test). Record summed test wall-time each way. In `run_mutations_schema`, call this before the full run; if `schema_time > warm_time`, log `schema auto-disabled (hot path): schema=<s> warm=<s>` and route the whole file's eligible sites through warm instead.

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/schema.jl test/test_schema.jl
git commit -m "feat(schema): warm-agreement soundness sample + hot-path auto-disable

<pasted test output>"
```

### Task C5: wire into run path, report taxonomy, EDD benchmark gate

**Files:**
- Modify: `src/Gremlins.jl` (export `run_mutations_schema`, `SchemaRunResult`)
- Modify: `src/report.jl` — show schema-ran vs warm-fallback split in `print_summary`
- Modify: `gremlins-cli.jl` — `--schema` flag (opt-in)

- [ ] **Step 1: Report split** — extend `print_summary` to print `schema-ran: N  warm-fallback: M  (schema-ineligible: …)` when a `SchemaRunResult` is passed. Add a test in `test/test_schema.jl` asserting the summary string contains both counts.

- [ ] **Step 2: CLI flag** — `--schema` selects `run_mutations_schema`; default stays warm. Print the auto-disable line if it fires (no-silent-caps).

- [ ] **Step 3: EDD GATE (campaign rule — pasted output)** — benchmark on the JUI dogfood package, same 25-site setup as the M2 ≥5× gate:

```bash
# from Gremlins, against the JUI package path used in the M2 gate
julia --project gremlins-cli.jl --schema --max-sites 25 <jui-src>   # schema
julia --project gremlins-cli.jl --warm   --max-sites 25 <jui-src>   # warm baseline
```
Target: schema ≥2× faster than warm on eligible-heavy files, agreement mismatches = 0, what fell back reported. Paste both runs into the commit + update `ROADMAP.yaml` (new m4 phase) and `docs/INVARIANTS.md` if schema adds an invariant (e.g. "I6 — schema baseline ≡ plain baseline or hard error").

- [ ] **Step 4: Commit**

```bash
git add src/Gremlins.jl src/report.jl gremlins-cli.jl ROADMAP.yaml docs/INVARIANTS.md
git commit -m "feat(schema): wire run path + report taxonomy + EDD benchmark gate

<pasted schema-vs-warm benchmark output>"
```

---

## Self-Review (against spec)

- **A (git-diff scope):** A1 parse, A2 changed_lines+filter, A3 discover kwarg, A4 CLI+report-line. Covers spec §A incl. no-silent-caps report contract. ✓
- **B (idiom operators):** B1 comparison-chain, B2 ternary-swap, B3 broadcast-drop, B5 multibyte regression, B4 register+exports+determinism. Each has a falsifiability test (campaign rule). Node kinds probe-verified. ✓
- **C (schemata):** C1 enum+eligibility+const-literal guard, C2 instrument codegen+disjoint partition, C3 group runner, C4 agreement+hot-path auto-disable, C5 wire+report+EDD gate. Covers spec §C incl. the three DESIGN-review tightenings (operator-swap-only, constant-literal guard, hot-path auto-disable) AND the two HIGH PLAN-review fixes: disjoint-only scoping (nesting bug 1) and fresh-include + killed≥1 world-age guard (bug 2). ✓
- **Invariants:** I2 (append operators, sites sorted), I3 (killed needs captured failing test — reuse warm classifier), I4 (discovery static), I1 (schema evals in-memory, warm property). New candidate I6 noted in C5. ✓
- **Sequencing:** A → B → C; C gated on the second atlas-flash consult of THIS plan. A and B are independently mergeable.

## Known coarse spots (honest)
- C3's runner body is specified as an ordered protocol with reused primitives
  (`_extract_toplevel_at_byte`, warm classifier) rather than line-complete code —
  it integrates with the 1161-line `warm.jl`. The implementing agent reads
  `worker_main.jl` + `warm.jl` first; the protocol steps and the `SchemaRunResult`
  shape are pinned. This is the one task to expand into sub-steps at execution
  time if it proves larger than a single bite.
