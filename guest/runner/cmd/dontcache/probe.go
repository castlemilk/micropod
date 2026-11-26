// dontcache checks one read-only Linux file descriptor with two preadv2 calls.
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"syscall"
)

const maxRead = 4096

type sample struct {
	Bytes  int    `json:"returned_bytes"`
	SHA256 string `json:"sha256,omitempty"`
	Errno  int    `json:"errno,omitempty"`
	Error  string `json:"error,omitempty"`
}

type report struct {
	Verdict   string  `json:"verdict"`
	Why       string  `json:"reason,omitempty"`
	Requested int     `json:"requested_bytes"`
	Control   *sample `json:"control,omitempty"`
	Flagged   *sample `json:"dontcache,omitempty"`
}

func readSample(buf []byte, n int, err error) *sample {
	s := &sample{Bytes: n}
	if n >= 0 && n <= len(buf) {
		s.SHA256 = fmt.Sprintf("%x", sha256.Sum256(buf[:n]))
	}
	if err != nil {
		s.Error = err.Error()
		var errno syscall.Errno
		if errors.As(err, &errno) {
			s.Errno = int(errno)
		}
	}
	return s
}

func compare(size uint64, read func([]byte, bool) (int, error)) report {
	result := report{Verdict: "error"}
	if size == 0 {
		result.Why = "empty file"
		return result
	}
	result.Requested = int(min(size, uint64(maxRead)))
	control := make([]byte, result.Requested)
	n, err := read(control, false)
	result.Control = readSample(control, n, err)
	if err != nil || n != len(control) {
		result.Why = "control did not return all requested bytes"
		return result
	}
	flagged := make([]byte, result.Requested)
	n, err = read(flagged, true)
	result.Flagged = readSample(flagged, n, err)
	if errors.Is(err, syscall.EOPNOTSUPP) && n == -1 {
		result.Verdict = "unsupported"
		result.Why = "EOPNOTSUPP on flagged preadv2"
		return result
	}
	if err != nil || n != len(flagged) {
		result.Why = "flagged read did not return all requested bytes"
		return result
	}
	if !bytes.Equal(control, flagged) {
		result.Why = "different bytes at the same offset"
		return result
	}
	result.Verdict = "supported"
	return result
}

// Decode only the mount backing the open fd. mountinfo escapes whitespace in path fields.
func mountType(data io.Reader, id uint64, dev string) (string, error) {
	s := bufio.NewScanner(data)
	s.Buffer(make([]byte, 4096), 1<<20)
	expected := strconv.FormatUint(id, 10)
	var kind string
	for s.Scan() {
		left, right, ok := strings.Cut(s.Text(), " - ")
		fields := strings.Fields(left)
		if len(fields) == 0 || fields[0] != expected {
			continue
		}
		tail := strings.Fields(right)
		if !ok || len(fields) < 6 || len(tail) < 3 || fields[2] != dev || kind != "" {
			return "", errors.New("ambiguous or mismatched mount identity")
		}
		kind = tail[0]
	}
	if err := s.Err(); err != nil {
		return "", err
	}
	if kind == "" {
		return "", errors.New("mount ID missing from mountinfo")
	}
	return kind, nil
}

func exitCode(verdict string) int {
	switch verdict {
	case "supported":
		return 0
	case "unsupported":
		return 3
	default:
		return 1
	}
}
