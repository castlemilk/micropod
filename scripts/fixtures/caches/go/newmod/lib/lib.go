// Package lib is the one-file-change target: the probe adds lib/edit.go.
package lib

import "github.com/google/go-cmp/cmp"

func Diff(a, b string) string { return cmp.Diff(a, b) }
