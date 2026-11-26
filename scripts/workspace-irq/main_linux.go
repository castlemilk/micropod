// workspace-irq is a dormant, one-transaction probe for a disposable HVF guest.
package main

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type device struct {
	Virtio string `json:"virtio_device"`
	MMIO   string `json:"mmio_device"`
	IRQ    int    `json:"linux_irq"`
	SPI    uint32 `json:"gic_intid"`
}

type snapshot struct {
	UTC           time.Time         `json:"utc"`
	RequestedMask string            `json:"requested_mask"`
	RequestedList string            `json:"requested_list"`
	EffectiveList string            `json:"effective_list"`
	Interrupts    map[string]uint64 `json:"interrupts"`
}

type phase struct {
	Action string    `json:"action"`
	Device device    `json:"device"`
	Before snapshot  `json:"before"`
	After  *snapshot `json:"after,omitempty"`
}

func readText(path string) (string, error) {
	data, err := os.ReadFile(path)
	return strings.TrimSpace(string(data)), err
}

func interruptRow(name string) (int, map[string]uint64, error) {
	text, err := readText("/proc/interrupts")
	if err != nil {
		return 0, nil, err
	}
	lines := strings.Split(text, "\n")
	cpus := strings.Fields(lines[0])
	if strings.Join(cpus, " ") != "CPU0 CPU1 CPU2 CPU3" {
		return 0, nil, fmt.Errorf("unexpected interrupt CPU columns %v", cpus)
	}
	var irq int
	var counts map[string]uint64
	for _, line := range lines[1:] {
		fields := strings.Fields(line)
		if len(fields) < len(cpus)+4 || fields[len(fields)-1] != name {
			continue
		}
		if irq != 0 || strings.Contains(line, ",") || fields[len(cpus)+1] != "GICv3" {
			return 0, nil, fmt.Errorf("ambiguous GICv3 interrupt for %s", name)
		}
		irq, err = strconv.Atoi(strings.TrimSuffix(fields[0], ":"))
		if err != nil || irq <= 0 {
			return 0, nil, fmt.Errorf("invalid Linux interrupt in %q", line)
		}
		counts = make(map[string]uint64, len(cpus))
		for index, cpu := range cpus {
			counts[cpu], err = strconv.ParseUint(fields[index+1], 10, 64)
			if err != nil {
				return 0, nil, err
			}
		}
	}
	if irq == 0 {
		return 0, nil, fmt.Errorf("missing interrupt action %s", name)
	}
	return irq, counts, nil
}

func discover() (device, map[string]uint64, error) {
	var result device
	var match string
	tags, err := filepath.Glob("/sys/fs/virtiofs/*/tag")
	if err != nil {
		return result, nil, err
	}
	for _, file := range tags {
		tag, err := readText(file)
		if err != nil {
			return result, nil, err
		}
		if tag == "workspace" {
			if match != "" {
				return result, nil, errors.New("multiple workspace tags")
			}
			match = filepath.Dir(file)
		}
	}
	if match == "" {
		return result, nil, errors.New("no workspace tag in virtiofs sysfs")
	}
	virtio, err := filepath.EvalSymlinks(filepath.Join(match, "device"))
	if err != nil || !strings.HasPrefix(virtio, "/sys/devices/platform/") {
		return result, nil, fmt.Errorf("unexpected workspace device %q: %v", virtio, err)
	}
	mmio := filepath.Dir(virtio)
	driver, err := filepath.EvalSymlinks(filepath.Join(mmio, "driver"))
	if err != nil || driver != "/sys/bus/platform/drivers/virtio-mmio" {
		return result, nil, fmt.Errorf("unexpected MMIO driver %q: %v", driver, err)
	}
	irq, counts, err := interruptRow(filepath.Base(virtio))
	if err != nil {
		return result, nil, err
	}
	dt, err := os.ReadFile(filepath.Join(mmio, "of_node", "interrupts"))
	if err != nil || len(dt) != 12 || binary.BigEndian.Uint32(dt[:4]) != 0 {
		return result, nil, errors.New("workspace device tree does not contain one GIC SPI")
	}
	spi := binary.BigEndian.Uint32(dt[4:8]) + 32
	irqSys := filepath.Join("/sys/kernel/irq", strconv.Itoa(irq))
	actions, err := readText(filepath.Join(irqSys, "actions"))
	if err != nil || actions != filepath.Base(virtio) {
		return result, nil, errors.New("workspace interrupt has an unexpected or shared action")
	}
	hwirq, err := readText(filepath.Join(irqSys, "hwirq"))
	if err != nil || hwirq != strconv.FormatUint(uint64(spi), 10) {
		return result, nil, fmt.Errorf("GIC ID %d from device tree differs from IRQ sysfs %q", spi, hwirq)
	}
	return device{Virtio: virtio, MMIO: mmio, IRQ: irq, SPI: spi}, counts, nil
}

func (d device) affinity(file string) string {
	return filepath.Join("/proc/irq", strconv.Itoa(d.IRQ), file)
}

func observe(d device, counts map[string]uint64) (snapshot, error) {
	s := snapshot{UTC: time.Now().UTC(), Interrupts: counts}
	for file, target := range map[string]*string{
		"smp_affinity": &s.RequestedMask, "smp_affinity_list": &s.RequestedList, "effective_affinity_list": &s.EffectiveList,
	} {
		value, err := readText(d.affinity(file))
		if err != nil || value == "" {
			return snapshot{}, fmt.Errorf("cannot read %s: %v", file, err)
		}
		*target = value
	}
	return s, nil
}

func sameRoute(a, b snapshot) bool {
	return a.RequestedMask == b.RequestedMask && a.RequestedList == b.RequestedList && a.EffectiveList == b.EffectiveList
}

func restoreRoute(original device, prior snapshot) (snapshot, error) {
	found, _, err := discover()
	if err != nil || found != original {
		return snapshot{}, fmt.Errorf("device changed before restore: %v", err)
	}
	if err = os.WriteFile(found.affinity("smp_affinity"), []byte(prior.RequestedMask+"\n"), 0); err != nil {
		return snapshot{}, err
	}
	_, counts, err := discover()
	if err != nil {
		return snapshot{}, err
	}
	after, err := observe(found, counts)
	if err != nil || !sameRoute(prior, after) {
		return after, fmt.Errorf("workspace interrupt did not return to its prior route: %v", err)
	}
	return after, nil
}

func publish(dir, name string, payload any) error {
	temp, err := os.CreateTemp(dir, ".report-")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	err = json.NewEncoder(temp).Encode(payload)
	if err = errors.Join(err, temp.Close()); err != nil {
		return err
	}
	return os.Link(temp.Name(), filepath.Join(dir, name))
}

func receive(path, token string) (string, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return "", errors.New("request is not a regular file")
	}
	defer os.Remove(path)
	data, err := io.ReadAll(io.LimitReader(file, 64))
	if err != nil {
		return "", err
	}
	for _, action := range []string{"begin", "route", "restore"} {
		if string(data) == token+" "+action+"\n" {
			return action, nil
		}
	}
	return "", errors.New("request token or action did not match")
}

func run(dir, token string) (err error) {
	if err := os.Mkdir(dir, 0o700); err != nil {
		return err
	}
	inbox := filepath.Join(dir, "inbox")
	if err := os.Mkdir(inbox, 0o700); err != nil {
		return err
	}
	fd, err := syscall.InotifyInit1(syscall.IN_CLOEXEC | syscall.IN_NONBLOCK)
	if err != nil {
		return err
	}
	watch := os.NewFile(uintptr(fd), "workspace-irq-inbox")
	defer watch.Close()
	if _, err = syscall.InotifyAddWatch(fd, inbox, syscall.IN_MOVED_TO); err != nil {
		return err
	}
	notify := make(chan error, 1)
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		var buf [4096]byte
		for {
			_, err := watch.Read(buf[:])
			select {
			case notify <- err:
			case <-stop:
				return
			}
			if err != nil {
				return
			}
		}
	}()
	if err = publish(dir, "ready.json", map[string]bool{"ready": true}); err != nil {
		return err
	}
	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(interrupt)
	var original device
	var prior snapshot
	var routed bool
	defer func() {
		if routed {
			after, restoreErr := restoreRoute(original, prior)
			err = errors.Join(err, restoreErr, publish(dir, "fallback-restore.json", map[string]any{
				"device": original, "before": prior, "after": after, "restored": restoreErr == nil,
			}))
		}
	}()
	var expires <-chan time.Time
	next := "begin"
	for {
		select {
		case <-interrupt:
			return errors.New("stopped by owner")
		case <-expires:
			return errors.New("timed out waiting for restore")
		case err := <-notify:
			if err != nil {
				return err
			}
		}
		action, err := receive(filepath.Join(inbox, "next"), token)
		if err != nil {
			return err
		}
		if action == "" {
			continue
		}
		if action != next {
			return fmt.Errorf("expected %s, received %s", next, action)
		}
		d, counts, err := discover()
		if err != nil {
			return err
		}
		if next != "begin" && d != original {
			return errors.New("workspace interrupt changed during transaction")
		}
		before, err := observe(d, counts)
		if err != nil {
			return err
		}
		result := phase{Action: action, Device: d, Before: before}
		switch action {
		case "begin":
			if before.EffectiveList != "0" {
				return fmt.Errorf("expected the workspace interrupt on vCPU0, got %q", before.EffectiveList)
			}
			original, prior, next = d, before, "route"
		case "route":
			if !sameRoute(prior, before) {
				return errors.New("workspace route changed before the experiment")
			}
			routed = true
			if err = os.WriteFile(d.affinity("smp_affinity_list"), []byte("1\n"), 0); err != nil {
				return err
			}
			found, counts, err := discover()
			if err != nil || found != d {
				return fmt.Errorf("workspace interrupt changed after route: %v", err)
			}
			after, err := observe(d, counts)
			if err != nil || after.RequestedList != "1" || after.EffectiveList != "1" {
				return fmt.Errorf("workspace interrupt did not route to vCPU1: %v", err)
			}
			result.After, next = &after, "restore"
			timer := time.NewTimer(180 * time.Second)
			defer timer.Stop()
			expires = timer.C
		case "restore":
			after, err := restoreRoute(d, prior)
			if err != nil {
				return err
			}
			routed, result.After = false, &after
			if before.EffectiveList != "1" || before.RequestedList != "1" {
				return errors.New("workspace interrupt route changed before restoration")
			}
		}
		if err = publish(dir, action+".json", result); err != nil {
			return err
		}
		if action == "restore" {
			return nil
		}
	}
}

func main() {
	workspace := os.Getenv("MICROPOD_ENGINE_WORKSPACE")
	if os.Geteuid() != 0 || !filepath.IsAbs(workspace) || filepath.Clean(workspace) != workspace || len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "workspace-irq requires the trusted disposable guest workspace and owner-token file")
		os.Exit(1)
	}
	token, err := readText(os.Args[1])
	_, tokenErr := hex.DecodeString(token)
	if err != nil || tokenErr != nil || len(token) != 32 || token != strings.ToLower(token) {
		fmt.Fprintln(os.Stderr, "workspace-irq has no valid owner token")
		os.Exit(1)
	}
	if err := run(filepath.Join(workspace, ".workspace-irq-owner"), token); err != nil {
		fmt.Fprintln(os.Stderr, "workspace-irq:", err)
		os.Exit(1)
	}
}
