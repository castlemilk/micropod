// A disposable Linux CI job. The host checks each response on a new published connection.
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const frame = 64 << 10

type tenant struct {
	name   string
	cookie uint64
	busy   atomic.Bool
	resets atomic.Uint64
	mu     sync.Mutex
	hold   chan struct{}
}

var revision = regexp.MustCompile(`^[a-z0-9-]{1,48}$`)

func file(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return err.Error()
	}
	return strings.TrimSpace(string(b))
}

func (t *tenant) identity(w http.ResponseWriter, _ *http.Request) {
	var stat syscall.Stat_t
	if err := syscall.Stat("/sys/fs/cgroup", &stat); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	t.mu.Lock()
	held := t.hold != nil
	t.mu.Unlock()
	json.NewEncoder(w).Encode(map[string]any{
		"name": t.name, "cookie": t.cookie, "cgroup": stat.Ino,
		"reset_after_verified_frame": t.resets.Load(), "holding_upload": held,
		"boot": file("/proc/sys/kernel/random/boot_id"), "cpu": file("/sys/fs/cgroup/cpu.max"),
		"memory": file("/sys/fs/cgroup/memory.max"), "pids": file("/sys/fs/cgroup/pids.max"),
		"memory_events": file("/sys/fs/cgroup/memory.events"),
		"memory_peak":   file("/sys/fs/cgroup/memory.peak"),
		"cpu_stat":      file("/sys/fs/cgroup/cpu.stat"),
		"iflink":        file("/sys/class/net/mppub0/iflink"),
		"published_mac": file("/sys/class/net/mppub0/address"),
		"tcp_queue":     file("/proc/sys/net/ipv4/tcp_limit_output_bytes"),
	})
}

func (t *tenant) build(w http.ResponseWriter, r *http.Request) {
	rev := r.URL.Query().Get("rev")
	if !revision.MatchString(rev) {
		http.Error(w, "invalid revision", 400)
		return
	}
	if !t.busy.CompareAndSwap(false, true) {
		http.Error(w, "job is busy", 409)
		return
	}
	defer t.busy.Store(false)
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/sh", "/mpcheck/job.sh", rev)
	cmd.Dir = "/workspace"
	out, err := cmd.CombinedOutput()
	if err != nil {
		http.Error(w, fmt.Sprintf("%v\n%.4096s", err, out), 500)
		return
	}
	w.Write(out)
}

func (t *tenant) release(w http.ResponseWriter, _ *http.Request) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.hold == nil {
		http.Error(w, "no held upload", 409)
		return
	}
	close(t.hold)
	t.hold = nil
	w.WriteHeader(204)
}

func (t *tenant) frames(w http.ResponseWriter, r *http.Request) {
	if r.ContentLength <= 0 || r.ContentLength > 64<<20 || r.ContentLength%frame != 0 {
		http.Error(w, "invalid upload length", 400)
		return
	}
	mode := r.URL.Query().Get("fault")
	if mode == "hold" {
		hold := make(chan struct{})
		t.mu.Lock()
		if t.hold != nil {
			t.mu.Unlock()
			http.Error(w, "already holding an upload", 409)
			return
		}
		t.hold = hold
		t.mu.Unlock()
		defer func() {
			t.mu.Lock()
			if t.hold == hold {
				t.hold = nil
			}
			t.mu.Unlock()
		}()
		select {
		case <-hold:
		case <-r.Context().Done():
			return
		case <-time.After(25 * time.Second):
			http.Error(w, "healthy siblings failed to finish before the hold deadline", 504)
			return
		}
	}
	data, pattern := make([]byte, frame), make([]byte, frame)
	count := uint64(r.ContentLength / frame)
	for seq := uint64(1); seq <= count; seq++ {
		if _, err := io.ReadFull(r.Body, data); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		pattern[0] = byte(t.cookie + seq)
		for filled := 1; filled < frame; filled *= 2 {
			copy(pattern[filled:], pattern[:filled])
		}
		if binary.LittleEndian.Uint64(data) != seq || binary.LittleEndian.Uint64(data[8:]) != t.cookie || !bytes.Equal(data[16:], pattern[16:]) {
			http.Error(w, "wrong tenant, sequence or frame body", 422)
			return
		}
		if mode == "reset" && seq == 1 {
			conn, _, err := w.(http.Hijacker).Hijack()
			if err == nil {
				t.resets.Add(1)
				if tcp, ok := conn.(*net.TCPConn); ok {
					tcp.SetLinger(0)
				}
				conn.Close()
			}
			return
		}
	}
	json.NewEncoder(w).Encode(map[string]any{"name": t.name, "cookie": t.cookie, "frames": count, "bytes": count * frame})
}

func main() {
	if len(os.Args) != 3 || !revision.MatchString(os.Args[1]) {
		log.Fatal("expected tenant name and numeric cookie")
	}
	cookie, err := strconv.ParseUint(os.Args[2], 10, 64)
	if err != nil || cookie == 0 {
		log.Fatal("invalid tenant cookie")
	}
	t := &tenant{name: os.Args[1], cookie: cookie}
	mux := http.NewServeMux()
	identity := func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, t.name) }
	mux.HandleFunc("GET /health", identity)
	mux.HandleFunc("GET /id", identity)
	if err := artifactRoutes(mux, t.name, os.Getenv("MCI_KERNEL_STUDY") == "1"); err != nil {
		log.Fatal(err)
	}
	mux.HandleFunc("GET /identity", t.identity)
	mux.HandleFunc("POST /build", t.build)
	mux.HandleFunc("GET /artifact", func(w http.ResponseWriter, r *http.Request) { http.ServeFile(w, r, "/tmp/product") })
	mux.HandleFunc("POST /frames", t.frames)
	mux.HandleFunc("POST /release", t.release)
	server := http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 3 * time.Minute, WriteTimeout: 4 * time.Minute}
	if os.Getenv("MCI_LINK_STUDY") == "1" {
		type connectionKey struct{}
		server.ConnContext = func(ctx context.Context, c net.Conn) context.Context {
			return context.WithValue(ctx, connectionKey{}, c)
		}
		mux.HandleFunc("GET /publication-link", func(w http.ResponseWriter, r *http.Request) {
			c := r.Context().Value(connectionKey{}).(*net.TCPConn)
			raw, err := c.SyscallConn()
			var mss int
			var optErr error
			if err == nil {
				err = raw.Control(func(fd uintptr) {
					mss, optErr = syscall.GetsockoptInt(int(fd), syscall.IPPROTO_TCP, syscall.TCP_MAXSEG)
				})
			}
			if err != nil || optErr != nil {
				http.Error(w, "TCP_MAXSEG unavailable", http.StatusInternalServerError)
				return
			}
			links, err := net.Interfaces()
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			mtus := make(map[string]int)
			for _, nic := range links {
				mtus[nic.Name] = nic.MTU
			}
			json.NewEncoder(w).Encode(map[string]any{"cookie": t.cookie, "name": t.name, "mss": mss, "links": mtus, "peer": c.RemoteAddr().String()})
		})
	}
	if err := server.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
