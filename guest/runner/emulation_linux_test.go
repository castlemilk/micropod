package main

import (
	"context"
	"encoding/binary"
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"

	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

// withEmulation sets the engine's emulation state for one test.
func withEmulation(t *testing.T, e *amd64Emulation) {
	t.Helper()
	old := engineEmulation.Load()
	engineEmulation.Store(e)
	t.Cleanup(func() { engineEmulation.Store(old) })
}

var qemuEmulation = &amd64Emulation{Emulator: "qemu", Interpreter: qemuX8664Path}

// The kernel command line setting reads as the kernel's own parameters do:
// absent is auto, the last one wins, and an unknown value is an error.
func TestAmd64Setting(t *testing.T) {
	for cmdline, want := range map[string]string{
		"":                                       "auto",
		"console=hvc0 mp.config=1":               "auto",
		"micropod.amd64=off":                     "off",
		"micropod.amd64=on":                      "auto",
		"micropod.amd64=off micropod.amd64=auto": "auto",
		"micropod.amd64=auto micropod.amd64=off": "off",
		"xmicropod.amd64=off":                    "auto",
	} {
		got, err := amd64Setting(cmdline)
		if err != nil || got != want {
			t.Errorf("%q = %q, %v; want %q", cmdline, got, err, want)
		}
	}
	if _, err := amd64Setting("micropod.amd64=maybe"); err == nil {
		t.Error("an unknown value was accepted")
	}
}

// Selection takes Rosetta when its share is mounted, else qemu, else nothing,
// and every outcome names each candidate and why it was or was not taken.
func TestSelectEmulator(t *testing.T) {
	present := func(paths ...string) func(string) error {
		return func(p string) error {
			for _, ok := range paths {
				if p == ok {
					return nil
				}
			}
			return os.ErrNotExist
		}
	}
	e := selectEmulator(emulationEnv{executable: present(qemuX8664Path)})
	if e.Emulator != "qemu" || e.Interpreter != qemuX8664Path || len(e.Candidates) != 2 ||
		e.Candidates[0].Available || !strings.Contains(e.Candidates[0].Reason, "Virtualization.framework") {
		t.Fatalf("qemu only = %+v", e)
	}
	e = selectEmulator(emulationEnv{executable: present(qemuX8664Path, rosettaPath)})
	if e.Emulator != "rosetta" || e.Interpreter != rosettaPath {
		t.Fatalf("both = %+v, want rosetta first", e)
	}
	e = selectEmulator(emulationEnv{executable: present()})
	if e.available() || !strings.Contains(e.Reason, "no x86-64 emulator") || !strings.Contains(e.Reason, "qemu-x86_64") {
		t.Fatalf("none = %+v", e)
	}
	e = selectEmulator(emulationEnv{cmdline: "micropod.amd64=off", executable: present(qemuX8664Path)})
	if e.available() || !strings.Contains(e.Reason, "micropod.amd64=off") {
		t.Fatalf("off = %+v", e)
	}
	e = selectEmulator(emulationEnv{cmdline: "micropod.amd64=bogus", executable: present(qemuX8664Path)})
	if e.available() || !strings.Contains(e.Reason, "unknown micropod.amd64=bogus") {
		t.Fatalf("bogus = %+v", e)
	}
	var unset *amd64Emulation
	if unset.available() || !strings.Contains(unset.unavailableReason(), "not set up") {
		t.Fatalf("an engine that never set up emulation says %q", unset.unavailableReason())
	}
}

// The rule is QEMU's x86-64 magic and mask with the fix-binary, open-binary,
// credentials and preserve-argv0 flags, and an entry reads as current only
// when the kernel shows it enabled with that interpreter and those flags.
func TestBinfmtRule(t *testing.T) {
	rule := binfmtRule("/opt/x/qemu-x86_64")
	fields := strings.Split(rule, ":")
	if len(fields) != 8 || fields[1] != binfmtEntryName || fields[2] != "M" || fields[6] != "/opt/x/qemu-x86_64" || fields[7] != "POCF" {
		t.Fatalf("rule %q", rule)
	}
	if !strings.HasPrefix(fields[4], `\x7f\x45\x4c\x46\x02\x01\x01`) || !strings.HasSuffix(fields[4], `\x02\x00\x3e\x00`) || len(fields[4]) != len(fields[5]) {
		t.Fatalf("magic %q mask %q", fields[4], fields[5])
	}
	entry := "enabled\ninterpreter /opt/x/qemu-x86_64\nflags: POCF\noffset 0\nmagic 7f454c46\nmask ffffffff\n"
	if !binfmtEntryCurrent([]byte(entry), "/opt/x/qemu-x86_64") {
		t.Fatal("the registered entry does not read as current")
	}
	for _, stale := range []string{
		strings.Replace(entry, "enabled", "disabled", 1),
		strings.Replace(entry, "flags: POCF", "flags: F", 1),
		strings.Replace(entry, "/opt/x/qemu-x86_64", "/usr/bin/qemu-x86_64-static", 1),
	} {
		if binfmtEntryCurrent([]byte(stale), "/opt/x/qemu-x86_64") {
			t.Errorf("stale entry %q reads as current", stale)
		}
	}
}

// The probe is a well-formed x86-64 executable whose one segment holds its
// entry point, and binfmt_misc's rule matches its header.
func TestX8664ProbeIsAnX8664Executable(t *testing.T) {
	p := x8664Probe
	if len(p) != 132 || string(p[:4]) != "\x7fELF" || p[4] != 2 || p[5] != 1 {
		t.Fatalf("not a 64-bit little-endian ELF: % x", p[:8])
	}
	if typ, machine := binary.LittleEndian.Uint16(p[16:]), binary.LittleEndian.Uint16(p[18:]); typ != 2 || machine != 0x3e {
		t.Fatalf("type %d machine %#x, want ET_EXEC EM_X86_64", typ, machine)
	}
	entry, phoff := binary.LittleEndian.Uint64(p[24:]), binary.LittleEndian.Uint64(p[32:])
	vaddr, filesz := binary.LittleEndian.Uint64(p[phoff+16:]), binary.LittleEndian.Uint64(p[phoff+32:])
	if entry < vaddr || entry >= vaddr+filesz || filesz != uint64(len(p)) {
		t.Fatalf("entry %#x outside the segment %#x+%d", entry, vaddr, filesz)
	}
	// mov eax, 60; mov edi, 42; syscall
	if code := p[entry-vaddr:]; string(code) != "\xb8\x3c\x00\x00\x00\xbf\x2a\x00\x00\x00\x0f\x05" {
		t.Fatalf("code % x", code)
	}
	magic, mask := decodeBinfmtBytes(t, x8664Magic), decodeBinfmtBytes(t, x8664Mask)
	for i := range magic {
		if p[i]&mask[i] != magic[i]&mask[i] {
			t.Fatalf("byte %d of the probe (%#x) does not match the rule", i, p[i])
		}
	}
}

func decodeBinfmtBytes(t *testing.T, escaped string) []byte {
	t.Helper()
	var out []byte
	for _, part := range strings.Split(escaped, `\x`)[1:] {
		var b byte
		for _, c := range part {
			b <<= 4
			switch {
			case c >= '0' && c <= '9':
				b |= byte(c - '0')
			case c >= 'a' && c <= 'f':
				b |= byte(c-'a') + 10
			default:
				t.Fatalf("bad escape %q", part)
			}
		}
		out = append(out, b)
	}
	return out
}

// Registration in a real binfmt_misc, when the test runs as root in the
// machine: it registers, keeps an identical entry, replaces a stale one, runs
// the probe, and unregisters. It needs the shipped interpreter.
func TestRegisterBinfmtInTheGuest(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("needs root in the machine")
	}
	if err := executableFile(qemuX8664Path); err != nil {
		t.Skipf("no interpreter: %v", err)
	}
	if err := mountBinfmt(binfmtMount); err != nil {
		t.Skipf("no binfmt_misc: %v", err)
	}
	entry := binfmtMount + "/" + binfmtEntryName
	before, hadEntry := os.ReadFile(entry)
	t.Cleanup(func() {
		// Leave the machine as the engine had it.
		if hadEntry == nil && binfmtEntryCurrent(before, qemuX8664Path) {
			_ = registerBinfmt(binfmtMount, qemuX8664Path)
		}
	})
	if err := registerBinfmt(binfmtMount, qemuX8664Path); err != nil {
		t.Fatal(err)
	}
	if err := registerBinfmt(binfmtMount, qemuX8664Path); err != nil {
		t.Fatalf("an identical entry was not kept: %v", err)
	}
	if err := probeAmd64(context.Background()); err != nil {
		t.Fatalf("the probe did not run: %v", err)
	}
	if err := unregisterBinfmt(binfmtMount); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(entry); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the entry is still there: %v", err)
	}
	if err := probeAmd64(context.Background()); err == nil {
		t.Fatal("the probe ran with no interpreter registered")
	}
}

// With emulation available, every Docker spelling of linux/amd64 (and the v2
// and v3 levels) is accepted and normalized; other platforms are still
// refused, naming both platforms the engine runs.
func TestRequestedPlatformWithEmulation(t *testing.T) {
	withEmulation(t, qemuEmulation)
	for raw, want := range map[string]string{
		"linux/amd64": "linux/amd64", "amd64": "linux/amd64", "linux/x86_64": "linux/amd64", "x86_64": "linux/amd64",
		"linux/x86-64": "linux/amd64", "LINUX/AMD64": "linux/amd64", "linux/amd64/v1": "linux/amd64",
		"linux/amd64/v2": "linux/amd64/v2", "linux/amd64/v3": "linux/amd64/v3",
		"linux/arm64": "linux/arm64", "arm64": "linux/arm64", "linux/aarch64": "linux/arm64",
	} {
		p, err := requestedPlatform(raw)
		if err != nil || p == nil || formatPlatform(*p) != want {
			t.Errorf("%q = %v, %v; want %s", raw, p, err, want)
		}
	}
	if p, err := requestedPlatform(""); p != nil || err != nil {
		t.Errorf("no platform = %v, %v", p, err)
	}
	for _, raw := range []string{"linux/amd64/v4", "linux/386", "linux/arm/v7", "linux/s390x", "windows/amd64"} {
		var problem apiError
		_, err := requestedPlatform(raw)
		if !errors.As(err, &problem) || problem.code != http.StatusBadRequest ||
			!strings.Contains(problem.message, "this engine runs linux/arm64 images, and linux/amd64 images through x86-64 emulation") {
			t.Errorf("%q: %v", raw, err)
		}
	}
	if got := enginePlatforms(); len(got) != 2 || got[1] != "linux/amd64" {
		t.Errorf("platforms %v", got)
	}
}

// Without emulation linux/amd64 is refused naming why it is unavailable.
func TestRequestedPlatformWithoutEmulation(t *testing.T) {
	withEmulation(t, &amd64Emulation{Reason: "x86-64 emulation is off: the machine sets micropod.amd64=off"})
	var problem apiError
	_, err := requestedPlatform("linux/amd64")
	if !errors.As(err, &problem) || problem.code != http.StatusBadRequest ||
		!strings.HasPrefix(problem.message, "unsupported platform linux/amd64: this engine runs linux/arm64 images only (x86-64 emulation is off: the machine sets micropod.amd64=off)") {
		t.Fatalf("amd64 without emulation: %v", err)
	}
	if got := enginePlatforms(); len(got) != 1 {
		t.Errorf("platforms %v", got)
	}
	if runs, why := runsHere(amd64Platform); runs || !strings.Contains(why, "micropod.amd64=off") {
		t.Errorf("an amd64 image runs: %v %q", runs, why)
	}
}

func formatPlatform(p ocispec.Platform) string {
	s := p.OS + "/" + p.Architecture
	if p.Variant != "" {
		s += "/" + p.Variant
	}
	return s
}
