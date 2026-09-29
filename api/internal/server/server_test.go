package server

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"connectrpc.com/validate"

	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
	"micropod/api/internal/clicli"
)

// clients bundles one generated client per domain service, mounted the same
// way cmd/micropod-apiserver does (validate interceptor included).
type clients struct {
	containers micropodv1connect.ContainerServiceClient
	images     micropodv1connect.ImageServiceClient
	volumes    micropodv1connect.VolumeServiceClient
	system     micropodv1connect.SystemServiceClient
	stateDir   string
}

func mockPath(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(root, "Tests", "MicropodIntegrationTests", "Support", "mock-container")
}

// newTestServer points the CLI client at the shared mock-container script.
func newTestServer(t *testing.T) *clients {
	t.Helper()
	return newTestServerWithCLI(t, mockPath(t))
}

// newTestServerWithShim wraps the mock in a bash shim. `shim` runs first with
// the original argv ($@) and MOCK set to the real mock path; anything it does
// not handle falls through to the mock. Used to emulate CLI behaviour the
// shared mock does not model (a stopped runtime, real volume backing files).
func newTestServerWithShim(t *testing.T, shim string) *clients {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "container-shim")
	body := fmt.Sprintf("#!/bin/bash\nset -u\nMOCK=%q\n%s\nexec \"$MOCK\" \"$@\"\n", mockPath(t), shim)
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return newTestServerWithCLI(t, script)
}

func newTestServerWithCLI(t *testing.T, bin string) *clients {
	t.Helper()
	stateDir := t.TempDir()
	t.Setenv("MICROPOD_CONTAINER_CLI_PATH", bin)
	t.Setenv("MICROPOD_MOCK_STATE_DIR", stateDir)

	svc := New(clicli.New())
	opts := []connect.HandlerOption{connect.WithInterceptors(validate.NewInterceptor())}
	mux := http.NewServeMux()
	mux.Handle(micropodv1connect.NewContainerServiceHandler(svc, opts...))
	mux.Handle(micropodv1connect.NewImageServiceHandler(svc, opts...))
	mux.Handle(micropodv1connect.NewVolumeServiceHandler(svc, opts...))
	mux.Handle(micropodv1connect.NewNetworkServiceHandler(svc, opts...))
	mux.Handle(micropodv1connect.NewComposeServiceHandler(svc, opts...))
	mux.Handle(micropodv1connect.NewSystemServiceHandler(svc, opts...))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &clients{
		containers: micropodv1connect.NewContainerServiceClient(srv.Client(), srv.URL),
		images:     micropodv1connect.NewImageServiceClient(srv.Client(), srv.URL),
		volumes:    micropodv1connect.NewVolumeServiceClient(srv.Client(), srv.URL),
		system:     micropodv1connect.NewSystemServiceClient(srv.Client(), srv.URL),
		stateDir:   stateDir,
	}
}

func (c *clients) run(t *testing.T, ctx context.Context, req *micropodv1.RunContainerRequest) string {
	t.Helper()
	res, err := c.containers.RunContainer(ctx, connect.NewRequest(req))
	if err != nil {
		t.Fatalf("RunContainer: %v", err)
	}
	id := res.Msg.GetId()
	if id == "" {
		t.Fatal("RunContainer returned an empty id")
	}
	t.Cleanup(func() {
		_, _ = c.containers.DeleteContainer(context.Background(), connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: id, Force: true}))
	})
	return id
}

func (c *clients) stop(t *testing.T, ctx context.Context, id string) {
	t.Helper()
	if _, err := c.containers.StopContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: id})); err != nil {
		t.Fatalf("StopContainer(%s): %v", id, err)
	}
}

func requireCode(t *testing.T, err error, want connect.Code) *connect.Error {
	t.Helper()
	if err == nil {
		t.Fatalf("expected %v error, got nil", want)
	}
	if got := connect.CodeOf(err); got != want {
		t.Fatalf("expected code %v, got %v (%v)", want, got, err)
	}
	var cerr *connect.Error
	if ce, ok := err.(*connect.Error); ok {
		cerr = ce
	}
	return cerr
}

// --- existing coverage, re-homed on the per-domain clients ---

func TestGetSystem(t *testing.T) {
	c := newTestServer(t)
	res, err := c.system.GetSystem(context.Background(), connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	if res.Msg.GetStatus().GetStatus() != "running" {
		t.Fatalf("expected running, got %q", res.Msg.GetStatus().GetStatus())
	}
	if res.Msg.GetStatus().GetCliVersion() != "1.2.3" {
		t.Fatalf("expected cli 1.2.3, got %q", res.Msg.GetStatus().GetCliVersion())
	}
	if res.Msg.GetStatus().GetRuntimeBackend() != "cli" {
		t.Fatalf("expected runtime_backend cli, got %q", res.Msg.GetStatus().GetRuntimeBackend())
	}
	if res.Msg.GetDiskUsage() == nil {
		t.Fatal("expected disk usage for a running runtime")
	}
}

func TestContainerLifecycleViaConnect(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()

	name := "ctl-web"
	id := c.run(t, ctx, &micropodv1.RunContainerRequest{Image: "nginx:1.27", Name: &name, Env: []string{"API=go"}})

	list, err := c.containers.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	var mine *micropodv1.Container
	for _, ct := range list.Msg.GetContainers() {
		if ct.GetId() == id {
			mine = ct
		}
	}
	if mine == nil {
		t.Fatal("container not listed")
	}
	if mine.GetState() != "running" {
		t.Fatalf("expected running, got %s", mine.GetState())
	}
	if mine.GetImage() != "nginx:1.27" {
		t.Fatalf("unexpected image %q", mine.GetImage())
	}
	foundEnv := false
	for _, e := range mine.GetEnv() {
		if e == "API=go" {
			foundEnv = true
		}
	}
	if !foundEnv {
		t.Fatal("env did not round-trip")
	}

	createdName := "ctl-created"
	created, err := c.containers.CreateContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{Image: "alpine:3.20", Name: &createdName}))
	if err != nil {
		t.Fatal(err)
	}
	list2, err := c.containers.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	for _, ct := range list2.Msg.GetContainers() {
		if ct.GetId() == created.Msg.GetId() && ct.GetState() != "created" {
			t.Fatalf("create must not start the container (state=%s)", ct.GetState())
		}
	}

	c.stop(t, ctx, id)
	if _, err := c.containers.RestartContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: id})); err != nil {
		t.Fatal(err)
	}
	if _, err := c.containers.DeleteContainer(ctx, connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: id, Force: true})); err != nil {
		t.Fatal(err)
	}
	if _, err := c.containers.DeleteContainer(ctx, connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: created.Msg.GetId(), Force: true})); err != nil {
		t.Fatal(err)
	}
	// Unknown ids are not_found, not unavailable.
	_, err = c.containers.StartContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: "ghost"}))
	requireCode(t, err, connect.CodeNotFound)
}

func TestStreamLogsAndPull(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()

	name := "ctl-logs"
	c.run(t, ctx, &micropodv1.RunContainerRequest{
		Image: "nginx:1.27", Name: &name, Arguments: []string{"sh", "-c", "echo boot-line; sleep 30"},
	})

	stream, err := c.containers.StreamContainerLogs(ctx, connect.NewRequest(&micropodv1.StreamLogsRequest{Id: name, Tail: 5}))
	if err != nil {
		t.Fatal(err)
	}
	gotLine := false
	for stream.Receive() {
		if stream.Msg().GetText() != "" {
			gotLine = true
			break
		}
	}
	if stream.Err() != nil {
		t.Fatal(stream.Err())
	}
	if !gotLine {
		t.Fatal("no log lines received")
	}

	pull, err := c.images.PullImage(ctx, connect.NewRequest(&micropodv1.PullImageRequest{Reference: "redis:7"}))
	if err != nil {
		t.Fatal(err)
	}
	lines := 0
	for pull.Receive() {
		lines++
	}
	if pull.Err() != nil {
		t.Fatal(pull.Err())
	}
	if lines == 0 {
		t.Fatal("pull produced no progress lines")
	}
}

// --- GetContainer / WaitContainer ---

func TestGetContainer(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	name := "ctl-get"
	id := c.run(t, ctx, &micropodv1.RunContainerRequest{Image: "nginx:1.27", Name: &name})

	res, err := c.containers.GetContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: id}))
	if err != nil {
		t.Fatal(err)
	}
	if res.Msg.GetId() != id || res.Msg.GetState() != "running" || res.Msg.GetImage() != "nginx:1.27" {
		t.Fatalf("unexpected container: id=%q state=%q image=%q", res.Msg.GetId(), res.Msg.GetState(), res.Msg.GetImage())
	}
	// The CLI resolves names as well as ids.
	byName, err := c.containers.GetContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: name}))
	if err != nil {
		t.Fatal(err)
	}
	if byName.Msg.GetId() != id {
		t.Fatalf("lookup by name returned %q, want %q", byName.Msg.GetId(), id)
	}

	_, err = c.containers.GetContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: "ghost"}))
	requireCode(t, err, connect.CodeNotFound)
}

func TestWaitContainerStoppedReturnsImmediately(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	id := c.run(t, ctx, &micropodv1.RunContainerRequest{Image: "alpine:3.20"})
	c.stop(t, ctx, id)

	start := time.Now()
	res, err := c.containers.WaitContainer(ctx, connect.NewRequest(&micropodv1.WaitContainerRequest{Id: id, TimeoutSeconds: 5}))
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("wait on a stopped container took %v; must return without waiting for the timeout", elapsed)
	}
	if !res.Msg.GetExited() {
		t.Fatalf("expected exited=true, got %v", res.Msg)
	}
	if res.Msg.GetKnown() {
		t.Fatalf("CLI backend has no exit-code source; expected known=false, got %v", res.Msg)
	}
	if res.Msg.GetState() != "stopped" {
		t.Fatalf("expected state stopped, got %q", res.Msg.GetState())
	}
}

func TestWaitContainerRunningTimesOut(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	id := c.run(t, ctx, &micropodv1.RunContainerRequest{Image: "alpine:3.20"})

	start := time.Now()
	res, err := c.containers.WaitContainer(ctx, connect.NewRequest(&micropodv1.WaitContainerRequest{Id: id, TimeoutSeconds: 1}))
	if err != nil {
		t.Fatal(err)
	}
	elapsed := time.Since(start)
	if elapsed < 900*time.Millisecond || elapsed > 4*time.Second {
		t.Fatalf("expected the wait to be bounded by timeout_seconds=1, took %v", elapsed)
	}
	if res.Msg.GetExited() || res.Msg.GetKnown() {
		t.Fatalf("running container must not report exited/known: %v", res.Msg)
	}
	if res.Msg.GetState() != "running" {
		t.Fatalf("expected state running, got %q", res.Msg.GetState())
	}

	// created-but-never-started is not exited either.
	created, err := c.containers.CreateContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{Image: "alpine:3.20"}))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = c.containers.DeleteContainer(context.Background(), connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: created.Msg.GetId(), Force: true}))
	})
	res, err = c.containers.WaitContainer(ctx, connect.NewRequest(&micropodv1.WaitContainerRequest{Id: created.Msg.GetId(), TimeoutSeconds: 1}))
	if err != nil {
		t.Fatal(err)
	}
	if res.Msg.GetExited() || res.Msg.GetState() != "created" {
		t.Fatalf("created container must report exited=false state=created: %v", res.Msg)
	}
}

func TestWaitContainerUnknownIsNotFound(t *testing.T) {
	c := newTestServer(t)
	_, err := c.containers.WaitContainer(context.Background(), connect.NewRequest(&micropodv1.WaitContainerRequest{Id: "ghost", TimeoutSeconds: 1}))
	requireCode(t, err, connect.CodeNotFound)
}

// --- Ping / stopped runtime ---

func TestPingRunning(t *testing.T) {
	c := newTestServer(t)
	res, err := c.system.Ping(context.Background(), connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	if res.Msg.GetStatus() != "running" {
		t.Fatalf("expected running, got %q", res.Msg.GetStatus())
	}
	if res.Msg.GetRuntimeBackend() != "cli" {
		t.Fatalf("expected runtime_backend cli, got %q", res.Msg.GetRuntimeBackend())
	}
	if res.Msg.GetCliVersion() != "1.2.3" {
		t.Fatalf("expected cli_version 1.2.3, got %q", res.Msg.GetCliVersion())
	}
	if res.Msg.GetApiServerVersion() == "" {
		t.Fatal("expected api_server_version to be populated from `system status`")
	}
}

// TestPingAndGetSystemReportStoppedRuntime runs against the shared mock's
// stopped mode, which reproduces `container` 1.3.1 byte-for-byte: `system
// status --format json` prints {"status":"unregistered"} on STDOUT and exits
// 1 with an empty stderr (the "apiserver is not running" sentence is
// table-mode only), and every apiserver-backed command fails with the XPC
// "connection invalid" text on stderr.
func TestPingAndGetSystemReportStoppedRuntime(t *testing.T) {
	t.Setenv("MICROPOD_MOCK_RUNTIME_STOPPED", "1")
	c := newTestServer(t)
	ctx := context.Background()

	start := time.Now()
	ping, err := c.system.Ping(ctx, connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatalf("Ping must report a stopped runtime as a status, not an error: %v", err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("Ping took %v against a stopped runtime", elapsed)
	}
	if ping.Msg.GetStatus() != "stopped" || ping.Msg.GetRuntimeBackend() != "cli" {
		t.Fatalf("expected status=stopped runtime_backend=cli, got %v", ping.Msg)
	}
	if ping.Msg.GetCliVersion() != "1.2.3" {
		t.Fatalf("cli_version should still be reported while the runtime is stopped, got %q", ping.Msg.GetCliVersion())
	}

	sys, err := c.system.GetSystem(ctx, connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatalf("GetSystem must report a stopped runtime as a status, not an error: %v", err)
	}
	if sys.Msg.GetStatus().GetStatus() != "stopped" || sys.Msg.GetStatus().GetRuntimeBackend() != "cli" {
		t.Fatalf("expected status=stopped runtime_backend=cli, got %v", sys.Msg.GetStatus())
	}
	if sys.Msg.GetDiskUsage() != nil {
		t.Fatalf("stopped runtime must not fabricate disk usage: %v", sys.Msg.GetDiskUsage())
	}

	// Anything that needs the apiserver is a transport failure: unavailable,
	// never not_found or internal.
	_, err = c.containers.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
	requireCode(t, err, connect.CodeUnavailable)
}

func TestRuntimeErrorClassification(t *testing.T) {
	statusArgs := []string{"system", "status", "--format", "json"}
	xpcDown := "Error: interrupted: \"XPC connection error: Connection invalid\nEnsure container system service has been started with `container system start`.\"\n"

	stoppedCases := map[string]*clicli.CommandError{
		// `container` 1.3.1 json mode: payload on stdout, exit 1, empty stderr.
		"unregistered on stdout": {Args: statusArgs, Stdout: "{\"status\":\"unregistered\"}\n", ExitCode: 1},
		"not running on stdout":  {Args: statusArgs, Stdout: "{\"status\":\"not running\"}\n", ExitCode: 1},
		// Any encoder whitespace still decodes to the same status word.
		"pretty-printed stdout": {Args: statusArgs, Stdout: "{\n  \"status\" : \"unregistered\"\n}\n", ExitCode: 1},
		// Exit 1 with nothing on either stream from `system status` is a
		// stopped runtime too (usage errors exit 64 and print to stderr).
		"silent exit 1": {Args: statusArgs, ExitCode: 1},
		// Table mode / older builds print the sentence on stderr.
		"launchd sentence": {Args: []string{"system", "status"}, Stderr: "Error: apiserver is not running and not registered with launchd\n", ExitCode: 1},
		// Every other apiserver-backed command fails with XPC's text.
		"xpc on list": {Args: []string{"list", "--all", "--format", "json"}, Stderr: xpcDown, ExitCode: 1},
		"xpc on df":   {Args: []string{"system", "df", "--format", "json"}, Stderr: xpcDown, ExitCode: 1},
	}
	for name, ce := range stoppedCases {
		if !clicli.IsRuntimeStopped(ce) {
			t.Errorf("%s: expected IsRuntimeStopped", name)
		}
		if clicli.IsNotFound(ce) {
			t.Errorf("%s: stopped runtime must not be classified as not found", name)
		}
	}

	// A stopped *container* is not a stopped runtime, and a silent exit 1
	// only means "stopped" for `system status`.
	notStopped := map[string]*clicli.CommandError{
		"stopped container": {Args: []string{"start", "web"}, Stderr: "Error: invalidState: \"container web is not running\"\n", ExitCode: 1},
		"silent stop":       {Args: []string{"stop", "web"}, ExitCode: 1},
		"usage error":       {Args: statusArgs, Stderr: "Error: Unknown option '--bogus'\n", ExitCode: 64},
	}
	for name, ce := range notStopped {
		if clicli.IsRuntimeStopped(ce) {
			t.Errorf("%s: must not be classified as a stopped runtime", name)
		}
		if clicli.IsNotFound(ce) {
			t.Errorf("%s: must not be classified as not found", name)
		}
	}

	notFound := map[string]*clicli.CommandError{
		// Mock wording.
		"mock no such container": {Args: []string{"inspect", "ghost"}, Stderr: "Error: no such container: ghost\n", ExitCode: 1},
		// Real CLI inspect commands.
		"inspect container": {Args: []string{"inspect", "ghost"}, Stderr: "Error: container not found: ghost\n", ExitCode: 1},
		"inspect image":     {Args: []string{"image", "inspect", "x"}, Stderr: "Error: image not found: x\n", ExitCode: 1},
		"inspect volume":    {Args: []string{"volume", "inspect", "v"}, Stderr: "Error: volume not found: v\n", ExitCode: 1},
		"inspect network":   {Args: []string{"network", "inspect", "n"}, Stderr: "Error: network not found: n\n", ExitCode: 1},
		"legacy not found:": {Args: []string{"image", "inspect", "x"}, Stderr: "Error: not found: \"x\"\n", ExitCode: 1},
		// Runtime-originated ContainerizationError(.notFound) as rendered by
		// start/stop/delete/exec on a missing id.
		"runtime notFound":        {Args: []string{"start", "ghost"}, Stderr: "Error: notFound: \"container with ID ghost not found\"\n", ExitCode: 1},
		"runtime notFound volume": {Args: []string{"volume", "delete", "v"}, Stderr: "Error: notFound: \"volume 'v' not found\"\n", ExitCode: 1},
	}
	for name, ce := range notFound {
		if !clicli.IsNotFound(ce) {
			t.Errorf("%s: expected IsNotFound", name)
		}
		if clicli.IsRuntimeStopped(ce) {
			t.Errorf("%s: missing resource must not be classified as a stopped runtime", name)
		}
	}

	// Guest output is never a CLI not-found: the shell's phrase has the colon
	// before "not found". The exec pre-filter is deliberately broad (it only
	// gates an inspect that confirms), the mapError classifier is not.
	guest := &clicli.CommandError{Args: []string{"exec", "web", "sh", "-c", "foo"}, Stderr: "sh: foo: not found\n", ExitCode: 127}
	if clicli.IsNotFound(guest) {
		t.Error("guest 'sh: foo: not found' must not satisfy IsNotFound")
	}
	if !clicli.LooksLikeNotFound(guest.Stderr) {
		t.Error("exec pre-filter should be broad enough to trigger the inspect confirmation")
	}
	if !clicli.LooksLikeNotFound("Error: notFound: \"container with ID ghost not found\"") {
		t.Error("exec pre-filter must match the runtime's notFound rendering")
	}

	if clicli.IsNotFound(nil) || clicli.IsRuntimeStopped(nil) {
		t.Fatal("nil is neither not-found nor stopped")
	}
}

// realCLINotFoundShim answers with the wording `container` 1.3.1 really
// prints for a missing id: the runtime's ContainerizationError(.notFound) on
// start/stop/delete/exec and the inspect command's own phrase on inspect. The
// mock's "no such container" is never seen.
const realCLINotFoundShim = `
has_ghost=0
for a in "$@"; do [ "$a" = ghost ] && has_ghost=1; done
if [ "$has_ghost" = 1 ]; then
  case "${1:-}" in
    start|stop|kill|delete|exec)
      echo 'Error: notFound: "container with ID ghost not found"' >&2
      exit 1 ;;
    inspect)
      echo 'Error: container not found: ghost' >&2
      exit 1 ;;
  esac
fi
`

func TestRealCLINotFoundWordingMapsToNotFound(t *testing.T) {
	c := newTestServerWithShim(t, realCLINotFoundShim)
	ctx := context.Background()
	ghost := &micropodv1.ContainerRef{Id: "ghost"}

	_, err := c.containers.StartContainer(ctx, connect.NewRequest(ghost))
	requireCode(t, err, connect.CodeNotFound)
	_, err = c.containers.StopContainer(ctx, connect.NewRequest(ghost))
	requireCode(t, err, connect.CodeNotFound)
	_, err = c.containers.RestartContainer(ctx, connect.NewRequest(ghost))
	requireCode(t, err, connect.CodeNotFound)
	_, err = c.containers.KillContainer(ctx, connect.NewRequest(ghost))
	requireCode(t, err, connect.CodeNotFound)
	_, err = c.containers.DeleteContainer(ctx, connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: "ghost", Force: true}))
	requireCode(t, err, connect.CodeNotFound)
	_, err = c.containers.GetContainer(ctx, connect.NewRequest(ghost))
	requireCode(t, err, connect.CodeNotFound)

	// Exec must surface not_found, not an ExecResponse carrying the CLI's
	// exit status and error text.
	_, err = c.containers.Exec(ctx, connect.NewRequest(&micropodv1.ExecRequest{Id: "ghost", Arguments: []string{"sh", "-c", "true"}}))
	requireCode(t, err, connect.CodeNotFound)
}

// --- run flags / no_pull ---

func TestRunArgsIncludesEntrypointPlatformWorkdirUser(t *testing.T) {
	entrypoint, platform, workdir, user := "/bin/sh", "linux/arm64", "/w", "1000:1000"
	args := runArgs(&micropodv1.RunContainerRequest{
		Image: "alpine:3.20", Entrypoint: &entrypoint, Platform: &platform, Workdir: &workdir, User: &user,
		Arguments: []string{"-c", "true"},
	})
	joined := " " + strings.Join(args, " ") + " "
	for _, want := range []string{" --entrypoint /bin/sh ", " --platform linux/arm64 ", " --workdir /w ", " --user 1000:1000 "} {
		if !strings.Contains(joined, want) {
			t.Fatalf("runArgs missing %q in %q", strings.TrimSpace(want), joined)
		}
	}
	// Flags precede the image; the image precedes the argv.
	imageAt := strings.Index(joined, " alpine:3.20 ")
	if imageAt < 0 || strings.Index(joined, " --user ") > imageAt || strings.Index(joined, " -c true ") < imageAt {
		t.Fatalf("unexpected ordering in %q", joined)
	}
	// Unset optionals emit nothing.
	plain := strings.Join(runArgs(&micropodv1.RunContainerRequest{Image: "alpine:3.20"}), " ")
	for _, flag := range []string{"--entrypoint", "--platform", "--workdir", "--user"} {
		if strings.Contains(plain, flag) {
			t.Fatalf("unset %s must not be emitted: %q", flag, plain)
		}
	}
}

func TestRunArgsCapabilitiesRosettaPrivileged(t *testing.T) {
	yes := true
	joined := " " + strings.Join(runArgs(&micropodv1.RunContainerRequest{
		Image: "alpine:3.20", CapAdd: []string{"CAP_NET_ADMIN"}, CapDrop: []string{"CAP_NET_RAW"}, Rosetta: &yes,
	}), " ") + " "
	for _, want := range []string{" --cap-add CAP_NET_ADMIN ", " --cap-drop CAP_NET_RAW ", " --rosetta "} {
		if !strings.Contains(joined, want) {
			t.Fatalf("runArgs missing %q in %q", strings.TrimSpace(want), joined)
		}
	}
	if strings.Contains(joined, "--masked-path") || strings.Contains(joined, "--read-only-path") {
		t.Fatalf("unprivileged run must keep the runtime's default paths: %q", joined)
	}

	priv := " " + strings.Join(runArgs(&micropodv1.RunContainerRequest{
		Image: "docker:dind", CapAdd: []string{"CAP_SYS_ADMIN"}, Privileged: &yes,
	}), " ") + " "
	for _, want := range []string{" --cap-add ALL ", " --read-only-path NONE --masked-path NONE "} {
		if !strings.Contains(priv, want) {
			t.Fatalf("privileged runArgs missing %q in %q", strings.TrimSpace(want), priv)
		}
	}
	if strings.Contains(priv, "CAP_SYS_ADMIN") {
		t.Fatalf("privileged subsumes cap_add: %q", priv)
	}

	// The runtime drops before it adds: with a drop, ALL expands to every
	// other capability so the drop really applies.
	dropped := " " + strings.Join(runArgs(&micropodv1.RunContainerRequest{
		Image: "docker:dind", CapDrop: []string{"CAP_SYS_MODULE"}, Privileged: &yes,
	}), " ") + " "
	for _, want := range []string{" --cap-add CAP_SYS_ADMIN ", " --cap-add CAP_CHECKPOINT_RESTORE ", " --cap-drop CAP_SYS_MODULE "} {
		if !strings.Contains(dropped, want) {
			t.Fatalf("privileged+drop runArgs missing %q in %q", strings.TrimSpace(want), dropped)
		}
	}
	if strings.Contains(dropped, " --cap-add ALL ") || strings.Contains(dropped, " --cap-add CAP_SYS_MODULE ") {
		t.Fatalf("a dropped capability must not be re-added: %q", dropped)
	}
	addAll := strings.Join(runArgs(&micropodv1.RunContainerRequest{
		Image: "alpine:3.20", CapAdd: []string{"ALL"}, CapDrop: []string{"CAP_NET_RAW"},
	}), " ")
	if strings.Contains(addAll, "--cap-add ALL") || strings.Contains(addAll, "--cap-add CAP_NET_RAW") || strings.Count(addAll, "--cap-add ") != 40 {
		t.Fatalf("cap_add ALL + cap_drop NET_RAW: %q", addAll)
	}
	if strings.Index(priv, " --masked-path ") > strings.Index(priv, " docker:dind ") {
		t.Fatalf("flags must precede the image: %q", priv)
	}
	no := false
	off := strings.Join(runArgs(&micropodv1.RunContainerRequest{Image: "alpine:3.20", Rosetta: &no, Privileged: &no}), " ")
	for _, flag := range []string{"--rosetta", "--cap-add", "--masked-path"} {
		if strings.Contains(off, flag) {
			t.Fatalf("false optionals must emit nothing (%s): %q", flag, off)
		}
	}
}

func TestNormalizeCapabilities(t *testing.T) {
	got, err := normalizeCapabilities("cap_add", []string{"net_admin", "CAP_SYS_PTRACE", "all", "NET_ADMIN"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got, ",") != "CAP_NET_ADMIN,CAP_SYS_PTRACE,ALL" {
		t.Fatalf("normalized = %v", got)
	}
	if len(linuxCapabilities) != 41 {
		t.Fatalf("expected the 41 kernel capabilities, have %d", len(linuxCapabilities))
	}
	// Whitespace is invalid (the proto pattern; MicropodCore agrees).
	for _, bad := range []string{"NET_ADMINN", "CAP_ALL", "CAP_", " NET_ADMIN", "NET_ADMIN\n", "\tNET_RAW"} {
		if _, err := normalizeCapabilities("cap_add", []string{bad}); connect.CodeOf(err) != connect.CodeInvalidArgument {
			t.Fatalf("%q: want invalid_argument, got %v", bad, err)
		}
	}
}

func TestRunRequestRejectsDropAllWithAnAllGrant(t *testing.T) {
	yes := true
	for _, req := range []*micropodv1.RunContainerRequest{
		{Image: "alpine:3.20", Privileged: &yes, CapDrop: []string{"all"}},
		{Image: "alpine:3.20", CapAdd: []string{"ALL"}, CapDrop: []string{"ALL"}},
	} {
		requireCode(t, normalizeRunRequest(req), connect.CodeInvalidArgument)
	}
	for _, req := range []*micropodv1.RunContainerRequest{
		{Image: "alpine:3.20", CapAdd: []string{"NET_ADMIN"}, CapDrop: []string{"ALL"}},
		{Image: "alpine:3.20", Privileged: &yes, CapDrop: []string{"NET_RAW"}},
	} {
		if err := normalizeRunRequest(req); err != nil {
			t.Fatalf("%+v: %v", req, err)
		}
	}
	c := newTestServer(t)
	_, err := c.containers.RunContainer(context.Background(), connect.NewRequest(&micropodv1.RunContainerRequest{
		Image: "alpine:3.20", Privileged: &yes, CapDrop: []string{"ALL"},
	}))
	requireCode(t, err, connect.CodeInvalidArgument)
}

func TestPingAdvertisesFeatures(t *testing.T) {
	c := newTestServer(t)
	res, err := c.system.Ping(context.Background(), connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(res.Msg.GetFeatures(), ","); got != "cap_add,cap_drop,rosetta,privileged,runtime" {
		t.Fatalf("features = %q", got)
	}
	if got := res.Msg.GetDefaultRuntime(); got != "apple" {
		t.Fatalf("default runtime = %q", got)
	}
}

// The Go server drives only the apple engine: it lists it, accepts it as the
// default, and refuses every other engine instead of silently running on apple.
func TestRuntimesAreAppleOnly(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	res, err := c.system.ListRuntimes(ctx, connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Msg.Runtimes) != 1 || res.Msg.Runtimes[0].Name != "apple" || !res.Msg.Runtimes[0].Default {
		t.Fatalf("runtimes = %v", res.Msg.Runtimes)
	}
	if _, err := c.system.SetDefaultRuntime(ctx, connect.NewRequest(&micropodv1.SetDefaultRuntimeRequest{Name: "apple"})); err != nil {
		t.Fatal(err)
	}
	_, err = c.system.SetDefaultRuntime(ctx, connect.NewRequest(&micropodv1.SetDefaultRuntimeRequest{Name: "sandbox"}))
	requireCode(t, err, connect.CodeFailedPrecondition)
	no := false
	_, err = c.system.UpdateRuntime(ctx, connect.NewRequest(&micropodv1.UpdateRuntimeRequest{Name: "apple", Enabled: &no}))
	requireCode(t, err, connect.CodeFailedPrecondition)
	docker := "docker"
	_, err = c.containers.RunContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{Image: "alpine:3.20", Runtime: &docker}))
	requireCode(t, err, connect.CodeFailedPrecondition)
}

func TestCreateContainerRejectsUnknownCapability(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	_, err := c.containers.CreateContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{Image: "alpine:3.20", CapAdd: []string{"NOT_A_CAP"}}))
	requireCode(t, err, connect.CodeInvalidArgument)
	_, err = c.containers.RunContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{Image: "alpine:3.20", CapDrop: []string{"bad-name"}}))
	requireCode(t, err, connect.CodeInvalidArgument)

	yes := true
	id := c.run(t, ctx, &micropodv1.RunContainerRequest{Image: "alpine:3.20", CapAdd: []string{"net_raw"}, Rosetta: &yes})
	res, err := c.containers.GetContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: id}))
	if err != nil {
		t.Fatal(err)
	}
	if !res.Msg.GetRosetta() {
		t.Fatalf("rosetta not recorded: %+v", res.Msg)
	}
}

func TestRunContainerAcceptsEntrypointPlatformWorkdirUser(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	entrypoint, platform, workdir, user := "/bin/sh", "linux/arm64", "/w", "1000:1000"
	id := c.run(t, ctx, &micropodv1.RunContainerRequest{
		Image: "alpine:3.20", Entrypoint: &entrypoint, Platform: &platform, Workdir: &workdir, User: &user,
		Arguments: []string{"-c", "true"},
	})
	res, err := c.containers.GetContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: id}))
	if err != nil {
		t.Fatal(err)
	}
	if res.Msg.GetPlatform() != "linux/arm64" {
		t.Fatalf("expected platform linux/arm64, got %q", res.Msg.GetPlatform())
	}
}

func TestNoPullMissingImageIsNotFound(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()

	// Absent everywhere: not_found, and the CLI must not have been asked to run.
	_, err := c.containers.CreateContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{Image: "ghost/none:1", NoPull: true}))
	requireCode(t, err, connect.CodeNotFound)
	list, err := c.containers.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	if n := len(list.Msg.GetContainers()); n != 0 {
		t.Fatalf("no container may be created when no_pull rejects the image, found %d", n)
	}

	// Present for linux/arm64 only (the mock's pull records that variant).
	pull, err := c.images.PullImage(ctx, connect.NewRequest(&micropodv1.PullImageRequest{Reference: "redis:7"}))
	if err != nil {
		t.Fatal(err)
	}
	for pull.Receive() {
	}
	if pull.Err() != nil {
		t.Fatal(pull.Err())
	}
	amd64 := "linux/amd64"
	_, err = c.containers.CreateContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{Image: "redis:7", NoPull: true, Platform: &amd64}))
	cerr := requireCode(t, err, connect.CodeNotFound)
	if !strings.Contains(cerr.Message(), "linux/amd64") {
		t.Fatalf("not_found message must name the requested platform, got %q", cerr.Message())
	}

	// Present for the requested platform: proceeds.
	arm64 := "linux/arm64"
	created, err := c.containers.CreateContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{Image: "redis:7", NoPull: true, Platform: &arm64}))
	if err != nil {
		t.Fatalf("no_pull with a locally present image must succeed: %v", err)
	}
	if _, err := c.containers.DeleteContainer(ctx, connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: created.Msg.GetId(), Force: true})); err != nil {
		t.Fatal(err)
	}
	// Present, no platform requested: proceeds too.
	run, err := c.containers.RunContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{Image: "redis:7", NoPull: true}))
	if err != nil {
		t.Fatalf("no_pull with a locally present image must succeed: %v", err)
	}
	if _, err := c.containers.DeleteContainer(ctx, connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: run.Msg.GetId(), Force: true})); err != nil {
		t.Fatal(err)
	}
}

// --- Exec argv ---

func TestExecSpecArgv(t *testing.T) {
	workdir := "/app"
	spec, err := execSpec(&micropodv1.ExecRequest{
		Id: "web", Command: "ignored when arguments are set",
		Arguments: []string{"sh", "-c", "echo a  b"}, Workdir: &workdir, Env: []string{"A=1", "B=2"},
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"exec", "--workdir", "/app", "--env", "A=1", "--env", "B=2", "web", "sh", "-c", "echo a  b"}
	if got := spec.Args(); strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("argv mismatch:\n got %q\nwant %q", got, want)
	}

	// Legacy `command` is whitespace-split for compatibility.
	spec, err = execSpec(&micropodv1.ExecRequest{Id: "web", Command: "ls  -la /tmp"})
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(spec.Argv, "\x00"); got != strings.Join([]string{"ls", "-la", "/tmp"}, "\x00") {
		t.Fatalf("command split mismatch: %q", spec.Argv)
	}

	if _, err := execSpec(&micropodv1.ExecRequest{Id: "web"}); err == nil {
		t.Fatal("neither command nor arguments must be rejected")
	}
	if _, err := execSpec(&micropodv1.ExecRequest{Id: "web", Command: "   "}); err == nil {
		t.Fatal("a blank command with no arguments must be rejected")
	}
}

func TestExecUsesArgumentsAndRejectsEmpty(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	id := c.run(t, ctx, &micropodv1.RunContainerRequest{Image: "alpine:3.20"})

	res, err := c.containers.Exec(ctx, connect.NewRequest(&micropodv1.ExecRequest{Id: id, Arguments: []string{"sh", "-c", "echo a  b"}}))
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(res.Msg.GetOutput()) != "ok" || res.Msg.GetExitCode() != 0 {
		t.Fatalf("unexpected exec result: %v", res.Msg)
	}

	_, err = c.containers.Exec(ctx, connect.NewRequest(&micropodv1.ExecRequest{Id: id}))
	requireCode(t, err, connect.CodeInvalidArgument)

	_, err = c.containers.Exec(ctx, connect.NewRequest(&micropodv1.ExecRequest{Id: "ghost", Arguments: []string{"true"}}))
	requireCode(t, err, connect.CodeNotFound)
}

// --- skip_lines ---

func TestStreamLogsSkipLines(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	id := c.run(t, ctx, &micropodv1.RunContainerRequest{Image: "alpine:3.20"})

	// The mock prints min(tail, 12) backlog lines then one "after-follow" line.
	stream, err := c.containers.StreamContainerLogs(ctx, connect.NewRequest(&micropodv1.StreamLogsRequest{Id: id, Tail: 5, SkipLines: 4}))
	if err != nil {
		t.Fatal(err)
	}
	var lines []string
	for stream.Receive() {
		lines = append(lines, stream.Msg().GetText())
	}
	if stream.Err() != nil {
		t.Fatal(stream.Err())
	}
	if len(lines) != 2 {
		t.Fatalf("expected 6-4=2 lines after skip_lines, got %d: %q", len(lines), lines)
	}
	if !strings.Contains(lines[0], "mock log line 5 ") {
		t.Fatalf("skip_lines must drop the first four lines; first delivered was %q", lines[0])
	}
}

// --- stats ids ---

func TestGetStatsFiltersIds(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	a := c.run(t, ctx, &micropodv1.RunContainerRequest{Image: "alpine:3.20"})
	b := c.run(t, ctx, &micropodv1.RunContainerRequest{Image: "alpine:3.20"})

	all, err := c.containers.GetStats(ctx, connect.NewRequest(&micropodv1.GetStatsRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	if n := len(all.Msg.GetSnapshot().GetContainers()); n != 2 {
		t.Fatalf("expected both running containers in an unfiltered snapshot, got %d", n)
	}

	only, err := c.containers.GetStats(ctx, connect.NewRequest(&micropodv1.GetStatsRequest{Ids: []string{a}}))
	if err != nil {
		t.Fatal(err)
	}
	got := only.Msg.GetSnapshot().GetContainers()
	if len(got) != 1 || got[0].GetId() != a {
		t.Fatalf("expected exactly [%s], got %v (other id %s)", a, got, b)
	}
	if got[0].GetMemoryLimitBytes() == 0 {
		t.Fatal("stats entry lost its fields in the filter")
	}
}

// --- volumes: clone / commit ---

func (c *clients) volumeByName(t *testing.T, ctx context.Context, name string) *micropodv1.Volume {
	t.Helper()
	list, err := c.volumes.ListVolumes(ctx, connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range list.Msg.GetVolumes() {
		if v.GetId() == name {
			return v
		}
	}
	t.Fatalf("volume %q not listed", name)
	return nil
}

func TestCloneVolume(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()

	size := "2M"
	if _, err := c.volumes.CreateVolume(ctx, connect.NewRequest(&micropodv1.CreateVolumeRequest{Name: "golden", Size: &size})); err != nil {
		t.Fatal(err)
	}
	golden := c.volumeByName(t, ctx, "golden")
	if !strings.HasPrefix(golden.GetSource(), c.stateDir) {
		t.Fatalf("the mock backs volumes with real files under the state dir: %q", golden.GetSource())
	}
	marker := []byte("golden-marker-bytes")
	f, err := os.OpenFile(golden.GetSource(), os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteAt(marker, 4096); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}

	res, err := c.volumes.CloneVolume(ctx, connect.NewRequest(&micropodv1.CloneVolumeRequest{
		Source: "golden", Name: "job-1", Labels: []string{"job=1"},
	}))
	if err != nil {
		t.Fatalf("CloneVolume: %v", err)
	}
	clone := res.Msg
	if clone.GetId() != "job-1" {
		t.Fatalf("expected the new volume, got %v", clone)
	}
	if clone.GetSizeBytes() != golden.GetSizeBytes() {
		t.Fatalf("clone size must default to the source's provisioned size: %d vs %d", clone.GetSizeBytes(), golden.GetSizeBytes())
	}
	if clone.GetLabels()["job"] != "1" || clone.GetLabels()["com.micropod.clone-of"] != "golden" {
		t.Fatalf("clone labels must carry the request labels and clone-of: %v", clone.GetLabels())
	}
	if clone.GetAllocatedBytes() == 0 {
		t.Fatal("allocated_bytes must be populated from the backing file")
	}
	data, err := os.ReadFile(clone.GetSource())
	if err != nil {
		t.Fatal(err)
	}
	if len(data) != 1048576 || string(data[4096:4096+len(marker)]) != string(marker) {
		t.Fatalf("clone backing file is not a byte-for-byte clone of the source (len=%d)", len(data))
	}
	// A rename left no temp file behind.
	entries, err := os.ReadDir(filepath.Dir(clone.GetSource()))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected only volume.img in the clone dir, got %d entries", len(entries))
	}

	// Writes to the clone do not reach the golden (copy-on-write).
	if err := os.WriteFile(clone.GetSource(), []byte("scribble"), 0o644); err != nil {
		t.Fatal(err)
	}
	orig, err := os.ReadFile(golden.GetSource())
	if err != nil {
		t.Fatal(err)
	}
	if string(orig[4096:4096+len(marker)]) != string(marker) {
		t.Fatal("writing the clone modified the golden image")
	}

	// Unknown source.
	_, err = c.volumes.CloneVolume(ctx, connect.NewRequest(&micropodv1.CloneVolumeRequest{Source: "nope", Name: "job-2"}))
	requireCode(t, err, connect.CodeNotFound)
	// Only the golden and the one successful clone exist: a failed clone leaves no volume behind.
	list, err := c.volumes.ListVolumes(ctx, connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	if n := len(list.Msg.GetVolumes()); n != 2 {
		t.Fatalf("expected 2 volumes, got %d", n)
	}
}

func TestCloneVolumeSourceInUseIsFailedPrecondition(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	if _, err := c.volumes.CreateVolume(ctx, connect.NewRequest(&micropodv1.CreateVolumeRequest{Name: "golden"})); err != nil {
		t.Fatal(err)
	}
	writer := c.run(t, ctx, &micropodv1.RunContainerRequest{Image: "alpine:3.20", Volumes: []string{"golden:/x"}})

	_, err := c.volumes.CloneVolume(ctx, connect.NewRequest(&micropodv1.CloneVolumeRequest{Source: "golden", Name: "job-1"}))
	cerr := requireCode(t, err, connect.CodeFailedPrecondition)
	if !strings.Contains(cerr.Message(), writer) {
		t.Fatalf("failed_precondition must name the running container %s: %q", writer, cerr.Message())
	}

	// A stopped writer no longer blocks the clone.
	c.stop(t, ctx, writer)
	if _, err := c.volumes.CloneVolume(ctx, connect.NewRequest(&micropodv1.CloneVolumeRequest{Source: "golden", Name: "job-1"})); err != nil {
		t.Fatalf("clone after the writer stopped: %v", err)
	}
}

func TestCommitVolumeCloneIsUnimplemented(t *testing.T) {
	c := newTestServer(t)
	_, err := c.volumes.CommitVolumeClone(context.Background(), connect.NewRequest(&micropodv1.CommitVolumeCloneRequest{ContainerId: "job-1", Volume: "golden"}))
	requireCode(t, err, connect.CodeUnimplemented)
}

func TestListVolumesReportsAllocatedBytes(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	if _, err := c.volumes.CreateVolume(ctx, connect.NewRequest(&micropodv1.CreateVolumeRequest{Name: "v"})); err != nil {
		t.Fatal(err)
	}
	v := c.volumeByName(t, ctx, "v")
	if v.GetAllocatedBytes() == 0 {
		t.Fatalf("allocated_bytes must reflect the backing file: %v", v)
	}
	if v.GetAllocatedBytes() > v.GetSizeBytes() {
		t.Fatalf("allocated %d exceeds provisioned %d", v.GetAllocatedBytes(), v.GetSizeBytes())
	}
}
