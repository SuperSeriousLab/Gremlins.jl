module BlamePkg

# sign(x): mutating `<` to `<=` changes only the x==0 boundary.
function sign_of(x)
    if x < 0
        return -1
    else
        return 1
    end
end

# g: clearly killable so test_strong kills its mutants (never blamed).
add1(x) = x + 1

export sign_of, add1

end
