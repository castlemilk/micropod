// workspacebench is the guest half of bench_workspace_edits.py.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

const original = "previous"
const revision = "revision"
const appended = original + revision

func marker(dir, name, value string) error {
	return os.WriteFile(filepath.Join(dir, name), []byte(value), 0600)
}

func contents(f *os.File, length int) (string, error) {
	var b [len(appended)]byte
	n, err := f.ReadAt(b[:length], 0)
	if err != nil && err != io.EOF {
		return "", err
	}
	return string(b[:n]), nil
}

func observe(dir, kind string, index int) error {
	key := fmt.Sprintf("%s-%d", kind, index)
	path := filepath.Join(dir, key)
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	startValue, err := contents(f, len(original))
	if err != nil || startValue != original {
		return fmt.Errorf("%s initial value %q, error %v", key, startValue, err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Size() != int64(len(original)) {
		return fmt.Errorf("%s initial stat: %v", key, err)
	}
	if err := marker(dir, key+".ready", "1"); err != nil {
		return err
	}
	var seen bool
	until := time.Now().Add(1800 * time.Millisecond)
	for time.Now().Before(until) {
		switch kind {
		case "size":
			var i os.FileInfo
			i, err = os.Stat(path)
			seen = err == nil && i.Size() == int64(len(appended))
		case "held":
			var data string
			// A read beyond the original EOF can revalidate Linux FUSE metadata
			// and mask whether the existing handle observed a same-size edit.
			data, err = contents(f, len(original))
			seen = data == revision
		case "replace":
			var data []byte
			data, err = os.ReadFile(path)
			seen = string(data) == revision
		case "unlink":
			_, err = os.Stat(path)
			if errors.Is(err, os.ErrNotExist) {
				err = nil
				seen = true
			}
		}
		if err != nil {
			return fmt.Errorf("%s: %w", key, err)
		}
		if seen {
			// Verify the other view only after detection so it cannot revalidate
			// the view being measured before the edit becomes visible there.
			switch kind {
			case "size":
				value, readErr := contents(f, len(appended))
				if readErr != nil || value != appended {
					return marker(dir, key+".done", "append-data-mismatch")
				}
			case "held":
				data, readErr := os.ReadFile(path)
				if readErr != nil || string(data) != revision {
					return marker(dir, key+".done", "path-data-mismatch")
				}
			case "replace", "unlink":
				old, readErr := contents(f, len(original))
				if readErr != nil || old != original {
					return marker(dir, key+".done", "old-handle-changed")
				}
			}
			return marker(dir, key+".done", "observed")
		}
		time.Sleep(time.Millisecond)
	}
	return marker(dir, key+".done", "timeout")
}

func run(dir string, rounds int) error {
	for i := 0; i < rounds; i++ {
		for _, kind := range []string{"size", "held", "replace", "unlink"} {
			if err := observe(dir, kind, i); err != nil {
				return err
			}
		}
	}
	return nil
}

func scan(dir string) error {
	type pass struct {
		Pass       int     `json:"pass"`
		PauseMS    int64   `json:"scheduled_pause_ms"`
		Files      int     `json:"files"`
		Bytes      int64   `json:"bytes"`
		ReadBytes  int64   `json:"read_bytes"`
		WalkMS     float64 `json:"stat_ms"`
		ReadMS     float64 `json:"read_ms"`
		Digest     string  `json:"sha256"`
		PathDigest string  `json:"path_sha256"`
	}
	results := make([]pass, 0, 3)
	for i, delay := range []time.Duration{0, 0, 50 * time.Millisecond} {
		time.Sleep(delay)
		result := pass{Pass: i + 1, PauseMS: delay.Milliseconds()}
		var files []string
		start := time.Now()
		err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
			if err != nil || entry.IsDir() {
				return err
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if !info.Mode().IsRegular() {
				return fmt.Errorf("workspace file %q is not regular", path)
			}
			files = append(files, path)
			result.Bytes += info.Size()
			return nil
		})
		if err != nil {
			return err
		}
		result.WalkMS = float64(time.Since(start).Microseconds()) / 1000
		result.Files = len(files)
		start = time.Now()
		digest := sha256.New()
		for _, path := range files {
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			result.ReadBytes += int64(len(data))
			digest.Write(data)
		}
		result.ReadMS = float64(time.Since(start).Microseconds()) / 1000
		result.Digest = fmt.Sprintf("%x", digest.Sum(nil))
		paths := sha256.New()
		for _, path := range files {
			rel, err := filepath.Rel(dir, path)
			if err != nil {
				return err
			}
			paths.Write([]byte(filepath.ToSlash(rel)))
			paths.Write([]byte{0})
		}
		result.PathDigest = fmt.Sprintf("%x", paths.Sum(nil))
		results = append(results, result)
	}
	return json.NewEncoder(os.Stdout).Encode(results)
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: workspacebench DIRECTORY ROUNDS | workspacebench scan DIRECTORY")
		os.Exit(2)
	}
	if os.Args[1] == "scan" {
		if err := scan(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	n, err := strconv.Atoi(os.Args[2])
	if err != nil || n < 1 || n > 100 {
		fmt.Fprintln(os.Stderr, "rounds must be between 1 and 100")
		os.Exit(2)
	}
	if err := run(os.Args[1], n); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
