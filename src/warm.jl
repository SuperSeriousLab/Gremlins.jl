# warm.jl — Warm-worker pool execution for Gremlins.jl (M2b)
#
# Design:
#   - ONE persistent Julia worker process per run (started lazily, recycled periodically).
#   - Worker starts with --project=<pkgdir>, loads the target package ONCE.
#   - Per mutant (warm path, disk NEVER touched):
#       a. Core.eval(TargetPkg, mutated_body)  — replaces methods in-place
#       b. Run test file in fresh Module via Base.invokelatest(Base.include, m, test_path)
#       c. Core.eval(TargetPkg, original_body) — always restored (try/finally in worker)
#   - Protocol: JSON-Lines over worker's stdin/stdout.
#   - Worker recycled every WORKER_RECYCLE_INTERVAL mutants or after fallback_evalerr.
#   - Ineligible sites (macro defs, type defs, const globals) route cold directly.
#   - Dynamic fallback: warm eval error → cold re-run + fallback_evalerr taxonomy.
#   - I4 agreement invariant: ≥10 warm-run mutants sampled and re-run cold;
#     any outcome mismatch is a hard error surfaced in the report.
#
# Public API:
#   WarmEligibility           — struct with flag + reason
#   FallbackReason            — enum
#   WarmRunResult             — warm-run summary
#   classify_warm_eligibility — static eligibility check for a MutationSite
#   run_mutations_warm        — warm-pool runner (returns WarmRunResult)
#   GREMLINS_VERSION          — version string used in cache keys

import Base64

# ─── Gremlins version string (cache key component) ────────────────────────────

const GREMLINS_VERSION = "0.1.0-m2b"

# ─── Worker recycle interval ──────────────────────────────────────────────────

"""Number of warm mutants run before recycling the worker (state-pollution hygiene)."""
const WORKER_RECYCLE_INTERVAL = 25

# ─── Fallback taxonomy ────────────────────────────────────────────────────────

"""
    FallbackReason

Enum classifying why a mutant ran on the cold path instead of the warm path.

Values:
- `warm_ok`           — ran warm successfully, no fallback
- `fallback_macro`    — site is inside a macro definition (static)
- `fallback_typedef`  — site is inside struct/abstract/primitive type def (static)
- `fallback_const`    — site is inside a const global assignment (static)
- `fallback_evalerr`  — warm eval threw an exception (dynamic)
- `fallback_pollution` — warm eval left state detectable by subsequent tests (reserved)
"""
@enum FallbackReason begin
    warm_ok
    fallback_macro
    fallback_typedef
    fallback_const
    fallback_evalerr
    fallback_pollution
end

# ─── Warm eligibility ─────────────────────────────────────────────────────────

"""
    WarmEligibility

Static classification of whether a mutation site can run on the warm path.

Fields:
- `eligible`  — true if the site can use the warm path
- `reason`    — FallbackReason (warm_ok when eligible, otherwise explains why not)
"""
struct WarmEligibility
    eligible::Bool
    reason::FallbackReason
end

# ─── Static eligibility classification ───────────────────────────────────────

"""
    classify_warm_eligibility(site::MutationSite) -> WarmEligibility

Static check: parse the source file and determine whether the mutation site
is inside a macro definition, type definition, or const global assignment.
These constructs cannot be safely eval'd into a fresh anonymous module.

Uses JuliaSyntax tree ancestry — never regex.
"""
function classify_warm_eligibility(site::MutationSite, pkgdir::AbstractString)::WarmEligibility
    abs_path = _find_abs_path(pkgdir, site)
    abs_path === nothing && return WarmEligibility(true, warm_ok)  # assume eligible if can't locate

    src = try
        read(abs_path, String)
    catch
        return WarmEligibility(true, warm_ok)
    end

    tree = try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, src;
            filename=abs_path, ignore_errors=true)
    catch
        return WarmEligibility(true, warm_ok)
    end

    # Find the node covering the mutation's byte range start
    target_byte = first(site.byte_range)
    node = _find_node_at_byte(tree, target_byte, src)
    node === nothing && return WarmEligibility(true, warm_ok)

    reason = _check_ancestry(node)
    return WarmEligibility(reason == warm_ok, reason)
end

"""
Walk ancestry checking for ineligible parent kinds.
Returns warm_ok if no disqualifying ancestor found, else the reason.
"""
function _check_ancestry(node::JuliaSyntax.SyntaxNode)::FallbackReason
    p = node.parent
    while !isnothing(p)
        k = JuliaSyntax.kind(p)
        # Macro definition body
        if k == JuliaSyntax.K"macro"
            return fallback_macro
        end
        # Struct / abstract type / primitive type definitions
        if k in (JuliaSyntax.K"struct", JuliaSyntax.K"abstract",
                 JuliaSyntax.K"primitive")
            return fallback_typedef
        end
        # Const assignment at module level
        if k == JuliaSyntax.K"const"
            return fallback_const
        end
        p = p.parent
    end
    return warm_ok
end

"""
Find the deepest leaf node whose byte range contains `target_byte`.
"""
function _find_node_at_byte(
    root::JuliaSyntax.SyntaxNode,
    target_byte::Int,
    src::String,
)::Union{JuliaSyntax.SyntaxNode, Nothing}
    br = JuliaSyntax.byte_range(root)
    (first(br) <= target_byte <= last(br)) || return nothing

    cs = JuliaSyntax.children(root)
    if !isnothing(cs)
        for child in cs
            result = _find_node_at_byte(child, target_byte, src)
            result !== nothing && return result
        end
    end
    return root
end

"""
Find the absolute path to a site's source file.
Returns nothing if not locatable.
"""
function _find_abs_path(pkgdir::AbstractString, site::MutationSite)::Union{String, Nothing}
    candidate = joinpath(pkgdir, site.relpath)
    isfile(candidate) && return candidate
    candidate2 = joinpath(pkgdir, "src", site.relpath)
    isfile(candidate2) && return candidate2
    return nothing
end

# ─── WarmMutantResult ─────────────────────────────────────────────────────────

"""
    WarmMutantResult

Extends MutantResult with warm-path metadata.
"""
struct WarmMutantResult
    base::MutantResult         # underlying outcome (same enum as cold path)
    fallback_reason::FallbackReason  # warm_ok = ran warm; else = cold fallback cause
    warm_elapsed::Float64      # 0.0 if ran cold
    cold_elapsed::Float64      # 0.0 if ran warm (or matched warm)
end

# ─── WarmRunResult ─────────────────────────────────────────────────────────────

"""
    WarmRunResult

Complete result of a warm-pool mutation run.

Includes I4 agreement check results and fallback taxonomy counts.
"""
struct WarmRunResult
    run::RunResult                       # base run (warm outcomes, adapted)
    warm_results::Vector{WarmMutantResult}
    fallback_taxonomy::Dict{FallbackReason, Int}
    i4_sample_count::Int
    i4_mismatches::Vector{String}        # non-empty = hard error
    cache_hits::Int
    worker_recycles::Int                 # number of worker restarts during run
end

# ─── Worker process management ────────────────────────────────────────────────

"""
    WorkerHandle

Encapsulates a running warm-worker subprocess.

Two separate pipes:
  pipe_in:  parent writes to pipe_in.in  → child reads from stdin (pipe_in.out)
  pipe_out: child writes to stdout (pipe_out.in) → parent reads from pipe_out.out
"""
mutable struct WorkerHandle
    proc::Base.Process          # the underlying process (for kill/status checks)
    pipe_in::Base.Pipe          # parent writes to .in → child reads stdin from .out
    pipe_out::Base.Pipe         # child writes stdout to .in → parent reads from .out
    mutants_served::Int         # since last recycle
    alive::Bool
end

"""
    _worker_main_path() -> String

Return the absolute path to worker_main.jl (sibling of this file).
"""
function _worker_main_path()::String
    # @__FILE__ gives the path to warm.jl; worker_main.jl is in the same directory
    dir = dirname(@__FILE__)
    return joinpath(dir, "worker_main.jl")
end

"""
    _spawn_worker(pkgdir, pkg_name; startup_timeout=90.0) -> WorkerHandle

Start a persistent warm-worker subprocess.
Uses open(pipeline(...), "r+") for a bidirectional stdio channel.
Waits for the ready acknowledgment before returning.
"""
function _spawn_worker(
    pkgdir::AbstractString,
    pkg_name::AbstractString;
    startup_timeout::Float64 = 90.0,
)::Union{WorkerHandle, Nothing}
    jl = _julia_exe()
    worker_script = _worker_main_path()

    # Two separate pipes for bidirectional communication:
    # pipe_in:  parent writes to .in → child reads from stdin (.out)
    # pipe_out: child writes to stdout (.in) → parent reads from .out
    cmd = Cmd([jl, "--project=$pkgdir", worker_script, pkg_name])

    p_in  = Base.Pipe()
    p_out = Base.Pipe()
    try
        Base.link_pipe!(p_in)
        Base.link_pipe!(p_out)
    catch e
        @warn "[gremlins/warm] Failed to create pipes: $e"
        return nothing
    end

    proc = try
        run(pipeline(cmd, stdin=p_in.out, stdout=p_out.in, stderr=devnull); wait=false)
    catch e
        @warn "[gremlins/warm] Failed to spawn worker: $e"
        return nothing
    end

    handle = WorkerHandle(proc, p_in, p_out, 0, true)

    # Wait for the ready acknowledgment {"ok":true,"started":"..."}
    # Use async task to read the first line (Julia async IO requirement)
    ready_ch = Channel{String}(1)
    @async begin
        try
            line = readline(p_out.out)
            put!(ready_ch, line)
        catch e
            put!(ready_ch, "")
        end
    end

    deadline = time() + startup_timeout
    while time() < deadline
        if !process_running(proc)
            @warn "[gremlins/warm] Worker process died during startup"
            _kill_worker!(handle)
            return nothing
        end
        if isready(ready_ch)
            line = take!(ready_ch)
            if occursin("\"ok\":true", line) && occursin("\"started\"", line)
                return handle
            elseif occursin("\"ok\":false", line)
                @warn "[gremlins/warm] Worker startup failed: $line"
                _kill_worker!(handle)
                return nothing
            else
                @warn "[gremlins/warm] Unexpected worker output: $line"
                _kill_worker!(handle)
                return nothing
            end
        end
        sleep(0.05)
    end

    @warn "[gremlins/warm] Worker startup timed out after $(startup_timeout)s"
    _kill_worker!(handle)
    return nothing
end

"""
    _line_available(io, timeout_secs) -> Bool

Non-blocking check: is a line available on `io` within `timeout_secs`?
"""
function _line_available(io::IO, timeout_secs::Float64)::Bool
    deadline = time() + timeout_secs
    while time() < deadline
        bytesavailable(io) > 0 && return true
        sleep(0.01)
    end
    return false
end

"""
    _send_request(handle, line) -> Union{String, Nothing}

Write a JSON-Lines request to the worker and return the response line.
Returns `nothing` on IO error or if the worker has died.
"""
function _send_request(
    handle::WorkerHandle,
    line::AbstractString,
    response_timeout::Float64 = 120.0,
)::Union{String, Nothing}
    handle.alive || return nothing

    try
        println(handle.pipe_in.in, line)
        flush(handle.pipe_in.in)
    catch e
        @warn "[gremlins/warm] Failed to write to worker stdin: $e"
        handle.alive = false
        return nothing
    end

    # Use an async task to read the response (Julia async IO requirement)
    resp_ch = Channel{Union{String, Nothing}}(1)
    @async begin
        try
            put!(resp_ch, readline(handle.pipe_out.out))
        catch
            put!(resp_ch, nothing)
        end
    end

    deadline = time() + response_timeout
    while time() < deadline
        if !process_running(handle.proc)
            handle.alive = false
            # Drain channel
            isready(resp_ch) && take!(resp_ch)
            return nothing
        end
        if isready(resp_ch)
            return take!(resp_ch)
        end
        sleep(0.01)
    end

    @warn "[gremlins/warm] Worker response timed out after $(response_timeout)s"
    handle.alive = false
    return nothing
end

"""
    _kill_worker!(handle)

SIGKILL the worker process and mark it dead.
"""
function _kill_worker!(handle::WorkerHandle)
    handle.alive = false
    try
        if process_running(handle.proc)
            kill(handle.proc, Base.SIGKILL)
        end
    catch
    end
    try; close(handle.pipe_in.in); catch; end
    try; close(handle.pipe_in.out); catch; end
    try; close(handle.pipe_out.in); catch; end
    try; close(handle.pipe_out.out); catch; end
end

"""
    _ping_worker(handle) -> Bool

Check that the worker is alive and responsive.
"""
function _ping_worker(handle::WorkerHandle)::Bool
    handle.alive || return false
    resp = _send_request(handle, "{\"cmd\":\"ping\"}", 10.0)
    resp === nothing && return false
    return occursin("\"ok\":true", resp)
end

# ─── Per-mutant warm execution via worker ────────────────────────────────────

"""
    _extract_toplevel_at_byte(content, target_byte, filename) -> Union{String, Nothing}

Use JuliaSyntax to find the top-level expression (function def, macro, struct, etc.)
that contains `target_byte` in `content`.

If the file has a top-level `module X ... end` wrapper, search inside the module body.
Returns the source text of just that top-level expression, or `nothing` if not found.

This allows the worker to eval ONLY the changed function, avoiding struct-redefinition
errors that occur when re-evaling entire files containing struct definitions.
"""
function _extract_toplevel_at_byte(
    content::AbstractString,
    target_byte::Int,
    filename::AbstractString,
)::Union{String, Nothing}
    tree = try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, content;
            filename=filename, ignore_errors=true)
    catch
        return nothing
    end

    # Determine which list of children to search in:
    # If top-level has a module wrapper, search inside its body.
    search_children = JuliaSyntax.children(tree)
    if !isnothing(search_children)
        for child in search_children
            if JuliaSyntax.kind(child) == JuliaSyntax.K"module"
                cs = JuliaSyntax.children(child)
                # JuliaSyntax module node children: [name_ident, body_block]
                # (NOT [Bool, name, block] like Meta.parse — JuliaSyntax omits the baremodule flag)
                if !isnothing(cs) && length(cs) >= 2
                    # Last child is the module body block node
                    body_node = cs[end]
                    body_children = JuliaSyntax.children(body_node)
                    if !isnothing(body_children)
                        search_children = body_children
                    end
                end
                break
            end
        end
    end

    # Find the child whose byte range contains target_byte
    isnothing(search_children) && return nothing
    for child in search_children
        br = JuliaSyntax.byte_range(child)
        if first(br) <= target_byte <= last(br)
            # Extract the source text of this top-level expression
            # Clamp to valid codeunit range
            lo = max(1, first(br))
            hi = min(ncodeunits(content), last(br))
            return content[lo:hi]
        end
    end
    return nothing
end

"""
    _run_mutant_via_worker(
        handle, abs_path, mutated_content, original_content, site, test_path, timeout
    ) -> (outcome::MutantOutcome, elapsed::Float64, errmsg::String, fallback::FallbackReason)

Send a mutant to the worker process. The worker:
  a. Eval mutated body into TargetPkg module (NO disk write)
  b. Run test in fresh anonymous module
  c. Restore original body (try/finally — ALWAYS)

Disk is NEVER touched on the warm path.

Uses `site.byte_range` to extract only the changed top-level expression (function def)
from the source files — avoiding struct-redefinition errors from re-evaling entire files.
Falls back to sending the full file if extraction fails.

Returns fallback_evalerr if the worker reports an error or times out.
The caller is responsible for cold fallback on fallback_evalerr.
"""
function _run_mutant_via_worker(
    handle::WorkerHandle,
    abs_path::AbstractString,
    mutated_content::AbstractString,
    original_content::AbstractString,
    site::MutationSite,
    test_path::AbstractString,
    timeout_secs::Float64,
)::Tuple{MutantOutcome, Float64, String, FallbackReason}
    handle.alive || return (error, 0.0, "worker not alive", fallback_evalerr)

    # Extract only the changed top-level expression (avoids struct-redefinition errors).
    # We use the mutation's byte range start to locate the enclosing top-level expression.
    mut_byte = first(site.byte_range)
    mut_expr   = _extract_toplevel_at_byte(mutated_content,  mut_byte, abs_path)
    orig_expr  = _extract_toplevel_at_byte(original_content, mut_byte, abs_path)

    # If extraction succeeds for both, send only those expressions.
    # If extraction fails, send the full file (worker will handle it — may produce fallback_evalerr).
    send_mut  = !isnothing(mut_expr)  && !isnothing(orig_expr) ? mut_expr  : mutated_content
    send_orig = !isnothing(orig_expr) && !isnothing(mut_expr)  ? orig_expr : original_content
    send_path = !isnothing(mut_expr)  && !isnothing(orig_expr) ? "(expr@$(abs_path))" : abs_path

    # Build JSON-Lines request
    c_b64 = Base64.base64encode(send_mut)
    o_b64 = Base64.base64encode(send_orig)
    # Minimal JSON — only ASCII-safe chars in b64; test_path and src_path need escaping
    # send_path may be "(expr@<abs_path>)" for expression-only sends (no module wrapper needed)
    src_esc  = _json_esc(send_path)
    test_esc = _json_esc(test_path)
    line = "{\"cmd\":\"mutant\",\"src_path\":$src_esc,\"content_b64\":\"$c_b64\",\"orig_b64\":\"$o_b64\",\"test_path\":$test_esc}"

    t0 = time()
    resp = _send_request(handle, line, timeout_secs + 5.0)  # +5s buffer for comms overhead

    if resp === nothing
        # Timeout or dead worker
        handle.alive = false
        return (error, time() - t0, "worker timeout or died", fallback_evalerr)
    end

    # Parse response: {"outcome":"killed|survived|error","elapsed":...,"err":"..."}
    outcome_str = _extract_field(resp, "outcome")
    elapsed_str = _extract_field_num(resp, "elapsed")
    err_str     = _extract_field(resp, "err")

    elapsed  = elapsed_str === nothing ? (time() - t0) : elapsed_str
    err_msg  = err_str === nothing ? "" : err_str

    outcome = if outcome_str == "killed"
        killed
    elseif outcome_str == "survived"
        survived
    elseif outcome_str == "error"
        error
    else
        error  # unknown response
    end

    fallback = outcome == error ? fallback_evalerr : warm_ok
    handle.mutants_served += 1
    return (outcome, elapsed, err_msg, fallback)
end

# ─── JSON helpers (no external deps) ─────────────────────────────────────────

function _json_esc(s::AbstractString)::String
    buf = IOBuffer()
    write(buf, '"')
    for c in s
        if c == '"';      write(buf, "\\\"")
        elseif c == '\\'; write(buf, "\\\\")
        elseif c == '\n'; write(buf, "\\n")
        elseif c == '\r'; write(buf, "\\r")
        elseif c == '\t'; write(buf, "\\t")
        elseif codepoint(c) < 0x20
            write(buf, "\\u$(lpad(string(codepoint(c), base=16), 4, '0'))")
        else; write(buf, c)
        end
    end
    write(buf, '"')
    return String(take!(buf))
end

function _extract_field(line::AbstractString, field::AbstractString)::Union{String, Nothing}
    pattern = Regex("\"" * field * "\"\\s*:\\s*\"((?:[^\\\\\"]|\\\\.)*)\"")
    m = match(pattern, line)
    m === nothing && return nothing
    v = m.captures[1]
    v = replace(v, "\\\"" => "\"")
    v = replace(v, "\\\\" => "\\")
    v = replace(v, "\\n" => "\n")
    return v
end

function _extract_field_num(line::AbstractString, field::AbstractString)::Union{Float64, Nothing}
    pattern = Regex("\"" * field * "\"\\s*:\\s*([+-]?[0-9]*\\.?[0-9]+(?:[eE][+-]?[0-9]+)?)")
    m = match(pattern, line)
    m === nothing && return nothing
    return tryparse(Float64, m.captures[1])
end

# ─── Main warm runner ─────────────────────────────────────────────────────────

"""
    run_mutations_warm(pkgdir, sites, cmap;
                       test_dir="test", test_file="runtests.jl",
                       baseline_elapsed=nothing,
                       timeout_multiplier=3.0,
                       n_workers=nothing,    # accepted for API compat; warm uses 1 worker
                       verbose=false,
                       cache=nothing,
                       pkg_name=nothing) -> WarmRunResult

Warm-pool mutation runner.

For each site (sorted by id, respecting I2):
1. Check cache — if hit, skip execution.
2. Classify warm eligibility (static, at run time per site).
3. Ineligible sites → cold path directly (with taxonomy reason).
4. Eligible sites → warm path: mutated content shipped to persistent worker.
   Worker evals into module (NO disk write), runs test in fresh Module, restores.
5. Dynamic fallback on warm error → cold re-run + fallback_evalerr taxonomy.
   Worker recycled after each fallback_evalerr.
6. Worker recycled every WORKER_RECYCLE_INTERVAL mutants (hygiene).
7. After all mutants: I4 sample check (≥10 warm-run mutants re-run cold).
8. Any I4 mismatch → record in WarmRunResult.i4_mismatches (hard error for caller).

`pkg_name`: target package name (e.g. "TeleTUI", "MiniTarget"). If not provided,
inferred from pkgdir/Project.toml. Required for worker startup.

`test_file`: for the warm path, if a file named `<stem>_warm.jl` exists alongside
`test_file`, it is used instead (warm-compatible variant that uses `using PkgName`
rather than `include(src)`). The cold path always uses `test_file`.
"""
function run_mutations_warm(
    pkgdir::AbstractString,
    sites::Vector{MutationSite},
    cmap::CoverageMap;
    test_dir::AbstractString     = "test",
    test_file::AbstractString    = "runtests.jl",
    baseline_elapsed::Union{Float64, Nothing} = nothing,
    timeout_multiplier::Float64  = 3.0,
    n_workers::Union{Int, Nothing} = nothing,  # API compat — warm uses 1 worker
    verbose::Bool                = false,
    cache::Union{MutantCache, Nothing} = nothing,
    pkg_name::Union{String, Nothing} = nothing,
)::WarmRunResult
    pkgdir = abspath(pkgdir)

    # Infer package name from Project.toml if not provided
    if isnothing(pkg_name)
        pkg_name = _infer_pkg_name(pkgdir)
    end

    # Establish baseline
    if isnothing(baseline_elapsed)
        verbose && println("[gremlins/warm] Running baseline...")
        elapsed_b, _ = baseline_run(pkgdir; test_dir=test_dir, test_file=test_file)
        baseline_elapsed = elapsed_b
        verbose && println("[gremlins/warm] Baseline: $(round(elapsed_b, digits=2))s")
    end

    mutant_timeout = max(10.0, baseline_elapsed * timeout_multiplier)
    verbose && println("[gremlins/warm] Timeout per mutant: $(round(mutant_timeout, digits=1))s")

    # Sort sites deterministically (I2)
    sorted_sites = sort(sites, by = s -> s.id)

    # Determine warm test file (prefer _warm.jl variant)
    cold_test_path = joinpath(pkgdir, test_dir, test_file)
    warm_test_path = _find_warm_test_file(pkgdir, test_dir, test_file)
    verbose && println("[gremlins/warm] Cold test : $cold_test_path")
    verbose && println("[gremlins/warm] Warm test : $warm_test_path")

    warm_results   = WarmMutantResult[]
    taxonomy       = Dict{FallbackReason, Int}()
    warm_ran       = WarmMutantResult[]   # track warm-executed for I4
    cache_hits     = 0
    worker_recycles = 0
    run_t0         = time()

    # Start worker
    worker = nothing
    if !isnothing(pkg_name)
        worker = _spawn_worker(pkgdir, pkg_name)
        if isnothing(worker)
            verbose && println("[gremlins/warm] WARNING: worker spawn failed; all mutants run cold")
        else
            verbose && println("[gremlins/warm] Worker started (pkg=$pkg_name)")
        end
    end

    for (i, site) in enumerate(sorted_sites)
        # Coverage check
        if !is_covered(cmap, site)
            verbose && println("[gremlins/warm] [$i/$(length(sorted_sites))] $(site.id[1:8])… no_coverage")
            base = MutantResult(site, no_coverage, 0.0, "")
            wr = WarmMutantResult(base, warm_ok, 0.0, 0.0)
            push!(warm_results, wr)
            _tally!(taxonomy, warm_ok)
            continue
        end

        # Cache check
        if !isnothing(cache)
            abs_path = _find_abs_path_or_throw(pkgdir, site)
            src_content = try; read(abs_path, String); catch; ""; end
            cached = cache_get(cache, src_content, site.id)
            if !isnothing(cached)
                cache_hits += 1
                base = MutantResult(site, cached.outcome, cached.elapsed, "")
                wr = WarmMutantResult(base, warm_ok, 0.0, 0.0)
                push!(warm_results, wr)
                verbose && println("[gremlins/warm] [$i/$(length(sorted_sites))] $(site.id[1:8])… cache_hit ($(cached.outcome))")
                _tally!(taxonomy, warm_ok)
                continue
            end
        end

        # Static warm eligibility
        elig = classify_warm_eligibility(site, pkgdir)

        if !elig.eligible
            verbose && println("[gremlins/warm] [$i/$(length(sorted_sites))] $(site.id[1:8])… cold ($(elig.reason))")
            cold_t0 = time()
            cold_outcome, cold_elapsed, cold_err = _run_cold_single(site, pkgdir, cold_test_path, mutant_timeout)
            base = MutantResult(site, cold_outcome, cold_elapsed, cold_err)
            wr = WarmMutantResult(base, elig.reason, 0.0, cold_elapsed)
            push!(warm_results, wr)
            _tally!(taxonomy, elig.reason)
            if !isnothing(cache)
                abs_path = _find_abs_path_or_throw(pkgdir, site)
                src_content = try; read(abs_path, String); catch; ""; end
                cache_put!(cache, src_content, site.id, cold_outcome, cold_elapsed)
            end
            continue
        end

        # Warm path — requires worker
        abs_path = try
            _find_abs_path_or_throw(pkgdir, site)
        catch e
            base = MutantResult(site, error, 0.0, "cannot locate source: $e")
            wr = WarmMutantResult(base, fallback_evalerr, 0.0, 0.0)
            push!(warm_results, wr)
            _tally!(taxonomy, fallback_evalerr)
            continue
        end

        src_content = try
            read(abs_path, String)
        catch e
            base = MutantResult(site, error, 0.0, "cannot read source: $e")
            wr = WarmMutantResult(base, fallback_evalerr, 0.0, 0.0)
            push!(warm_results, wr)
            _tally!(taxonomy, fallback_evalerr)
            continue
        end

        mutated_content = try
            apply(site, src_content)
        catch e
            base = MutantResult(site, error, 0.0, "apply failed: $e")
            wr = WarmMutantResult(base, fallback_evalerr, 0.0, 0.0)
            push!(warm_results, wr)
            _tally!(taxonomy, fallback_evalerr)
            continue
        end

        # Check worker recycle threshold
        if !isnothing(worker) && worker.alive &&
           worker.mutants_served >= WORKER_RECYCLE_INTERVAL
            verbose && println("[gremlins/warm] Recycling worker at $(worker.mutants_served) mutants")
            _send_request(worker, "{\"cmd\":\"exit\"}", 5.0)
            _kill_worker!(worker)
            worker = _spawn_worker(pkgdir, pkg_name)
            worker_recycles += 1
            if isnothing(worker)
                verbose && println("[gremlins/warm] WARNING: worker re-spawn failed")
            end
        end

        # Attempt warm execution
        ran_warm = false
        if !isnothing(worker) && worker.alive
            verbose && print("[gremlins/warm] [$i/$(length(sorted_sites))] $(site.id[1:8])… warm ")

            outcome, warm_elapsed, errmsg, fallback_r = _run_mutant_via_worker(
                worker, abs_path, mutated_content, src_content, site, warm_test_path, mutant_timeout
            )

            if fallback_r == fallback_evalerr
                # Dynamic fallback: error in worker → cold re-run
                verbose && print("→ fallback_evalerr, cold ")
                # Recycle worker on error (state may be contaminated)
                if !isnothing(worker) && worker.alive
                    _send_request(worker, "{\"cmd\":\"exit\"}", 3.0)
                    _kill_worker!(worker)
                    worker = _spawn_worker(pkgdir, pkg_name)
                    worker_recycles += 1
                    if isnothing(worker)
                        verbose && println("[gremlins/warm] WARNING: worker re-spawn after fallback failed")
                    end
                end
                cold_t0 = time()
                cold_outcome, cold_elapsed, cold_err = _run_cold_single(site, pkgdir, cold_test_path, mutant_timeout)
                base = MutantResult(site, cold_outcome, cold_elapsed, cold_err)
                wr = WarmMutantResult(base, fallback_evalerr, 0.0, cold_elapsed)
                push!(warm_results, wr)
                _tally!(taxonomy, fallback_evalerr)
                verbose && println(string(cold_outcome))
                if !isnothing(cache)
                    cache_put!(cache, src_content, site.id, cold_outcome, cold_elapsed)
                end
                continue
            end

            # Warm execution succeeded
            base = MutantResult(site, outcome, warm_elapsed, errmsg)
            wr = WarmMutantResult(base, warm_ok, warm_elapsed, 0.0)
            push!(warm_results, wr)
            push!(warm_ran, wr)
            _tally!(taxonomy, warm_ok)
            verbose && println(string(outcome), " ($(round(warm_elapsed, digits=2))s)")
            if !isnothing(cache)
                cache_put!(cache, src_content, site.id, outcome, warm_elapsed)
            end
            ran_warm = true
        end

        # Fallback: no worker available — run cold
        if !ran_warm
            verbose && print("[gremlins/warm] [$i/$(length(sorted_sites))] $(site.id[1:8])… cold (no_worker) ")
            cold_t0 = time()
            cold_outcome, cold_elapsed, cold_err = _run_cold_single(site, pkgdir, cold_test_path, mutant_timeout)
            base = MutantResult(site, cold_outcome, cold_elapsed, cold_err)
            wr = WarmMutantResult(base, fallback_evalerr, 0.0, cold_elapsed)
            push!(warm_results, wr)
            _tally!(taxonomy, fallback_evalerr)
            verbose && println(string(cold_outcome))
            if !isnothing(cache)
                cache_put!(cache, src_content, site.id, cold_outcome, cold_elapsed)
            end
        end
    end

    total_elapsed = time() - run_t0

    # Shut down worker
    if !isnothing(worker) && worker.alive
        _send_request(worker, "{\"cmd\":\"exit\"}", 5.0)
        _kill_worker!(worker)
    end

    # I4 agreement invariant — sample min(10, N) warm-ran mutants, re-run cold
    # Gate spec: ≥10 sampled. We sample min(10, N) to bound I4 overhead.
    i4_mismatches = String[]
    n_sample = min(10, length(warm_ran))
    sample = warm_ran[1:n_sample]

    verbose && println("[gremlins/warm] I4 agreement check: sampling $(length(sample)) warm-ran mutants cold...")
    for wr in sample
        site = wr.base.site
        cold_outcome2, _, _ = try
            _run_cold_single(site, pkgdir, cold_test_path, mutant_timeout)
        catch
            continue
        end
        if cold_outcome2 != wr.base.outcome
            push!(i4_mismatches,
                "I4 MISMATCH: site=$(site.id[1:8]) warm=$(wr.base.outcome) cold=$(cold_outcome2)")
            verbose && println("[gremlins/warm] WARNING: $(i4_mismatches[end])")
        end
    end

    # Assemble base RunResult from warm_results
    base_results = [wr.base for wr in warm_results]
    run_result = RunResult(pkgdir, sorted_sites, base_results, baseline_elapsed, total_elapsed)

    return WarmRunResult(
        run_result,
        warm_results,
        taxonomy,
        length(sample),
        i4_mismatches,
        cache_hits,
        worker_recycles,
    )
end

# ─── Internal helpers ─────────────────────────────────────────────────────────

"""Run one mutant on the cold path, returning (outcome, elapsed, errmsg)."""
function _run_cold_single(
    site::MutationSite,
    pkgdir::AbstractString,
    test_path::AbstractString,
    timeout_secs::Float64,
)::Tuple{MutantOutcome, Float64, String}
    abs_path = try
        _find_abs_path_or_throw(pkgdir, site)
    catch e
        return (error, 0.0, "cannot locate source: $e")
    end

    original_src = try
        read(abs_path, String)
    catch e
        return (error, 0.0, "cannot read source: $e")
    end

    outcome   = survived
    err_msg   = ""
    mutant_t0 = time()

    try
        apply!(site, abs_path)
        jl = _julia_exe()
        cmd = Cmd([jl, "--project=$pkgdir", test_path])
        exit_code, _ = _run_with_timeout(cmd, timeout_secs)

        outcome = if exit_code == :timeout
            timeout
        elseif exit_code != 0
            killed
        else
            survived
        end
    catch e
        outcome = error
        err_msg = sprint(showerror, e)
    finally
        try
            _atomic_write(abs_path, original_src)
        catch restore_err
            @error "CRITICAL: failed to restore source after cold run" path=abs_path err=restore_err
        end
    end

    elapsed = time() - mutant_t0
    return (outcome, elapsed, err_msg)
end

"""Throw if source file cannot be located."""
function _find_abs_path_or_throw(pkgdir::AbstractString, site::MutationSite)::String
    p = _find_abs_path(pkgdir, site)
    p !== nothing && return p
    throw(MutationError("cannot locate source file for site $(site.id): relpath=$(site.relpath)"))
end

"""Increment taxonomy counter."""
function _tally!(d::Dict{FallbackReason, Int}, r::FallbackReason)
    d[r] = get(d, r, 0) + 1
end

"""
    _infer_pkg_name(pkgdir) -> Union{String, Nothing}

Read the package name from Project.toml in pkgdir.
"""
function _infer_pkg_name(pkgdir::AbstractString)::Union{String, Nothing}
    toml_path = joinpath(pkgdir, "Project.toml")
    isfile(toml_path) || return nothing
    content = try; read(toml_path, String); catch; return nothing; end
    m = match(r"""^name\s*=\s*"([^"]+)"""m, content)
    m === nothing && return nothing
    return m.captures[1]
end

"""
    _find_warm_test_file(pkgdir, test_dir, test_file) -> String

Return the warm-path test file path. If a `<stem>_warm.jl` variant exists
alongside `test_file`, return its path; otherwise return the standard path.

Warm variants use `using PkgName` instead of `include(src)` so the worker's
eval-into-module works correctly.
"""
function _find_warm_test_file(
    pkgdir::AbstractString,
    test_dir::AbstractString,
    test_file::AbstractString,
)::String
    base = test_file
    stem, ext = splitext(base)
    warm_file = stem * "_warm" * ext
    warm_path = joinpath(pkgdir, test_dir, warm_file)
    isfile(warm_path) && return warm_path
    return joinpath(pkgdir, test_dir, test_file)
end

# ─── High-level entry point ───────────────────────────────────────────────────

"""
    mutate_warm(pkgdir;
                src_dir="src",
                test_dir="test", test_file="runtests.jl",
                operators=DEFAULT_OPERATORS,
                timeout_multiplier=3.0,
                n_workers=nothing,
                verbose=false,
                use_cache=true,
                pkg_name=nothing) -> WarmRunResult

High-level entry point for warm-pool mutation run.
Discovers mutations, runs baseline, executes all mutants with warm-pool + cache.
"""
function mutate_warm(
    pkgdir::AbstractString;
    src_dir::AbstractString       = "src",
    test_dir::AbstractString      = "test",
    test_file::AbstractString     = "runtests.jl",
    operators::Vector{MutationOperator} = DEFAULT_OPERATORS,
    timeout_multiplier::Float64   = 3.0,
    n_workers::Union{Int, Nothing} = nothing,
    verbose::Bool                 = false,
    use_cache::Bool               = true,
    pkg_name::Union{String, Nothing} = nothing,
)::WarmRunResult
    pkgdir = abspath(pkgdir)
    verbose && println("[gremlins/warm] Discovering mutations in $(joinpath(pkgdir, src_dir))...")

    sites = discover(joinpath(pkgdir, src_dir); operators=operators, root=pkgdir)
    verbose && println("[gremlins/warm] Discovered $(length(sites)) mutation sites")

    verbose && println("[gremlins/warm] Running baseline test suite...")
    baseline_elapsed, cmap = baseline_run(pkgdir; test_dir=test_dir, test_file=test_file)
    verbose && println("[gremlins/warm] Baseline: $(round(baseline_elapsed, digits=2))s")

    cache = use_cache ? load_cache(pkgdir) : nothing

    result = run_mutations_warm(pkgdir, sites, cmap;
        test_dir=test_dir,
        test_file=test_file,
        baseline_elapsed=baseline_elapsed,
        timeout_multiplier=timeout_multiplier,
        n_workers=n_workers,
        verbose=verbose,
        cache=cache,
        pkg_name=pkg_name,
    )

    if !isnothing(cache) && use_cache
        save_cache(cache)
    end

    return result
end
