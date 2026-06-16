# schema_agreement.jl — Schema-vs-warm agreement soundness check (Feature C, C4).
#
# Split out of schema.jl: the AgreementResult struct, the schema_warm_agreement
# driver, and the pure _check_agreement comparator (the soundness backstop that
# throws on a killed↔survived disagreement). Pure code-move — no behavior change.

# ─── C4: AgreementResult + schema_warm_agreement + hot-path auto-disable ─────

"""
    AgreementResult

Result of `schema_warm_agreement`: comparison of schema-mode vs warm-mode
classifications on a sample of schema-eligible sites.

Fields:
- `mismatches`         — number of sites where schema and warm classified differently
                         (killed ↔ survived; no_coverage/timeout/error not counted)
- `schema_time`        — total summed test wall-time (seconds) for the schema path
- `warm_time`          — total summed test wall-time (seconds) for the warm path
- `sample_size`        — actual number of sites sampled (may be < k)
- `schema_time_both`   — schema wall-time for the "both paths ran" subset (for hot-path comparison)
- `warm_time_both`     — warm wall-time for the "both paths ran" subset
- `both_ran`           — count of sites where BOTH paths produced killed/survived
"""
struct AgreementResult
    mismatches::Int
    schema_time::Float64
    warm_time::Float64
    sample_size::Int
    schema_time_both::Float64
    warm_time_both::Float64
    both_ran::Int
end

function Base.show(io::IO, r::AgreementResult)
    print(io, "AgreementResult(mismatches=$(r.mismatches), ",
          "schema=$(round(r.schema_time, digits=3))s, ",
          "warm=$(round(r.warm_time, digits=3))s, ",
          "sample=$(r.sample_size), both_ran=$(r.both_ran))")
end

"""
    schema_warm_agreement(pkgdir, sites, cmap;
                          pkg_name=nothing,
                          k=10,
                          test_dir="test", test_file="runtests.jl",
                          baseline_elapsed=nothing,
                          mutant_timeout=nothing,
                          verbose=false) -> AgreementResult

Run the first `k` schema-ELIGIBLE + disjoint sites BOTH on the schema path AND
the warm path. Assert identical kill/survive classification; count mismatches.
Records summed test wall-time for each path.

Uses `run_mutations_schema` (with `agreement_check=false` to avoid recursion) and
`run_mutations_warm` on the k-site subset rather than reimplementing classification.

Mismatch semantics: any site where schema classified killed and warm classified
survived (or vice versa) increments `mismatches`. Timeout / no_coverage / error
outcomes on either side are NOT counted as mismatches — they are infrastructure
uncertainties, not classification disagreements.
"""
function schema_warm_agreement(
    pkgdir::AbstractString,
    sites::Vector{MutationSite},
    cmap::CoverageMap;
    pkg_name::Union{String, Nothing} = nothing,
    k::Int = 10,
    test_dir::AbstractString = "test",
    test_file::AbstractString = "runtests.jl",
    baseline_elapsed::Union{Float64, Nothing} = nothing,
    mutant_timeout::Union{Float64, Nothing} = nothing,
    verbose::Bool = false,
)::AgreementResult
    pkgdir = abspath(pkgdir)
    isnothing(pkg_name) && (pkg_name = _infer_pkg_name(pkgdir))

    # Pick the first k schema-eligible + disjoint sites (the exact subset that
    # will run schema mode in the full run — sampling warm-fallback sites is pointless)
    elig = filter(schema_eligible, sites)
    schema_sites, _nested = disjoint_eligible(elig)
    sample = schema_sites[1:min(k, length(schema_sites))]

    if isempty(sample)
        return AgreementResult(0, 0.0, 0.0, 0, 0.0, 0.0, 0)
    end

    # Establish baseline elapsed once (shared by both sub-runs)
    if isnothing(baseline_elapsed)
        baseline_elapsed, _ = baseline_run(pkgdir; test_dir=test_dir, test_file=test_file)
    end

    # ── Schema path on sample ─────────────────────────────────────────────────
    schema_res = run_mutations_schema(
        pkgdir, sample, cmap;
        test_dir=test_dir, test_file=test_file,
        baseline_elapsed=baseline_elapsed,
        mutant_timeout=mutant_timeout,
        pkg_name=pkg_name,
        verbose=verbose,
        agreement_check=false,   # no recursion
    )
    schema_time = sum(r.elapsed for r in schema_res.run.results; init=0.0)

    # ── Warm path on same sample ──────────────────────────────────────────────
    warm_res = run_mutations_warm(
        pkgdir, sample, cmap;
        test_dir=test_dir, test_file=test_file,
        baseline_elapsed=baseline_elapsed,
        mutant_timeout=mutant_timeout,
        pkg_name=pkg_name,
        verbose=verbose,
        cache=nothing,
    )
    warm_time = sum(r.elapsed for r in warm_res.run.results; init=0.0)

    # ── Compare classifications + throw on disagreement ───────────────────────
    # Delegated to the pure `_check_agreement` so the soundness backstop (the
    # killed↔survived comparison AND the MutationError throw) is unit-testable
    # with hand-constructed divergent results.
    mismatches, both_ran, schema_time_both, warm_time_both =
        _check_agreement(sample, schema_res.run.results, warm_res.run.results)

    return AgreementResult(mismatches, schema_time, warm_time, length(sample),
                           schema_time_both, warm_time_both, both_ran)
end

"""
    _check_agreement(sample, schema_results, warm_results)
        -> (mismatches, both_ran, schema_time_both, warm_time_both)

Pure soundness comparator for `schema_warm_agreement`. Given a `sample` of sites
and the per-site `MutantResult` vectors from the schema and warm runs, count the
sites where BOTH paths produced a definitive outcome (`killed`/`survived`) and,
among those, any `killed ↔ survived` disagreement.

A disagreement is a soundness violation: schema mode misclassified a mutant
relative to the trusted warm path. On ANY such mismatch this THROWS a
`MutationError` (the hot backstop). `timeout`/`no_coverage`/`error` on either
side are infrastructure uncertainties, not classification disagreements, and are
ignored.

Returns the mismatch count (always 0 on the non-throwing path), the count of
comparable (`both_ran`) sites, and the summed schema/warm wall-time over that
comparable subset (used by the hot-path auto-disable so a coverage-key mismatch
— warm `no_coverage`, elapsed 0 — never spuriously triggers a disable).
"""
function _check_agreement(
    sample::Vector{MutationSite},
    schema_results::Vector{MutantResult},
    warm_results::Vector{MutantResult},
)::Tuple{Int, Int, Float64, Float64}
    # id → (outcome, elapsed) maps, built ONCE for each path
    schema_map = Dict{String, Tuple{MutantOutcome, Float64}}(
        r.site.id => (r.outcome, r.elapsed) for r in schema_results
    )
    warm_map = Dict{String, Tuple{MutantOutcome, Float64}}(
        r.site.id => (r.outcome, r.elapsed) for r in warm_results
    )

    mismatch_ids     = String[]
    both_ran         = 0
    schema_time_both = 0.0
    warm_time_both   = 0.0

    for s in sample
        sv = get(schema_map, s.id, nothing)
        wv = get(warm_map,   s.id, nothing)
        (sv === nothing || wv === nothing) && continue
        (so, se) = sv
        (wo, we) = wv
        # Only compare on definitive (killed/survived) outcomes on BOTH sides.
        if (so == killed || so == survived) && (wo == killed || wo == survived)
            both_ran         += 1
            schema_time_both += se
            warm_time_both   += we
            so != wo && push!(mismatch_ids, s.id)
        end
    end

    if !isempty(mismatch_ids)
        throw(MutationError(
            "schema_warm_agreement: $(length(mismatch_ids)) classification mismatch(es) detected — " *
            "schema result disagrees with warm result for sites: " *
            join([id[1:min(8, length(id))] for id in mismatch_ids], ", ") *
            ". This is a soundness violation in _schema_instr_unit. " *
            "Schema mode is unsafe for this package; investigate before proceeding."))
    end

    return (length(mismatch_ids), both_ran, schema_time_both, warm_time_both)
end
