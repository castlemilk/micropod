package main

import (
	"encoding/binary"
	"testing"
)

func TestLinuxAuxiliaryVector(t *testing.T) {
	for _, tc := range []struct {
		name  string
		words []uint64
		page  uint64
	}{
		{"4k", []uint64{3, 64, 6, 4096, 0, 0}, 4096},
		{"16k", []uint64{6, 16384, 0, 0}, 16384},
		{"missing", []uint64{0, 0}, 0},
		{"duplicated", []uint64{6, 16384, 6, 4096, 0, 0}, 0},
		{"unterminated", []uint64{6, 16384}, 0},
		{"truncated", []uint64{6}, 0},
		{"zero", []uint64{6, 0, 0, 0}, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			data := make([]byte, len(tc.words)*8)
			for i, word := range tc.words {
				binary.LittleEndian.PutUint64(data[i*8:], word)
			}
			page, err := parseAuxPage(data)
			if page != tc.page || (err != nil) != (tc.page == 0) {
				t.Fatalf("got page %d, error %v", page, err)
			}
		})
	}
}
