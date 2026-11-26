// Read TCP structure sizes and cache group boundaries from raw Linux ARM64 Images.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cilium/ebpf/btf"
)

type layout struct {
	Image       string            `json:"file"`
	ImageSHA256 string            `json:"image_sha256"`
	BTFOffset   int               `json:"btf_offset"`
	BTFSHA256   string            `json:"btf_sha256"`
	Bytes       map[string]uint32 `json:"struct_bytes"`
	Absent      []string          `json:"absent_types,omitempty"`
	GroupBytes  map[string]uint32 `json:"tcp_sock_group_offsets_bytes"`
}

func digest(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func inspect(path string) (layout, error) {
	image, err := os.ReadFile(path)
	if err != nil {
		return layout{}, err
	}
	// The archived raw ARM64 Images embed one little-endian BTF v1 blob
	// with the 24-byte header. Reject ambiguous or truncated input.
	header := []byte{0x9f, 0xeb, 1, 0, 24, 0, 0, 0}
	start := bytes.Index(image, header)
	if start < 0 || bytes.Count(image, header) != 1 || len(image)-start < 24 {
		return layout{}, fmt.Errorf("expected a unique BTF v1 header")
	}
	payload := image[start:]
	field := func(i int) uint64 { return uint64(binary.LittleEndian.Uint32(payload[i:])) }
	end := 24 + field(16) + field(20)
	if field(8)+field(12) != field(16) || end > uint64(len(payload)) {
		return layout{}, fmt.Errorf("invalid BTF type or string bounds")
	}
	blob := payload[:end]
	spec, err := btf.LoadSpecFromReader(bytes.NewReader(blob))
	if err != nil {
		return layout{}, err
	}
	result := layout{Image: filepath.Base(path), ImageSHA256: digest(image), BTFOffset: start,
		BTFSHA256: digest(blob), Bytes: map[string]uint32{}, GroupBytes: map[string]uint32{}}
	for _, name := range []string{"sock", "tcp_sock", "tcp6_sock", "tcp_request_sock", "tcp6_request_sock",
		"tcp_timewait_sock", "tcp6_timewait_sock", "ipv6_pinfo"} {
		var structure *btf.Struct
		if err := spec.TypeByName(name, &structure); err != nil {
			if errors.Is(err, btf.ErrNotFound) && name != "tcp_sock" && name != "sock" {
				result.Absent = append(result.Absent, name)
				continue
			}
			return layout{}, fmt.Errorf("%s: %w", name, err)
		}
		result.Bytes[name] = structure.Size
		if name == "tcp_sock" {
			for _, member := range structure.Members {
				if strings.HasPrefix(member.Name, "__cacheline_group_") {
					result.GroupBytes[member.Name] = member.Offset.Bytes()
				}
			}
		}
	}
	return result, nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: socket_layout IMAGE [IMAGE ...]")
		os.Exit(2)
	}
	var results []layout
	for _, path := range os.Args[1:] {
		result, err := inspect(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, path, err)
			os.Exit(1)
		}
		results = append(results, result)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(results); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
