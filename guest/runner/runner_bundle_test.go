package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"
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
	// A dead engine's own status (4 when its start-up outlasted its budget,
	// startup_watchdog.go) is the one start.sh exits with: guest init reports
	// it, and a fixed 1 would hide why the engine stopped.
	waiting := loop[:done]
	if !regexp.MustCompile(`kill -0 "\$engine" 2>/dev/null \|\| \{[^\n]*exit 1; \}`).MatchString(waiting) {
		t.Fatal(`the wait for the engine's Docker socket does not stop when kill -0 "$engine" fails`)
	}
	engineDied := regexp.MustCompile(`if ! kill -0 "\$api" 2>/dev/null; then\n((?:[^\n]*\n)*?)\s*fi\n`).FindStringSubmatch(waiting)
	if engineDied == nil {
		t.Fatal(`the wait for the engine's Docker socket does not stop when kill -0 "$api" fails`)
	}
	for _, step := range []string{`wait "$api" || status=$?`, `exit "$status"`} {
		if !strings.Contains(engineDied[1], step) {
			t.Fatalf("when the engine dies the wait does not exit with its status (no %s):\n%s", step, engineDied[1])
		}
	}
}

// start.sh serves until containerd, the engine or the OCI service exits, and
// then ends itself with a failure: guest init reports that and the supervisor
// relaunches the machine. Run its serving loop as the guest does (BusyBox ash)
// with three stand-ins, each in turn the one that dies, by exiting and by a
// SIGKILL from outside the shell (ash's `wait -n` misses that one, and with
// IDs it waits for all three). A stop's SIGTERM must still end it at once.
func TestStartScriptEndsWhenAnyServingProcessDies(t *testing.T) {
	if sh, err := filepath.EvalSymlinks("/bin/sh"); err != nil || filepath.Base(sh) != "busybox" {
		t.Skip("/bin/sh is not the guest's BusyBox ash")
	}
	b, err := os.ReadFile("../../ci/runner/start.sh")
	if err != nil {
		t.Fatal(err)
	}
	const marker = "\nstep=\"serving ("
	at := strings.LastIndex(string(b), marker)
	if at < 0 {
		t.Fatal("start.sh no longer names its serving step")
	}
	serving := string(b)[at:]
	// The stand-ins, as start.sh names its processes, their PIDs on stdout.
	const begin = "set -eu\ntrap 'kill $engine $service $api 2>/dev/null || true' EXIT\ntrap 'exit 0' TERM INT\n" +
		"sleep 60 &\nengine=$!\nsleep 60 &\nservice=$!\nsleep 60 &\napi=$!\necho $engine $service $api\n"
	run := func(t *testing.T, act func(shell *os.Process, pids []int)) (time.Duration, error) {
		ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "/bin/sh", "-c", begin+serving)
		cmd.WaitDelay = time.Second // the stand-ins outlive a killed shell and hold its output
		out, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		var pids [3]int
		if _, err := fmt.Fscan(out, &pids[0], &pids[1], &pids[2]); err != nil {
			t.Fatalf("read the stand-ins' PIDs: %v", err)
		}
		time.Sleep(300 * time.Millisecond) // inside the serving loop
		start := time.Now()
		act(cmd.Process, pids[:])
		err = cmd.Wait()
		return time.Since(start), err
	}
	for i, name := range []string{"containerd", "the OCI service", "the engine"} {
		for _, sig := range []syscall.Signal{syscall.SIGKILL, syscall.SIGTERM} {
			// SIGTERM ends a sleep as an exit would end a daemon: without a core or a kill.
			took, err := run(t, func(_ *os.Process, pids []int) { _ = syscall.Kill(pids[i], sig) })
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 1 || took > 5*time.Second {
				t.Fatalf("start.sh kept serving after %s alone died of %v (after %v: %v), want exit status 1", name, sig, took.Round(time.Millisecond), err)
			}
		}
	}
	took, err := run(t, func(shell *os.Process, _ []int) { _ = shell.Signal(syscall.SIGTERM) })
	if err != nil || took > 500*time.Millisecond {
		t.Fatalf("a stop's SIGTERM ended the serving start.sh with %v after %v, want status 0 at once", err, took.Round(time.Millisecond))
	}
}
