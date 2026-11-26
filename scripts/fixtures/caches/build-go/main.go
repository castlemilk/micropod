package main

import (
	"fmt"

	"github.com/google/go-cmp/cmp"
)

// token is defined in token.go, which the harness rewrites before each build
// so that exactly this package recompiles.
func main() { fmt.Println("qual-build", token, cmp.Diff("a", "a") == "") }
