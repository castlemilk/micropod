package main

import (
	"crypto/sha256"
	"fmt"
	"strings"
	"syscall"
	"testing"
)

func TestProbeVerdicts(t *testing.T) {
	tests := []struct {
		name     string
		n        int
		err      error
		mismatch bool
		code     int
	}{
		{"identical", 4, nil, false, 0},
		{"different bytes", 4, nil, true, 1},
		{"short read", 2, nil, false, 1},
		{"unexpected zero", 0, nil, false, 1},
		{"unsupported", -1, syscall.EOPNOTSUPP, false, 3},
		{"unsupported plus bytes", 1, syscall.EOPNOTSUPP, false, 1},
		{"different rejection", -1, syscall.EINVAL, false, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			calls := 0
			r := compare(4, func(b []byte, flagged bool) (int, error) {
				calls++
				if flagged != (calls == 2) {
					t.Fatal("incorrect control/flagged call sequence")
				}
				copy(b, "data")
				if !flagged {
					return 4, nil
				}
				if tt.mismatch {
					b[1]++
				}
				return tt.n, tt.err
			})
			if calls != 2 || exitCode(r.Verdict) != tt.code || r.Flagged.Bytes != tt.n ||
				r.Control.SHA256 != fmt.Sprintf("%x", sha256.Sum256([]byte("data"))) {
				t.Fatalf("%+v", r)
			}
			if tt.code == 0 && r.Flagged.SHA256 != r.Control.SHA256 {
				t.Fatal("different hashes")
			}
			if tt.code == 3 && r.Flagged.Errno != int(syscall.EOPNOTSUPP) {
				t.Fatal("missing errno")
			}
		})
	}
}

func TestControlFailureAndReadBounds(t *testing.T) {
	calls := 0
	read := func(b []byte, flagged bool) (int, error) {
		calls++
		if flagged || len(b) != 4096 {
			t.Fatalf("unexpected read: %d, flagged=%v", len(b), flagged)
		}
		return -1, syscall.EOPNOTSUPP
	}
	empty := compare(0, read)
	if calls != 0 || empty.Verdict != "error" {
		t.Fatal("touched empty file")
	}
	large := compare(1<<40, read)
	if calls != 1 || large.Verdict != "error" || large.Flagged != nil {
		t.Fatal("ignored control failure")
	}
}

func TestMountSelection(t *testing.T) {
	overlay := "31 20 0:29 / / rw shared:2 - overlay overlay rw\n"
	ext4 := "32 31 8:2 /bind /space\\040path rw,nosuid - ext4 /dev/vdb1 rw\n"
	kind, err := mountType(strings.NewReader(overlay+ext4), 32, "8:2")
	if err != nil || kind != "ext4" {
		t.Fatalf("kind %q: %v", kind, err)
	}
	for _, input := range []string{overlay, strings.Replace(ext4, "8:2", "8:3", 1), strings.Replace(ext4, " - ", " ?", 1), ext4 + ext4} {
		if _, err := mountType(strings.NewReader(input), 32, "8:2"); err == nil {
			t.Fatal("accepted missing, ambiguous or mismatched mount")
		}
	}
}
