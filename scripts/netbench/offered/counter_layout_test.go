//go:build darwin && offeredlayout

package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

var (
	layoutStride    = flag.Int("counter-stride", 8, "bytes between stream counters")
	layoutWriters   = flag.Int("counter-writers", 32, "bulk stream writers")
	layoutChunk     = flag.Int("counter-chunk", 32768, "maximum bytes per body read")
	layoutResponses = flag.Int("counter-responses", 64, "total scored 8 MiB responses")
)

// Expose only Read, as with a streaming HTTP body. bytes.Reader.WriteTo would
// bypass the io.Copy scratch buffer and count a whole response in one write.
type chunkedBody struct {
	body  bytes.Reader
	chunk int
	reads int
}

func (r *chunkedBody) Read(p []byte) (int, error) {
	n, err := r.body.Read(p[:min(len(p), r.chunk)])
	if n > 0 {
		r.reads++
	}
	return n, err
}

func processCPU(t *testing.T) time.Duration {
	t.Helper()
	var r syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &r); err != nil {
		t.Fatal(err)
	}
	return time.Duration(r.Utime.Nano() + r.Stime.Nano())
}

// Run explicitly with the offeredlayout build tag. Both layouts use the same
// binary, allocation and production writer. Only the selected addresses differ.
func TestOfferedCounterLayout(t *testing.T) {
	const bodyBytes = 8 << 20
	writers, stride := *layoutWriters, *layoutStride
	if (stride != 8 && stride != 128) || (writers != 1 && writers != 32) ||
		(*layoutChunk != 4096 && *layoutChunk != 32768) ||
		*layoutResponses < writers || *layoutResponses%writers != 0 {
		t.Fatal("invalid layout or workload")
	}
	body := make([]byte, bodyBytes)
	for i := range body {
		body[i] = byte(i*31 + i/4093)
	}

	var storage [32 * 16]atomic.Int64
	var counters [32]*atomic.Int64
	for i := range counters {
		counters[i] = &storage[i*(stride/8)]
	}
	// Report the actual addresses' spacing, independent of Go's allocation alignment.
	base := uintptr(unsafe.Pointer(counters[0]))
	if uintptr(unsafe.Pointer(counters[31]))-base != uintptr(31*stride) {
		t.Fatal("unexpected counter layout")
	}
	snapshot := func() (s [32]int64) {
		for i, c := range counters {
			s[i] = c.Load()
		}
		return
	}

	// Start the goroutines before timing. Warmup and drain are complete 8 MiB
	// responses for every active stream. Only the middle phase is timed.
	type duration struct{ cpu, wall time.Duration }
	phase := func(bodies int) duration {
		var ready, done sync.WaitGroup
		start := make(chan struct{})
		ready.Add(writers)
		done.Add(writers)
		for stream := range writers {
			go func() {
				defer done.Done()
				dst := counter{counters[stream]}
				ready.Done()
				<-start
				src := chunkedBody{chunk: *layoutChunk}
				for range bodies {
					src.body.Reset(body)
					n, err := io.Copy(dst, &src)
					if err != nil || n != bodyBytes {
						t.Errorf("stream %d copied %d bytes: %v", stream, n, err)
						return
					}
				}
				if src.reads != bodies*bodyBytes / *layoutChunk {
					t.Error("unexpected body read count")
				}
			}()
		}
		ready.Wait()
		cpu := processCPU(t)
		wall := time.Now()
		close(start)
		done.Wait()
		elapsedWall := time.Since(wall)
		return duration{processCPU(t) - cpu, elapsedWall}
	}
	phase(1)
	before := snapshot()
	d := phase(*layoutResponses / writers)
	end := snapshot()
	phase(1)
	final := snapshot()
	phases, err := bulkBodyBytes(&before, &end, &final)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range []struct {
		got       phaseBytes
		perWriter int64
	}{
		{phases.Warmup, bodyBytes}, {phases.Scored, int64(*layoutResponses/writers) * bodyBytes},
		{phases.Drain, bodyBytes}, {phases.Invocation, int64(2+*layoutResponses/writers) * bodyBytes},
	} {
		if p.got.Bytes != p.perWriter*int64(writers) {
			t.Fatal("incorrect aggregate")
		}
		for i, v := range p.got.Streams {
			var want int64
			if i < writers {
				want = p.perWriter
			}
			if v != want {
				t.Fatalf("stream %d: got %d, want %d", i, v, want)
			}
		}
	}

	fmt.Print("layout ")
	err = json.NewEncoder(os.Stdout).Encode(map[string]any{
		"stride_bytes": stride, "base_mod_128": base % 128, "writers": writers, "chunk_bytes": *layoutChunk,
		"warmup_bytes": phases.Warmup.Bytes, "scored_bytes": phases.Scored.Bytes, "drain_bytes": phases.Drain.Bytes,
		"scored_counter_writes": phases.Scored.Bytes / int64(*layoutChunk), "cpu_ns": d.cpu.Nanoseconds(), "wall_ns": d.wall.Nanoseconds(),
	})
	if err != nil {
		t.Fatal(err)
	}
}
