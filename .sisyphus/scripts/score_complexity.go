// score_complexity.go computes per-function max block-nesting depth
// using Go's AST parser, replacing the awk script's brace-counting
// approach. The previous approach over-counted depth on composite
// literals (struct/map/slice {...}), nested function literals, and
// `} else {` line-spikes — see passes 29-47 in .sisyphus/PASS_LOG.md.
//
// This tool walks only control-flow statements (Block, If, For,
// Range, Switch, TypeSwitch, Select, CommClause, CaseClause) so
// composite-literal braces never count toward depth. The output
// format matches the previous awk pipeline:
//
//   <max_loc> <max_depth> <worst_name> <worst_line> <func_count>
//
// One line, space-separated, on stdout. The shell wrapper
// (score_complexity.sh) consumes this and produces the JSON
// ledger entry.
package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: score_complexity <go-file>")
		os.Exit(2)
	}
	path := os.Args[1]
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, path, nil, 0)
	if err != nil {
		// Non-Go or parse error — emit zeros so the shell wrapper
		// can still produce a JSON line. Same fallthrough as the
		// awk version.
		fmt.Println("0 0 - 0 0")
		return
	}

	var maxLoc, maxDepth, funcCount, worstLine int
	worstName := "-"
	worstScore := 2.0 // higher than any valid score so the first func wins.

	for _, decl := range f.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		start := fset.Position(fn.Pos()).Line
		end := fset.Position(fn.End()).Line
		loc := end - start + 1
		depth := blockDepth(fn.Body, 1)
		funcCount++
		sc := score(loc, depth)

		if loc > maxLoc {
			maxLoc = loc
		}
		if depth > maxDepth {
			maxDepth = depth
		}
		if funcCount == 1 || sc < worstScore {
			worstScore = sc
			worstName = fn.Name.Name
			worstLine = start
		}
	}

	fmt.Printf("%d %d %s %d %d\n", maxLoc, maxDepth, worstName, worstLine, funcCount)
}

// blockDepth returns the maximum control-flow nesting depth
// reachable inside stmt, with `current` as the depth at which
// stmt itself sits. Walks only control-flow constructs; composite
// literals, struct literals, and function-literal expressions
// are NOT descended into for depth purposes.
//
// A FuncLit body IS walked, but at a fresh depth-1 baseline —
// nested function literals don't add to the outer function's
// depth count. The outer function's max already captures the
// FuncLit's containing depth.
func blockDepth(node ast.Node, current int) int {
	max := current
	ast.Inspect(node, func(n ast.Node) bool {
		switch s := n.(type) {
		case *ast.BlockStmt:
			// BlockStmt itself doesn't add depth — its container
			// (If/For/etc) already accounted for it. But we visit
			// children directly so they inherit the right depth.
			// Skipped here; the parent visitor will handle children.
			_ = s
		case *ast.IfStmt:
			d := blockDepth(s.Body, current+1)
			if d > max {
				max = d
			}
			if s.Else != nil {
				d := blockDepth(s.Else, current+1)
				if d > max {
					max = d
				}
			}
			return false
		case *ast.ForStmt:
			d := blockDepth(s.Body, current+1)
			if d > max {
				max = d
			}
			return false
		case *ast.RangeStmt:
			d := blockDepth(s.Body, current+1)
			if d > max {
				max = d
			}
			return false
		case *ast.SwitchStmt:
			d := blockDepth(s.Body, current+1)
			if d > max {
				max = d
			}
			return false
		case *ast.TypeSwitchStmt:
			d := blockDepth(s.Body, current+1)
			if d > max {
				max = d
			}
			return false
		case *ast.SelectStmt:
			d := blockDepth(s.Body, current+1)
			if d > max {
				max = d
			}
			return false
		case *ast.CaseClause:
			// Case bodies sit one level inside their switch.
			for _, child := range s.Body {
				d := blockDepth(child, current+1)
				if d > max {
					max = d
				}
			}
			return false
		case *ast.CommClause:
			for _, child := range s.Body {
				d := blockDepth(child, current+1)
				if d > max {
					max = d
				}
			}
			return false
		case *ast.FuncLit:
			// Nested function literal — count its inner depth
			// against itself, NOT against the outer function.
			d := blockDepth(s.Body, 1)
			if d > max {
				max = d
			}
			return false
		case *ast.CompositeLit:
			// Composite literals never push depth.
			return false
		}
		return true
	})
	return max
}

// score returns the [0,1] complexity score for one function:
//
//	1.0 if loc <= 60 AND depth <= 3
//	linear decay to 0 at loc=300 or depth=8
//
// Matches the original awk decay function exactly.
func score(loc, depth int) float64 {
	scLoc := 1.0
	if loc > 60 {
		if loc >= 300 {
			scLoc = 0.0
		} else {
			scLoc = 1.0 - float64(loc-60)/240.0
		}
	}
	scDepth := 1.0
	if depth > 3 {
		if depth >= 8 {
			scDepth = 0.0
		} else {
			scDepth = 1.0 - float64(depth-3)/5.0
		}
	}
	if scLoc < scDepth {
		return scLoc
	}
	return scDepth
}
