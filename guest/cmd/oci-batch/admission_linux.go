package main

import (
	"context"
	"errors"
	"os"
	"sync"
	"syscall"
	"unsafe"
)

func validToken(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'f' || c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}
func validScope(s string) bool {
	if len(s) == 0 || len(s) > 63 {
		return false
	}
	for i, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || i > 0 && (c == '-' || c == '_')) {
			return false
		}
	}
	return true
}

// runc publishes its pid file after starting init. A token limits concurrent OCI startup only.
// The inotify watch is on supervisor-owned tmpfs. Running workloads never hold a token.
type launchGate struct {
	dir      string
	watch    *os.File
	slots    chan struct{}
	finished chan struct{}
	mu       sync.Mutex
	waiting  map[string]func()
}

func newLaunchGate(state string, n, slots int) (*launchGate, error) {
	if !native || slots == 0 {
		return nil, nil
	}
	if slots >= n {
		return nil, nil
	}
	dir, err := os.MkdirTemp(state, "starts-")
	if err != nil {
		return nil, err
	}
	fd, err := syscall.InotifyInit1(syscall.IN_CLOEXEC | syscall.IN_NONBLOCK)
	if err != nil {
		os.Remove(dir)
		return nil, err
	}
	if _, err = syscall.InotifyAddWatch(fd, dir, syscall.IN_MOVED_TO|syscall.IN_CLOSE_WRITE); err != nil {
		syscall.Close(fd)
		os.Remove(dir)
		return nil, err
	}
	g := &launchGate{dir: dir, watch: os.NewFile(uintptr(fd), "OCI admission"), slots: make(chan struct{}, slots), finished: make(chan struct{}), waiting: make(map[string]func())}
	go g.observe()
	return g, nil
}
func (g *launchGate) observe() {
	defer close(g.finished)
	buf := make([]byte, 8192)
	for {
		n, err := g.watch.Read(buf)
		if err != nil {
			return
		}
		for i := 0; i+syscall.SizeofInotifyEvent <= n; {
			ev := (*syscall.InotifyEvent)(unsafe.Pointer(&buf[i]))
			start := i + syscall.SizeofInotifyEvent
			i = start + int(ev.Len)
			if i > n || ev.Len == 0 {
				continue
			}
			end := start
			for end < i && buf[end] != 0 {
				end++
			}
			name := string(buf[start:end])
			g.mu.Lock()
			release := g.waiting[name]
			g.mu.Unlock()
			if release != nil {
				release()
			}
		}
	}
}
func (g *launchGate) acquire(ctx context.Context, id string) (func(), error) {
	select {
	case g.slots <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-g.finished:
		return nil, errors.New("startup observer stopped")
	}
	once := sync.Once{}
	release := func() { once.Do(func() { g.mu.Lock(); delete(g.waiting, id); g.mu.Unlock(); <-g.slots }) }
	g.mu.Lock()
	g.waiting[id] = release
	g.mu.Unlock()
	return release, nil
}
func (g *launchGate) close() { g.watch.Close(); <-g.finished; os.RemoveAll(g.dir) }
