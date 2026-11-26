package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"runtime"
	"runtime/debug"
)

type scenario struct {
	Name      string
	Payloads  [][]byte
	Wire      []byte
	ChunkSize int
	Streams   int
}

type chunkReader struct {
	r   *bytes.Reader
	max int
}

func (r *chunkReader) Read(b []byte) (int, error) {
	return r.r.Read(b[:min(len(b), r.max)])
}

// Produce valid A/AAAA IN queries. Larger records carry one EDNS PADDING option.
func query(size, id int) []byte {
	msg := make([]byte, 12, size)
	binary.BigEndian.PutUint16(msg[0:2], uint16(id))
	msg[2], msg[5] = 1, 1
	typ := uint16(1)
	if id%2 == 1 {
		typ = 28
	}
	msg = append(msg, 3, 'w', 'e', 'b', 3, 's', 'v', 'c', 0)
	msg = binary.BigEndian.AppendUint16(msg, typ)
	msg = binary.BigEndian.AppendUint16(msg, 1)
	if len(msg) == size {
		return msg
	}
	pad := size - len(msg) - 15
	if pad < 0 {
		panic("invalid EDNS size")
	}
	msg[11] = 1
	msg = append(msg, 0, 0, 41, 0x10, 0, 0, 0, 0, 0)
	msg = binary.BigEndian.AppendUint16(msg, uint16(pad+4))
	msg = binary.BigEndian.AppendUint16(msg, 12)
	msg = binary.BigEndian.AppendUint16(msg, uint16(pad))
	for i := 0; i < pad; i++ {
		msg = append(msg, byte((i+id)%251))
	}
	return msg
}

func makeScenario(name string, sizes []int, requests, chunk, streams int) scenario {
	s := scenario{Name: name, ChunkSize: chunk, Streams: streams}
	for i := 0; i < requests; i++ {
		q := query(sizes[i%len(sizes)], i)
		s.Payloads = append(s.Payloads, q)
		s.Wire = binary.BigEndian.AppendUint16(s.Wire, uint16(len(q)))
		s.Wire = append(s.Wire, q...)
	}
	return s
}

// Both loops model the synchronous service immediately consuming a request
// before the next read. The relay and external resolver are outside this fixture.
func stream(s scenario, bounded bool) int {
	r := &chunkReader{bytes.NewReader(s.Wire), s.ChunkSize}
	read := func(payload, want []byte, err error) {
		if err != nil || !bytes.Equal(payload, want) {
			panic("invalid request delivery")
		}
	}
	if bounded {
		var scratch [512]byte
		for _, want := range s.Payloads {
			actual, err := readDNSWithBuffer(r, scratch[:])
			read(actual, want, err)
		}
	} else {
		for _, want := range s.Payloads {
			actual, err := readDNS(r)
			read(actual, want, err)
		}
	}
	if r.r.Len() != 0 {
		panic("trailing bytes")
	}
	return len(s.Payloads)
}

type sample struct {
	Pair      int    `json:"pair"`
	Arm       string `json:"arm"`
	Streams   int    `json:"streams"`
	Delivered int    `json:"delivered_queries"`
	Allocs    uint64 `json:"allocations"`
	Heap      uint64 `json:"allocated_bytes"`
}
type cell struct {
	Name    string   `json:"name"`
	Sizes   []int    `json:"pattern_bytes"`
	Chunk   int      `json:"read_chunk_limit_bytes"`
	Wire    int      `json:"wire_bytes_per_stream"`
	SHA     string   `json:"wire_sha256"`
	Samples []sample `json:"samples"`
}
type fault struct {
	Bytes     string `json:"frame_hex"`
	Control   string `json:"control_error"`
	Candidate string `json:"candidate_error"`
}

func measure(s scenario, bounded bool, pair int) sample {
	name := "control"
	if bounded {
		name = "candidate"
	}
	runtime.GC()
	var start, end runtime.MemStats
	runtime.ReadMemStats(&start)
	delivered := 0
	for i := 0; i < s.Streams; i++ {
		delivered += stream(s, bounded)
	}
	runtime.ReadMemStats(&end)
	return sample{pair, name, s.Streams, delivered, end.Mallocs - start.Mallocs, end.TotalAlloc - start.TotalAlloc}
}

func main() {
	debug.SetGCPercent(-1)
	type testCase struct {
		name                     string
		sizes                    []int
		requests, chunk, streams int
	}
	cases := []testCase{
		{"fresh", []int{25}, 1, 64, 128},
		{"persistent_short", []int{25}, 32, 64, 64},
		{"persistent_fragmented_edns", []int{25, 96, 512, 25}, 32, 3, 64},
		{"persistent_mixed_size", []int{25, 513, 96, 4096}, 32, 64, 32},
		{"oversize_only", []int{65535}, 2, 1024, 8},
	}
	cells := make([]cell, 0, len(cases))
	for _, c := range cases {
		s := makeScenario(c.name, c.sizes, c.requests, c.chunk, c.streams)
		digest := sha256.Sum256(s.Wire)
		row := cell{Name: c.name, Sizes: c.sizes, Chunk: c.chunk, Wire: len(s.Wire), SHA: hex.EncodeToString(digest[:])}
		for pair := 1; pair <= 6; pair++ {
			for pos := 0; pos < 2; pos++ {
				cand := (pair+pos)%2 == 0
				row.Samples = append(row.Samples, measure(s, cand, pair))
			}
		}
		cells = append(cells, row)
	}
	faults := []fault{}
	for _, wire := range [][]byte{nil, {0}, {0, 0}, {0, 11}, {0, 25, 0, 1}, {255, 255, 0, 1}} {
		var scratch [512]byte
		_, a := readDNS(bytes.NewReader(wire))
		_, b := readDNSWithBuffer(bytes.NewReader(wire), scratch[:])
		if a == nil || b == nil || a.Error() != b.Error() {
			panic("error mismatch")
		}
		faults = append(faults, fault{hex.EncodeToString(wire), a.Error(), b.Error()})
	}
	out := struct {
		Cells  []cell  `json:"cells"`
		Faults []fault `json:"faults"`
	}{cells, faults}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(fmt.Sprint(err))
	}
}

var _ io.Reader = (*chunkReader)(nil)
