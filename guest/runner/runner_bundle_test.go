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

// The OCI service runs a scheduler job the moment the host asks, and the
// engine's recovery (node.recover) removes every job directory and ready pod
// it finds. start.sh used to run `job recover` before it started either;
// with the recovery inside the engine, the service must not start until the
// engine has bound its Docker socket, which it does only after recovery.
func TestStartScriptStartsTheOCIServiceAfterTheEngineRecovered(t *testing.T) {
	b, err := os.ReadFile("../../ci/runner/start.sh")
	if err != nil {
		t.Fatal(err)
	}
	script := string(b)
	// dockerSocket (docker_engine_linux.go), where the engine listens.
	const dockerSocket = "/var/lib/micropod/docker.sock"
	clear := strings.Index(script, "rm -f "+dockerSocket+"\n")
	engine := strings.Index(script, `"$tools/runner/bin/job" engine &`)
	wait := strings.Index(script, "until [ -S "+dockerSocket+" ]; do")
	service := strings.Index(script, `"$tools/service" serve &`)
	if clear < 0 || engine < clear {
		t.Fatal("start.sh does not remove an earlier boot's Docker socket before it starts the engine")
	}
	if wait < engine || service < wait {
		t.Fatal("start.sh starts the OCI service without waiting for the engine's Docker socket")
	}
	loop := script[wait:service]
	done := strings.Index(loop, "\ndone\n")
	if done < 0 {
		t.Fatal("the wait for the engine's Docker socket does not end before the OCI service starts")
	}
	// A dead containerd or engine never binds the socket: the wait must end.
	for _, alive := range []string{`kill -0 "$engine"`, `kill -0 "$api"`} {
		if !strings.Contains(loop[:done], alive+" 2>/dev/null || exit 1") {
			t.Fatalf("the wait for the engine's Docker socket does not stop when %s fails", alive)
		}
	}
}
