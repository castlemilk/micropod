package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"testing"
)

func TestCRIOutputRecordBoundaries(t *testing.T) {
	long := bytes.Repeat([]byte{0, 0xff, ' '}, 13000)
	var source, seen bytes.Buffer
	output := criOutput{reader: bufio.NewReaderSize(&source, 64)}
	write := func(stream string, data []byte) error {
		seen.WriteString(stream + "|")
		seen.Write(data)
		seen.WriteByte('|')
		return nil
	}
	source.WriteString("t stderr P ")
	source.Write(long[:100])
	if err := output.drain(write); err != nil || seen.Len() != 0 {
		t.Fatalf("partial physical record: bytes=%d, err=%v", seen.Len(), err)
	}
	source.Write(long[100:])
	source.WriteString("\nt stdout F \nt stderr P \nt stdout F  a  b\r\n")
	if err := output.drain(write); err != nil {
		t.Fatal(err)
	}
	want := append([]byte("stderr|"), long...)
	want = append(want, []byte("|stdout|\n|stderr||stdout| a  b\r\n|")...)
	if !bytes.Equal(seen.Bytes(), want) || len(output.partial) != 0 {
		t.Fatal("records changed across EOF or buffer boundaries")
	}
}

func TestCRIOutputErrorsAndLimit(t *testing.T) {
	sinkErr := errors.New("sink failed")
	for _, tc := range []struct {
		raw, want string
		initial   int64
	}{
		{"t stdout F\n", "invalid CRI log record", 0},
		{"t other F payload\n", "invalid CRI log stream", 0},
		{"t stdout X payload\n", "invalid CRI log fragment", 0},
		{"t stdout F x\n", sinkErr.Error(), 0},
		{"t stdout F x\n", "job log exceeded the 8 MiB limit", (8 << 20) - 4096 - int64(len("t stdout F x\n"))},
	} {
		out := criOutput{reader: bufio.NewReader(bytes.NewBufferString(tc.raw)), bytes: tc.initial}
		err := out.drain(func(string, []byte) error { return sinkErr })
		if err == nil || err.Error() != tc.want || out.bytes != tc.initial+int64(len(tc.raw)) {
			t.Fatalf("raw=%q: err=%v bytes=%d", tc.raw, err, out.bytes)
		}
	}
}

func BenchmarkCRIDrain(b *testing.B) {
	for _, tc := range []struct {
		name        string
		count, size int
	}{
		{"one", 1, 96}, {"ci", 1024, 96}, {"oversized", 8, 65536},
	} {
		var wire, stdout, stderr, jsonWire bytes.Buffer
		for i := 0; i < tc.count; i++ {
			stream, target := "stdout", &stdout
			if i%4 == 1 {
				stream, target = "stderr", &stderr
			}
			tag := "F"
			if i%7 == 0 {
				tag = "P"
			}
			body := bytes.Repeat([]byte{byte('A' + i%26)}, tc.size)
			fmt.Fprintf(&wire, "2026-11-23T00:00:00.000000000Z %s %s ", stream, tag)
			wire.Write(body)
			wire.WriteByte('\n')
			if tag == "F" {
				body = append(body, '\n')
			}
			target.Write(body)
			rec, err := json.Marshal(struct {
				Type string `json:"type"`
				Data []byte `json:"data"`
			}{stream, body})
			if err != nil {
				b.Fatal(err)
			}
			jsonWire.Write(rec)
			jsonWire.WriteByte('\n')
		}
		f, err := os.CreateTemp(b.TempDir(), "job.log")
		if err != nil {
			b.Fatal(err)
		}
		if _, err := f.Write(wire.Bytes()); err != nil {
			b.Fatal(err)
		}
		for _, transport := range []string{"streams", "json"} {
			b.Run(tc.name+"/"+transport, func(b *testing.B) {
				reader := bufio.NewReaderSize(nil, 32<<10)
				var out, errout bytes.Buffer
				var sink outputSink
				if transport == "json" {
					out.Grow(jsonWire.Len())
					sink = jsonOutput(json.NewEncoder(&out))
				} else {
					out.Grow(stdout.Len())
					errout.Grow(stderr.Len())
					sink = func(stream string, data []byte) error {
						if stream == "stdout" {
							_, err := out.Write(data)
							return err
						}
						_, err := errout.Write(data)
						return err
					}
				}
				b.SetBytes(int64(wire.Len()))
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					reader.Reset(io.NewSectionReader(f, 0, int64(wire.Len())))
					state := criOutput{reader: reader}
					out.Reset()
					errout.Reset()
					if err := state.drain(sink); err != nil {
						b.Fatal(err)
					}
					expected := stdout.Bytes()
					if transport == "json" {
						expected = jsonWire.Bytes()
					}
					if state.bytes != int64(wire.Len()) || len(state.partial) != 0 || !bytes.Equal(out.Bytes(), expected) || (transport == "streams" && !bytes.Equal(errout.Bytes(), stderr.Bytes())) {
						b.Fatal("decoded output differs")
					}
				}
			})
		}
		if err := f.Close(); err != nil {
			b.Fatal(err)
		}
	}
}
