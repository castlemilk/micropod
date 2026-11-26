package main

import (
	"context"
	"encoding/binary"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func criLogTestDirectory(t *testing.T) string {
	t.Helper()
	root, required := os.LookupEnv("MICROPOD_CRI_LOG_TEST_TMPFS")
	if !required {
		root = "/dev/shm"
	}
	var fs unix.Statfs_t
	if err := unix.Statfs(root, &fs); err != nil || fs.Type != unix.TMPFS_MAGIC {
		if required {
			t.Fatalf("MICROPOD_CRI_LOG_TEST_TMPFS=%q is not a readable tmpfs: %v", root, err)
		}
		t.Skip("need a writable tmpfs for Linux inotify integration tests")
	}
	dir, err := os.MkdirTemp(root, "micropod-cri-log-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(dir); err != nil {
			t.Error(err)
		}
	})
	return dir
}

func TestCRILogWatcherCreateRenameAndReuse(t *testing.T) {
	dir := criLogTestDirectory(t)
	w, err := newCRILogWatcher()
	if err != nil {
		t.Fatal(err)
	}
	defer w.close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	path := filepath.Join(dir, "job.log")
	first, firstDone := w.watch(path)
	if first == nil || firstDone == nil {
		t.Fatal("failed to watch a private directory before file creation")
	}
	if duplicate, _ := w.watch(path); duplicate != nil {
		t.Fatal("duplicate registration replaced an active watch")
	}
	if unavailable, _ := w.watch("/proc/self/job.log"); unavailable != nil {
		t.Fatal("accepted a log watch outside tmpfs")
	}

	write := func(path string) {
		t.Helper()
		if err := os.WriteFile(path, []byte("t stdout F record\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	otherDir := filepath.Join(dir, "other")
	if err := os.Mkdir(otherDir, 0700); err != nil {
		t.Fatal(err)
	}
	otherPath := filepath.Join(otherDir, "job.log")
	other, otherDone := w.watch(otherPath)
	if other == nil {
		t.Fatal("failed to watch second directory")
	}
	defer otherDone()
	write(filepath.Join(dir, "unrelated"))
	write(otherPath)
	// Delivery from the same inotify instance proves prior events were read.
	receiveFollow(t, ctx, other)
	select {
	case <-first:
		t.Fatal("unrelated filename triggered log drain")
	default:
	}
	write(path)
	receiveFollow(t, ctx, first)
	if err := os.Rename(path, filepath.Join(dir, "old.log")); err != nil {
		t.Fatal(err)
	}
	for open := true; open; {
		select {
		case _, open = <-first:
		case <-ctx.Done():
			t.Fatal("renaming an active log did not trigger polling fallback")
		}
	}
	second, secondDone := w.watch(path)
	if second == nil {
		t.Fatal("failed to reuse directory after retiring old watch")
	}
	defer secondDone()
	firstDone()
	write(path)
	select {
	case _, open := <-second:
		if !open {
			t.Fatal("retired registration canceled a new watch")
		}
	case <-ctx.Done():
		t.Fatal("recreated log received no notification")
	}
}

func TestCRILogWatcherSharesOneFDAndRetiresWatches(t *testing.T) {
	root := criLogTestDirectory(t)
	w, err := newCRILogWatcher()
	if err != nil {
		t.Fatal(err)
	}
	defer w.close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	type watch struct {
		path string
		wake <-chan struct{}
		stop func()
	}
	var watches []watch
	for i := range 112 {
		dir := filepath.Join(root, strconv.Itoa(i))
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, "job.log")
		wake, stop := w.watch(path)
		if wake == nil {
			t.Fatalf("watch %d failed", i)
		}
		watches = append(watches, watch{path, wake, stop})
	}
	checkCount := func(want int) {
		t.Helper()
		w.mu.Lock()
		fd := w.fd
		w.mu.Unlock()
		info, err := os.ReadFile("/proc/self/fdinfo/" + strconv.Itoa(fd))
		if err != nil {
			t.Fatal(err)
		}
		if got := strings.Count(string(info), "inotify wd:"); got != want {
			t.Fatalf("kernel reports %d watches on one FD, wanted %d", got, want)
		}
	}
	checkCount(len(watches))
	// Leave all signal channels undrained during writes, including repeated
	// appends to the same file. One busy tail must not block the dispatcher.
	for _, watch := range watches {
		f, err := os.OpenFile(watch.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if err != nil {
			t.Fatal(err)
		}
		for range 4 {
			if _, err := f.WriteString("t stdout F record\n"); err != nil {
				f.Close()
				t.Fatal(err)
			}
		}
		if err := f.Close(); err != nil {
			t.Fatal(err)
		}
	}
	for _, watch := range watches {
		select {
		case _, open := <-watch.wake:
			if !open {
				t.Fatal("watch closed before delivery")
			}
		case <-ctx.Done():
			t.Fatalf("log %q did not notify", watch.path)
		}
		watch.stop()
		watch.stop()
	}
	checkCount(0)
}

func TestCRILogWatcherDisablesAllWatchesOnOverflow(t *testing.T) {
	// Inject the exact inotify overflow record instead of changing a sysctl
	// or overwhelming the kernel on a shared worker.
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	one, two := make(chan struct{}, 1), make(chan struct{}, 1)
	w := &criLogWatcher{
		file: reader, done: make(chan struct{}),
		watches: map[int32]criLogSubscription{
			1: {name: "job.log", wake: one},
			2: {name: "job.log", wake: two},
		},
	}
	go w.run()
	defer w.close()
	var overflow [unix.SizeofInotifyEvent]byte
	binary.NativeEndian.PutUint32(overflow[:4], ^uint32(0))
	binary.NativeEndian.PutUint32(overflow[4:8], unix.IN_Q_OVERFLOW)
	if _, err := writer.Write(overflow[:]); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	for _, signal := range []<-chan struct{}{one, two} {
		select {
		case _, open := <-signal:
			if open {
				t.Fatal("overflow delivered as an ordinary wake")
			}
		case <-ctx.Done():
			t.Fatal("overflow did not close a subscription")
		}
	}
	receiveFollow(t, ctx, w.done)
}
