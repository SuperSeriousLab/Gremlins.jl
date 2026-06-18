module MiniTarget

# KILLABLE mutant site:
# add(a, b) = a + b
# Tests check add(2, 3) == 5.
# Mutant: OP_PLUS_TO_MINUS → a - b → 2-3 = -1 ≠ 5 → tests fail → KILLED.
function add(a, b)
    return a + b
end

# SURVIVING mutant site:
# is_positive(x) uses x > 0.
# Tests only call is_positive with x=5 (strictly positive, non-zero).
# Mutant: OP_GT_TO_GE → x >= 0.
# For x=5: 5>0 == true, 5>=0 == true → same result → NOT caught → SURVIVED.
function is_positive(x)
    return x > 0
end


# UNCOVERED site:
# multiply(a, b) is never called by the test suite.
# Any mutation here will be classified as no_coverage.
function multiply(a, b)
    return a * b
end

end # module MiniTarget
