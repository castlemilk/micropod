package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	taskapi "github.com/containerd/containerd/api/types/task"
	"golang.org/x/sys/unix"
)

const (
	dockerPID1Command = "container-stdio"
	dockerPID1Startup = 10 * time.Second
)

// The generation's I/O lives in the guest engine. Only the short launch
// handshake uses a socket mounted in the container.
type dockerPID1 struct {
	dir       string
	listener  *net.UnixListener
	tty       bool
	openStdin bool
	ready     chan struct{}
	closed    chan struct{}
	input     chan []byte
	inputDone chan struct{}
	output    dockerOutputDrain
	files     []*os.File

	mu       sync.Mutex
	terminal *os.File
	size     unix.Winsize
	err      error
}

func newDockerPID1(root string, config dockerConfig) (_ *dockerPID1, err error) {
	dir, err := os.MkdirTemp(root, "pid1-")
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(dir)
		}
	}()
	// The enclosing engine directory stays owner-only in the guest.
	if err := os.Chmod(dir, 0755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(dir, "launch"), nil, 0444); err != nil {
		return nil, err
	}
	socket := filepath.Join(dir, "io")
	listener, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: socket, Net: "unixpacket"})
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(socket, 0666); err != nil {
		listener.Close()
		return nil, err
	}
	p := &dockerPID1{
		dir: dir, listener: listener,
		tty: config.Tty, openStdin: config.OpenStdin,
		ready: make(chan struct{}), closed: make(chan struct{}),
	}
	if config.OpenStdin {
		p.input = make(chan []byte)
		p.inputDone = make(chan struct{})
	}
	if size := config.HostConfig.ConsoleSize; len(size) == 2 {
		p.size = unix.Winsize{Row: size[0], Col: size[1]}
	}
	return p, nil
}

func (p *dockerPID1) spec(raw []byte) ([]byte, error) {
	var spec map[string]json.RawMessage
	if err := json.Unmarshal(raw, &spec); err != nil {
		return nil, err
	}
	var process map[string]json.RawMessage
	if err := json.Unmarshal(spec["process"], &process); err != nil || process == nil {
		return nil, errors.New("OCI process is missing")
	}
	var argv []string
	if err := json.Unmarshal(process["args"], &argv); err != nil || len(argv) == 0 || argv[0] == "" {
		return nil, errors.New("OCI process has no command")
	}
	mode := "output"
	if p.openStdin {
		mode = "pipes"
	}
	if p.tty {
		mode = "tty"
		var env []string
		if rawEnv := process["env"]; rawEnv != nil {
			if err := json.Unmarshal(rawEnv, &env); err != nil {
				return nil, err
			}
		}
		hasTerm := false
		for _, entry := range env {
			if strings.HasPrefix(entry, "TERM=") {
				hasTerm = true
				break
			}
		}
		if !hasTerm {
			env = append(env, "TERM=xterm")
			process["env"], _ = json.Marshal(env)
		}
	}
	launcher, err := os.Executable()
	if err != nil {
		return nil, err
	}
	var mounts []json.RawMessage
	if err := json.Unmarshal(spec["mounts"], &mounts); err != nil {
		return nil, err
	}
	target := "/dev/.micropod-" + filepath.Base(p.dir)
	devTmpfs := false
	for _, m := range mounts {
		var mount struct{ Destination, Type string }
		if err := json.Unmarshal(m, &mount); err != nil {
			return nil, err
		}
		dest := filepath.Clean(mount.Destination)
		if dest == "/dev" {
			devTmpfs = mount.Type == "tmpfs"
		}
		if dest == target || strings.HasPrefix(dest, target+"/") {
			return nil, errors.New("OCI mount collides with the console")
		}
	}
	if !devTmpfs {
		return nil, errors.New("interactive console requires a private /dev tmpfs")
	}
	// A target inside the runtime's /dev tmpfs keeps the image and writable
	// layer clean, including for readonly root filesystems and repeated starts.
	process["args"], _ = json.Marshal(append([]string{target + "/launch", dockerPID1Command, target + "/io", mode}, argv...))
	spec["process"], _ = json.Marshal(process)
	for _, bind := range []dockerOCITmpfsMount{
		{Destination: target, Type: "bind", Source: p.dir, Options: []string{"bind", "ro", "nosuid", "nodev"}},
		{Destination: target + "/launch", Type: "bind", Source: launcher, Options: []string{"bind", "ro", "nosuid", "nodev"}},
	} {
		data, _ := json.Marshal(bind)
		mounts = append(mounts, data)
	}
	spec["mounts"], _ = json.Marshal(mounts)
	return json.Marshal(spec)
}

func unixPeerPID(conn *net.UnixConn) (int32, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var cred *unix.Ucred
	var peerErr error
	err = raw.Control(func(fd uintptr) {
		cred, peerErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	})
	if err = errors.Join(err, peerErr); err != nil {
		return 0, err
	}
	return cred.Pid, nil
}

func (p *dockerPID1) accept(ctx context.Context, n node, id string, write outputSink, abort context.CancelFunc) error {
	if n.execTasks == nil {
		return errors.New("containerd task service is unavailable")
	}
	ctx, cancel := context.WithTimeout(dockerExecContext(ctx), dockerPID1Startup)
	defer cancel()
	reply, err := n.execTasks.Get(ctx, &tasks.GetRequest{ContainerID: id})
	if err != nil {
		return fmt.Errorf("get console task: %w", err)
	}
	task := reply.GetProcess()
	// Tasks.Get puts the init ID in Process.ID. Its ContainerID field is
	// unset in containerd's service response, even for the init task.
	if task.GetID() != id || task.GetPid() == 0 || task.GetStatus() != taskapi.Status_RUNNING {
		return errors.New("console task identity mismatch")
	}
	deadline, _ := ctx.Deadline()
	if err := p.listener.SetDeadline(deadline); err != nil {
		return err
	}
	for {
		conn, err := p.listener.AcceptUnix()
		if err != nil {
			return fmt.Errorf("accept PID 1 console: %w", err)
		}
		pid, err := unixPeerPID(conn)
		if err != nil || pid != int32(task.GetPid()) {
			conn.Close()
			continue
		}
		defer conn.Close()
		// Remove the socket before the launcher executes the image's command.
		if err := p.listener.Close(); err != nil {
			return err
		}
		if err := conn.SetDeadline(deadline); err != nil {
			return err
		}
		count := 2
		if p.tty {
			count = 1
		} else if p.openStdin {
			count = 3
		}
		p.files, err = receiveConsoleFiles(conn, count)
		if err != nil {
			return err
		}
		if p.tty {
			p.mu.Lock()
			p.terminal = p.files[0]
			if p.size.Row != 0 && p.size.Col != 0 {
				err = p.setSize()
			}
			p.mu.Unlock()
			if err != nil {
				return err
			}
		}
		p.startCopies(write, abort)
		close(p.ready)
		_, err = conn.Write([]byte{1})
		return err
	}
}

func receiveConsoleFiles(conn *net.UnixConn, count int) (_ []*os.File, err error) {
	var ready [1]byte
	rights := make([]byte, unix.CmsgSpace(3*4))
	n, m, flags, _, err := conn.ReadMsgUnix(ready[:], rights)
	if err != nil {
		return nil, err
	}
	msgs, err := unix.ParseSocketControlMessage(rights[:m])
	if err != nil {
		return nil, err
	}
	var fds []int
	defer func() {
		if err != nil {
			for _, fd := range fds {
				_ = unix.Close(fd)
			}
		}
	}()
	for _, msg := range msgs {
		values, err := unix.ParseUnixRights(&msg)
		if err != nil {
			return nil, err
		}
		fds = append(fds, values...)
	}
	if n != 1 || ready[0] != 1 || len(fds) != count || flags&(unix.MSG_TRUNC|unix.MSG_CTRUNC) != 0 {
		return nil, errors.New("invalid console file descriptors")
	}
	for _, fd := range fds {
		if err := unix.SetNonblock(fd, true); err != nil {
			return nil, err
		}
	}
	files := make([]*os.File, 0, count)
	for _, fd := range fds {
		files = append(files, os.NewFile(uintptr(fd), "container stdio"))
	}
	return files, nil
}

func (p *dockerPID1) startCopies(write outputSink, abort context.CancelFunc) {
	var output sync.WaitGroup
	p.output = newDockerOutputDrain()
	copyOutput := func(f *os.File, stream string) {
		defer output.Done()
		buffer := make([]byte, 32<<10)
		for {
			n, err := f.Read(buffer)
			if n != 0 {
				if writeErr := write(stream, buffer[:n]); writeErr != nil {
					p.recordOutputError(writeErr, abort)
					return
				}
				p.output.advanced()
			}
			if err != nil {
				if !errors.Is(err, io.EOF) && !errors.Is(err, os.ErrClosed) &&
					!(p.tty && errors.Is(err, unix.EIO)) {
					p.recordOutputError(err, abort)
				}
				return
			}
		}
	}
	output.Add(1)
	go copyOutput(p.files[0], "stdout")
	if !p.tty {
		output.Add(1)
		go copyOutput(p.files[1], "stderr")
	}
	go func() {
		output.Wait()
		close(p.output.done)
	}()
	if p.openStdin {
		input := p.files[0]
		if !p.tty {
			input = p.files[2]
		}
		go p.runInput(input)
	}
}

func (p *dockerPID1) recordOutputError(err error, abort context.CancelFunc) {
	p.mu.Lock()
	p.err = errors.Join(p.err, err)
	p.mu.Unlock()
	abort()
}

func (p *dockerPID1) runInput(f *os.File) {
	defer close(p.inputDone)
	for {
		select {
		case <-p.closed:
			return
		case data := <-p.input:
			if data == nil {
				_ = f.Close()
				return
			}
			if _, err := f.Write(data); err != nil {
				return
			}
		}
	}
}

func (p *dockerPID1) sendInput(ctx context.Context, data []byte) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-p.closed:
		return io.ErrClosedPipe
	case <-p.inputDone:
		return io.ErrClosedPipe
	case p.input <- data:
		return nil
	}
}

func (p *dockerPID1) setSize() error {
	fd, err := p.terminal.SyscallConn()
	if err != nil {
		return err
	}
	var resizeErr error
	err = fd.Control(func(raw uintptr) {
		resizeErr = unix.IoctlSetWinsize(int(raw), unix.TIOCSWINSZ, &p.size)
	})
	return errors.Join(err, resizeErr)
}

func (p *dockerPID1) resize(size unix.Winsize) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	select {
	case <-p.closed:
		return io.ErrClosedPipe
	default:
	}
	p.size = size
	if p.terminal == nil {
		return nil
	}
	return p.setSize()
}

// The caller retires this generation after CRI stops or fails the task. Closing
// the files also releases a blocked console writer or a descendant's open tty.
func (p *dockerPID1) finish(ctx context.Context) error {
	close(p.closed)
	_ = p.listener.Close()
	if p.output.done != nil && ctx.Err() == nil {
		if err := p.output.waitForEOF(dockerOutputDrainIdle, ctx.Done()); err != nil && !errors.Is(err, io.ErrClosedPipe) {
			log.Printf("drain Docker PID 1 console %s: %v", filepath.Base(p.dir), err)
		}
	}
	for _, f := range p.files {
		_ = f.Close()
	}
	if p.output.done != nil {
		<-p.output.done
		if p.openStdin {
			<-p.inputDone
		}
	}
	return errors.Join(p.err, os.RemoveAll(p.dir))
}
