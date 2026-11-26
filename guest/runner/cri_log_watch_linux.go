package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

type criLogSubscription struct {
	name string
	wake chan struct{}
}

// One inotify instance per Docker engine. Each live CRI tail watches the
// private directory so that it also sees a log created after registration.
type criLogWatcher struct {
	file *os.File
	done chan struct{}

	mu      sync.Mutex
	fd      int // -1 once stopped; protected by mu
	lastWD  int32
	watches map[int32]criLogSubscription
}

func newCRILogWatcher() (*criLogWatcher, error) {
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), "cri-log-inotify")
	// NewFile attempts to register a nonblocking descriptor with Go's poller.
	// Reject an unpollable descriptor instead of spinning on EAGAIN.
	if err := file.SetReadDeadline(time.Time{}); err != nil {
		file.Close()
		return nil, err
	}
	w := &criLogWatcher{
		file: file, done: make(chan struct{}), fd: fd,
		watches: make(map[int32]criLogSubscription),
	}
	go w.run()
	return w, nil
}

func (w *criLogWatcher) watch(path string) (<-chan struct{}, func()) {
	dir := filepath.Dir(path)
	var fs unix.Statfs_t
	// CRI logs are on private tmpfs for jobs or the native ext4 Docker store
	// for explicit /dev overrides. Keep polling for shared filesystems.
	if err := unix.Statfs(dir, &fs); err != nil || fs.Type != unix.TMPFS_MAGIC && fs.Type != unix.EXT4_SUPER_MAGIC {
		return nil, nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.fd < 0 {
		return nil, nil
	}
	mask := uint32(unix.IN_ONLYDIR | unix.IN_DONT_FOLLOW | unix.IN_MASK_CREATE |
		unix.IN_MODIFY | unix.IN_CREATE | unix.IN_MOVED_TO | unix.IN_MOVED_FROM |
		unix.IN_DELETE | unix.IN_DELETE_SELF | unix.IN_MOVE_SELF)
	wd, err := unix.InotifyAddWatch(w.fd, dir, mask)
	if err != nil {
		return nil, nil
	}
	id := int32(wd)
	if id <= w.lastWD {
		// Descriptors increase until the kernel's allocator wraps. A reused
		// descriptor can still have unread events from an older watch.
		w.stopLocked()
		return nil, nil
	}
	w.lastWD = id
	sub := criLogSubscription{name: filepath.Base(path), wake: make(chan struct{}, 1)}
	w.watches[id] = sub
	return sub.wake, func() {
		w.mu.Lock()
		defer w.mu.Unlock()
		if w.watches[id].wake == sub.wake {
			w.removeLocked(id)
		}
	}
}

func (w *criLogWatcher) removeLocked(id int32) {
	close(w.watches[id].wake)
	delete(w.watches, id)
	if _, err := unix.InotifyRmWatch(w.fd, uint32(id)); err != nil && !errors.Is(err, unix.EINVAL) {
		// Closing the instance also frees a watch we could not remove.
		w.stopLocked()
	}
}

func (w *criLogWatcher) stopLocked() {
	if w.fd < 0 {
		return
	}
	for _, sub := range w.watches {
		close(sub.wake)
	}
	clear(w.watches)
	w.fd = -1
	w.file.Close()
}

func (w *criLogWatcher) close() {
	w.mu.Lock()
	w.stopLocked()
	w.mu.Unlock()
	<-w.done
}

func (w *criLogWatcher) run() {
	defer close(w.done)
	err := w.readEvents()
	w.mu.Lock()
	active := w.fd >= 0
	w.stopLocked()
	w.mu.Unlock()
	if active {
		log.Printf("CRI log notifications interrupted, polling logs: %v", err)
	}
}

func (w *criLogWatcher) readEvents() error {
	var buffer [32 << 10]byte
	for {
		n, err := w.file.Read(buffer[:])
		if err != nil {
			return err
		}
		if err := w.dispatch(buffer[:n]); err != nil {
			return err
		}
	}
}

func (w *criLogWatcher) dispatch(events []byte) error {
	for len(events) != 0 {
		if len(events) < unix.SizeofInotifyEvent {
			return errors.New("short inotify event")
		}
		wd := int32(binary.NativeEndian.Uint32(events[:4]))
		mask := binary.NativeEndian.Uint32(events[4:8])
		nameLen := binary.NativeEndian.Uint32(events[12:16])
		if nameLen > uint32(len(events)-unix.SizeofInotifyEvent) {
			return errors.New("short inotify pathname")
		}
		if mask&unix.IN_Q_OVERFLOW != 0 {
			return errors.New("inotify queue overflow")
		}
		end := unix.SizeofInotifyEvent + int(nameLen)
		name, _, _ := bytes.Cut(events[unix.SizeofInotifyEvent:end], []byte{0})
		w.notify(wd, mask, name)
		events = events[end:]
	}
	return nil
}

func (w *criLogWatcher) notify(id int32, mask uint32, name []byte) {
	w.mu.Lock()
	defer w.mu.Unlock()
	sub, exists := w.watches[id]
	if !exists {
		return
	}
	if mask&(unix.IN_DELETE_SELF|unix.IN_MOVE_SELF|unix.IN_UNMOUNT|unix.IN_IGNORED) != 0 {
		w.removeLocked(id)
		return
	}
	if string(name) != sub.name {
		return
	}
	// A renamed file can keep receiving writes on its original open inode.
	// Resume polling that descriptor, as the original tail did.
	if mask&(unix.IN_MOVED_FROM|unix.IN_MOVED_TO|unix.IN_DELETE) != 0 {
		w.removeLocked(id)
		return
	}
	select {
	case sub.wake <- struct{}{}:
	default:
	}
}
