module Gremlins

using JuliaSyntax
using SHA
using Base64

include("operators.jl")
include("equivalence.jl")
include("discover.jl")
include("schema.jl")
include("diff_scope.jl")
include("patch.jl")
include("shadow.jl")
include("coverage.jl")
include("runner.jl")
include("cache.jl")
include("warm.jl")
include("report.jl")

# Types
export MutationError
export MutationOperator
export MutationSite

# Operators
export DEFAULT_OPERATORS
export OP_LT_TO_LE, OP_LE_TO_LT
export OP_GT_TO_GE, OP_GE_TO_GT
export OP_EQ_TO_NEQ, OP_NEQ_TO_EQ
export OP_AND_TO_OR, OP_OR_TO_AND
export OP_DELETE_NOT
export OP_PLUS_TO_MINUS, OP_MINUS_TO_PLUS
export OP_MUL_TO_DIV, OP_DIV_TO_MUL
export OP_INT_INCR, OP_INT_DECR
export OP_TRUE_TO_FALSE, OP_FALSE_TO_TRUE
export OP_RETURN_NOTHING
export OP_STMT_DELETE
export OP_CONST_POOL
export OP_DISPATCH_SWAP
export OP_COMPARISON_CHAIN, OP_TERNARY_SWAP, OP_BROADCAST_DROP

# Discovery
export discover
export discover_file
export mutant_id

# Diff scope (Feature A)
export parse_diff_hunks
export changed_lines
export scope_to_diff

# Patching
export apply
export revert
export apply!
export revert!
export roundtrip_ok

# Coverage (M1)
export CoverageMap
export baseline_run
export covered_lines
export is_covered

# Runner (M1)
export MutantOutcome
export killed, survived, timeout, no_coverage, error
export MutantResult
export RunResult
export run_mutations
export mutate
export mutation_score

# Report (M1)
export report
export report_json
export report_markdown
export print_summary

# Cache (M2)
export MutantCache
export CachedResult
export load_cache
export save_cache
export cache_get
export cache_put!
export cache_size
export GREMLINS_VERSION

# Mutant schemata (Feature C)
export __GREM_ACTIVE
export schema_eligible
export instrument_function
export disjoint_eligible

# Warm-worker pool (M2)
export FallbackReason
export warm_ok, fallback_macro, fallback_typedef, fallback_const, fallback_evalerr, fallback_pollution, fallback_schema_ineligible
export WarmEligibility
export WarmMutantResult
export WarmRunResult
export classify_warm_eligibility
export run_mutations_warm
export mutate_warm

end # module Gremlins
