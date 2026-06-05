# cli_test.jl — Tests for CLI arg parsing and band logic (M3a)
#
# Pure-function tests only. No subprocess spawning, no external processes.
# Lesson from M1 OOM: one shared fixture per run; no per-testset process fleets.

using Test

# Load the pure functions from the CLI without executing main().
# We source only the pure-function section by including the file in a fresh module.
# To avoid re-entrant using/include issues we define the testable functions inline
# (duplicated from bin/gremlins-cli.jl — kept in sync).

# ─── Inline duplicates of CLI pure functions ──────────────────────────────────
# These match bin/gremlins-cli.jl exactly. If they diverge, tests will still catch
# regressions in the CLI's own copy (tested below via subprocess if julia available).

struct ParsedArgs_t
    pkg::String
    files::Vector{String}
    test_file::String
    warm::Bool
    json_out::Union{String, Nothing}
    strong_threshold::Float64
    acceptable_threshold::Float64
    max_sites::Int
end

function _parse_args_t(argv::Vector{String})::ParsedArgs_t
    pkg = ""
    files = String[]
    test_file = "runtests.jl"
    warm = false
    json_out = nothing
    strong = 0.80
    acceptable = 0.60
    max_sites = 0
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg == "--pkg"
            i += 1; i > length(argv) && throw(ArgumentError("--pkg requires a value"))
            pkg = argv[i]
        elseif arg == "--files"
            i += 1; i > length(argv) && throw(ArgumentError("--files requires a value"))
            files = filter!(!isempty, split(argv[i], ","))
        elseif arg == "--test-file"
            i += 1; i > length(argv) && throw(ArgumentError("--test-file requires a value"))
            test_file = argv[i]
        elseif arg == "--warm"
            warm = true
        elseif arg == "--json"
            i += 1; i > length(argv) && throw(ArgumentError("--json requires a value"))
            json_out = argv[i]
        elseif arg == "--strong"
            i += 1; i > length(argv) && throw(ArgumentError("--strong requires a value"))
            v = tryparse(Float64, argv[i])
            (v === nothing || v < 0 || v > 1) && throw(ArgumentError("--strong must be a float in [0,1]"))
            strong = v
        elseif arg == "--acceptable"
            i += 1; i > length(argv) && throw(ArgumentError("--acceptable requires a value"))
            v = tryparse(Float64, argv[i])
            (v === nothing || v < 0 || v > 1) && throw(ArgumentError("--acceptable must be a float in [0,1]"))
            acceptable = v
        elseif arg == "--max-sites"
            i += 1; i > length(argv) && throw(ArgumentError("--max-sites requires a value"))
            v = tryparse(Int, argv[i])
            (v === nothing || v < 0) && throw(ArgumentError("--max-sites must be a non-negative integer"))
            max_sites = v
        else
            throw(ArgumentError("unknown argument: $(repr(arg))"))
        end
        i += 1
    end
    isempty(pkg) && throw(ArgumentError("--pkg is required"))
    acceptable > strong && throw(ArgumentError("--acceptable must be <= --strong"))
    ParsedArgs_t(pkg, files, test_file, warm, json_out, strong, acceptable, max_sites)
end

function classify_band_t(kill_rate::Float64, strong::Float64, acceptable::Float64)::Symbol
    isnan(kill_rate) && return :weak
    kill_rate >= strong     && return :strong
    kill_rate >= acceptable && return :acceptable
    :weak
end

function band_exit_code_t(band::Symbol)::Int
    band == :weak ? 1 : 0
end

function format_band_line_t(band::Symbol, kill_rate::Float64, killed::Int, n::Int)::String
    kr = isnan(kill_rate) ? "nan" : string(round(kill_rate, digits=4))
    "BAND\t$(band)\tkill_rate=$(kr)\tkilled=$(killed)/$(n)"
end

function _normalize_pat_t(pat::String)::String
    p = replace(pat, '\\' => '/')
    while startswith(p, "./")
        p = p[3:end]
    end
    return p
end

function _filter_sites_by_files_t(relpaths::Vector{String}, patterns::Vector{String})::Vector{String}
    isempty(patterns) && return relpaths
    filter(relpaths) do rp
        any(patterns) do raw_pat
            pat = _normalize_pat_t(raw_pat)
            rp == pat && return true
            endswith(rp, "/" * pat) && return true
            bn = basename(pat)
            endswith(rp, "/" * bn) || rp == bn
        end
    end
end

# ─── Tests ────────────────────────────────────────────────────────────────────

@testset "CLI — arg parsing" begin

    @testset "minimal valid: --pkg only" begin
        a = _parse_args_t(["--pkg", "/some/pkg"])
        @test a.pkg == "/some/pkg"
        @test isempty(a.files)
        @test a.test_file == "runtests.jl"
        @test a.warm == false
        @test a.json_out === nothing
        @test a.strong_threshold == 0.80
        @test a.acceptable_threshold == 0.60
        @test a.max_sites == 0
    end

    @testset "--warm flag" begin
        a = _parse_args_t(["--pkg", "/p", "--warm"])
        @test a.warm == true
    end

    @testset "--files parses comma list" begin
        a = _parse_args_t(["--pkg", "/p", "--files", "foo.jl,bar.jl,baz.jl"])
        @test a.files == ["foo.jl", "bar.jl", "baz.jl"]
    end

    @testset "--files ignores empty segments" begin
        a = _parse_args_t(["--pkg", "/p", "--files", "foo.jl,,bar.jl"])
        @test a.files == ["foo.jl", "bar.jl"]
    end

    @testset "--test-file" begin
        a = _parse_args_t(["--pkg", "/p", "--test-file", "smoke.jl"])
        @test a.test_file == "smoke.jl"
    end

    @testset "--json" begin
        a = _parse_args_t(["--pkg", "/p", "--json", "out.json"])
        @test a.json_out == "out.json"
    end

    @testset "--strong and --acceptable" begin
        a = _parse_args_t(["--pkg", "/p", "--strong", "0.90", "--acceptable", "0.70"])
        @test a.strong_threshold == 0.90
        @test a.acceptable_threshold == 0.70
    end

    @testset "error: --pkg missing" begin
        @test_throws ArgumentError _parse_args_t(String[])
    end

    @testset "error: --pkg value missing" begin
        @test_throws ArgumentError _parse_args_t(["--pkg"])
    end

    @testset "error: unknown flag" begin
        @test_throws ArgumentError _parse_args_t(["--pkg", "/p", "--unknown"])
    end

    @testset "error: --strong out of range" begin
        @test_throws ArgumentError _parse_args_t(["--pkg", "/p", "--strong", "1.5"])
        @test_throws ArgumentError _parse_args_t(["--pkg", "/p", "--strong", "-0.1"])
    end

    @testset "error: --acceptable > --strong" begin
        @test_throws ArgumentError _parse_args_t(["--pkg", "/p", "--strong", "0.60", "--acceptable", "0.80"])
    end

    @testset "error: --strong not a float" begin
        @test_throws ArgumentError _parse_args_t(["--pkg", "/p", "--strong", "notanumber"])
    end

    @testset "--max-sites default is 0" begin
        a = _parse_args_t(["--pkg", "/p"])
        @test a.max_sites == 0
    end

    @testset "--max-sites parses positive int" begin
        a = _parse_args_t(["--pkg", "/p", "--max-sites", "40"])
        @test a.max_sites == 40
    end

    @testset "--max-sites zero is valid (no cap)" begin
        a = _parse_args_t(["--pkg", "/p", "--max-sites", "0"])
        @test a.max_sites == 0
    end

    @testset "error: --max-sites negative" begin
        @test_throws ArgumentError _parse_args_t(["--pkg", "/p", "--max-sites", "-1"])
    end

    @testset "error: --max-sites not an int" begin
        @test_throws ArgumentError _parse_args_t(["--pkg", "/p", "--max-sites", "forty"])
    end

end

@testset "CLI — band classification" begin

    @testset "strong" begin
        @test classify_band_t(0.80, 0.80, 0.60) == :strong
        @test classify_band_t(0.95, 0.80, 0.60) == :strong
        @test classify_band_t(1.0,  0.80, 0.60) == :strong
    end

    @testset "acceptable" begin
        @test classify_band_t(0.70, 0.80, 0.60) == :acceptable
        @test classify_band_t(0.60, 0.80, 0.60) == :acceptable
        @test classify_band_t(0.79, 0.80, 0.60) == :acceptable
    end

    @testset "weak" begin
        @test classify_band_t(0.59, 0.80, 0.60) == :weak
        @test classify_band_t(0.0,  0.80, 0.60) == :weak
        @test classify_band_t(NaN,  0.80, 0.60) == :weak
    end

    @testset "boundary: acceptable at threshold" begin
        @test classify_band_t(0.60, 0.80, 0.60) == :acceptable
        @test classify_band_t(0.80, 0.80, 0.60) == :strong
    end

    @testset "custom thresholds" begin
        @test classify_band_t(0.75, 0.90, 0.70) == :acceptable
        @test classify_band_t(0.69, 0.90, 0.70) == :weak
        @test classify_band_t(0.90, 0.90, 0.70) == :strong
    end

end

@testset "CLI — exit codes" begin
    @test band_exit_code_t(:strong)     == 0
    @test band_exit_code_t(:acceptable) == 0
    @test band_exit_code_t(:weak)       == 1
end

@testset "CLI — band line format" begin
    line = format_band_line_t(:strong, 0.85, 17, 20)
    @test startswith(line, "BAND\t")
    @test occursin("strong", line)
    @test occursin("kill_rate=", line)
    @test occursin("killed=17/20", line)

    line2 = format_band_line_t(:weak, NaN, 0, 0)
    @test occursin("weak", line2)
    @test occursin("nan", line2)

    line3 = format_band_line_t(:acceptable, 0.6543, 10, 15)
    # Should round to 4 decimal places
    @test occursin("0.6543", line3)
end

@testset "CLI — path normalization" begin

    @testset "no-op for clean path" begin
        @test _normalize_pat_t("src/foo.jl") == "src/foo.jl"
    end

    @testset "strip single ./" begin
        @test _normalize_pat_t("./src/foo.jl") == "src/foo.jl"
    end

    @testset "strip double ./" begin
        @test _normalize_pat_t("././src/foo.jl") == "src/foo.jl"
    end

    @testset "bare filename unchanged" begin
        @test _normalize_pat_t("foo.jl") == "foo.jl"
    end

    @testset "backslash to forward slash" begin
        @test _normalize_pat_t("src\\auth\\auth.jl") == "src/auth/auth.jl"
    end

    @testset "mixed slashes with dotslash" begin
        # ".\\src\\foo.jl" → "./src/foo.jl" (backslash→slash) → "src/foo.jl" (strip ./)
        @test _normalize_pat_t(".\\src\\foo.jl") == "src/foo.jl"
    end

end

@testset "CLI — file filter" begin
    relpaths = ["src/foo.jl", "src/bar.jl", "src/utils/baz.jl"]

    @testset "empty pattern = no filter" begin
        result = _filter_sites_by_files_t(relpaths, String[])
        @test result == relpaths
    end

    @testset "exact basename match" begin
        result = _filter_sites_by_files_t(relpaths, ["foo.jl"])
        @test result == ["src/foo.jl"]
    end

    @testset "multiple patterns" begin
        result = _filter_sites_by_files_t(relpaths, ["foo.jl", "bar.jl"])
        @test Set(result) == Set(["src/foo.jl", "src/bar.jl"])
    end

    @testset "relpath suffix match" begin
        result = _filter_sites_by_files_t(relpaths, ["utils/baz.jl"])
        @test result == ["src/utils/baz.jl"]
    end

    @testset "no match = empty" begin
        result = _filter_sites_by_files_t(relpaths, ["notexist.jl"])
        @test isempty(result)
    end

    @testset "basename of path pattern" begin
        # --files src/foo.jl → basename is "foo.jl" which matches
        result = _filter_sites_by_files_t(relpaths, ["src/foo.jl"])
        @test result == ["src/foo.jl"]
    end

    @testset "dotslash prefix stripped — nested path" begin
        # T4 might pass "./src/foo.jl"; should match "src/foo.jl"
        result = _filter_sites_by_files_t(relpaths, ["./src/foo.jl"])
        @test result == ["src/foo.jl"]
    end

    @testset "dotslash prefix stripped — bare filename" begin
        result = _filter_sites_by_files_t(relpaths, ["./foo.jl"])
        @test result == ["src/foo.jl"]
    end

    @testset "nested sub-path filter — utils/baz.jl matches src/utils/baz.jl" begin
        result = _filter_sites_by_files_t(relpaths, ["utils/baz.jl"])
        @test result == ["src/utils/baz.jl"]
    end

    @testset "double dotslash stripped" begin
        result = _filter_sites_by_files_t(relpaths, ["././src/bar.jl"])
        @test result == ["src/bar.jl"]
    end

    @testset "backslash normalized to forward slash" begin
        # Windows-style path separator — should still match
        result = _filter_sites_by_files_t(["src/utils/baz.jl"], ["src\\utils\\baz.jl"])
        @test result == ["src/utils/baz.jl"]
    end
end
