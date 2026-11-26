package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDialEngineSocketConnectsSoonAfterTheEngineListens(t *testing.T) {
	// Short: a Unix socket path must stay under 104 bytes on macOS.
	dir, err := os.MkdirTemp("/tmp", "gi-dial")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, "docker.sock")
	var total time.Duration
	const rounds = 8
	for i := range rounds {
		connected := make(chan time.Time, 1)
		go func() {
			if c := dialEngineSocket(path, 2*time.Second, engineDialInterval); c != nil {
				_ = c.Close()
			}
			connected <- time.Now()
		}()
		time.Sleep(time.Duration(20+7*i) * time.Millisecond)
		ln, err := net.Listen("unix", path)
		if err != nil {
			t.Fatal(err)
		}
		listening := time.Now()
		total += (<-connected).Sub(listening)
		_ = ln.Close()
		_ = os.Remove(path)
	}
	// The first _ping after a switchover waits here: a 25 ms retry cost it
	// 12 ms on average.
	if mean := total / rounds; mean > 8*time.Millisecond {
		t.Fatalf("connected %v after the engine listened, on average", mean)
	}
}

func TestDialEngineSocketGivesUpAfterItsBudget(t *testing.T) {
	start := time.Now()
	if c := dialEngineSocket(filepath.Join(t.TempDir(), "absent.sock"), 60*time.Millisecond, engineDialInterval); c != nil {
		t.Fatal("connected to a socket nobody listens on")
	}
	if took := time.Since(start); took < 60*time.Millisecond || took > time.Second {
		t.Fatalf("gave up after %v, want about 60ms", took)
	}
}
