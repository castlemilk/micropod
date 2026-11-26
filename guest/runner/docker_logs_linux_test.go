package main

import (
	"bufio"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

func TestDockerLoggingDriverRejectsUnsupportedOptions(t *testing.T) {
	for _, raw := range []string{
		`{"Image":"a"}`,
		`{"Image":"a","HostConfig":{"LogConfig":{"Type":"","Config":{}}}}`,
		`{"Image":"a","HostConfig":{"LogConfig":{"Type":"json-file","Config":null}}}`,
	} {
		cfg, err := parseDockerConfig([]byte(raw))
		if err != nil || cfg.HostConfig.LogConfig.Type != dockerDefaultLogDriver || cfg.HostConfig.LogConfig.Config == nil {
			t.Fatalf("invalid default %v: %v", cfg.HostConfig.LogConfig, err)
		}
	}
	for _, tc := range []struct{ input, want string }{
		{`{"Type":"none"}`, `driver "none"`},
		{`{"Type":"local"}`, `driver "local"`},
		{`{"Type":"json-file","Config":{"max-size":"32m"}}`, `log option "max-size"`},
		{`{"Config":{"mode":"non-blocking"}}`, `log option "mode"`},
		{`{"Config":{"compress":""}}`, `log option "compress"`},
		{`{"Other":false}`, `configuration field "Other"`},
	} {
		body := `{"Image":"a","HostConfig":{"LogConfig":` + tc.input + `}}`
		if _, err := parseDockerConfig([]byte(body)); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Fatalf("invalid config %s: %v", tc.input, err)
		}
	}
}

type partialDockerOutputFile struct {
	*os.File
	writes int
}

func (f *partialDockerOutputFile) Write(data []byte) (int, error) {
	f.writes++
	if f.writes == 2 {
		n, _ := f.File.Write(data[:9])
		return n, unix.ENOSPC
	}
	return f.File.Write(data)
}

func TestDockerLogWriteFailureKeepsCompletePrefixAndExit(t *testing.T) {
	f, err := os.CreateTemp(t.TempDir(), "output")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	partial := &partialDockerOutputFile{File: f}
	s := &dockerEngine{}
	c := &dockerContainer{dockerRecord: dockerRecord{Exit: 23}, changed: make(chan struct{})}
	write, seal := s.appendDockerOutput(c, partial, 0)
	for _, body := range []string{"complete", "interrupted", "discarded"} {
		if err := write("stdout", []byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	want := appendOutputFrame(nil, 1, []byte("complete"))
	size, durable := seal()
	if size != int64(len(want)) || !durable || c.outputBytes != size || c.Exit != 23 || c.Failure != "" || partial.writes != 2 {
		t.Fatalf("failed log changed the exit or committed offset: %+v offset %d durable %v writes %d", c.waitStatus(), size, durable, partial.writes)
	}
	got, err := os.ReadFile(f.Name())
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("partial record was published: %x %v", got, err)
	}
	var notice bytes.Buffer
	if err := sendDockerLogError(&notice, false, c.LogError); err != nil {
		t.Fatal(err)
	}
	if notice.Bytes()[0] != 2 || !bytes.Contains(notice.Bytes(), []byte("no space left on device")) || c.generationLogError == "" {
		t.Fatalf("log loss was not visible on stderr: %q", notice.Bytes())
	}
}

func TestDockerLogRecoveryKeepsLegacyAndTrimsTornTail(t *testing.T) {
	old := appendOutputFrame(nil, 1, []byte("legacy\x00\r\n"))
	last := appendOutputFrame(nil, 2, []byte("complete\x7f\r\n"))
	valid := append(append([]byte(nil), old...), last...)
	for _, tc := range []struct {
		name   string
		offset int64
		tail   []byte
	}{
		{name: "legacy"},
		{name: "torn header", offset: int64(len(old)), tail: []byte{1, 0, 0}},
		{name: "torn payload", offset: int64(len(valid)), tail: appendOutputFrame(nil, 1, []byte("not durable"))[:10]},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			spool := filepath.Join(dir, dockerOutputName)
			if err := os.WriteFile(spool, append(append([]byte(nil), valid...), tc.tail...), 0600); err != nil {
				t.Fatal(err)
			}
			c := &dockerContainer{dockerRecord: dockerRecord{LogOffset: tc.offset, Phase: "exited", Exit: 29}, changed: make(chan struct{})}
			if err := c.recoverDockerOutput(dir); err != nil {
				t.Fatal(err)
			}
			if c.outputBytes != int64(len(valid)) || c.LogOffset != c.outputBytes || c.Exit != 29 || (c.LogError != "") != (tc.tail != nil) {
				t.Fatalf("unexpected recovered log and state: %+v", c.waitStatus())
			}
			f, err := os.OpenFile(spool, os.O_WRONLY|os.O_APPEND, 0)
			if err != nil {
				t.Fatal(err)
			}
			write, _ := (&dockerEngine{}).appendDockerOutput(c, f, c.outputBytes)
			if err := write("stdout", []byte("replacement")); err != nil {
				t.Fatal(err)
			}
			if err := f.Close(); err != nil {
				t.Fatal(err)
			}
			f, err = os.Open(spool)
			if err != nil {
				t.Fatal(err)
			}
			defer f.Close()
			var replay bytes.Buffer
			read := bufio.NewReader(io.NewSectionReader(f, 0, c.outputBytes))
			want := appendOutputFrame(append([]byte(nil), valid...), 1, []byte("replacement"))
			if err := copyFrames(read, &replay, true, true); err != nil || !bytes.Equal(replay.Bytes(), want) {
				t.Fatalf("logs following recovery: %x %v", replay.Bytes(), err)
			}
		})
	}
}

func TestDockerLogRecoveryPersistsInvalidOffsetOnEmptyFile(t *testing.T) {
	root := t.TempDir()
	id := strings.Repeat("a", 64)
	dir := filepath.Join(root, id)
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, dockerOutputName), nil, 0600); err != nil {
		t.Fatal(err)
	}
	old := dockerRecord{ID: id, Name: "recovered", Phase: "exited", Exit: 29, LogOffset: 1234}
	if err := old.saveIn(dir); err != nil {
		t.Fatal(err)
	}
	c, err := loadDockerRecord(root, id)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.recoverDockerOutput(dir); err != nil {
		t.Fatal(err)
	}
	reloaded, err := loadDockerRecord(root, id)
	if err != nil || c.outputBytes != 0 || reloaded.LogOffset != 0 || reloaded.Exit != 29 ||
		!strings.Contains(reloaded.LogError, "shorter than its last saved offset") {
		t.Fatalf("invalid checkpoint correction was not durable: %+v %v", reloaded, err)
	}
}

func TestDockerLogCustomDeviceMountKeepsCRICompatibility(t *testing.T) {
	for _, tc := range []struct {
		json string
		raw  bool
	}{
		{`{"Image":"a"}`, true},
		{`{"Image":"a","HostConfig":{"Tmpfs":{"/dev/shm":""}}}`, true},
		{`{"Image":"a","HostConfig":{"Tmpfs":{"/dev":"mode=755"}}}`, false},
		{`{"Image":"a","HostConfig":{"Mounts":[{"Type":"bind","Source":"/owned","Target":"/dev"}]}}`, false},
		{`{"Image":"a","Tty":true,"HostConfig":{"Tmpfs":{"/dev":"mode=755"}}}`, true},
	} {
		config, err := parseDockerConfig([]byte(tc.json))
		if err != nil || config.captureRawOutput() != tc.raw {
			t.Errorf("raw capture for %s: %v %v", tc.json, config.captureRawOutput(), err)
		}
	}
}

func TestDockerLogDiskCRIOutputExceedsStandaloneCap(t *testing.T) {
	const count = 560
	body := bytes.Repeat([]byte{'x'}, 16<<10)
	record := append([]byte("t stdout P "), body...)
	record = append(record, '\n')
	physical := bytes.Repeat(record, count)
	var written int
	output := criOutput{reader: bufio.NewReader(bytes.NewReader(physical)), diskBacked: true}
	err := output.drain(func(stream string, data []byte) error {
		if stream != "stdout" || !bytes.Equal(data, body) {
			t.Fatal("disk CRI record changed")
		}
		written += len(data)
		return nil
	})
	if err != nil || written != len(body)*count {
		t.Fatalf("disk CRI output stopped at %d bytes: %v", written, err)
	}
	output = criOutput{reader: bufio.NewReader(bytes.NewReader(physical))}
	if err := output.drain(func(string, []byte) error { return nil }); err == nil || !strings.Contains(err.Error(), "8 MiB") {
		t.Fatalf("standalone CRI cap changed: %v", err)
	}
}
