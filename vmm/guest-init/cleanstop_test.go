package main

import (
	"os"
	"path/filepath"
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
		if got := readBootID(rec); got != id {
			t.Fatalf("record %q, want %q", got, id)
		}
	}
	if _, err := os.Lstat(rec + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("temporary left: %v", err)
	}
	// Without a boot id the previous record stays as it was.
	if err := writeCleanStop(rec, ""); err != nil || readBootID(rec) != "b2" {
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
	if readBootID(rec) != "b3" {
		t.Fatalf("record %q", readBootID(rec))
	}
}
