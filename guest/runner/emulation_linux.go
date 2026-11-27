package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

// linux/amd64 containers on the arm64 machine.
//
// The kernel runs x86-64 programs through binfmt_misc: an x86-64 ELF's exec
// is handed to a registered interpreter that translates it. The engine picks
// one interpreter at start, before it opens its socket and before buildkitd
// can start (BuildKit lists the platforms it can build by executing a test
// binary of each, once), and registers it with the flags Docker's own
// emulation uses:
//
//   - F (fix binary): the kernel opens the interpreter when it is registered
//     and keeps that file, so an exec in any container's mount namespace finds
//     it; no container needs the interpreter in its own root.
//   - O and C: the kernel passes the program as an open file and computes the
//     credentials from the program, not the interpreter, so a setuid-root
//     x86-64 program (sudo in a GitHub runner image) works as it does natively.
//     The interpreter then runs with those credentials and reads its own QEMU_*
//     environment variables, which a process that could already run such a
//     program as root in its container could use to the same end; nothing
//     reaches past the container. Docker Desktop registers with the same flags.
//   - P: argv[0] is the program's own, as the program passed it.
//
// The candidates, in order:
//
//  1. Rosetta for Linux, when a share mounts Apple's binary at rosettaPath.
//     Rosetta checks, through ioctls on its own executable, that the share is
//     Virtualization.framework's Rosetta directory share; micropod-vmm is a
//     Hypervisor.framework VMM and cannot provide that share without
//     impersonating Apple's, which this engine does not do
//     (docs/amd64-emulation.md). So no share is mounted today and this
//     candidate reports why it is unavailable.
//  2. qemu-x86_64 (QEMU user-mode emulation, a static build), shipped in the
//     guest tool bundle at qemuX8664Path.
//
// The kernel command line setting micropod.amd64=off turns it all off (the
// machine.json kernelArguments entry of the same text): pulls and creates for
// linux/amd64 are then refused, naming the setting.
//
// An emulated container is a container like any other: the same cache trust
// and read-only cache views, the same limits, the same family scoping and the
// same image store. Only its programs run through the interpreter.
const (
	amd64KernelSetting = "micropod.amd64"
	qemuX8664Path      = "/opt/micropod-oci/runner/emulators/qemu-x86_64"
	rosettaPath        = "/run/micropod/rosetta/rosetta"
	binfmtMount        = "/proc/sys/fs/binfmt_misc"
	binfmtEntryName    = "micropod-x86_64"
	binfmtFlags        = "POCF"
	binfmtFSMagic      = 0x42494e4d
	// The x86-64 ELF header bytes binfmt_misc matches (QEMU's own
	// binfmt.d/qemu-x86_64.conf): ELFCLASS64, little-endian, EM_X86_64,
	// ET_EXEC or ET_DYN.
	x8664Magic = `\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00`
	x8664Mask  = `\xff\xff\xff\xff\xff\xfe\xfe\xfc\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff`
)

// x8664Probe is a complete static x86-64 Linux program of 132 bytes: one
// program header and `mov eax, 60; mov edi, 42; syscall` (exit(42)). The
// engine runs it after registering an interpreter: only x86-64 code that
// actually ran exits 42.
var x8664Probe = []byte{
	0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x02, 0x00, 0x3e, 0x00, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x38, 0x00, 0x01, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb8, 0x3c, 0x00, 0x00, 0x00, 0xbf, 0x2a, 0x00,
	0x00, 0x00, 0x0f, 0x05,
}

// emulatorCandidate is one way to run x86-64 programs, and why it was or was
// not used.
type emulatorCandidate struct {
	Name        string `json:"name"`
	Interpreter string `json:"interpreter,omitempty"`
	Available   bool   `json:"available"`
	Reason      string `json:"reason,omitempty"`
}

// amd64Emulation is what the engine found at start. Emulator is "" when
// linux/amd64 is unavailable, and Reason then says why.
type amd64Emulation struct {
	Emulator    string              `json:"emulator,omitempty"`
	Interpreter string              `json:"interpreter,omitempty"`
	Reason      string              `json:"reason,omitempty"`
	Candidates  []emulatorCandidate `json:"candidates,omitempty"`
	// SetupMillis is how long selection, registration and the probe took.
	SetupMillis int64 `json:"setupMillis"`
}

func (e *amd64Emulation) available() bool { return e != nil && e.Emulator != "" }

func (e *amd64Emulation) unavailableReason() string {
	switch {
	case e == nil:
		return "x86-64 emulation is not set up on this engine"
	case e.Reason != "":
		return e.Reason
	default:
		return "no x86-64 emulator is registered"
	}
}

var engineEmulation atomic.Pointer[amd64Emulation]

// currentEmulation is the engine's emulation state; nil before setup (and in
// a private engine, which never sets it up).
func currentEmulation() *amd64Emulation { return engineEmulation.Load() }

// emulationEnv is what selection reads, so tests can run it without a guest.
type emulationEnv struct {
	cmdline    string
	executable func(path string) error
}

func hostEmulationEnv() emulationEnv {
	raw, _ := os.ReadFile("/proc/cmdline")
	return emulationEnv{cmdline: string(raw), executable: executableFile}
}

func executableFile(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !st.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", path)
	}
	if st.Mode().Perm()&0o111 == 0 {
		return fmt.Errorf("%s is not executable", path)
	}
	return nil
}

// amd64Setting reads micropod.amd64 from the kernel command line: "auto"
// (also the default when it is absent), "on" (the same as auto) or "off".
// The last occurrence wins, as the kernel's own parameters do.
func amd64Setting(cmdline string) (string, error) {
	setting := "auto"
	for _, field := range strings.Fields(cmdline) {
		value, ok := strings.CutPrefix(field, amd64KernelSetting+"=")
		if !ok {
			continue
		}
		switch value {
		case "auto", "on":
			setting = "auto"
		case "off":
			setting = "off"
		default:
			return "", fmt.Errorf("unknown %s=%s (want auto or off)", amd64KernelSetting, value)
		}
	}
	return setting, nil
}

// selectEmulator picks the first available candidate. It never registers
// anything; the result names every candidate and why each was or was not
// taken.
func selectEmulator(env emulationEnv) amd64Emulation {
	setting, err := amd64Setting(env.cmdline)
	if err != nil {
		return amd64Emulation{Reason: "x86-64 emulation is off: " + err.Error()}
	}
	if setting == "off" {
		return amd64Emulation{Reason: "x86-64 emulation is off: the machine sets " + amd64KernelSetting + "=off"}
	}
	rosetta := emulatorCandidate{Name: "rosetta", Interpreter: rosettaPath}
	if err := env.executable(rosettaPath); err != nil {
		rosetta.Reason = "no Rosetta share is mounted: Rosetta for Linux runs only in a Virtualization.framework " +
			"VM's Rosetta directory share, which this Hypervisor.framework machine does not have"
	} else {
		rosetta.Available = true
	}
	qemu := emulatorCandidate{Name: "qemu", Interpreter: qemuX8664Path}
	if err := env.executable(qemuX8664Path); err != nil {
		qemu.Reason = "the guest tool bundle ships no qemu-x86_64 (" + err.Error() + ")"
	} else {
		qemu.Available = true
	}
	e := amd64Emulation{Candidates: []emulatorCandidate{rosetta, qemu}}
	for _, c := range e.Candidates {
		if c.Available {
			e.Emulator, e.Interpreter = c.Name, c.Interpreter
			return e
		}
	}
	e.Reason = "no x86-64 emulator is available: " + rosetta.Reason + "; " + qemu.Reason
	return e
}

// setupAmd64Emulation selects, registers and proves an x86-64 interpreter, and
// publishes the result for the rest of the engine. A failure never stops the
// engine: linux/amd64 is then unavailable and says why.
func setupAmd64Emulation(ctx context.Context) *amd64Emulation {
	start := time.Now()
	e := selectEmulator(hostEmulationEnv())
	if e.available() {
		if err := registerBinfmt(binfmtMount, e.Interpreter); err != nil {
			e.Reason = fmt.Sprintf("x86-64 emulation is unavailable: registering %s with binfmt_misc failed: %v", e.Emulator, err)
			e.Emulator, e.Interpreter = "", ""
		} else if err := probeAmd64(ctx); err != nil {
			e.Reason = fmt.Sprintf("x86-64 emulation is unavailable: %s is registered but an x86-64 program did not run: %v", e.Emulator, err)
			e.Emulator, e.Interpreter = "", ""
			_ = unregisterBinfmt(binfmtMount)
		}
	} else if setting, _ := amd64Setting(hostEmulationEnv().cmdline); setting == "off" {
		// Off means off, also for an entry an earlier engine of this boot made.
		_ = unregisterBinfmt(binfmtMount)
	}
	e.SetupMillis = time.Since(start).Milliseconds()
	engineEmulation.Store(&e)
	if e.available() {
		log.Printf("linux/amd64 containers run through %s (%s), set up in %d ms", e.Emulator, e.Interpreter, e.SetupMillis)
	} else {
		log.Printf("linux/amd64 containers are unavailable: %s", e.Reason)
	}
	return &e
}

func binfmtMounted(dir string) bool {
	var st unix.Statfs_t
	return unix.Statfs(dir, &st) == nil && st.Type == binfmtFSMagic
}

func mountBinfmt(dir string) error {
	if binfmtMounted(dir) {
		return nil
	}
	if err := unix.Mount("binfmt_misc", dir, "binfmt_misc", unix.MS_NOSUID|unix.MS_NODEV|unix.MS_NOEXEC, ""); err != nil && !errors.Is(err, unix.EBUSY) {
		return fmt.Errorf("mount binfmt_misc: %w", err)
	}
	if !binfmtMounted(dir) {
		return errors.New("binfmt_misc is not mounted at " + dir)
	}
	return nil
}

func binfmtRule(interpreter string) string {
	return ":" + binfmtEntryName + ":M::" + x8664Magic + ":" + x8664Mask + ":" + interpreter + ":" + binfmtFlags
}

// binfmtEntryCurrent reports whether an entry (/proc/sys/fs/binfmt_misc/<name>
// as the kernel prints it) is enabled with this interpreter and these flags.
func binfmtEntryCurrent(entry []byte, interpreter string) bool {
	var enabled, interp, flags bool
	for _, line := range strings.Split(string(entry), "\n") {
		switch {
		case line == "enabled":
			enabled = true
		case line == "interpreter "+interpreter:
			interp = true
		case line == "flags: "+binfmtFlags:
			flags = true
		}
	}
	return enabled && interp && flags
}

// registerBinfmt registers the interpreter under binfmtEntryName, keeping an
// identical entry an earlier engine of this boot registered (binfmt_misc
// outlives the engine; the kernel already holds that interpreter open).
func registerBinfmt(dir, interpreter string) error {
	if err := mountBinfmt(dir); err != nil {
		return err
	}
	entry := filepath.Join(dir, binfmtEntryName)
	if current, err := os.ReadFile(entry); err == nil {
		if binfmtEntryCurrent(current, interpreter) {
			return nil
		}
		if err := os.WriteFile(entry, []byte("-1"), 0); err != nil {
			return fmt.Errorf("remove the earlier %s entry: %w", binfmtEntryName, err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "register"), []byte(binfmtRule(interpreter)), 0); err != nil {
		return fmt.Errorf("register %s: %w", interpreter, err)
	}
	current, err := os.ReadFile(entry)
	if err != nil {
		return fmt.Errorf("read back %s: %w", binfmtEntryName, err)
	}
	if !binfmtEntryCurrent(current, interpreter) {
		return fmt.Errorf("the kernel registered %s as %q", binfmtEntryName, bytes.TrimSpace(current))
	}
	return nil
}

func unregisterBinfmt(dir string) error {
	entry := filepath.Join(dir, binfmtEntryName)
	if _, err := os.Stat(entry); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return os.WriteFile(entry, []byte("-1"), 0)
}

// probeAmd64 runs x8664Probe through the registered interpreter.
func probeAmd64(ctx context.Context) error {
	dir, err := os.MkdirTemp("/run", "micropod-amd64-probe-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	probe := filepath.Join(dir, "probe")
	if err := os.WriteFile(probe, x8664Probe, 0o755); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, probe).CombinedOutput()
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 42 {
		return nil
	}
	if err == nil {
		return errors.New("the probe exited 0, not 42")
	}
	return fmt.Errorf("%w: %.256s", err, bytes.TrimSpace(out))
}
