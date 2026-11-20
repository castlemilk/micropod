package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
)

// A runner-owned stdin/stdout connection. Jobs have separate, binary-safe output frames and receive no control descriptors.
type request struct {
	Op      string   `json:"op,omitempty"`
	ID      string   `json:"id"`
	Clients int      `json:"clients"`
	Args    []string `json:"args"`
}
type frame struct {
	Type    string   `json:"type"`
	ID      string   `json:"id,omitempty"`
	Job     int      `json:"job"`
	Data    []byte   `json:"data,omitempty"`
	Results []result `json:"results,omitempty"`
	Exit    int      `json:"exit"`
}
type encoder struct {
	mu     sync.Mutex
	out    *json.Encoder
	cancel context.CancelFunc
}

func (e *encoder) send(f frame) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	err := e.out.Encode(f)
	if err != nil {
		e.cancel()
	}
	return err
}

type stream struct {
	encoder *encoder
	request string
	index   int
	name    string
}

func (s stream) Write(p []byte) (int, error) {
	if err := s.encoder.send(frame{Type: s.name, ID: s.request, Job: s.index, Data: p}); err != nil {
		return 0, err
	}
	return len(p), nil
}
func serve(parent context.Context, template jobTemplate) error {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	wire := encoder{out: json.NewEncoder(os.Stdout), cancel: cancel}
	requests := make(chan request)
	end := make(chan error, 1)
	go func() {
		defer cancel()
		sc := bufio.NewScanner(os.Stdin)
		sc.Buffer(make([]byte, 4096), 1<<20)
		for sc.Scan() {
			var req request
			if err := json.Unmarshal(sc.Bytes(), &req); err != nil {
				end <- err
				return
			}
			if req.Op == "close" {
				end <- nil
				return
			}
			if len(req.ID) == 0 || len(req.ID) > 128 || req.Clients < 1 || req.Clients > 64 || len(req.Args) == 0 || req.Args[0] == "" {
				end <- errors.New("invalid OCI batch request")
				return
			}
			select {
			case requests <- req:
			case <-ctx.Done():
				return
			}
		}
		end <- sc.Err()
	}()
	if err := wire.send(frame{Type: "ready"}); err != nil {
		return err
	}
	for {
		select {
		case <-ctx.Done():
			select {
			case err := <-end:
				return err
			default:
				return nil
			}
		case req := <-requests:
			results, code := launch(ctx, template, req.Args, req.Clients, func(i int) (io.Writer, io.Writer) {
				return stream{&wire, req.ID, i, "stdout"}, stream{&wire, req.ID, i, "stderr"}
			})
			if ctx.Err() != nil {
				continue
			}
			if err := wire.send(frame{Type: "done", ID: req.ID, Results: results, Exit: code}); err != nil {
				return fmt.Errorf("write batch result: %w", err)
			}
		}
	}
}
