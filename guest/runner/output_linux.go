package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"time"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// The sink consumes data synchronously, before the next read reuses its buffer.
type outputSink func(stream string, data []byte) error

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
	reader  *bufio.Reader
	partial []byte
	bytes   int64
}

func (s *criOutput) drain(write outputSink) error {
	for {
		line, err := s.reader.ReadSlice('\n')
		s.bytes += int64(len(line))
		if s.bytes >= (8<<20)-4096 {
			return errors.New("job log exceeded the 8 MiB limit")
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

func (n node) follow(ctx context.Context, id, path string, write outputSink) (int32, string, error) {
	var file *os.File
	var output criOutput
	defer func() {
		if file != nil {
			file.Close()
		}
	}()
	drain := func() error {
		if file == nil {
			f, err := os.Open(path)
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
	delay := 5 * time.Millisecond
	for {
		st, err := n.runtime.ContainerStatus(ctx, &cri.ContainerStatusRequest{ContainerId: id})
		if err != nil {
			return 0, "", err
		}
		if err := drain(); err != nil {
			return 0, "", err
		}
		if st.Status == nil {
			return 0, "", errors.New("missing runtime status")
		}
		if st.Status.State == cri.ContainerState_CONTAINER_EXITED {
			if st.Status.FinishedAt == 0 {
				return 0, "", errors.New("runtime has no recorded exit")
			}
			if len(output.partial) != 0 {
				return 0, "", errors.New("incomplete final CRI log record")
			}
			return st.Status.ExitCode, st.Status.Reason, nil
		}
		select {
		case <-ctx.Done():
			return 0, "", ctx.Err()
		case <-time.After(delay):
		}
		delay = min(delay*2, 200*time.Millisecond)
	}
}
