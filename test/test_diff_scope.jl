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

@testset "scope_to_diff" begin
    # MutationSite positional fields: id, relpath, byte_range, op_id, op_name, original, replacement, line
    mk(relpath, line) = Gremlins.MutationSite("id$line", relpath, 1:1, :relop_lt_le,
                                              "relop_lt_le", "<", "<=", line)
    sites = [mk("src/foo.jl", 12), mk("src/foo.jl", 99), mk("src/bar.jl", 5)]
    diff_lines = Dict("src/foo.jl" => [11:13], "src/bar.jl" => [5:5])
    kept, suppressed = Gremlins.scope_to_diff(sites, diff_lines)
    @test [s.line for s in kept] == [12, 5]   # 99 excluded (outside 11:13)
    @test suppressed == 1
    # boundary falsifiability: line one above/below the hunk
    @test isempty(Gremlins.scope_to_diff([mk("src/foo.jl", 10)], diff_lines)[1])
    @test length(Gremlins.scope_to_diff([mk("src/foo.jl", 13)], diff_lines)[1]) == 1
end

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
