package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	containers "github.com/containerd/containerd/api/services/containers/v1"
	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/anypb"
)

const (
	dockerExecWriteTimeout = 30 * time.Second
	dockerExecSpecType     = "types.containerd.io/opencontainers/runtime-spec/1/Spec"
	dockerExecProcessType  = "types.containerd.io/opencontainers/runtime-spec/1/Process"
)

type dockerExecStream struct {
	conn     net.Conn
	input    io.Reader
	tty      bool
	mu       sync.Mutex
	lost     chan struct{}
	writeErr error // published before lost is closed
}

func (s *dockerExecStream) write(channel byte, p []byte) {
	if len(p) == 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	select {
	case <-s.lost:
		return
	default:
	}
	_ = s.conn.SetWriteDeadline(time.Now().Add(dockerExecWriteTimeout))
	var err error
	if s.tty {
		_, err = s.conn.Write(p)
	} else {
		var header [8]byte
		header[0] = channel
		binary.BigEndian.PutUint32(header[4:], uint32(len(p)))
		buf := net.Buffers{header[:], p}
		_, err = buf.WriteTo(s.conn)
	}
	if err != nil {
		s.writeErr = err
		close(s.lost)
	}
}

type dockerExecOutput struct {
	stream  *dockerExecStream
	channel byte
	drain   dockerOutputDrain
}

func (o dockerExecOutput) Write(p []byte) (int, error) {
	if o.stream != nil {
		o.stream.write(o.channel, p)
	}
	o.drain.advanced()
	// Continue draining the shim's FIFO after a client write fails so that
	// the process can exit and containerd can release the I/O.
	return len(p), nil
}

type dockerExecPipes struct {
	dir                   string
	stdinPath             string
	stdin, stdout, stderr *os.File
}

func newDockerExecPipes(root string, stdin, tty bool) (*dockerExecPipes, error) {
	dir, err := os.MkdirTemp(root, "io-")
	if err != nil {
		return nil, err
	}
	p := &dockerExecPipes{dir: dir}
	if stdin {
		p.stdinPath = filepath.Join(dir, "stdin")
		err = unix.Mkfifo(p.stdinPath, 0600)
	}
	if err == nil {
		p.stdout, err = openDockerExecOutput(filepath.Join(dir, "stdout"))
	}
	if err == nil && !tty {
		p.stderr, err = openDockerExecOutput(filepath.Join(dir, "stderr"))
	}
	if err != nil {
		p.close()
		return nil, err
	}
	return p, nil
}

func openDockerExecOutput(path string) (*os.File, error) {
	if err := unix.Mkfifo(path, 0600); err != nil {
		return nil, err
	}
	// The shim opens its writer as part of Start. Keep the reader open
	// before Start and begin copying after the writer has been connected.
	return os.OpenFile(path, os.O_RDONLY|unix.O_NONBLOCK, 0)
}

func (p *dockerExecPipes) close() {
	for _, f := range []*os.File{p.stdin, p.stdout, p.stderr} {
		if f != nil {
			_ = f.Close()
		}
	}
	if p.dir != "" {
		if err := os.RemoveAll(p.dir); err != nil {
			log.Printf("remove Docker exec FIFOs: %v", err)
		}
	}
}

type nativeDockerExec struct {
	tasks      tasks.TasksClient
	ctx        context.Context
	id, target string
	pipes      *dockerExecPipes
	exits      chan dockerExecExit
	cancelWait context.CancelFunc
}

type dockerExecExit struct {
	code int32
	err  error
}

func (s *dockerEngine) startNativeExec(ctx context.Context, id string, e *dockerExec, opts dockerExecStart, stream *dockerExecStream) error {
	p, pid, err := s.prepareNativeExec(ctx, id, e, opts, stream != nil)
	if err != nil {
		s.recordExecStartFailure(id, e, stream, err)
		return err
	}
	s.mu.Lock()
	e.pid = pid
	if e.ready != nil {
		close(e.ready)
		e.ready = nil
	}
	s.mu.Unlock()

	if opts.Detach {
		go s.relayNativeExec(p, e, nil)
	} else {
		s.relayNativeExec(p, e, stream)
	}
	return nil
}

func (s *dockerEngine) prepareNativeExec(ctx context.Context, id string, e *dockerExec, opts dockerExecStart, attached bool) (*nativeDockerExec, uint32, error) {
	if s.node.execTasks == nil || s.node.containers == nil {
		return nil, 0, fail(503, "containerd exec is unavailable")
	}
	if err := s.noteExecStart(id, e); err != nil {
		return nil, 0, err
	}
	ctx, cancel := context.WithTimeout(dockerExecContext(ctx), 30*time.Second)
	defer cancel()
	p, pid, err := s.startNativeTaskExec(ctx, id, e, opts.ConsoleSize, attached)
	if err != nil && p != nil {
		p.cancelWait()
		p.delete(true)
		p.pipes.close()
		return nil, 0, err
	}
	return p, pid, err
}

// On errors after the Exec acknowledgement, return the owned task so the
// caller can reap it. Until that acknowledgement the task does not belong to us.
func (s *dockerEngine) startNativeTaskExec(ctx context.Context, id string, e *dockerExec, size []uint16, attached bool) (*nativeDockerExec, uint32, error) {
	if s.node.execTasks == nil || s.node.containers == nil {
		return nil, 0, fail(503, "containerd exec is unavailable")
	}
	spec, err := s.dockerExecProcessSpec(ctx, e, size)
	if err != nil {
		return nil, 0, err
	}

	pipes := &dockerExecPipes{}
	if attached || e.tty {
		pipes, err = newDockerExecPipes(s.execPipeDir, attached && e.stdin, e.tty)
		if err != nil {
			return nil, 0, fmt.Errorf("prepare exec I/O: %w", err)
		}
	}
	p := &nativeDockerExec{
		tasks: s.node.execTasks, ctx: context.WithoutCancel(ctx), id: id, target: e.target, pipes: pipes,
		exits: make(chan dockerExecExit, 1),
	}
	req := &tasks.ExecProcessRequest{
		ContainerID: e.target, ExecID: id, Terminal: e.tty, Spec: spec, Stdin: pipes.stdinPath,
	}
	if pipes.stdout != nil {
		req.Stdout = pipes.stdout.Name()
	}
	if pipes.stderr != nil {
		req.Stderr = pipes.stderr.Name()
	}
	if _, err := p.tasks.Exec(ctx, req); err != nil {
		pipes.close()
		return nil, 0, fmt.Errorf("create containerd exec: %w", err)
	}
	p.startWait()
	res, err := p.tasks.Start(ctx, &tasks.StartRequest{ContainerID: e.target, ExecID: id})
	if err != nil {
		return p, 0, e.workdirStartError(fmt.Errorf("start containerd exec: %w", err))
	}
	if res.GetPid() == 0 {
		return p, 0, errors.New("containerd did not report an exec PID")
	}
	if pipes.stdinPath != "" {
		pipes.stdin, err = p.openInput(ctx)
		if err != nil {
			return p, 0, fmt.Errorf("open exec stdin: %w", err)
		}
	}
	return p, res.GetPid(), nil
}

func (p *nativeDockerExec) openInput(ctx context.Context) (*os.File, error) {
	retry := time.NewTicker(10 * time.Millisecond)
	defer retry.Stop()
	for {
		f, err := os.OpenFile(p.pipes.stdinPath, os.O_WRONLY|unix.O_NONBLOCK, 0)
		if !errors.Is(err, unix.ENXIO) {
			return f, err
		}
		// The shim opens the read end asynchronously. If the process has
		// already exited, hand that receipt back to the relay and drain output.
		select {
		case exit := <-p.exits:
			p.exits <- exit
			return nil, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-retry.C:
		}
	}
}

func (s *dockerEngine) dockerExecProcessSpec(ctx context.Context, e *dockerExec, size []uint16) (*anypb.Any, error) {
	if err := e.checkWorkingDir(); err != nil {
		return nil, err
	}
	res, err := s.node.containers.Get(ctx, &containers.GetContainerRequest{ID: e.target})
	if err != nil {
		return nil, fmt.Errorf("read containerd exec spec: %w", err)
	}
	record := res.GetContainer()
	if record.GetID() != e.target || record.GetSpec().GetTypeUrl() != dockerExecSpecType {
		return nil, errors.New("invalid OCI spec for exec target")
	}
	var spec struct {
		Process map[string]json.RawMessage
	}
	if err := json.Unmarshal(record.Spec.Value, &spec); err != nil || spec.Process == nil {
		return nil, errors.New("invalid OCI process spec for exec target")
	}
	// Retain the container's user, cwd, capabilities, security settings, and
	// any process fields added by the runtime spec.
	args, err := json.Marshal(e.cmd)
	if err != nil {
		return nil, err
	}
	spec.Process["args"] = args
	delete(spec.Process, "commandLine")
	delete(spec.Process, "consoleSize")
	spec.Process["terminal"] = json.RawMessage("false")
	if e.tty {
		spec.Process["terminal"] = json.RawMessage("true")
		if size == nil {
			size = e.size
		}
		if len(size) == 2 {
			spec.Process["consoleSize"] = fmt.Appendf(nil, `{"height":%d,"width":%d}`, size[0], size[1])
		}
	}
	if err := e.applyProcessOverrides(spec.Process); err != nil {
		return nil, err
	}
	raw, err := json.Marshal(spec.Process)
	if err != nil {
		return nil, err
	}
	return &anypb.Any{TypeUrl: dockerExecProcessType, Value: raw}, nil
}

func (p *nativeDockerExec) startWait() {
	ctx, cancel := context.WithCancel(p.ctx)
	p.cancelWait = cancel
	go func() {
		res, err := p.tasks.Wait(ctx, &tasks.WaitRequest{ContainerID: p.target, ExecID: p.id})
		if err == nil && res == nil {
			err = errors.New("containerd returned no exec result")
		}
		p.exits <- dockerExecExit{code: int32(res.GetExitStatus()), err: err}
	}()
}

func (s *dockerEngine) relayNativeExec(p *nativeDockerExec, e *dockerExec, stream *dockerExecStream) {
	defer p.pipes.close()
	defer p.cancelWait()

	output := p.copyOutput(e, stream)
	var inputDone chan struct{}
	if p.pipes.stdin != nil {
		inputDone = make(chan struct{})
		go func() {
			defer close(inputDone)
			_, _ = io.Copy(p.pipes.stdin, stream.input)
			if !e.tty {
				p.closeStdin()
			}
		}()
	}

	exit := p.wait(stream)
	s.finishExec(p.id, e, exit.code, exit.err, exit.err == nil)
	var lost <-chan struct{}
	if stream != nil {
		lost = stream.lost
	}
	if exit.err != nil {
		p.closeOutput(output.done, stream)
	} else if err := output.waitForEOF(dockerOutputDrainIdle, lost); err != nil {
		if !errors.Is(err, io.ErrClosedPipe) {
			log.Printf("drain Docker exec %s output: %v", p.id, err)
		}
		p.closeOutput(output.done, stream)
	}
	if inputDone != nil {
		_ = stream.conn.Close()
		_ = p.pipes.stdin.Close()
		<-inputDone
	}
	if p.pipes.stdinPath != "" && (e.tty || inputDone == nil) {
		// EOF on the shim's input FIFO closes the whole PTY. Release its
		// writer after the console output has been drained.
		p.closeStdin()
	}
	p.delete(exit.err != nil)
}

func (p *nativeDockerExec) closeStdin() {
	if p.pipes.stdin != nil {
		_ = p.pipes.stdin.Close()
	}
	ctx, cancel := context.WithTimeout(p.ctx, 5*time.Second)
	defer cancel()
	_, err := p.tasks.CloseIO(ctx, &tasks.CloseIORequest{ContainerID: p.target, ExecID: p.id, Stdin: true})
	if err != nil && status.Code(err) != codes.NotFound {
		log.Printf("close Docker exec %s stdin: %v", p.id, err)
	}
}

func (p *nativeDockerExec) copyOutput(e *dockerExec, stream *dockerExecStream) dockerOutputDrain {
	pump := newDockerOutputDrain()
	var wg sync.WaitGroup
	copyPipe := func(f *os.File, channel byte, attached bool) {
		if f == nil {
			return
		}
		dst := dockerExecOutput{channel: channel, drain: pump}
		if attached {
			dst.stream = stream
		}
		wg.Go(func() {
			_, _ = io.Copy(dst, f)
		})
	}
	copyPipe(p.pipes.stdout, 1, e.stdout || e.tty && e.stderr)
	copyPipe(p.pipes.stderr, 2, e.stderr)
	go func() {
		wg.Wait()
		close(pump.done)
	}()
	return pump
}

func (p *nativeDockerExec) closeOutput(done <-chan struct{}, stream *dockerExecStream) {
	if stream != nil {
		_ = stream.conn.Close()
	}
	if p.pipes.stdout != nil {
		_ = p.pipes.stdout.Close()
	}
	if p.pipes.stderr != nil {
		_ = p.pipes.stderr.Close()
	}
	<-done
}

func (p *nativeDockerExec) wait(stream *dockerExecStream) dockerExecExit {
	if stream == nil {
		return <-p.exits
	}
	var poll <-chan time.Time
	peer, _ := stream.conn.(*net.UnixConn)
	if peer != nil {
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		poll = ticker.C
	}
	var disconnect error
waitForExit:
	for {
		select {
		case exit := <-p.exits:
			return exit
		case <-stream.lost:
			disconnect = stream.writeErr
			if disconnect == nil {
				disconnect = io.ErrClosedPipe
			}
			break waitForExit
		case <-poll:
			if disconnect = peerDisconnectError(peer); disconnect != nil {
				break waitForExit
			}
		}
	}

	ctx, cancel := context.WithTimeout(p.ctx, 5*time.Second)
	defer cancel()
	if p.kill(ctx) {
		log.Printf("sent SIGKILL to Docker exec %s in %s after client disconnect: %v", p.id, p.target, disconnect)
	}
	select {
	case exit := <-p.exits:
		return exit
	case <-ctx.Done():
		return dockerExecExit{err: fmt.Errorf("wait for disconnected exec: %w", ctx.Err())}
	}
}

func (p *nativeDockerExec) kill(ctx context.Context) bool {
	_, err := p.tasks.Kill(ctx, &tasks.KillRequest{ContainerID: p.target, ExecID: p.id, Signal: uint32(unix.SIGKILL)})
	if err != nil && status.Code(err) != codes.NotFound && status.Code(err) != codes.FailedPrecondition {
		log.Printf("kill Docker exec %s: %v", p.id, err)
	}
	return err == nil
}

func (p *nativeDockerExec) delete(force bool) {
	ctx, cancel := context.WithTimeout(p.ctx, 15*time.Second)
	defer cancel()
	if force && p.kill(ctx) {
		// DeleteProcess rejects a running exec. Allow the shim's reaper to
		// observe the signal before trying to delete the owned process.
		wait, done := context.WithTimeout(ctx, 5*time.Second)
		_, _ = p.tasks.Wait(wait, &tasks.WaitRequest{ContainerID: p.target, ExecID: p.id})
		done()
	}
	if force && p.pipes.stdinPath != "" {
		p.closeStdin()
	}
	_, err := p.tasks.DeleteProcess(ctx, &tasks.DeleteProcessRequest{ContainerID: p.target, ExecID: p.id})
	if err != nil && status.Code(err) != codes.NotFound {
		log.Printf("delete Docker exec %s: %v", p.id, err)
	}
}
