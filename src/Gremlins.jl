module Gremlins

using JuliaSyntax
using SHA

include("operators.jl")
include("discover.jl")
include("patch.jl")

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

# Discovery
export discover
export discover_file
export mutant_id

# Patching
export apply
export revert
export apply!
export revert!
export roundtrip_ok

end # module Gremlins
