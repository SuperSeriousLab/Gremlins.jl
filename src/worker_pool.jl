# worker_pool.jl — Warm-worker subprocess pool + transport (M2b)
#
# Split out of warm.jl: the WorkerHandle struct, worker lifecycle (spawn/kill/
# ping/recycle), the JSON-Lines transport, the per-mutant + schema worker
# commands, and the JSON helpers. Pure code-move — no behavior change.

import Base64

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
    # @__FILE__ gives the path to this file; worker_main.jl is in the same directory
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

# ─── Schema (compile-once) worker commands ───────────────────────────────────

"""
    _instrument_via_worker(handle, src_path, instrumented_body) -> (ok::Bool, err::String)

Send an `instrument` command: the worker evals `instrumented_body` (the source
text of ONE instrumented top-level function) ONCE into the package module.
This is the compile-once step. Returns (false, msg) on any worker/IO error.
"""
function _instrument_via_worker(
    handle::WorkerHandle,
    src_path::AbstractString,
    instrumented_body::AbstractString;
    timeout_secs::Float64 = 120.0,
)::Tuple{Bool, String}
    handle.alive || return (false, "worker not alive")
    b_b64   = Base64.base64encode(instrumented_body)
    src_esc = _json_esc(src_path)
    line = "{\"cmd\":\"instrument\",\"src_path\":$src_esc,\"body_b64\":\"$b_b64\"}"
    resp = _send_request(handle, line, timeout_secs)
    resp === nothing && (handle.alive = false; return (false, "worker timeout or died"))
    if occursin("\"ok\":true", resp)
        return (true, "")
    end
    err = _extract_field(resp, "err")
    return (false, err === nothing ? "instrument failed: $resp" : err)
end

"""
    _schema_run_via_worker(handle, key, test_path, timeout_secs)
        -> (outcome::MutantOutcome, elapsed::Float64, errmsg::String, ok::Bool)

Send a `schema_run` command: worker flips `__GREM_ACTIVE[]=key`, runs the tests
fresh (compile-once instrumented methods are called, Ref read at runtime),
classifies (captured failing test = killed, I3), resets Ref to 0.

`ok=false` signals a worker-level error/timeout (caller should fall back / recycle).
"""
function _schema_run_via_worker(
    handle::WorkerHandle,
    key::Int,
    test_path::AbstractString,
    timeout_secs::Float64,
)::Tuple{MutantOutcome, Float64, String, Bool}
    handle.alive || return (error, 0.0, "worker not alive", false)
    test_esc = _json_esc(test_path)
    line = "{\"cmd\":\"schema_run\",\"key\":$key,\"test_path\":$test_esc}"
    t0 = time()
    resp = _send_request(handle, line, timeout_secs + 5.0)
    if resp === nothing
        handle.alive = false
        return (error, time() - t0, "worker timeout or died", false)
    end
    outcome_str = _extract_field(resp, "outcome")
    elapsed_str = _extract_field_num(resp, "elapsed")
    err_str     = _extract_field(resp, "err")
    elapsed = elapsed_str === nothing ? (time() - t0) : elapsed_str
    err_msg = err_str === nothing ? "" : err_str
    if outcome_str == "killed"
        return (killed, elapsed, err_msg, true)
    elseif outcome_str == "survived"
        return (survived, elapsed, err_msg, true)
    else
        return (error, elapsed, err_msg, false)
    end
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
