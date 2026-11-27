package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const buildkitBinary = "/opt/micropod-oci/runner/bin/buildkitd"
const buildkitConfig = "/opt/micropod-oci/runner/buildkitd.toml"
const buildkitSocket = "/run/containerd/buildkitd.sock"
const buildkitPublic = "/var/lib/micropod/buildkit.sock"

// Messages through the Docker socket proxy and the raw bridge share buildkitd's
// own 16 MiB limit with headroom; LLB definitions and session chunks stay far below.
const buildkitMaxMessage = 64 << 20

// engineCapabilities is what GET /version reports as MicropodCapabilities and
// what the tool bundle's runner/manifest.json lists for the same engine.
func engineCapabilities(buildkit bool) []string {
	caps := []string{"caches"}
	if buildkit {
		caps = append(caps, "buildkit", "grpc-build")
	}
	return caps
}

// One buildkitd per engine, started on first use. Buildx sessions use the
// worker's existing content store, and a run-only worker never starts the
// builder. Each connected client holds the same drain fence as a job.
type buildkitService struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	lifetime context.Context // buildkitd runs until this ends, never a request's context
	// output is the end of the current or last buildkitd's output, and exited
	// closes when that buildkitd has exited (tornCacheSetAside).
	output *tailBuffer
	exited chan struct{}
	// cacheSetAside is true once this engine moved a torn cache index aside.
	cacheSetAside bool
}

// tailBuffer keeps the last bytes written to it.
type tailBuffer struct {
	mu  sync.Mutex
	buf []byte
}

const buildkitOutputTail = 64 << 10

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if over := len(t.buf) - buildkitOutputTail; over > 0 {
		t.buf = append([]byte(nil), t.buf[over:]...)
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return string(t.buf)
}

// buildkitCacheDB is BuildKit's solver cache index (cache keys to results).
// BuildKit opens it without fsync (NoSync), so an unclean stop can leave it
// torn; its own fallback for a database that does not open (set it aside,
// start empty) does not catch the panic bbolt raises in the goroutine that
// rebuilds the free list, and buildkitd then dies at every start.
func buildkitCacheDB() string { return filepath.Join(buildkitRoot, "cache.db") }

// tornCacheSetAside waits briefly for the last buildkitd to exit; if it died
// panicking in bbolt, it moves BuildKit's cache index aside (once per
// engine), as BuildKit's own fallback would, and reports true: the next
// start begins with an empty index. Only the index goes: the cache records
// and their snapshots stay, and BuildKit's collector removes the ones no key
// reaches any more. Builds miss the cache until it is filled again.
func (b *buildkitService) tornCacheSetAside() bool {
	b.mu.Lock()
	exited, output, done := b.exited, b.output, b.cacheSetAside
	b.mu.Unlock()
	if exited == nil || output == nil || done {
		return false
	}
	select {
	case <-exited:
	case <-time.After(5 * time.Second):
		return false
	}
	text := output.String()
	if !strings.Contains(text, "panic") || !strings.Contains(text, "go.etcd.io/bbolt") {
		return false
	}
	db := buildkitCacheDB()
	aside := fmt.Sprintf("%s.torn-%d", db, time.Now().Unix())
	if err := os.Rename(db, aside); err != nil {
		log.Printf("BuildKit died in its database and its cache index cannot be moved aside: %v", err)
		return false
	}
	_ = syncDir(filepath.Dir(db))
	b.mu.Lock()
	b.cacheSetAside = true
	b.mu.Unlock()
	log.Printf("BuildKit died in its database at start (an unclean stop tore its cache index, which it does not sync): moved %s to %s; it starts with an empty index", db, aside)
	return true
}

// sharedBuildkit serves the raw vsock bridge, the Docker socket's /grpc and
// /session routes and any engine-side BuildKit client.
var sharedBuildkit = &buildkitService{lifetime: context.Background()}

// setLifetime binds buildkitd to the engine's lifetime. A process that is
// already running keeps the context it was started with.
func (b *buildkitService) setLifetime(ctx context.Context) {
	b.mu.Lock()
	b.lifetime = ctx
	b.mu.Unlock()
}

// running reports whether this engine has started buildkitd and it has not
// exited.
func (b *buildkitService) running() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.cmd != nil
}

// dial starts buildkitd if it is not running and connects to its socket. ctx
// bounds only the wait for the socket; buildkitd itself outlives it.
func (b *buildkitService) dial(ctx context.Context) (*net.UnixConn, error) {
	b.mu.Lock()
	if b.cmd == nil {
		if err := b.lifetime.Err(); err != nil {
			b.mu.Unlock()
			return nil, err
		}
		cmd := exec.CommandContext(b.lifetime, buildkitBinary, "--config", buildkitConfig)
		cmd.Env = buildkitEnv()
		output := &tailBuffer{}
		cmd.Stdout = io.MultiWriter(os.Stderr, output)
		cmd.Stderr = cmd.Stdout
		cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
		if err := cmd.Start(); err != nil {
			b.mu.Unlock()
			return nil, err
		}
		exited := make(chan struct{})
		b.cmd, b.output, b.exited = cmd, output, exited
		go func() {
			err := cmd.Wait()
			if err != nil {
				fmt.Fprintln(os.Stderr, "BuildKit:", err)
			}
			b.mu.Lock()
			if b.cmd == cmd {
				b.cmd = nil
			}
			b.mu.Unlock()
			close(exited)
		}()
	}
	b.mu.Unlock()
	timeout, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	for {
		var d net.Dialer
		conn, err := d.DialContext(timeout, "unix", buildkitSocket)
		if err == nil {
			return conn.(*net.UnixConn), nil
		}
		select {
		case <-timeout.Done():
			return nil, err
		case <-time.After(40 * time.Millisecond):
		}
	}
}

func serveBuildKit(ctx context.Context) (string, error) {
	buildkitPublic := clientSocket(buildkitPublic, "buildkit.sock")
	if _, err := os.Stat(buildkitBinary); errors.Is(err, os.ErrNotExist) {
		return "", nil
	} else if err != nil {
		return "", err
	}
	b := sharedBuildkit
	b.setLifetime(ctx)
	if st, err := os.Lstat(buildkitPublic); err == nil {
		if st.Mode()&os.ModeSocket == 0 {
			return "", errors.New("BuildKit socket path is occupied")
		}
		if err := os.Remove(buildkitPublic); err != nil {
			return "", err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: buildkitPublic, Net: "unix"})
	if err != nil {
		return "", err
	}
	if err := os.Chmod(buildkitPublic, 0600); err != nil {
		l.Close()
		return "", err
	}
	slots := make(chan struct{}, 128)
	stop := context.AfterFunc(ctx, func() { l.Close() })
	go func() {
		defer stop()
		for {
			client, err := l.AcceptUnix()
			if err != nil {
				return
			}
			select {
			case slots <- struct{}{}:
			default:
				client.Close()
				continue
			}
			go func() {
				defer func() { <-slots }()
				defer client.Close()
				lease, err := engineLease()
				if err != nil {
					return
				}
				defer lease.Close()
				dst, err := b.dial(ctx)
				if err != nil {
					fmt.Fprintln(os.Stderr, "BuildKit connection:", err)
					return
				}
				defer dst.Close()
				stop := context.AfterFunc(ctx, func() { client.Close(); dst.Close() })
				defer stop()
				upstream := make(chan struct{})
				go func() {
					io.Copy(dst, client)
					if disconnected(client) {
						dst.Close()
					} else {
						dst.CloseWrite()
					}
					close(upstream)
				}()
				io.Copy(client, dst)
				client.CloseWrite()
				<-upstream
			}()
		}
	}()
	return buildkitPublic, nil
}

// buildkitEnv gives buildkitd the rig depproxy settings (from
// cache-policy.json). BuildKit stays outside the shared stores: its own state
// (RUN --mount=type=cache records included) is its root on the OS disk, with
// the containerd snapshots that state refers to (vmm/guest-init cachedisk.go:
// both survive a restart and both go with a replaced OS disk), and nothing
// hands it a path into scopes/. A build step that wrote
// a store would bypass the crash fence (no unit lock, no dirty mark) and the
// janitor's in-use test, so no such path is exported. (An earlier version set
// MICROPOD_CACHE_L0_DIR to scopes/global and created that directory outside
// ensureStore; nothing read it, and buildkitd does not pass its environment to
// build steps.)
func buildkitEnv() []string {
	env := append([]string(nil), os.Environ()...)
	if raw, err := os.ReadFile(cachePolicyFile); err == nil {
		if pol, err := parseCachePolicy(raw); err == nil {
			if pol.GoProxy != "" {
				env = append(env, "GOPROXY="+pol.GoProxy)
			}
			if pol.NpmRegistry != "" {
				env = append(env, "npm_config_registry="+pol.NpmRegistry)
			}
		}
	}
	return env
}
