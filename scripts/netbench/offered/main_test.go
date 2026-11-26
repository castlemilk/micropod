package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPublishedPortTargets(t *testing.T) {
	one, err := readServices([]string{"http://127.0.0.1:8080", "first"})
	if err != nil || len(one) != 1 || one[0].marker != "first" {
		t.Fatalf("single-port invocation: %v, %v", one, err)
	}
	var rows []string
	for i := range 32 {
		rows = append(rows, fmt.Sprintf("http://127.0.0.1:%d\tservice-%d", 18080+i, i))
	}
	file := filepath.Join(t.TempDir(), "ports.tsv")
	cases := []struct {
		name string
		rows []string
		ok   bool
	}{
		{"distinct", rows, true},
		{"missing", rows[:31], false},
		{"repeated address", append(append([]string{}, rows[:31]...), "http://127.0.0.1:18080\tservice-31"), false},
		{"repeated identity", append(append([]string{}, rows[:31]...), "http://127.0.0.1:18111\tservice-0"), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := os.WriteFile(file, []byte(strings.Join(tc.rows, "\n")), 0600); err != nil {
				t.Fatal(err)
			}
			services, err := readServices([]string{"--targets", file})
			if (err == nil) != tc.ok {
				t.Fatalf("targets: %v", err)
			}
			if tc.ok && (len(services) != 32 || services[31] != (service{"http://127.0.0.1:18111", "service-31"})) {
				t.Fatalf("lost endpoint or order: %v", services)
			}
		})
	}
}
