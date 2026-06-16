# worker_main.jl — Persistent warm-execution worker process for Gremlins.jl (M2b)
#
# USAGE (started by parent via run_mutations_warm):
#   julia --project=<pkgdir> <gremlins>/src/worker_main.jl <PkgName>
#
# STARTUP:
#   1. using Test
#   2. using <PkgName>          (pays startup + package compile ONCE)
#   3. Enter JSON-Lines stdin loop
#
# PROTOCOL — JSON Lines over stdin/stdout:
#
#   Request (parent → worker):
#     {"cmd":"ping"}
#     {"cmd":"mutant","src_path":"<relpath>","content_b64":"<b64>","orig_b64":"<b64>","test_path":"<abs>"}
#     {"cmd":"exit"}
#
#   Response (worker → parent):
#     {"ok":true}                                        (ping)
#     {"outcome":"killed|survived|error","elapsed":<f>,"err":"<msg>"}  (mutant)
#
# WARM EXECUTION (per mutant, disk NEVER touched):
#   a. Extract module body from mutated content.
#   b. Core.eval(PkgModule, body_expr)   — replaces method definitions in-place.
#   c. Run test file in fresh anonymous module via Base.invokelatest(Base.include, m, test_path).
#      TestSetException or any error → killed; clean completion → survived.
#   d. Restore: Core.eval(PkgModule, original_body_expr). Runs in try/finally.
#
# NO external package dependencies beyond stdlib (Base64 + Test).
# Errors are reported as outcome="error" so parent can cold-fallback.

import Base64

# stderr is buffered when not a TTY (worker stderr is inherited / redirected), so
# diagnostics would stall until exit. Flush after each. stdout stays the JSON-Lines
# protocol channel — never write diagnostics there.
welog(msg) = (println(stderr, msg); flush(stderr))

# ─── Minimal JSON utilities ───────────────────────────────────────────────────

function _json_escape(s::AbstractString)::String
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

function _respond(pairs::Pair...)
    buf = IOBuffer()
    write(buf, '{')
    for (i, (k, v)) in enumerate(pairs)
        i > 1 && write(buf, ',')
        write(buf, _json_escape(string(k)))
        write(buf, ':')
        if v isa AbstractString
            write(buf, _json_escape(v))
        elseif v isa Bool
            write(buf, v ? "true" : "false")
        elseif v isa Number
            write(buf, string(v))
        else
            write(buf, _json_escape(string(v)))
        end
    end
    write(buf, '}')
    println(String(take!(buf)))
    flush(stdout)
end

function _extract_str(line::AbstractString, field::AbstractString)::Union{String, Nothing}
    # Match: "field": "value" where value may have \" escapes
    pattern = Regex("\"" * field * "\"\\s*:\\s*\"((?:[^\\\\\"]|\\\\.)*)\"")
    m = match(pattern, line)
    m === nothing && return nothing
    v = m.captures[1]
    # Unescape basic escapes (b64 values have none; src_path/test_path may have \\)
    v = replace(v, "\\\"" => "\"")
    v = replace(v, "\\\\" => "\\")
    v = replace(v, "\\n" => "\n")
    return v
end

"""
    _extract_str_or_num(line, field) -> Union{String, Nothing}

Extract `field`'s value whether it is quoted (`"k"`) or a bare JSON number (`k`).
Used for the schema_run `key` field which is sent unquoted.
"""
function _extract_str_or_num(line::AbstractString, field::AbstractString)::Union{String, Nothing}
    s = _extract_str(line, field)
    s !== nothing && return s
    pattern = Regex("\"" * field * "\"\\s*:\\s*([+-]?[0-9]+)")
    m = match(pattern, line)
    m === nothing && return nothing
    return m.captures[1]
end

# ─── Module body extraction ───────────────────────────────────────────────────

"""
    _extract_module_body(content, filename) -> Expr

If `content` is a file with a top-level `module X ... end` wrapper, return
just the inner block expression (so we can eval it into the existing module
without creating a nested submodule).

If there is no module wrapper (or parsing fails), return the full toplevel
expression — the caller will handle it gracefully or report error.
"""
function _extract_module_body(content::AbstractString, filename::AbstractString)::Expr
    parsed = try
        Meta.parseall(content; filename=filename)
    catch e
        error("parse error in $filename: $e")
    end
    # Scan top-level args for a module expression
    for arg in parsed.args
        arg isa Expr          || continue
        arg.head === :module  || continue
        length(arg.args) >= 3 || continue
        body = arg.args[3]
        body isa Expr && body.head === :block && return body
    end
    # No module wrapper found — return full toplevel block
    return parsed
end

# ─── Per-mutant warm execution ────────────────────────────────────────────────

"""
    _run_one_mutant(pkg_mod, src_path, mutated_content, orig_content, test_path)
        -> (outcome::String, elapsed::Float64, err::String)

Eval mutated content into pkg_mod, run test_path in fresh module, restore.
outcome is "killed", "survived", or "error".
"""
function _run_one_mutant(
    pkg_mod::Module,
    src_path::AbstractString,
    mutated_content::AbstractString,
    orig_content::AbstractString,
    test_path::AbstractString,
)::Tuple{String, Float64, String}
    t0 = time()

    # Parse both bodies before any eval (fast-fail on syntax errors)
    mut_body = try
        _extract_module_body(mutated_content, src_path)
    catch e
        return ("error", time() - t0, "parse mutant: $(sprint(showerror, e))")
    end

    orig_body = try
        _extract_module_body(orig_content, src_path)
    catch e
        return ("error", time() - t0, "parse original: $(sprint(showerror, e))")
    end

    # ── Step a: eval mutated body into package module ─────────────────────────
    try
        Core.eval(pkg_mod, mut_body)
    catch e
        return ("error", time() - t0, "eval mutant into module: $(sprint(showerror, e))")
    end

    outcome = "survived"
    err_msg = ""

    # ── Step b: run test in fresh child-module of Main ────────────────────────
    # We create the module as a child of Main (via Core.eval) rather than using
    # Module(:name) directly. This ensures:
    #   - `include(...)` (bare form) is available (inherited from Main)
    #   - `using PkgName` resolves correctly (uses Main's project/LOAD_PATH context)
    # Direct Module(:name) creates an orphan module that cannot resolve `using` or `include`.
    #
    # Redirect stdout→stderr during test execution to protect the JSON protocol channel.
    # Test output (e.g. "x: Test Failed ...") goes to stderr (discarded by parent).
    # Only our JSON responses go to real stdout.
    old_stdout = stdout
    try
        redirect_stdout(stderr)
    catch
    end

    # try/finally ensures restore always runs (step c + stdout restore)
    try
        # Create a uniquely named child module of Main
        mod_name = Symbol("__gremlins_test_$(rand(UInt32))__")
        Core.eval(Main, :(module $mod_name; end))
        test_mod = Core.eval(Main, mod_name)
        # Run the test file via invokelatest so it picks up the latest method world age
        Base.invokelatest(Base.include, test_mod, test_path)
        # Clean completion = survived (no exception thrown)
        outcome = "survived"
    catch e
        # Any exception during test execution = mutant detected = killed
        outcome = "killed"
        err_msg = string(typeof(e))
    finally
        # Restore stdout for JSON protocol output
        try
            redirect_stdout(old_stdout)
        catch
        end
        # ── Step c: ALWAYS restore original ──────────────────────────────────
        try
            Core.eval(pkg_mod, orig_body)
        catch re
            # Restore failed — signal error; parent will restart worker
            # Return outcome as "error" so parent handles gracefully
            return ("error", time() - t0,
                    "RESTORE FAILED (state contaminated): $(sprint(showerror, re))")
        end
    end

    return (outcome, time() - t0, err_msg)
end

# ─── Schema (compile-once) execution ──────────────────────────────────────────
#
# Schema mode differs from warm mode: instead of swapping a function body per
# mutant (recompile each time), it instruments the function ONCE with a runtime
# `Main.__GREM_ACTIVE[] == k ? (mut) : (orig)` guard, evals it once, then flips
# the global Ref per mutant. Tests are still include'd FRESH each mutant (so they
# compile in a world ≥ the instrument world and call the instrumented methods,
# reading the Ref at runtime — atlas-flash bug 2 world-age fix).

"""
    _run_test_fresh(test_path) -> (outcome::String, err::String)

Run `test_path` in a fresh child-module of Main via invokelatest(include).
Clean completion = "survived"; any thrown exception (incl. TestSetException) =
"killed" (I3: a kill requires a captured failing test). stdout is redirected to
stderr for the duration to protect the JSON protocol channel.

This is the SAME fresh-include primitive the warm path uses (_run_one_mutant
step b), factored out so schema_run reuses it verbatim.
"""
function _run_test_fresh(test_path::AbstractString)::Tuple{String, String}
    outcome = "survived"
    err_msg = ""
    old_stdout = stdout
    try
        redirect_stdout(stderr)
    catch
    end
    try
        mod_name = Symbol("__gremlins_test_$(rand(UInt32))__")
        Core.eval(Main, :(module $mod_name; end))
        test_mod = Core.eval(Main, mod_name)
        Base.invokelatest(Base.include, test_mod, test_path)
        outcome = "survived"
    catch e
        outcome = "killed"
        err_msg = string(typeof(e))
    finally
        try
            redirect_stdout(old_stdout)
        catch
        end
    end
    return (outcome, err_msg)
end

"""
    _ensure_active!()

Define `Main.__GREM_ACTIVE = Ref(0)` in the worker's Main if it is not already
bound. The instrumented code (eval'd into the package module) references
`Main.__GREM_ACTIVE[]`, which resolves to this binding. The worker does NOT load
Gremlins, so the controller cannot flip a Ref across the process boundary — it
sends the key over the protocol and the worker flips this binding locally.
"""
function _ensure_active!()
    if !isdefined(Main, :__GREM_ACTIVE)
        Core.eval(Main, :(const __GREM_ACTIVE = Base.RefValue(0)))
    end
    return nothing
end

"""
    _instrument_once(pkg_mod, src_path, instrumented_body) -> (ok::Bool, err::String)

Parse `instrumented_body` (the source text of ONE instrumented top-level
function) and `Core.eval` it ONCE into `pkg_mod`. This is the compile-once step:
the method is redefined with the runtime Ref-guard, and invalidation propagates
to callers on their next call (picked up by the fresh-include'd tests).
"""
function _instrument_once(
    pkg_mod::Module,
    src_path::AbstractString,
    instrumented_body::AbstractString,
)::Tuple{Bool, String}
    _ensure_active!()
    body = try
        _extract_module_body(instrumented_body, src_path)
    catch e
        return (false, "parse instrumented: $(sprint(showerror, e))")
    end
    try
        Core.eval(pkg_mod, body)
    catch e
        return (false, "eval instrumented into module: $(sprint(showerror, e))")
    end
    return (true, "")
end

"""
    _schema_run(key, test_path) -> (outcome::String, elapsed::Float64, err::String)

Set `Main.__GREM_ACTIVE[] = key`, run the tests fresh, classify, reset to 0.
key=0 selects the all-original baseline (used for the schema-baseline soundness
check); key=k activates mutant k. The Ref is ALWAYS reset to 0 (try/finally).
"""
function _schema_run(key::Int, test_path::AbstractString)::Tuple{String, Float64, String}
    t0 = time()
    _ensure_active!()
    outcome = "survived"
    err_msg = ""
    try
        Main.__GREM_ACTIVE[] = key
        outcome, err_msg = _run_test_fresh(test_path)
    catch e
        return ("error", time() - t0, "schema_run: $(sprint(showerror, e))")
    finally
        try
            Main.__GREM_ACTIVE[] = 0
        catch
        end
    end
    return (outcome, time() - t0, err_msg)
end

# ─── Main loop ────────────────────────────────────────────────────────────────

function main()
    if length(ARGS) < 1
        welog("[gremlins/worker] ERROR: usage: worker_main.jl <PkgName>")
        exit(1)
    end

    pkg_name = ARGS[1]

    # Load Test (needed for test execution inside this process)
    using_test_expr = Meta.parse("using Test")
    try
        Core.eval(Main, using_test_expr)
    catch e
        welog("[gremlins/worker] WARNING: could not load Test: $e")
    end

    # Load target package — pays startup cost ONCE
    pkg_mod::Union{Module, Nothing} = nothing
    try
        using_expr = Meta.parse("using $pkg_name")
        Core.eval(Main, using_expr)
        pkg_mod = Core.eval(Main, Symbol(pkg_name))
        welog("[gremlins/worker] Ready: pkg=$pkg_name module=$pkg_mod")
    catch e
        welog("[gremlins/worker] ERROR: could not load package '$pkg_name': $e")
        _respond("ok" => false, "err" => "startup: $(sprint(showerror, e))")
        # Continue — parent can still send exit; report error on mutant cmds
    end

    flush(stderr)

    # Signal readiness
    _respond("ok" => true, "started" => pkg_name)

    # ── Stdin command loop ────────────────────────────────────────────────────
    for line in eachline(stdin)
        line = strip(line)
        isempty(line) && continue

        cmd = _extract_str(line, "cmd")
        cmd === nothing && continue

        if cmd == "ping"
            _respond("ok" => true)

        elseif cmd == "exit"
            break

        elseif cmd == "mutant"
            if pkg_mod === nothing
                _respond("outcome" => "error", "elapsed" => 0.0,
                         "err" => "package not loaded at startup")
                continue
            end

            src_path  = _extract_str(line, "src_path")
            c_b64     = _extract_str(line, "content_b64")
            o_b64     = _extract_str(line, "orig_b64")
            test_path = _extract_str(line, "test_path")

            if any(isnothing, (src_path, c_b64, o_b64, test_path))
                _respond("outcome" => "error", "elapsed" => 0.0,
                         "err" => "malformed mutant request: missing fields")
                continue
            end

            mutated_content = try
                String(Base64.base64decode(c_b64))
            catch e
                _respond("outcome" => "error", "elapsed" => 0.0,
                         "err" => "base64 decode content: $e")
                continue
            end

            orig_content = try
                String(Base64.base64decode(o_b64))
            catch e
                _respond("outcome" => "error", "elapsed" => 0.0,
                         "err" => "base64 decode original: $e")
                continue
            end

            outcome, elapsed, err_msg = _run_one_mutant(
                pkg_mod, src_path, mutated_content, orig_content, test_path
            )

            _respond("outcome" => outcome,
                     "elapsed" => round(elapsed, digits=4),
                     "err"     => err_msg)

        elseif cmd == "instrument"
            # Schema compile-once: eval ONE instrumented top-level function into
            # the package module. {"cmd":"instrument","src_path":"<p>","body_b64":"<b64>"}
            if pkg_mod === nothing
                _respond("ok" => false, "err" => "package not loaded at startup")
                continue
            end
            src_path = _extract_str(line, "src_path")
            b_b64    = _extract_str(line, "body_b64")
            if any(isnothing, (src_path, b_b64))
                _respond("ok" => false, "err" => "malformed instrument request: missing fields")
                continue
            end
            instr_body = try
                String(Base64.base64decode(b_b64))
            catch e
                _respond("ok" => false, "err" => "base64 decode body: $e")
                continue
            end
            ok, ierr = _instrument_once(pkg_mod, src_path, instr_body)
            _respond("ok" => ok, "err" => ierr)

        elseif cmd == "schema_run"
            # Flip __GREM_ACTIVE[]=key, run tests fresh, classify, reset.
            # {"cmd":"schema_run","key":<int>,"test_path":"<abs>"}
            if pkg_mod === nothing
                _respond("outcome" => "error", "elapsed" => 0.0,
                         "err" => "package not loaded at startup")
                continue
            end
            key_str   = _extract_str_or_num(line, "key")
            test_path = _extract_str(line, "test_path")
            if any(isnothing, (key_str, test_path))
                _respond("outcome" => "error", "elapsed" => 0.0,
                         "err" => "malformed schema_run request: missing fields")
                continue
            end
            key = tryparse(Int, string(key_str))
            if key === nothing
                _respond("outcome" => "error", "elapsed" => 0.0,
                         "err" => "schema_run: bad key '$key_str'")
                continue
            end
            outcome, elapsed, err_msg = _schema_run(key, test_path)
            _respond("outcome" => outcome,
                     "elapsed" => round(elapsed, digits=4),
                     "err"     => err_msg)

        else
            _respond("outcome" => "error", "elapsed" => 0.0,
                     "err" => "unknown cmd: $cmd")
        end
    end

    welog("[gremlins/worker] Exiting.")
end

main()
