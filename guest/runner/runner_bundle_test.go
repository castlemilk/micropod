package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// The runner bundle's start-up files (ci/runner), as the guest boots them.

// start.sh must start the engine right after containerd and let it wait for
// the CRI itself (awaitRuntime), with no `job status` poll or separate `job
// recover` in front of it.
func TestStartScriptStartsTheEngineBesideContainerd(t *testing.T) {
	b, err := os.ReadFile("../../ci/runner/start.sh")
	if err != nil {
		t.Fatal(err)
	}
	script := string(b)
	containerd := strings.Index(script, "exec containerd --config")
	engine := strings.Index(script, `"$tools/runner/bin/job" engine &`)
	if containerd < 0 || engine < containerd {
		t.Fatal("start.sh does not start the engine after containerd")
	}
	between := script[containerd:engine]
	if regexp.MustCompile(`job"? (status|recover)`).MatchString(between) || strings.Contains(between, "sleep") {
		t.Fatalf("start.sh waits for containerd before it starts the engine:\n%s", between)
	}
}

// containerd logs to the guest's serial console. At info level its start
// alone (a line per plugin) cost every boot ~25 ms.
func TestContainerdLogsOnlyWarningsAndErrors(t *testing.T) {
	b, err := os.ReadFile("../../ci/runner/containerd.toml")
	if err != nil {
		t.Fatal(err)
	}
	table, level := "", ""
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			table = line
			continue
		}
		if key, value, ok := strings.Cut(line, "="); ok && table == "[debug]" && strings.TrimSpace(key) == "level" {
			level = strings.Trim(strings.TrimSpace(value), `"`)
		}
	}
	if level != "warn" && level != "error" {
		t.Fatalf("containerd's [debug] level is %q, want warn", level)
	}
}
