package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// The sink consumes data synchronously, before the next read reuses its buffer.
type outputSink func(stream string, data []byte) error

const dockerOutputDrainIdle = 30 * time.Second

type dockerOutputDrain struct {
	done     chan struct{}
	progress chan struct{}
}

func newDockerOutputDrain() dockerOutputDrain {
	return dockerOutputDrain{done: make(chan struct{}), progress: make(chan struct{}, 1)}
}

func (d dockerOutputDrain) advanced() {
	select {
	case d.progress <- struct{}{}:
	default:
	}
}

// A process can exit while bytes remain in its stdio buffers. Bound idle
// drains and continue while the reader makes progress.
func (d dockerOutputDrain) waitForEOF(idle time.Duration, cancelled <-chan struct{}) error {
	timer := time.NewTimer(idle)
	defer timer.Stop()
	for {
		select {
		case <-d.done:
			return nil
		case <-cancelled:
			return io.ErrClosedPipe
		case <-d.progress:
			timer.Reset(idle)
		case <-timer.C:
			select {
			case <-d.done:
				return nil
			case <-cancelled:
				return io.ErrClosedPipe
			case <-d.progress:
				timer.Reset(idle)
			default:
				return errors.New("inactive after exit")
			}
		}
	}
}

func jsonOutput(out *json.Encoder) outputSink {
	return func(stream string, data []byte) error {
		return out.Encode(struct {
			Type string `json:"type"`
			Data []byte `json:"data"`
		}{stream, data})
	}
}

// A regular file can reach EOF between writes. Keep the partial physical record
// until its newline arrives. CRI P records preserve unterminated process output.
type criOutput struct {
	reader     *bufio.Reader
	partial    []byte
	bytes      int64
	diskBacked bool
}

func (s *criOutput) drain(write outputSink) error {
	for {
		line, err := s.reader.ReadSlice('\n')
		if s.diskBacked {
			// containerd's CRI splits long lines into 16 KiB records. Retain
			// a generous per-record bound for bad or incomplete input.
			if len(s.partial)+len(line) > 64<<10 {
				return errors.New("CRI log record exceeds 64 KiB")
			}
		} else {
			s.bytes += int64(len(line))
			if s.bytes >= (8<<20)-4096 {
				return errors.New("job log exceeded the 8 MiB limit")
			}
		}
		if err != nil || len(s.partial) != 0 {
			s.partial = append(s.partial, line...)
			line = s.partial
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		_, rest, _ := bytes.Cut(line, []byte(" "))
		channel, rest, _ := bytes.Cut(rest, []byte(" "))
		tag, body, ok := bytes.Cut(rest, []byte(" "))
		if !ok {
			return errors.New("invalid CRI log record")
		}
		var stream string
		switch string(channel) {
		case "stdout":
			stream = "stdout"
		case "stderr":
			stream = "stderr"
		default:
			return errors.New("invalid CRI log stream")
		}
		switch string(tag) {
		case "F":
		case "P":
			body = body[:len(body)-1] // Skip the physical newline on partial records.
		default:
			return errors.New("invalid CRI log fragment")
		}
		if err := write(stream, body[:len(body):len(body)]); err != nil {
			return err
		}
		s.partial = s.partial[:0]
	}
}

type taskWaitClient interface {
	Wait(context.Context, *tasks.WaitRequest, ...grpc.CallOption) (*tasks.WaitResponse, error)
}

type criLogSource struct {
	path       string
	diskBacked bool
}

func (n node) follow(ctx context.Context, id string, source criLogSource, write outputSink, watchTask bool) (int32, string, error) {
	var file *os.File
	output := criOutput{diskBacked: source.diskBacked}
	defer func() {
		if file != nil {
			file.Close()
		}
	}()
	drain := func() error {
		if file == nil {
			f, err := os.Open(source.path)
			if errors.Is(err, os.ErrNotExist) {
				return nil
			}
			if err != nil {
				return err
			}
			file = f
			output.reader = bufio.NewReaderSize(f, 32<<10)
		}
		return output.drain(write)
	}
	const firstPoll = 5 * time.Millisecond
	delay := firstPoll
	var timer *time.Timer
	var poll <-chan time.Time
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	var logReady <-chan struct{}
	if write != nil && watchTask && n.watchLog != nil {
		var unwatch func()
		logReady, unwatch = n.watchLog(source.path)
		if unwatch != nil {
			defer unwatch()
		}
	}
	var taskDone <-chan error
	if watchTask && n.tasks != nil {
		waitCtx, cancel := context.WithCancel(ctx)
		defer cancel()
		waitCtx = metadata.AppendToOutgoingContext(waitCtx, "containerd-namespace", dockerRuntimeNamespace)
		done := make(chan error, 1)
		taskDone = done
		go func() {
			_, err := n.tasks.Wait(waitCtx, &tasks.WaitRequest{ContainerID: id})
			done <- err
		}()
	}
	checkStatus, readLog := true, true
	for {
		var st *cri.ContainerStatus
		if checkStatus {
			r, err := n.runtime.ContainerStatus(ctx, &cri.ContainerStatusRequest{ContainerId: id})
			if err != nil {
				return 0, "", err
			}
			st = r.GetStatus()
		}
		exited := st != nil && st.State == cri.ContainerState_CONTAINER_EXITED
		if write != nil && (readLog || exited) {
			if err := drain(); err != nil {
				return 0, "", err
			}
		}
		if checkStatus && st == nil {
			return 0, "", errors.New("missing runtime status")
		}
		if exited {
			if st.FinishedAt == 0 {
				return 0, "", errors.New("runtime has no recorded exit")
			}
			if len(output.partial) != 0 {
				return 0, "", errors.New("incomplete final CRI log record")
			}
			return st.ExitCode, st.Reason, nil
		}
		// Use a timer only for a missing event source. A busy log must not
		// postpone polling when the task has exited but CRI is still committing.
		if poll == nil && (taskDone == nil || write != nil && logReady == nil) {
			if timer == nil {
				timer = time.NewTimer(delay)
			} else {
				timer.Reset(delay)
			}
			poll = timer.C
		}
		checkStatus, readLog = false, false
		select {
		case <-ctx.Done():
			return 0, "", ctx.Err()
		case err := <-taskDone:
			if poll != nil {
				timer.Stop()
				poll = nil
			}
			if ctx.Err() != nil {
				return 0, "", ctx.Err()
			}
			// CRI can delete a fast-exiting task before this waiter attaches.
			// Even a successful wait can precede CRI's status and log commit.
			// Recheck immediately, then use bounded polling until CRI records exit.
			if err != nil && status.Code(err) != codes.NotFound {
				fmt.Fprintf(os.Stderr, "CRI task wait failed for %s: %v; checking CRI status\n", id, err)
			}
			taskDone = nil
			checkStatus, readLog = true, true
			delay = firstPoll
		case _, ok := <-logReady:
			if !ok {
				logReady = nil
			}
			readLog = true
		case <-poll:
			poll = nil
			checkStatus, readLog = taskDone == nil, logReady == nil
			delay = min(delay*2, 200*time.Millisecond)
		}
	}
}
