# blame.jl — Survivor-coverage blame: name the test file(s) covering each
# surviving mutant. Opt-in pass after a normal campaign. Reuses coverage.jl
# internals; never modifies baseline_run / whole-suite coverage.
#
# Soundness: an `include("test_X.jl")` in runtests.jl runs in Main's top-level
# scope, so a subfile can only depend on top-level definitions (the prelude),
# never on @testset-local bindings. A prelude = (top-level statements minus
# testfile-includes minus @testset blocks) is therefore sufficient for any
# subfile that runs correctly in the real suite. Detection failure -> the unit
# is reported failed and its survivors fall back to "unattributed".

using JuliaSyntax

"""
    TestUnit

One independently-runnable test unit. `label` is the included filename
(e.g. "test_x.jl") or "<inline>" for runtests' own top-level @testset blocks.
`driver` is complete Julia source: the shared prelude followed by this unit's
tests, written into the shadow test/ dir and run under --code-coverage.
"""
struct TestUnit
    label::String
    driver::String
end

_is_testset(node)::Bool = begin
    JuliaSyntax.kind(node) == JuliaSyntax.K"macrocall" || return false
    cs = JuliaSyntax.children(node)
    isempty(cs) && return false
    return JuliaSyntax.sourcetext(cs[1]) == "testset"
end

"""Return the included path string for an `include("...")` call, else nothing."""
function _include_target(node)::Union{String, Nothing}
    JuliaSyntax.kind(node) == JuliaSyntax.K"call" || return nothing
    cs = JuliaSyntax.children(node)
    length(cs) >= 2 || return nothing
    JuliaSyntax.sourcetext(cs[1]) == "include" || return nothing
    for c in cs[2:end]
        if JuliaSyntax.kind(c) == JuliaSyntax.K"string"
            return strip(JuliaSyntax.sourcetext(c), ['"'])
        end
    end
    return nothing
end

"""True if `name` looks like a test file AND exists in `test_dir`."""
_is_test_unit(name::AbstractString, test_dir::AbstractString)::Bool =
    (startswith(name, "test_") || endswith(name, "_test.jl")) &&
    isfile(joinpath(test_dir, name))

"""
    detect_units(runtests_path; test_dir=dirname(runtests_path)) -> (prelude, units)

Parse `runtests_path` with JuliaSyntax. Classify each top-level statement:
include of a test file -> a unit; `@testset` -> inline tests; else -> prelude
(defs shared by every unit). Returns the prelude source and the unit list
(include-units sorted by label, then one "<inline>" unit if any @testset exists).
"""
function detect_units(runtests_path::AbstractString;
                      test_dir::AbstractString = dirname(runtests_path))
    isfile(runtests_path) || throw(MutationError("detect_units: not a file: $runtests_path"))
    src = read(runtests_path, String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, src; filename=runtests_path)

    defs = String[]
    inlines = String[]
    include_units = Tuple{String, String}[]   # (label, statement source)

    for node in JuliaSyntax.children(tree)
        txt = JuliaSyntax.sourcetext(node)
        inc = _include_target(node)
        if inc !== nothing && _is_test_unit(inc, test_dir)
            push!(include_units, (inc, txt))
        elseif _is_testset(node)
            push!(inlines, txt)
        else
            push!(defs, txt)
        end
    end

    sort!(include_units, by = first)
    prelude = join(defs, "\n\n")

    units = TestUnit[]
    for (label, stmt) in include_units
        push!(units, TestUnit(label, prelude * "\n\n" * stmt * "\n"))
    end
    if !isempty(inlines)
        push!(units, TestUnit("<inline>", prelude * "\n\n" * join(inlines, "\n\n") * "\n"))
    end
    return prelude, units
end
