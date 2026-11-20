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
)

const buildkitBinary = "/opt/micropod-oci/runner/bin/buildkitd"
const buildkitPublic = "/var/lib/micropod/buildkit.sock"

// Buildx sessions use the worker's existing content store. A run-only worker
// never starts the builder. Each connected client holds the same drain fence as a job.
type buildkitService struct {
	mu  sync.Mutex
	cmd *exec.Cmd
}

func (b *buildkitService) connect(ctx context.Context) (*net.UnixConn, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cmd == nil {
		cmd := exec.CommandContext(ctx, buildkitBinary, "--config", "/opt/micropod-oci/runner/buildkitd.toml")
		cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
		cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
		if err := cmd.Start(); err != nil {
			return nil, err
		}
		b.cmd = cmd
		go func() {
			err := cmd.Wait()
			if err != nil {
				fmt.Fprintln(os.Stderr, "BuildKit:", err)
			}
			b.mu.Lock()
			b.cmd = nil
			b.mu.Unlock()
		}()
	}
	timeout, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	for {
		var d net.Dialer
		conn, err := d.DialContext(timeout, "unix", "/run/containerd/buildkitd.sock")
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

func serveBuildKit(ctx context.Context) error {
	buildkitPublic := clientSocket(buildkitPublic, "buildkit.sock")
	if _, err := os.Stat(buildkitBinary); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
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
	b := new(buildkitService)
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
				dst, err := b.connect(ctx)
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
