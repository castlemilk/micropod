//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

func newDiskGrower(dev, tools string) diskGrower {
	return diskGrower{
		dev: dev, tools: tools, geometry: readExt4Geometry, size: blockDeviceBytes,
		replay: func(dev string) error {
			if err := os.MkdirAll(diskGrowMount, 0700); err != nil {
				return err
			}
			if err := syscall.Mount(dev, diskGrowMount, "ext4", syscall.MS_NOATIME, ""); err != nil {
				return fmt.Errorf("mount %s: %w", dev, err)
			}
			if err := syscall.Unmount(diskGrowMount, 0); err != nil {
				return fmt.Errorf("unmount %s: %w", dev, err)
			}
			return nil
		},
		run: func(tool string, args ...string) (int, error) {
			lib := filepath.Join(tools, "e2fsprogs", "lib")
			argv := append([]string{"--library-path", lib, filepath.Join(tools, "e2fsprogs", tool)}, args...)
			cmd := exec.Command(muslLoader, argv...)
			cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
			err := cmd.Run()
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				return exit.ExitCode(), nil
			}
			return 0, err
		},
		log: func(format string, args ...any) { fmt.Printf("[mp-hvf-init] disk grow: "+format+"\n", args...) },
	}
}

// growDiskAndPowerOff is a maintenance boot: it grows the second disk, says
// how it went on the console, and powers the machine off. It never returns.
func growDiskAndPowerOff() {
	before, after, err := newDiskGrower(diskGrowDevice, toolsDir).grow()
	if err != nil {
		fmt.Printf("%s %s\n", diskGrowFailed, strings.ReplaceAll(err.Error(), "\n", " "))
	} else {
		fmt.Printf("%s blocks=%d->%d block_size=%d\n", diskGrowOK, before.blocks, after.blocks, after.blockSize)
	}
	syscall.Sync()
	_ = syscall.Unmount(toolsDir, syscall.MNT_DETACH)
	_ = syscall.Mount("", "/", "", syscall.MS_REMOUNT|syscall.MS_RDONLY, "")
	syscall.Sync()
	_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
	os.Exit(1)
}
