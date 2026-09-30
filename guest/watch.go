//go:build linux

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const dirMask = syscall.IN_CREATE | syscall.IN_MODIFY | syscall.IN_ATTRIB | syscall.IN_DELETE |
	syscall.IN_MOVED_FROM | syscall.IN_MOVED_TO | syscall.IN_DELETE_SELF | syscall.IN_MOVE_SELF

const fileMask = syscall.IN_MODIFY | syscall.IN_ATTRIB | syscall.IN_DELETE_SELF | syscall.IN_MOVE_SELF

// watch reports changes under PATH as JSON lines — {"event":"ready"} once
// the watch is live, then create/modify/delete/rename (both ends of a move)
// with absolute paths, and "overflow" if the kernel dropped events. With
// --recursive, directories created or moved in later are watched too.
// Runs until stdout closes.
func watch(args []string, stdout io.Writer) error {
	f, err := parse(args, 1)
	if err != nil {
		return err
	}
	root, err := filepath.Abs(f.pos[0])
	if err != nil {
		return err
	}
	info, err := os.Stat(root)
	if err != nil {
		return err
	}
	fd, err := syscall.InotifyInit1(syscall.IN_CLOEXEC)
	if err != nil {
		return os.NewSyscallError("inotify_init1", err)
	}
	defer syscall.Close(fd)
	out := bufio.NewWriter(stdout)
	w := &watcher{fd: fd, root: root, recursive: f.has("--recursive"), paths: map[int32]string{}, enc: json.NewEncoder(out)}
	if info.IsDir() {
		if err := w.add(root, false); err != nil {
			return err
		}
	} else {
		wd, err := syscall.InotifyAddWatch(fd, root, fileMask)
		if err != nil {
			return &fs.PathError{Op: "watch", Path: root, Err: err}
		}
		w.paths[int32(wd)] = root
		w.file = true
	}
	w.emit("ready", "")
	if err := out.Flush(); err != nil {
		return nil
	}
	buf := make([]byte, 64<<10)
	for {
		n, err := syscall.Read(fd, buf)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return os.NewSyscallError("read", err)
		}
		w.handle(buf[:n])
		if err := out.Flush(); err != nil {
			return nil // the host stopped listening
		}
	}
}

type watcher struct {
	fd        int
	root      string
	recursive bool
	file      bool
	paths     map[int32]string
	enc       *json.Encoder
	lastKey   string
	lastAt    time.Time
	full      bool
}

// add watches dir (and, recursively, its subdirectories). With announce,
// entries already inside are reported as created: they appeared between the
// directory's creation and its watch.
func (w *watcher) add(dir string, announce bool) error {
	wd, err := syscall.InotifyAddWatch(w.fd, dir, dirMask|syscall.IN_ONLYDIR)
	if err != nil {
		if err == syscall.ENOSPC && !w.full {
			w.full = true
			fmt.Fprintf(os.Stderr, "micropod-guest: ENOSPC: inotify watch limit reached; %s and below are not watched\n", dir)
		}
		return &fs.PathError{Op: "watch", Path: dir, Err: err}
	}
	w.paths[int32(wd)] = dir
	if !w.recursive && !announce {
		return nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil // gone again already
	}
	for _, e := range entries {
		path := filepath.Join(dir, e.Name())
		if announce {
			w.emit("create", path)
		}
		if w.recursive && e.IsDir() {
			_ = w.add(path, announce)
		}
	}
	return nil
}

// forget drops the watches on dir and below (it moved away: their paths
// are stale).
func (w *watcher) forget(dir string) {
	for wd, path := range w.paths {
		if path == dir || strings.HasPrefix(path, dir+"/") {
			_, _ = syscall.InotifyRmWatch(w.fd, uint32(wd))
			delete(w.paths, wd)
		}
	}
}

func (w *watcher) handle(buf []byte) {
	for off := 0; off+syscall.SizeofInotifyEvent <= len(buf); {
		ev := (*syscall.InotifyEvent)(unsafe.Pointer(&buf[off]))
		start := off + syscall.SizeofInotifyEvent
		end := start + int(ev.Len)
		if end > len(buf) {
			return
		}
		name := strings.TrimRight(string(buf[start:end]), "\x00")
		off = end
		if ev.Mask&syscall.IN_Q_OVERFLOW != 0 {
			w.emit("overflow", "")
			continue
		}
		dir, ok := w.paths[ev.Wd]
		if !ok {
			continue
		}
		path := dir
		if name != "" {
			path = filepath.Join(dir, name)
		}
		isDir := ev.Mask&syscall.IN_ISDIR != 0
		self := w.file || dir == w.root
		switch {
		case ev.Mask&syscall.IN_IGNORED != 0:
			delete(w.paths, ev.Wd)
		case ev.Mask&syscall.IN_CREATE != 0:
			w.emit("create", path)
			if isDir && w.recursive {
				_ = w.add(path, true)
			}
		case ev.Mask&syscall.IN_MOVED_FROM != 0:
			w.emit("rename", path)
			if isDir {
				w.forget(path)
			}
		case ev.Mask&syscall.IN_MOVED_TO != 0:
			w.emit("rename", path)
			if isDir && w.recursive {
				_ = w.add(path, false)
			}
		case ev.Mask&syscall.IN_DELETE != 0:
			w.emit("delete", path)
		case ev.Mask&syscall.IN_DELETE_SELF != 0:
			// A subdirectory's own deletion was already reported by its parent.
			if self && name == "" {
				w.emit("delete", dir)
			}
		case ev.Mask&syscall.IN_MOVE_SELF != 0:
			if self && name == "" {
				w.emit("rename", dir)
			}
		case ev.Mask&(syscall.IN_MODIFY|syscall.IN_ATTRIB) != 0:
			if !isDir {
				w.emit("modify", path)
			}
		}
	}
}

// emit writes one event; a burst of modifies to one file (one per write())
// is reported once per 50 ms.
func (w *watcher) emit(event, path string) {
	key := event + "\x00" + path
	now := time.Now()
	if event == "modify" && key == w.lastKey && now.Sub(w.lastAt) < 50*time.Millisecond {
		w.lastAt = now
		return
	}
	w.lastKey, w.lastAt = key, now
	_ = w.enc.Encode(struct {
		Event string `json:"event"`
		Path  string `json:"path,omitempty"`
	}{event, path})
}
