package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteCleanStop(t *testing.T) {
	dir := t.TempDir()
	rec := filepath.Join(dir, "micropod", "clean-stop")
	// No engine ever ran on this disk: nothing to record, nothing created.
	if err := writeCleanStop(rec, "b1"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Dir(rec)); !os.IsNotExist(err) {
		t.Fatalf("created %s: %v", filepath.Dir(rec), err)
	}
	if err := os.Mkdir(filepath.Dir(rec), 0755); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"b1", "b2"} {
		if err := writeCleanStop(rec, id); err != nil {
			t.Fatal(err)
		}
		if got := lastBootID(rec); got != id {
			t.Fatalf("record %q, want %q", got, id)
		}
	}
	// The record keeps the recent clean stops: a later boot whose engine never
	// ran recovery does not hide the stop the marks belong to.
	if got := readBootID(rec); got != "b1\nb2" {
		t.Fatalf("record %q", got)
	}
	if err := writeCleanStop(rec, "b1"); err != nil || readBootID(rec) != "b2\nb1" {
		t.Fatalf("a repeated boot id: %v %q", err, readBootID(rec))
	}
	for i := 0; i < 2*cleanStopKeep; i++ {
		if err := writeCleanStop(rec, fmt.Sprintf("x%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	if ids := strings.Fields(readBootID(rec)); len(ids) != cleanStopKeep || ids[len(ids)-1] != fmt.Sprintf("x%d", 2*cleanStopKeep-1) {
		t.Fatalf("record keeps %d: %v", len(ids), ids)
	}
	if err := writeCleanStop(rec, "b2"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(rec + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("temporary left: %v", err)
	}
	// Without a boot id the previous record stays as it was.
	if err := writeCleanStop(rec, ""); err != nil || lastBootID(rec) != "b2" {
		t.Fatalf("empty boot id: %v %q", err, readBootID(rec))
	}
	// A leftover or planted temporary is replaced, never followed.
	target := filepath.Join(dir, "elsewhere")
	if err := os.Symlink(target, rec+".tmp"); err != nil {
		t.Fatal(err)
	}
	if err := writeCleanStop(rec, "b3"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(target); !os.IsNotExist(err) {
		t.Fatalf("followed the symlink: %v", err)
	}
	if lastBootID(rec) != "b3" {
		t.Fatalf("record %q", readBootID(rec))
	}
}

func lastBootID(p string) string {
	ids := strings.Fields(readBootID(p))
	if len(ids) == 0 {
		return ""
	}
	return ids[len(ids)-1]
}
