package main

import (
	"os"
	"path/filepath"
	"sync"
)

// toolsDir is where the tool bundle share is mounted.
const toolsDir = "/opt/micropod-oci"

// bootTools are the tool bundle's files that start.sh runs before the engine
// can answer: containerd, the engine (runner/bin/job), the OCI service, and
// what containerd's CRI runs while it starts (the runc shim and crun, for the
// runtime's features). Globs, so a new crun version is still found.
var bootTools = []string{
	"runner/bin/containerd",
	"runner/bin/job",
	"runner/bin/containerd-shim-runc-v2",
	"service",
	"crun-*",
}

// prefetchTools reads every file the patterns name under dir once, all at
// the same time, and returns the bytes read; what is missing or unreadable
// is skipped. Guest init runs it as soon as the tool bundle is mounted, so
// the page cache holds them by the time start.sh runs them. A boot's page
// cache starts empty, and executing them read them a page fault at a time
// over the share: containerd's start (36 MB) waited on that, and the
// engine's (28 MB), ~20 ms of every boot and payload switchover. Read in
// parallel ahead of time, they take ~12 ms while guest init still sets up
// the network and start.sh its cgroups.
func prefetchTools(dir string, patterns []string) int64 {
	var files []string
	for _, pattern := range patterns {
		matches, _ := filepath.Glob(filepath.Join(dir, pattern))
		files = append(files, matches...)
	}
	var mu sync.Mutex
	var total int64
	var wg sync.WaitGroup
	for _, file := range files {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// Regular files only: opening a FIFO would block.
			if st, err := os.Lstat(file); err != nil || !st.Mode().IsRegular() {
				return
			}
			f, err := os.Open(file)
			if err != nil {
				return
			}
			defer f.Close()
			// Large reads: each is one request over the share.
			buf := make([]byte, 1<<20)
			var n int64
			for {
				read, err := f.Read(buf)
				n += int64(read)
				if err != nil {
					break
				}
			}
			mu.Lock()
			total += n
			mu.Unlock()
		}()
	}
	wg.Wait()
	return total
}
