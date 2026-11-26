package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
	"testing/iotest"
)

func appendOutputFrame(wire []byte, stream byte, body []byte) []byte {
	var header [8]byte
	header[0] = stream
	binary.BigEndian.PutUint32(header[4:], uint32(len(body)))
	wire = append(wire, header[:]...)
	return append(wire, body...)
}

func TestStreamFramesFragmentationAndSelection(t *testing.T) {
	var all, both, stdout, stderr []byte
	for i, spec := range []struct {
		stream byte
		length int
	}{{1, 0}, {2, 3}, {1, 23}, {7, 17}, {2, 65537}, {1, 126}, {2, 1}} {
		body := bytes.Repeat([]byte{byte(i + 1)}, spec.length)
		all = appendOutputFrame(all, spec.stream, body)
		if spec.stream == 1 || spec.stream == 2 {
			both = appendOutputFrame(both, spec.stream, body)
		}
		switch spec.stream {
		case 1:
			stdout = appendOutputFrame(stdout, 1, body)
		case 2:
			stderr = appendOutputFrame(stderr, 2, body)
		}
	}
	for _, size := range []int{16, 32, 4096, len(all)} {
		for _, sel := range []struct {
			out, err bool
			expected []byte
		}{{true, true, both}, {true, false, stdout}, {false, true, stderr}, {false, false, nil}} {
			for _, chunked := range []bool{false, true} {
				var input io.Reader = bytes.NewReader(all)
				if chunked {
					input = iotest.HalfReader(input)
				}
				var output bytes.Buffer
				if err := copyFrames(bufio.NewReaderSize(input, size), &output, sel.out, sel.err); err != nil ||
					!bytes.Equal(output.Bytes(), sel.expected) {
					t.Fatalf("buffer %d, split %t, selection %t/%t: got %d bytes, error %v; want %d", size, chunked, sel.out, sel.err, output.Len(), err, len(sel.expected))
				}
			}
		}
	}
}

func TestStreamFramesIncompleteSpool(t *testing.T) {
	frame := appendOutputFrame(nil, 1, []byte("abcdefghij"))
	for end := 0; end < len(frame); end++ {
		for _, selected := range []bool{false, true} {
			var output bytes.Buffer
			err := copyFrames(bufio.NewReader(bytes.NewReader(frame[:end])), &output, selected, false)
			var want []byte
			if end >= 8 && selected {
				want = frame[:end]
			}
			if (end >= 8 && !errors.Is(err, io.EOF)) || (end < 8 && err != nil) || !bytes.Equal(output.Bytes(), want) {
				t.Fatalf("end %d, selected %t: output %x, err %v", end, selected, output.Bytes(), err)
			}
		}
	}
}

type outputFrameErrorWriter struct{ err error }

func (w outputFrameErrorWriter) Write([]byte) (int, error) { return 0, w.err }

func TestStreamFrameWriteFailure(t *testing.T) {
	failure := errors.New("writer closed")
	for _, size := range []int{16, 4096} {
		frame := appendOutputFrame(nil, 1, bytes.Repeat([]byte{1}, 128))
		if err := copyFrames(bufio.NewReaderSize(bytes.NewReader(frame), size), outputFrameErrorWriter{failure}, true, true); !errors.Is(err, failure) {
			t.Fatalf("writer failure: %v", err)
		}
	}
}

func TestShortFrameWriter(t *testing.T) {
	for _, size := range []int{16, 4096} {
		frame := appendOutputFrame(nil, 1, bytes.Repeat([]byte{1}, 128))
		if err := copyFrames(bufio.NewReaderSize(bytes.NewReader(frame), size), outputFrameErrorWriter{}, true, true); !errors.Is(err, io.ErrShortWrite) {
			t.Fatalf("short header/frame write with buffer size %d: %v", size, err)
		}
	}
}

func BenchmarkCopyDockerFrames(b *testing.B) {
	for _, tc := range []struct {
		name           string
		count, size    int
		stdout, stderr bool
	}{
		{"short-both", 1024, 96, true, true},
		{"short-stdout", 1024, 96, true, false},
		{"short-stderr", 1024, 96, false, true},
		{"one-short", 1, 96, true, true},
		{"cross-buffer", 32, 4090, true, true},
		{"large-both", 16, 65536, true, true},
		{"large-stderr", 16, 65536, false, true},
	} {
		b.Run(tc.name, func(b *testing.B) {
			var spool, wanted []byte
			for i := 0; i < tc.count; i++ {
				stream := byte(1)
				if i%4 == 3 {
					stream = 2
				}
				body := bytes.Repeat([]byte{byte(i)}, tc.size)
				spool = appendOutputFrame(spool, stream, body)
				if (stream == 1 && tc.stdout) || (stream == 2 && tc.stderr) {
					wanted = appendOutputFrame(wanted, stream, body)
				}
			}
			path := filepath.Join(b.TempDir(), "output")
			if err := os.WriteFile(path, spool, 0600); err != nil {
				b.Fatal(err)
			}
			f, err := os.Open(path)
			if err != nil {
				b.Fatal(err)
			}
			defer f.Close()
			r := bufio.NewReader(nil)
			var output bytes.Buffer
			output.Grow(len(wanted))
			writer := bufio.NewWriter(&output)
			b.SetBytes(int64(len(wanted)))
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				output.Reset()
				r.Reset(io.NewSectionReader(f, 0, int64(len(spool))))
				if err := copyFrames(r, writer, tc.stdout, tc.stderr); err != nil {
					b.Fatal(err)
				}
				if err := writer.Flush(); err != nil {
					b.Fatal(err)
				}
				if !bytes.Equal(output.Bytes(), wanted) {
					b.Fatal("output mismatch")
				}
			}
		})
	}
}
