package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sync"
)

const dockerDefaultLogDriver = "json-file"
const dockerOutputName = "output"
const dockerRuntimeLogName = "runtime.log"

type dockerLogConfig struct {
	Type   string
	Config map[string]string
}

func (c dockerLogConfig) withDefault() dockerLogConfig {
	if c.Type == "" {
		c.Type = dockerDefaultLogDriver
	}
	if c.Config == nil {
		c.Config = map[string]string{}
	}
	return c
}

func (c dockerLogConfig) validate() error {
	if c.Type != dockerDefaultLogDriver {
		return fmt.Errorf("Docker log driver %q is unsupported. Use json-file without log options", c.Type)
	}
	for key := range c.Config {
		return fmt.Errorf("json-file log option %q is unsupported. Omit --log-opt to retain logs until container removal", key)
	}
	return nil
}

func (c *dockerContainer) logPath() string { return filepath.Join(c.dir(), dockerOutputName) }

func removeDockerRuntimeLog(directory string) error {
	err := os.Remove(filepath.Join(directory, dockerRuntimeLogName))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

type dockerLogWatermark struct {
	end                           int64
	historyError, generationError string
}

func (c *dockerContainer) logWatermark() dockerLogWatermark {
	return dockerLogWatermark{c.outputBytes, c.LogError, c.generationLogError}
}

// appendDockerOutput owns one generation's writer. It publishes offsets only
// after complete frames are readable by independent attached clients.
func (s *dockerEngine) appendDockerOutput(c *dockerContainer, f dockerOutputFile, offset int64) (outputSink, func() (int64, bool)) {
	frame := make([]byte, 8, 8+(32<<10))
	initialOffset := offset
	dropped := false
	var mu sync.Mutex
	recordError := func(err error) {
		log.Printf("Docker container %s log: %v", c.ID, err)
		s.mu.Lock()
		defer s.mu.Unlock()
		if c.generationLogError == "" {
			c.generationLogError = err.Error()
		}
		if c.LogError == "" {
			c.LogError = err.Error()
		}
		c.signal()
	}
	// The writer serializes stdout and stderr. Readers only refer to the
	// published offsets, and the caller seals after both copies have returned.
	write := func(stream string, data []byte) error {
		mu.Lock()
		defer mu.Unlock()
		if dropped || len(data) == 0 {
			return nil
		}
		frame[0] = 1
		if stream == "stderr" {
			frame[0] = 2
		}
		binary.BigEndian.PutUint32(frame[4:], uint32(len(data)))
		record := append(frame[:8], data...)
		if n, err := f.Write(record); err != nil || n != len(record) {
			if err == nil {
				err = io.ErrShortWrite
			}
			dropped = true
			if n != 0 {
				err = errors.Join(err, f.Truncate(offset))
			}
			recordError(err)
			// Keep reading the process's pipes after a logging failure. The
			// runtime's real exit stays available through wait and inspect.
			return nil
		}
		offset += int64(len(record))
		s.mu.Lock()
		c.outputBytes = offset
		c.signal()
		s.mu.Unlock()
		return nil
	}
	seal := func() (int64, bool) {
		if c.Config.HostConfig.AutoRemove || offset == initialOffset {
			return 0, false
		}
		// The record that holds this offset is saved durably next (the exit's
		// save). Written out first, the log is durable with that save's one
		// journal commit, never after the offset that covers it (writeOut).
		if err := writeOutput(f); err != nil {
			recordError(err)
			return 0, false
		}
		return offset, true
	}
	return write, seal
}

// writeOutput is writeOut for the log file, Sync for any other writer.
func writeOutput(f dockerOutputFile) error {
	if file, ok := f.(*os.File); ok {
		return writeOut(file)
	}
	return f.Sync()
}

type dockerOutputFile interface {
	io.Writer
	Truncate(int64) error
	Sync() error
}

// A completed retained generation writes its log out before the durable save
// of its offset (writeOutput), so the offset never covers bytes a crash lost.
// Older catalogs have offset zero. Scan only the suffix after a valid offset,
// using bounded storage, then trim a frame interrupted by a worker crash.
func (c *dockerContainer) recoverDockerOutput(directory string) error {
	f, err := os.OpenFile(filepath.Join(directory, dockerOutputName), os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	end := info.Size()
	base := c.LogOffset
	validOffset := base >= 0 && base <= end
	if !validOffset {
		base = 0
		c.LogOffset = 0
		c.LogError = "log is shorter than its last saved offset"
	}
	if base == end && validOffset {
		c.outputBytes = end
		return nil
	}
	start := base
	r := bufio.NewReaderSize(io.NewSectionReader(f, base, end-base), 32<<10)
	for end-base >= 8 {
		var header [8]byte
		if _, err := io.ReadFull(r, header[:]); err != nil {
			return err
		}
		size := int64(binary.BigEndian.Uint32(header[4:]))
		if (header[0] != 1 && header[0] != 2) || !slices.Equal(header[1:4], []byte{0, 0, 0}) || size > end-base-8 {
			break
		}
		if _, err := io.CopyN(io.Discard, r, size); err != nil {
			return err
		}
		base += 8 + size
	}
	if base != end {
		if err := f.Truncate(base); err != nil {
			return err
		}
		if c.LogError == "" {
			c.LogError = "discarded an incomplete log frame during recovery"
		}
	}
	c.outputBytes = base
	if !validOffset || base != start || base != end {
		if err := f.Sync(); err != nil {
			return err
		}
		c.LogOffset = base
		return c.dockerRecord.saveIn(directory)
	}
	return nil
}
