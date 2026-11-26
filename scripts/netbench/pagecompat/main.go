// Inspect userspace page size and file-backed private mappings in a worker mount.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"runtime"
	"syscall"
)

type window struct {
	Offset int    `json:"offset"`
	Raw    string `json:"raw_mmap"`
	Base   int    `json:"aligned_base"`
	Length int    `json:"verified_window_bytes"`
}

type receipt struct {
	OS       string   `json:"os"`
	Arch     string   `json:"arch"`
	Page     int      `json:"runtime_page_bytes"`
	AuxPage  uint64   `json:"linux_at_pagesz,omitempty"`
	FileSize int      `json:"temporary_file_bytes"`
	Windows  []window `json:"windows"`
}

func auxPage() (uint64, error) {
	data, err := os.ReadFile("/proc/self/auxv")
	if err != nil {
		return 0, err
	}
	return parseAuxPage(data)
}

func parseAuxPage(data []byte) (uint64, error) {
	if len(data)%16 != 0 {
		return 0, errors.New("truncated ARM64 auxiliary vector")
	}
	var page uint64
	for len(data) >= 16 {
		tag, value := binary.LittleEndian.Uint64(data), binary.LittleEndian.Uint64(data[8:])
		if tag == 0 {
			if page == 0 {
				return 0, errors.New("missing AT_PAGESZ")
			}
			return page, nil
		}
		if tag == 6 {
			if page != 0 || value == 0 {
				return 0, errors.New("duplicate or zero AT_PAGESZ")
			}
			page = value
		}
		data = data[16:]
	}
	return 0, errors.New("unterminated ARM64 auxiliary vector")
}

// Submit the unadjusted offset first, then verify an offset window using the OS granule.
func checkWindow(f *os.File, input []byte, offset, length, page int) (window, error) {
	base := offset / page * page
	result := window{Offset: offset, Base: base, Length: length}
	want := input[offset : offset+length]
	raw, err := syscall.Mmap(int(f.Fd()), int64(offset), length, syscall.PROT_READ, syscall.MAP_PRIVATE)
	switch {
	case err == nil:
		matches := bytes.Equal(raw, want)
		if err := syscall.Munmap(raw); err != nil {
			return result, err
		}
		if !matches {
			return result, errors.New("raw mapping returned different bytes")
		}
		result.Raw = "matched"
	case errors.Is(err, syscall.EINVAL) && offset != base:
		result.Raw = "EINVAL"
	default:
		return result, fmt.Errorf("raw mmap at %d: %w", offset, err)
	}

	delta := offset - base
	mapped, err := syscall.Mmap(int(f.Fd()), int64(base), delta+length, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_PRIVATE)
	if err != nil {
		return result, err
	}
	view := mapped[delta:]
	matches := bytes.Equal(view, want)
	view[len(view)-1] ^= 0xff
	if err := syscall.Munmap(mapped); err != nil {
		return result, err
	}
	disk := make([]byte, length)
	if _, err := f.ReadAt(disk, int64(offset)); err != nil {
		return result, err
	}
	if !matches || !bytes.Equal(disk, want) {
		return result, errors.New("aligned window content or private-write isolation failed")
	}
	return result, nil
}

func inspect(dir string, expected int) (receipt, error) {
	page := os.Getpagesize()
	r := receipt{OS: runtime.GOOS, Arch: runtime.GOARCH, Page: page}
	if r.Arch != "arm64" || (r.OS != "linux" && r.OS != "darwin") {
		return r, errors.New("expected ARM64 Linux or macOS")
	}
	if expected != 0 && page != expected {
		return r, fmt.Errorf("runtime reported %d-byte pages, expected %d", page, expected)
	}
	if r.OS == "linux" {
		var err error
		r.AuxPage, err = auxPage()
		if err != nil {
			return r, err
		}
		if r.AuxPage != uint64(page) {
			return r, fmt.Errorf("AT_PAGESZ reports %d, Go reports %d", r.AuxPage, page)
		}
	}

	f, err := os.CreateTemp(dir, "micropod-pagecompat-*")
	if err != nil {
		return r, err
	}
	defer f.Close()
	if err := os.Remove(f.Name()); err != nil {
		return r, err
	}
	length := page + 17
	data := make([]byte, 16384+length)
	r.FileSize = len(data)
	for i := range data {
		data[i] = byte((i*23 + i/251 + i/4096*41) % 251)
	}
	if _, err := f.Write(data); err != nil {
		return r, err
	}
	for _, offset := range []int{4096, 8192, 12288, 16384} {
		w, err := checkWindow(f, data, offset, length, page)
		if err != nil {
			return r, err
		}
		r.Windows = append(r.Windows, w)
	}
	return r, nil
}

func main() {
	dir := flag.String("dir", os.TempDir(), "writable directory on the filesystem being checked")
	expected := flag.Int("expect-page", 0, "required system page size in bytes (0 to observe)")
	flag.Parse()
	result, err := inspect(*dir, *expected)
	if err == nil {
		err = json.NewEncoder(os.Stdout).Encode(result)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
