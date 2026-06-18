#!/usr/bin/env julia
# gremlins-cli.jl — Gremlins mutation-testing CLI
#
# Usage:
#   julia --project=<gremlins-dir> bin/gremlins-cli.jl \
#         --pkg <dir> [--files a.jl,b.jl] [--test-file runtests.jl] \
#         [--warm] [--json out.json] [--strong 0.80] [--acceptable 0.60]
#
# Exit codes:
#   0 — strong or acceptable (kill_rate >= acceptable threshold)
#   1 — weak (kill_rate < acceptable threshold)
#   2 — infrastructure error
#
# BAND output line (always on stdout):
#   BAND\tstrong|acceptable|weak\tkill_rate=<x>\tkilled=<k>/<n>
#
# NOTE: using/import must be at top-level in Julia scripts.
# Gremlins is loaded unconditionally; if not found, an error is printed and exit(2).

using Gremlins

# Julia buffers stderr when it is not a TTY (e.g. redirected to a log file), so
# progress lines stay invisible until the process exits. Flush after each write.
elog(msg) = (println(stderr, msg); flush(stderr))

# ─── Arg parsing (pure functions, no external deps) ────────────────────────────

"""
    ParsedArgs

Parsed CLI arguments.
"""
struct ParsedArgs
    pkg::String
    files::Vector{String}       # empty = all files
    test_file::String
    warm::Bool
    schema::Bool                # --schema: opt-in compile-once schema mode
    blame::Bool                 # --blame: opt-in survivor-coverage blame pass
    diff::Bool                  # --diff: print unified diff per surviving mutant
    json_out::Union{String, Nothing}
    strong_threshold::Float64
    acceptable_threshold::Float64
    max_sites::Int              # 0 = no cap; >0 = take first N sites (deterministic)
    indiff_ref::Union{String, Nothing}  # --in-diff <ref>: scope to diff vs this ref
    parallel::Int               # --parallel N: concurrent mutant execution (cold path only, default 1)
end

"""
    _parse_args(argv::Vector{String}) -> ParsedArgs

Parse CLI arguments. Throws ArgumentError on invalid input.
"""
function _parse_args(argv::Vector{String})::ParsedArgs
    pkg = ""
    files = String[]
    test_file = "runtests.jl"
    warm = false
    schema = false
    blame = false
    diff = false
    json_out = nothing
    strong = 0.80
    acceptable = 0.60
    max_sites = 0
    indiff_ref = nothing
    parallel = 1

    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg == "--pkg"
            i += 1
            i > length(argv) && throw(ArgumentError("--pkg requires a value"))
            pkg = argv[i]
        elseif arg == "--files"
            i += 1
            i > length(argv) && throw(ArgumentError("--files requires a value"))
            raw = argv[i]
            files = filter!(!isempty, split(raw, ","))
        elseif arg == "--test-file"
            i += 1
            i > length(argv) && throw(ArgumentError("--test-file requires a value"))
            test_file = argv[i]
        elseif arg == "--warm"
            warm = true
        elseif arg == "--schema"
            schema = true
        elseif arg == "--blame"
            blame = true
        elseif arg == "--diff"
            diff = true
        elseif arg == "--json"
            i += 1
            i > length(argv) && throw(ArgumentError("--json requires a value"))
            json_out = argv[i]
        elseif arg == "--strong"
            i += 1
            i > length(argv) && throw(ArgumentError("--strong requires a value"))
            v = tryparse(Float64, argv[i])
            (v === nothing || v < 0 || v > 1) && throw(ArgumentError("--strong must be a float in [0,1]"))
            strong = v
        elseif arg == "--acceptable"
            i += 1
            i > length(argv) && throw(ArgumentError("--acceptable requires a value"))
            v = tryparse(Float64, argv[i])
            (v === nothing || v < 0 || v > 1) && throw(ArgumentError("--acceptable must be a float in [0,1]"))
            acceptable = v
        elseif arg == "--max-sites"
            i += 1
            i > length(argv) && throw(ArgumentError("--max-sites requires a value"))
            v = tryparse(Int, argv[i])
            (v === nothing || v < 0) && throw(ArgumentError("--max-sites must be a non-negative integer"))
            max_sites = v
        elseif arg == "--in-diff"
            i += 1
            i > length(argv) && throw(ArgumentError("--in-diff requires a value"))
            indiff_ref = argv[i]
        elseif arg == "--parallel" || arg == "--jobs"
            i += 1
            i > length(argv) && throw(ArgumentError("--parallel requires a value"))
            v = tryparse(Int, argv[i])
            (v === nothing || v < 1) && throw(ArgumentError("--parallel must be an integer >= 1"))
            parallel = v
        elseif arg == "--help" || arg == "-h"
            _print_usage()
            exit(0)
        else
            throw(ArgumentError("unknown argument: $(repr(arg))"))
        end
        i += 1
    end

    isempty(pkg) && throw(ArgumentError("--pkg is required"))
    acceptable > strong && throw(ArgumentError("--acceptable must be <= --strong"))
    (warm && schema) && throw(ArgumentError("--warm and --schema are mutually exclusive"))

    return ParsedArgs(pkg, files, test_file, warm, schema, blame, diff, json_out, strong, acceptable, max_sites, indiff_ref, parallel)
end

function _print_usage()
    println("""
gremlins-cli — Mutation testing for Julia

Usage:
  julia --project=<gremlins-dir> bin/gremlins-cli.jl \\
        --pkg <dir> [options]

Options:
  --pkg <dir>          Package directory to mutate (required)
  --files a.jl,b.jl   Mutate ONLY sites whose relpath matches these file names
                       (comma-separated). Empty = all files. Use this to scope
                       CI runs to changed files.
  --in-diff <ref>      Restrict mutation sites to lines added/changed relative
                       to <ref> (e.g. HEAD~1, a commit SHA, or a branch name).
                       Uses `git diff --unified=0`. A report line is printed to
                       stderr: "scoped to diff <ref>: N of M discoverable sites (K suppressed)".
  --test-file <file>   Test entry point relative to test/ OR relative to pkg root
                       (default: runtests.jl, resolved as test/runtests.jl)
  --warm               Use warm-worker pool (5-6x faster, recommended)
  --schema             Use compile-once schema mode for operator-swap sites
                       (faster than warm on eligible-heavy files; ineligible sites
                        fall back to warm automatically). Mutually exclusive with --warm.
  --blame              After the run, name the test file(s) covering each surviving mutant (N extra coverage runs)
  --diff               Print a unified diff hunk per surviving mutant (Vimes parity)
  --json <out.json>    Write JSON report to this file
  --strong <float>     Kill-rate threshold for "strong" band (default: 0.80)
  --acceptable <float> Kill-rate threshold for "acceptable" band (default: 0.60)
  --max-sites <int>    Cap eligible mutation sites to first N (deterministic order).
                       0 = no cap (default). Use to bound per-chunk CI run time
                       (e.g. --max-sites 40 keeps T4 under ~10 min on JUI).
                       Capped runs are noted in the band output line.
  --parallel <int>     Run N mutants concurrently (default: 1 = sequential).
                       Applies to the cold run path only. Use to exploit multi-core
                       machines; each mutant runs in its own shadow copy so there
                       is no shared state between concurrent runs.
                       (--jobs is accepted as an alias)
  --help               Print this message

Band output (always printed to stdout):
  BAND\\tstrong|acceptable|weak\\tkill_rate=<x>\\tkilled=<k>/<n>

Exit codes:
  0  strong or acceptable
  1  weak (below acceptable threshold)
  2  infrastructure error
""")
end

# ─── Band classification (pure function, testable without side effects) ─────────

"""
    classify_band(kill_rate, strong_threshold, acceptable_threshold) -> Symbol

Return :strong, :acceptable, or :weak.
"""
function classify_band(
    kill_rate::Float64,
    strong_threshold::Float64,
    acceptable_threshold::Float64,
)::Symbol
    isnan(kill_rate) && return :weak
    kill_rate >= strong_threshold     && return :strong
    kill_rate >= acceptable_threshold && return :acceptable
    return :weak
end

"""
    band_exit_code(band::Symbol) -> Int

0 for strong/acceptable, 1 for weak.
"""
function band_exit_code(band::Symbol)::Int
    band == :weak ? 1 : 0
end

"""
    format_band_line(band, kill_rate, killed, n_eligible) -> String

BAND output line (tab-separated).
"""
function format_band_line(
    band::Symbol,
    kill_rate::Float64,
    killed::Int,
    n_eligible::Int,
)::String
    kr_str = isnan(kill_rate) ? "nan" : string(round(kill_rate, digits=4))
    "BAND\t$(band)\tkill_rate=$(kr_str)\tkilled=$(killed)/$(n_eligible)"
end

# ─── File filter ──────────────────────────────────────────────────────────────

"""
    _normalize_pat(pat::String) -> String

Normalize a --files pattern for robust path matching:
- Replace backslashes with forward slashes (Windows-safe)
- Strip leading "./" (e.g. "./src/foo.jl" → "src/foo.jl")

This ensures patterns like "./src/style.jl", "src/style.jl", or "style.jl"
all match a site with relpath "src/style.jl".
"""
function _normalize_pat(pat::String)::String
    p = replace(pat, '\\' => '/')
    while startswith(p, "./")
        p = p[3:end]
    end
    return p
end

"""
    _filter_sites_by_files(sites, file_patterns) -> Vector

Keep only sites whose relpath matches any of the given patterns.
Matching rules (applied after normalizing the pattern with _normalize_pat):
1. Exact match: relpath == normalized_pat
2. Suffix match: endswith(relpath, "/" * normalized_pat) — nested path match
3. Basename match: endswith(relpath, "/" * basename(normalized_pat)) — bare filename

All comparisons use forward slashes. Patterns are basenames or relative paths
passed via --files (e.g. "style.jl", "src/style.jl", "./src/style.jl").
Empty patterns = no filter (all sites).
"""
function _filter_sites_by_files(sites, file_patterns::Vector{String})
    isempty(file_patterns) && return sites
    return filter(sites) do site
        rp = site.relpath
        any(file_patterns) do raw_pat
            pat = _normalize_pat(raw_pat)
            # Exact match (e.g. relpath IS the full relative path)
            rp == pat && return true
            # Suffix match: relpath ends with /<pat>
            # This handles "src/style.jl" matching when discover produces "src/style.jl"
            # AND handles nested paths like "auth/auth.jl" matching "src/auth/auth.jl"
            endswith(rp, "/" * pat) && return true
            # Basename match: relpath ends with /<basename(pat)>
            # This handles bare filenames like "style.jl" → "src/style.jl"
            bn = basename(pat)
            endswith(rp, "/" * bn) || rp == bn
        end
    end
end

# ─── Test file resolution ─────────────────────────────────────────────────────

"""
    _resolve_test_file(pkgdir, test_file) -> (test_dir::String, test_file::String)

Resolve --test-file to (test_dir, bare_filename) for passing to Gremlins runners.

Accepts:
  - "runtests.jl"           → test_dir="test", test_file="runtests.jl"
  - "test/runtests.jl"      → test_dir="test", test_file="runtests.jl"
  - "test/gremlins_smoke.jl" → test_dir="test", test_file="gremlins_smoke.jl"
"""
function _resolve_test_file(pkgdir::String, test_file::String)::Tuple{String, String}
    # If it looks like a relative path with a directory component, split it
    if occursin("/", test_file)
        parts = splitpath(test_file)
        if length(parts) >= 2
            # Check if first component is an existing dir in pkgdir
            candidate_dir = joinpath(pkgdir, parts[1])
            if isdir(candidate_dir)
                return (parts[1], join(parts[2:end], "/"))
            end
        end
    end
    # Default: assume test/ directory
    return ("test", test_file)
end

# ─── Main ─────────────────────────────────────────────────────────────────────

function main(argv::Vector{String})
    # Parse args
    args = try
        _parse_args(argv)
    catch e
        if e isa ArgumentError
            elog("ERROR: $(e.msg)")
            _print_usage()
            exit(2)
        end
        rethrow()
    end

    pkgdir = abspath(args.pkg)
    if !isdir(pkgdir)
        elog("ERROR: --pkg directory does not exist: $(pkgdir)")
        exit(2)
    end

    # Discover
    src_dir = joinpath(pkgdir, "src")
    if !isdir(src_dir)
        elog("ERROR: no src/ directory in $(pkgdir)")
        exit(2)
    end

    elog("[gremlins] Discovering mutations in $(src_dir)...")
    sites = try
        Gremlins.discover(src_dir; root=pkgdir)
    catch e
        elog("ERROR: discovery failed: $e")
        exit(2)
    end

    # Apply --in-diff scope filter (before --files filter, after discovery)
    if args.indiff_ref !== nothing
        diff_lines = try
            Gremlins.changed_lines(args.indiff_ref; pkgdir=pkgdir)
        catch e
            elog("ERROR: --in-diff failed: $e")
            exit(2)
        end
        sites_all = sites
        sites, n_suppressed = Gremlins.scope_to_diff(sites_all, diff_lines)
        n = length(sites)
        m = length(sites_all)
        println(stderr, "scoped to diff $(args.indiff_ref): $n of $m discoverable sites ($n_suppressed suppressed)")
        flush(stderr)
    end

    # Apply file filter
    sites = _filter_sites_by_files(sites, args.files)
    if !isempty(args.files)
        elog("[gremlins] After --files filter: $(length(sites)) sites")
    else
        elog("[gremlins] Discovered $(length(sites)) mutation sites")
    end

    # Apply --max-sites cap (deterministic: sites are already sorted by discover())
    capped = false
    if args.max_sites > 0 && length(sites) > args.max_sites
        elog("[gremlins] Capping to first $(args.max_sites) sites (--max-sites; total=$(length(sites)))")
        sites = sites[1:args.max_sites]
        capped = true
    end

    if isempty(sites)
        elog("[gremlins] No mutation sites found (check --files filter and src/ contents)")
        band_line = format_band_line(:weak, NaN, 0, 0)
        println(band_line)
        exit(1)
    end

    # Resolve test file
    test_dir, test_file_bare = _resolve_test_file(pkgdir, args.test_file)

    # Verify test file exists
    test_path = joinpath(pkgdir, test_dir, test_file_bare)
    if !isfile(test_path)
        elog("ERROR: test file not found: $(test_path)")
        exit(2)
    end

    # Baseline
    elog("[gremlins] Running baseline test suite ($(test_dir)/$(test_file_bare))...")
    baseline_elapsed, cmap = try
        Gremlins.baseline_run(pkgdir; test_dir=test_dir, test_file=test_file_bare)
    catch e
        elog("ERROR: baseline run failed: $e")
        exit(2)
    end
    elog("[gremlins] Baseline: $(round(baseline_elapsed, digits=2))s")

    # Run mutations
    run_result = if args.schema
        elog("[gremlins] Running schema (compile-once) mutation run...")
        schema_result = try
            Gremlins.run_mutations_schema(pkgdir, sites, cmap;
                test_dir=test_dir,
                test_file=test_file_bare,
                baseline_elapsed=baseline_elapsed,
                verbose=false)
        catch e
            elog("ERROR: schema run failed: $e")
            exit(2)
        end
        Gremlins.print_schema_summary(schema_result)
        # Report auto-disable if fired
        if schema_result.auto_disabled
            st = round(schema_result.agreement_schema_time, digits=3)
            wt = round(schema_result.agreement_warm_time, digits=3)
            elog("[gremlins] schema auto-disabled (hot path): schema=$(st)s warm=$(wt)s — ran all eligible on warm")
        end
        schema_result.run
    elseif args.warm
        elog("[gremlins] Running warm-pool mutation run...")
        warm_result = try
            cache = Gremlins.load_cache(pkgdir)
            wr = Gremlins.run_mutations_warm(pkgdir, sites, cmap;
                test_dir=test_dir,
                test_file=test_file_bare,
                baseline_elapsed=baseline_elapsed,
                verbose=false,
                cache=cache)
            Gremlins.save_cache(cache)
            wr
        catch e
            elog("ERROR: warm run failed: $e")
            exit(2)
        end
        Gremlins.print_warm_summary(warm_result)
        # Report I4 mismatches
        if !isempty(warm_result.i4_mismatches)
            elog("WARNING: I4 warm/cold mismatches detected:")
            for m in warm_result.i4_mismatches
                elog("  $m")
            end
        end
        warm_result.run
    else
        if args.parallel > 1
            elog("[gremlins] Running cold mutation run (parallel=$(args.parallel))...")
        else
            elog("[gremlins] Running cold mutation run...")
        end
        try
            Gremlins.run_mutations(pkgdir, sites, cmap;
                test_dir=test_dir,
                test_file=test_file_bare,
                baseline_elapsed=baseline_elapsed,
                parallel=args.parallel,
                verbose=false)
        catch e
            elog("ERROR: cold run failed: $e")
            exit(2)
        end
    end

    Gremlins.print_summary(run_result)

    # Opt-in survivor-coverage blame pass
    if args.blame
        elog("[gremlins] Running survivor-coverage blame (per-test coverage)...")
        try
            blame_report = Gremlins.blame_survivors(run_result, pkgdir;
                test_dir=test_dir, test_file=test_file_bare)
            Gremlins.render_blame(stdout, blame_report)
        catch e
            elog("WARNING: blame pass failed: $e")
        end
    end

    # Opt-in unified diff per surviving mutant (--diff, Issue #4, Vimes parity)
    if args.diff
        try
            diff_str = Gremlins.render_survivor_diffs(run_result, pkgdir)
            if !isempty(strip(diff_str))
                println(diff_str)
            end
        catch e
            elog("WARNING: --diff rendering failed: $e")
        end
    end

    # Write JSON report if requested
    if !isnothing(args.json_out)
        try
            json_str = Gremlins.report_json(run_result)
            open(args.json_out, "w") do io
                write(io, json_str)
            end
            elog("[gremlins] JSON report written to $(args.json_out)")
        catch e
            elog("WARNING: failed to write JSON report: $e")
        end
    end

    # Compute band
    score = Gremlins.mutation_score(run_result)
    n_killed   = count(r -> r.outcome == Gremlins.killed,     run_result.results)
    n_nocov    = count(r -> r.outcome == Gremlins.no_coverage, run_result.results)
    n_err      = count(r -> r.outcome == Gremlins.error,       run_result.results)
    n_eligible = length(run_result.results) - n_nocov - n_err

    band = classify_band(score, args.strong_threshold, args.acceptable_threshold)
    band_line = format_band_line(band, score, n_killed, n_eligible)
    if capped
        band_line = band_line * "\tcapped=first-$(args.max_sites)"
    end
    println(band_line)

    exit(band_exit_code(band))
end

main(ARGS)
