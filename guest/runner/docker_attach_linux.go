package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/moby/term"
	"golang.org/x/sys/unix"
)

const dockerMuxStream = "application/vnd.docker.multiplexed-stream"
const dockerRawStream = "application/vnd.docker.raw-stream"

type dockerLogStreamWriter struct {
	io.Writer
	deadline func(time.Time) error
}

func (w dockerLogStreamWriter) Write(data []byte) (int, error) {
	// Give each successful chunk a fresh write window. A large disk-backed
	// backlog can take much longer to transmit to a progressing reader.
	_ = w.deadline(time.Now().Add(dockerExecWriteTimeout))
	return w.Writer.Write(data)
}

func sendDockerLogError(w io.Writer, tty bool, problem string) error {
	message := []byte("\nmicropod: container output incomplete: " + problem + "\n")
	if !tty {
		// A stderr message stays visible without a multiplexed system error
		// overriding the process's exit status in a foreground Docker CLI.
		var header [8]byte
		header[0] = 2
		binary.BigEndian.PutUint32(header[4:], uint32(len(message)))
		message = append(header[:], message...)
	}
	_, err := w.Write(message)
	return err
}

func (s *dockerEngine) stream(w http.ResponseWriter, r *http.Request, c *dockerContainer, attach bool) error {
	q := r.URL.Query()
	streaming := attach && truth(q.Get("stream"))
	follow := streaming || !attach && truth(q.Get("follow"))
	history := !attach || truth(q.Get("logs"))
	stdout, stderr := truth(q.Get("stdout")), truth(q.Get("stderr"))
	if !attach && ((q.Get("tail") != "" && q.Get("tail") != "all") || q.Get("since") != "" || q.Get("until") != "" || truth(q.Get("timestamps"))) {
		return fail(400, "time and tail log selection are unavailable")
	}
	keys := []byte{16, 17}
	if raw := q.Get("detachKeys"); attach && raw != "" {
		var err error
		keys, err = term.ToBytes(raw)
		if err != nil {
			return fail(400, "invalid detach keys")
		}
	}
	f, err := os.Open(c.logPath())
	if errors.Is(err, os.ErrNotExist) {
		return fail(404, "container log no longer exists")
	}
	if err != nil {
		return err
	}
	defer f.Close()
	s.mu.Lock()
	if c.removed {
		s.mu.Unlock()
		return fail(404, "container removed")
	}
	prestart := c.Phase == "created" || c.Phase == "exited"
	var generation *dockerExitReceipt
	if follow && (c.busy() || streaming && prestart) {
		generation = c.pendingExitReceipt()
	}
	if streaming && prestart {
		if c.foregroundReaders == 0 {
			c.readersDone = make(chan struct{})
		}
		c.foregroundReaders++
		defer func() {
			s.mu.Lock()
			c.foregroundReaders--
			if c.foregroundReaders == 0 {
				close(c.readersDone)
				c.readersDone = nil
			}
			s.mu.Unlock()
		}()
	}
	var offset int64
	if !history {
		offset = c.outputBytes
	}
	tty, openStdin, stdinOnce := c.Config.Tty, c.Config.OpenStdin, c.Config.StdinOnce
	s.mu.Unlock()

	contentType := dockerMuxStream
	if tty {
		contentType = dockerRawStream
	}
	controller := http.NewResponseController(w)
	writer, flush := io.Writer(w), controller.Flush
	deadline := controller.SetWriteDeadline
	var conn net.Conn
	var peer *net.UnixConn
	var pulse <-chan time.Time
	var detached <-chan struct{}
	cancelled := r.Context().Done()
	if attach {
		var rw *bufio.ReadWriter
		conn, rw, err = http.NewResponseController(w).Hijack()
		if err != nil {
			return err
		}
		deadline = conn.SetWriteDeadline
		ctx, cancel := context.WithCancel(context.Background())
		var inputDone chan struct{}
		defer func() {
			cancel()
			_ = conn.Close()
			if inputDone != nil {
				<-inputDone
			}
		}()
		_ = conn.SetReadDeadline(time.Time{})
		_ = conn.SetWriteDeadline(time.Now().Add(dockerExecWriteTimeout))
		cancelled = nil
		peer, _ = conn.(*net.UnixConn)
		if peer != nil {
			timer := time.NewTicker(2 * time.Second)
			defer timer.Stop()
			pulse = timer.C
		}
		header := "HTTP/1.1 200 OK\r\n"
		if strings.EqualFold(r.Header.Get("Upgrade"), "tcp") {
			header = "HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n"
		}
		if _, err := fmt.Fprintf(rw, "%sContent-Type: %s\r\n\r\n", header, contentType); err != nil || rw.Flush() != nil {
			return nil
		}
		s.mu.Lock()
		s.containerEvent(c, "attach", nil)
		s.mu.Unlock()
		if streaming && generation != nil && openStdin && truth(q.Get("stdin")) {
			clientDone := make(chan struct{})
			inputDone = make(chan struct{})
			var input io.Reader = rw.Reader
			if tty {
				input = term.NewEscapeProxy(input, keys)
			}
			go func() {
				defer close(inputDone)
				if s.copyContainerInput(ctx, c, generation, input, stdinOnce && !tty) {
					close(clientDone)
				}
			}()
			detached = clientDone
		}
		writer, flush = rw, rw.Flush
	} else {
		defer deadline(time.Time{})
		w.Header().Set("Content-Type", contentType)
		w.WriteHeader(http.StatusOK)
		if err := flush(); err != nil {
			return nil
		}
	}

	writer = dockerLogStreamWriter{writer, deadline}
	read := bufio.NewReaderSize(nil, 32<<10)
	copyOutput := copyFrames
	if tty {
		copyOutput = copyRawConsoleFrames
	}
	reportedLogError := false
	for {
		s.mu.Lock()
		ch := c.changed
		watermark := c.logWatermark()
		done := !follow || c.removed || !c.busy()
		if generation != nil {
			select {
			case <-generation.done:
				watermark, done = generation.result.log, true
			default:
				done = false
			}
		}
		s.mu.Unlock()
		end := watermark.end
		read.Reset(io.NewSectionReader(f, offset, end-offset))
		offset = end
		if err := copyOutput(read, writer, stdout, stderr); err != nil {
			return nil
		}
		failure := watermark.generationError
		if history {
			failure = watermark.historyError
		}
		if !reportedLogError && failure != "" {
			if err := sendDockerLogError(writer, tty, failure); err != nil {
				return nil
			}
			reportedLogError = true
		}
		_ = deadline(time.Now().Add(dockerExecWriteTimeout))
		if err := flush(); err != nil || done {
			return nil
		}
		select {
		case <-ch:
		case <-cancelled:
			return nil
		case <-detached:
			s.mu.Lock()
			if !c.removed && c.Exits == generation.epoch {
				s.containerEvent(c, "detach", nil)
			}
			s.mu.Unlock()
			return nil
		case <-pulse:
			if disconnected(peer) {
				return nil
			}
		}
	}
}

func (s *dockerEngine) copyContainerInput(ctx context.Context, c *dockerContainer, generation *dockerExitReceipt, input io.Reader, stdinOnce bool) bool {
	for {
		s.mu.Lock()
		if c.removed || c.Exits != generation.epoch || c.Phase == "dead" {
			s.mu.Unlock()
			return false
		}
		console, changed := c.console, c.changed
		s.mu.Unlock()
		if console != nil {
			return copyConsoleInput(ctx, console, input, stdinOnce)
		}
		select {
		case <-ctx.Done():
			return false
		case <-generation.done:
			return false
		case <-changed:
		}
	}
}

func copyConsoleInput(ctx context.Context, console *dockerPID1, input io.Reader, stdinOnce bool) bool {
	select {
	case <-ctx.Done():
		return false
	case <-console.closed:
		return false
	case <-console.ready:
	}
	buf := make([]byte, 32<<10)
	for {
		n, err := input.Read(buf)
		if n > 0 {
			if err := console.sendInput(ctx, append([]byte(nil), buf[:n]...)); err != nil {
				return false
			}
		}
		if err == nil {
			continue
		}
		if stdinOnce {
			_ = console.sendInput(ctx, nil)
			return false
		}
		var escape term.EscapeError
		return errors.As(err, &escape)
	}
}

func copyRawConsoleFrames(r *bufio.Reader, w io.Writer, stdout, stderr bool) error {
	for {
		var header [8]byte
		if _, err := io.ReadFull(r, header[:]); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		dest := io.Writer(io.Discard)
		if header[0] == 1 && stdout || header[0] == 2 && stderr {
			dest = w
		}
		if _, err := io.CopyN(dest, r, int64(binary.BigEndian.Uint32(header[4:]))); err != nil {
			return err
		}
	}
}

func (s *dockerEngine) resizeContainer(w http.ResponseWriter, r *http.Request, c *dockerContainer) error {
	q := r.URL.Query()
	h, hErr := strconv.ParseUint(q.Get("h"), 10, 16)
	width, wErr := strconv.ParseUint(q.Get("w"), 10, 16)
	if hErr != nil || wErr != nil || h == 0 || width == 0 {
		return fail(400, "invalid console size")
	}
	s.mu.Lock()
	console := c.console
	tty := c.Config.Tty
	s.mu.Unlock()
	if !tty {
		return fail(400, "container has no TTY")
	}
	if console == nil {
		return fail(409, "container is not running")
	}
	err := console.resize(unix.Winsize{Row: uint16(h), Col: uint16(width)})
	if errors.Is(err, io.ErrClosedPipe) || errors.Is(err, os.ErrClosed) {
		return fail(409, "container is not running")
	}
	if err != nil {
		return err
	}
	w.WriteHeader(http.StatusOK)
	return nil
}
