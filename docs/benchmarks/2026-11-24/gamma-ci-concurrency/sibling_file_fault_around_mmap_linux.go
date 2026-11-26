// Observe warm file faults on a read-only executable segment of the pinned Go tool.
package main

import (
	"crypto/sha256"
	"debug/elf"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

const (
	schema      = "micropod-file-fault-around-mmap-v1"
	toolPath    = "/usr/local/go/bin/go"
	toolDigest  = "2c77b9243b17c9d5ecd5983acbdeaee36d470a9b62a2952f1279c319cc9b97fb"
	pageBytes   = 16 * 1024
	windowBytes = 1024 * 1024
	pages       = windowBytes / pageBytes
)

type toolIdentity struct {
	Path             string `json:"path"`
	SHA256           string `json:"sha256"`
	Inode            uint64 `json:"inode"`
	Device           uint64 `json:"device"`
	DeviceMajor      uint64 `json:"device_major"`
	DeviceMinor      uint64 `json:"device_minor"`
	SizeBytes        int64  `json:"size_bytes"`
	SegmentOffset    uint64 `json:"segment_offset"`
	SegmentSizeBytes uint64 `json:"segment_size_bytes"`
	WindowOffset     uint64 `json:"window_offset"`
}

type sample struct {
	Order                    string `json:"order"`
	MapsLine                 string `json:"maps_line"`
	ResidentBeforePages      int    `json:"resident_before_pages"`
	PresentBeforePages       int    `json:"present_before_pages"`
	PresentAfterFirstIndices []int  `json:"present_after_first_indices"`
	MinorFaults              int64  `json:"minor_faults"`
	MajorFaults              int64  `json:"major_faults"`
	Checksum                 string `json:"checksum"`
	ExpectedChecksum         string `json:"expected_checksum"`
}

type receipt struct {
	Schema      string       `json:"schema"`
	BootID      string       `json:"boot_id"`
	PageBytes   int          `json:"page_bytes"`
	WindowBytes int          `json:"window_bytes"`
	Tool        toolIdentity `json:"tool"`
	Samples     []sample     `json:"samples"`
}

func identify(f *os.File) (toolIdentity, error) {
	var st syscall.Stat_t
	if err := syscall.Fstat(int(f.Fd()), &st); err != nil {
		return toolIdentity{}, err
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFREG || st.Ino == 0 {
		return toolIdentity{}, fmt.Errorf("Go executable is not a regular file")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, f); err != nil {
		return toolIdentity{}, err
	}
	digest := hex.EncodeToString(hash.Sum(nil))
	if digest != toolDigest {
		return toolIdentity{}, fmt.Errorf("Go executable digest differs: %s", digest)
	}
	image, err := elf.NewFile(f)
	if err != nil {
		return toolIdentity{}, err
	}
	if image.Class != elf.ELFCLASS64 || image.Machine != elf.EM_AARCH64 {
		return toolIdentity{}, fmt.Errorf("Go executable is not an ARM64 ELF")
	}
	for _, segment := range image.Progs {
		if segment.Type != elf.PT_LOAD || segment.Flags&elf.PF_X == 0 {
			continue
		}
		offset := (segment.Off + windowBytes - 1) &^ (windowBytes - 1)
		if offset+windowBytes <= segment.Off+segment.Filesz && offset+windowBytes <= uint64(st.Size) {
			return toolIdentity{
				Path: toolPath, SHA256: digest, Inode: st.Ino, Device: st.Dev, SizeBytes: st.Size,
				DeviceMajor:   (st.Dev>>8)&0xfff | (st.Dev>>32)&0xfffff000,
				DeviceMinor:   st.Dev&0xff | (st.Dev>>12)&0xffffff00,
				SegmentOffset: segment.Off, SegmentSizeBytes: segment.Filesz, WindowOffset: offset,
			}, nil
		}
	}
	return toolIdentity{}, fmt.Errorf("no complete aligned 1 MiB window in the Go text segment")
}

func mappingLine(address uintptr, tool toolIdentity) (string, error) {
	data, err := os.ReadFile("/proc/self/maps")
	if err != nil {
		return "", err
	}
	addressRange := fmt.Sprintf("%x-%x", address, address+windowBytes)
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 6 || fields[0] != addressRange {
			continue
		}
		offset, err := strconv.ParseUint(fields[2], 16, 64)
		devMajor, devMinor, devOK := strings.Cut(fields[3], ":")
		major, majorErr := strconv.ParseUint(devMajor, 16, 64)
		minor, minorErr := strconv.ParseUint(devMinor, 16, 64)
		if err != nil || offset != tool.WindowOffset || !devOK || majorErr != nil || minorErr != nil ||
			major != tool.DeviceMajor || minor != tool.DeviceMinor || fields[4] != strconv.FormatUint(tool.Inode, 10) ||
			fields[1] != "r--p" || fields[5] != tool.Path {
			return "", fmt.Errorf("file mapping identity differs: %s", line)
		}
		return line, nil
	}
	return "", fmt.Errorf("could not locate aligned executable-file mapping")
}

func present(pagemap *os.File, address uintptr) ([]int, error) {
	var entries [pages * 8]byte
	if _, err := pagemap.ReadAt(entries[:], int64(address/pageBytes)*8); err != nil {
		return nil, err
	}
	indices := make([]int, 0, pages)
	for i := range pages {
		// Bit 63 describes presence. The physical frame number is unnecessary.
		if binary.LittleEndian.Uint64(entries[i*8:])&(1<<63) != 0 {
			indices = append(indices, i)
		}
	}
	return indices, nil
}

func pageIndex(i int, reverse bool) int {
	if reverse {
		return pages - 1 - i
	}
	return i
}

func checksumStep(sum uint64, value byte) uint64 {
	return (sum ^ uint64(value)) * 1099511628211
}

func collect(f, pagemap *os.File, tool toolIdentity, want []byte, order string) (sample, error) {
	out := sample{Order: order}
	reserve, err := syscall.Mmap(-1, 0, 2*windowBytes, syscall.PROT_NONE, syscall.MAP_PRIVATE|syscall.MAP_ANON)
	if err != nil {
		return out, err
	}
	defer syscall.Munmap(reserve)
	base := uintptr(unsafe.Pointer(&reserve[0]))
	shift := int((-base) & (windowBytes - 1))
	mapped := reserve[shift : shift+windowBytes]
	address := uintptr(unsafe.Pointer(&mapped[0]))
	// MAP_FIXED replaces only the middle of our own inaccessible reservation.
	addr, _, errno := syscall.Syscall6(syscall.SYS_MMAP, address, windowBytes, syscall.PROT_READ,
		syscall.MAP_FIXED|syscall.MAP_PRIVATE, f.Fd(), uintptr(tool.WindowOffset))
	if errno != 0 || addr != address {
		return out, fmt.Errorf("map aligned file window: %s", errno)
	}
	out.MapsLine, err = mappingLine(address, tool)
	if err != nil {
		return out, err
	}
	before, err := present(pagemap, address)
	if err != nil {
		return out, err
	}
	out.PresentBeforePages = len(before)
	var residency [pages]byte
	_, _, errno = syscall.Syscall(syscall.SYS_MINCORE, address, windowBytes, uintptr(unsafe.Pointer(&residency[0])))
	if errno != 0 {
		return out, errno
	}
	for _, status := range residency {
		out.ResidentBeforePages += int(status & 1)
	}
	if out.PresentBeforePages != 0 || out.ResidentBeforePages != pages {
		return out, fmt.Errorf("expected a fresh mapping of resident pages, got %d present and %d resident",
			out.PresentBeforePages, out.ResidentBeforePages)
	}
	reverse := order == "reverse"
	const basis = uint64(14695981039346656037)
	expected := basis
	for i := range pages {
		expected = checksumStep(expected, want[pageIndex(i, reverse)*pageBytes])
	}
	// Count only this thread across the first touch and then the remaining page
	// touches. The page table observation itself stays outside both intervals.
	var firstBefore, firstAfter, restBefore, restAfter syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_THREAD, &firstBefore); err != nil {
		return out, err
	}
	sum := checksumStep(basis, mapped[pageIndex(0, reverse)*pageBytes])
	if err := syscall.Getrusage(syscall.RUSAGE_THREAD, &firstAfter); err != nil {
		return out, err
	}
	out.PresentAfterFirstIndices, err = present(pagemap, address)
	if err != nil {
		return out, err
	}
	if err := syscall.Getrusage(syscall.RUSAGE_THREAD, &restBefore); err != nil {
		return out, err
	}
	for i := 1; i < pages; i++ {
		sum = checksumStep(sum, mapped[pageIndex(i, reverse)*pageBytes])
	}
	if err := syscall.Getrusage(syscall.RUSAGE_THREAD, &restAfter); err != nil {
		return out, err
	}
	out.MinorFaults = (firstAfter.Minflt - firstBefore.Minflt) + (restAfter.Minflt - restBefore.Minflt)
	out.MajorFaults = (firstAfter.Majflt - firstBefore.Majflt) + (restAfter.Majflt - restBefore.Majflt)
	out.Checksum = fmt.Sprintf("%016x", sum)
	out.ExpectedChecksum = fmt.Sprintf("%016x", expected)
	if sum != expected {
		return out, fmt.Errorf("mapped Go executable bytes differ from pread")
	}
	return out, nil
}

func run() error {
	if os.Getpagesize() != pageBytes || runtime.GOARCH != "arm64" {
		return fmt.Errorf("this witness requires Linux ARM64 with 16 KiB pages")
	}
	runtime.GOMAXPROCS(1)
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	debug.SetGCPercent(-1)
	boot, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return err
	}
	f, err := os.Open(toolPath)
	if err != nil {
		return err
	}
	defer f.Close()
	tool, err := identify(f)
	if err != nil {
		return err
	}
	pagemap, err := os.Open("/proc/self/pagemap")
	if err != nil {
		return err
	}
	defer pagemap.Close()
	warm := make([]byte, windowBytes)
	out := receipt{Schema: schema, BootID: strings.TrimSpace(string(boot)), PageBytes: pageBytes,
		WindowBytes: windowBytes, Tool: tool}
	for _, order := range []string{"forward", "reverse", "reverse", "forward"} {
		if _, err := f.ReadAt(warm, int64(tool.WindowOffset)); err != nil {
			return err
		}
		row, err := collect(f, pagemap, tool, warm, order)
		if err != nil {
			return fmt.Errorf("%s touch: %w", order, err)
		}
		out.Samples = append(out.Samples, row)
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
