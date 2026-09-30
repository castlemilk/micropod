//go:build linux

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"
)

func runOK(t *testing.T, stdin string, args ...string) string {
	t.Helper()
	var out bytes.Buffer
	if err := run(args, strings.NewReader(stdin), &out); err != nil {
		t.Fatalf("%v: %v", args, err)
	}
	return out.String()
}

func runErr(t *testing.T, args ...string) string {
	t.Helper()
	err := run(args, strings.NewReader(""), io.Discard)
	if err == nil {
		t.Fatalf("%v: expected an error", args)
	}
	return errnoName(err)
}

func TestWriteReadAppendModeParents(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "a/b/c.bin")
	blob := string(bytes.Repeat([]byte{0, 1, 2, 255}, 20000))
	runOK(t, blob, "write", path, "--parents", "--mode", "4750")
	if got := runOK(t, "", "read", path); got != blob {
		t.Fatalf("roundtrip: %d bytes back, want %d", len(got), len(blob))
	}
	runOK(t, "tail", "write", path, "--append")
	var st entry
	if err := json.Unmarshal([]byte(runOK(t, "", "stat", path)), &st); err != nil {
		t.Fatal(err)
	}
	if st.Size != int64(len(blob)+4) || st.Type != "file" || st.Mode&0o7777 != 0o4750 {
		t.Fatalf("stat %+v", st)
	}
	if code := runErr(t, "read", path, "--max", "10"); code != "EFBIG" {
		t.Fatalf("over --max: %s", code)
	}
	if code := runErr(t, "read", dir); code != "EISDIR" {
		t.Fatalf("read dir: %s", code)
	}
	if code := runErr(t, "read", filepath.Join(dir, "missing")); code != "ENOENT" {
		t.Fatalf("missing: %s", code)
	}
	if code := runErr(t, "write", filepath.Join(dir, "no/parent/x")); code != "ENOENT" {
		t.Fatalf("no parents: %s", code)
	}
}

func TestListStatTypes(t *testing.T) {
	dir := t.TempDir()
	runOK(t, "x", "write", filepath.Join(dir, "file with space"))
	runOK(t, "", "mkdir", filepath.Join(dir, "sub"))
	if err := os.Symlink("sub", filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}
	var names []string
	sc := bufio.NewScanner(strings.NewReader(runOK(t, "", "list", dir)))
	for sc.Scan() {
		var e entry
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			t.Fatal(err)
		}
		names = append(names, e.Name+":"+e.Type)
	}
	slices.Sort(names)
	if want := []string{"file with space:file", "link:symlink", "sub:dir"}; !slices.Equal(names, want) {
		t.Fatalf("list %v, want %v", names, want)
	}
	if code := runErr(t, "list", filepath.Join(dir, "file with space")); code != "ENOTDIR" {
		t.Fatalf("list a file: %s", code)
	}
}

func TestMkdirRemoveRenameCopyChmod(t *testing.T) {
	dir := t.TempDir()
	deep := filepath.Join(dir, "a/b")
	runOK(t, "", "mkdir", deep, "--parents")
	if code := runErr(t, "mkdir", deep); code != "EEXIST" {
		t.Fatalf("mkdir existing: %s", code)
	}
	runOK(t, "data", "write", filepath.Join(deep, "f"), "--mode", "600")
	if code := runErr(t, "rm", filepath.Join(dir, "a")); code != "ENOTEMPTY" {
		t.Fatalf("rm non-empty: %s", code)
	}
	runOK(t, "", "cp", filepath.Join(dir, "a"), filepath.Join(dir, "copy"), "--recursive")
	if code := runErr(t, "cp", filepath.Join(dir, "a"), filepath.Join(dir, "x")); code != "EISDIR" {
		t.Fatalf("cp dir without --recursive: %s", code)
	}
	if code := runErr(t, "cp", filepath.Join(dir, "a"), filepath.Join(dir, "a/b/inside"), "--recursive"); code != "EINVAL" {
		t.Fatalf("cp into itself: %s", code)
	}
	info, err := os.Stat(filepath.Join(dir, "copy/b/f"))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("copied file %v %v", info, err)
	}
	runOK(t, "", "mv", filepath.Join(dir, "copy"), filepath.Join(dir, "moved"))
	if _, err := os.Stat(filepath.Join(dir, "moved/b/f")); err != nil {
		t.Fatal(err)
	}
	runOK(t, "", "chmod", "755", filepath.Join(dir, "moved/b/f"))
	info, _ = os.Stat(filepath.Join(dir, "moved/b/f"))
	if info.Mode().Perm() != 0o755 {
		t.Fatalf("chmod: %v", info.Mode())
	}
	runOK(t, "", "rm", filepath.Join(dir, "a"), "--recursive")
	if code := runErr(t, "rm", filepath.Join(dir, "a")); code != "ENOENT" {
		t.Fatalf("rm missing: %s", code)
	}
	if code := runErr(t, "chmod", "999", filepath.Join(dir, "moved")); code != "EINVAL" {
		t.Fatalf("bad mode: %s", code)
	}
}

// watchEvents runs a recursive watch on dir while act mutates it, returning
// the events seen (after "ready").
func watchEvents(t *testing.T, dir string, act func()) []string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = run([]string{"watch", dir, "--recursive"}, strings.NewReader(""), w) }()
	lines := make(chan string, 1024)
	go func() {
		sc := bufio.NewScanner(r)
		for sc.Scan() {
			lines <- sc.Text()
		}
	}()
	select {
	case line := <-lines:
		if line != `{"event":"ready"}` {
			t.Fatalf("first event %s", line)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no ready")
	}
	act()
	var events []string
	deadline := time.After(700 * time.Millisecond)
	for {
		select {
		case line := <-lines:
			var e struct{ Event, Path string }
			_ = json.Unmarshal([]byte(line), &e)
			events = append(events, e.Event+" "+strings.TrimPrefix(e.Path, dir))
		case <-deadline:
			r.Close()
			return events
		}
	}
}

func TestWatchReportsChangesRecursivelyAndFast(t *testing.T) {
	dir := t.TempDir()
	events := watchEvents(t, dir, func() {
		_ = os.WriteFile(filepath.Join(dir, "a.txt"), []byte("1"), 0o644)
		// Two writes within one second: a stat poll can't tell them apart.
		_ = os.WriteFile(filepath.Join(dir, "a.txt"), []byte("2"), 0o644)
		// A new directory with a file created before its watch can exist.
		_ = os.MkdirAll(filepath.Join(dir, "d/e"), 0o755)
		_ = os.WriteFile(filepath.Join(dir, "d/e/deep.txt"), []byte("x"), 0o644)
		time.Sleep(100 * time.Millisecond)
		_ = os.WriteFile(filepath.Join(dir, "d/e/later.txt"), []byte("y"), 0o644)
		_ = os.Rename(filepath.Join(dir, "a.txt"), filepath.Join(dir, "d/b.txt"))
		_ = os.Remove(filepath.Join(dir, "d/b.txt"))
	})
	for _, want := range []string{
		"create /a.txt", "modify /a.txt", "create /d", "create /d/e/deep.txt", "create /d/e/later.txt",
		"rename /a.txt", "rename /d/b.txt", "delete /d/b.txt",
	} {
		if !slices.Contains(events, want) {
			t.Errorf("missing %q in %v", want, events)
		}
	}
	modifies := 0
	for _, e := range events {
		if e == "modify /a.txt" {
			modifies++
		}
	}
	if modifies > 2 {
		t.Errorf("a modify burst should coalesce, got %d: %v", modifies, events)
	}
}

func TestWatchMissingPath(t *testing.T) {
	err := run([]string{"watch", "/definitely/missing"}, strings.NewReader(""), io.Discard)
	var errno syscall.Errno
	if !errors.As(err, &errno) || errno != syscall.ENOENT {
		t.Fatalf("got %v", err)
	}
}
