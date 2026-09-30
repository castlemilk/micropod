//go:build linux

package main

import (
	"os"
	"os/signal"
	"syscall"
)

// idle is a sandbox's main process when it has nothing to run: it waits for
// SIGTERM/SIGINT (exit 0) and, as the container's PID 1, reaps the
// orphans that processes started in the sandbox leave behind.
func idle() error {
	signals := make(chan os.Signal, 16)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGCHLD)
	for sig := range signals {
		if sig != syscall.SIGCHLD {
			return nil
		}
		for {
			var status syscall.WaitStatus
			pid, err := syscall.Wait4(-1, &status, syscall.WNOHANG, nil)
			if pid <= 0 || err != nil {
				break
			}
		}
	}
	return nil
}
