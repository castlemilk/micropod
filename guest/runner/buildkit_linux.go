package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const buildkitBinary = "/opt/micropod-oci/runner/bin/buildkitd"
const buildkitConfig = "/opt/micropod-oci/runner/buildkitd.toml"
const buildkitSocket = "/run/containerd/buildkitd.sock"
const buildkitPublic = "/var/lib/micropod/buildkit.sock"

// Messages through the Docker socket proxy and the raw bridge share buildkitd's
// own 16 MiB limit with headroom; LLB definitions and session chunks stay far below.
const buildkitMaxMessage = 64 << 20

func buildkitAvailable() bool {
	_, err := os.Stat(buildkitBinary)
	return err == nil
}

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

	ccMu sync.Mutex
	cc   *grpc.ClientConn
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
		cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
		cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
		if err := cmd.Start(); err != nil {
			b.mu.Unlock()
			return nil, err
		}
		b.cmd = cmd
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

// clientConn returns the engine's one gRPC connection to buildkitd. gRPC
// re-dials through dial (restarting buildkitd) whenever the transport breaks,
// so the connection stays usable across a buildkitd exit.
func (b *buildkitService) clientConn(context.Context) (*grpc.ClientConn, error) {
	if !buildkitAvailable() {
		return nil, errBuildkitUnavailable
	}
	b.ccMu.Lock()
	defer b.ccMu.Unlock()
	if b.cc != nil {
		return b.cc, nil
	}
	cc, err := grpc.NewClient("passthrough:///buildkitd",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return b.dial(ctx) }),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(buildkitMaxMessage), grpc.MaxCallSendMsgSize(buildkitMaxMessage)))
	if err != nil {
		return nil, err
	}
	b.cc = cc
	return cc, nil
}

var errBuildkitUnavailable = fail(503, "BuildKit is unavailable (tool bundle lacks buildkitd)")

func serveBuildKit(ctx context.Context) error {
	buildkitPublic := clientSocket(buildkitPublic, "buildkit.sock")
	if _, err := os.Stat(buildkitBinary); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	b := sharedBuildkit
	b.setLifetime(ctx)
	if st, err := os.Lstat(buildkitPublic); err == nil {
		if st.Mode()&os.ModeSocket == 0 {
			return errors.New("BuildKit socket path is occupied")
		}
		if err := os.Remove(buildkitPublic); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: buildkitPublic, Net: "unix"})
	if err != nil {
		return err
	}
	if err := os.Chmod(buildkitPublic, 0600); err != nil {
		l.Close()
		return err
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
				go func() { io.Copy(dst, client); dst.CloseWrite(); close(upstream) }()
				io.Copy(client, dst)
				client.CloseWrite()
				<-upstream
			}()
		}
	}()
	return nil
}
