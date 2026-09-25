// Package clicli is a minimal, typed client for the Apple `container` CLI.
// It mirrors the JSON shapes MicropodCore consumes so the connect-go API
// server can talk to the runtime directly.
package clicli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// CLI is a handle to the container binary.
type CLI struct {
	Bin string
}

func New() *CLI {
	bin := "/usr/local/bin/container"
	if env := os.Getenv("MICROPOD_CONTAINER_CLI_PATH"); env != "" {
		bin = env
	}
	return &CLI{Bin: bin}
}

func (c *CLI) Available() bool {
	_, err := exec.LookPath(c.Bin)
	return err == nil
}

// CommandError is returned by Run when the CLI exits non-zero. It keeps the
// argv, both output streams and the exit status so callers can classify the
// failure (IsNotFound, IsRuntimeStopped) instead of pattern-matching a
// flattened message. Stdout matters: `system status --format json` reports
// a down apiserver as a JSON payload on stdout with an empty stderr.
type CommandError struct {
	Args     []string
	Stdout   string
	Stderr   string
	ExitCode int // process exit status; -1 when the process did not exit on its own
	Err      error
}

func (e *CommandError) Error() string {
	detail := strings.TrimSpace(e.Stderr)
	if detail == "" {
		detail = strings.TrimSpace(e.Stdout)
	}
	return fmt.Sprintf("`container %s` failed: %v: %s", strings.Join(e.Args, " "), e.Err, detail)
}

func (e *CommandError) Unwrap() error { return e.Err }

// IsNotFound reports whether err is a CLI failure naming a missing resource.
// Only CLI-originated stderr is consulted, never guest process output.
func IsNotFound(err error) bool {
	var ce *CommandError
	if !errors.As(err, &ce) {
		return false
	}
	return looksLikeNotFound(ce.Stderr)
}

// looksLikeNotFound matches the CLI's own missing-resource phrasing:
//
//   - the inspect commands' "container|image|volume|network not found: x"
//     (ContainerInspect.swift and friends);
//   - the runtime's ContainerizationError(.notFound, …), which every other
//     verb (start, stop, delete, exec, volume delete, …) renders as
//     `notFound: "container with ID x not found"` — the same prefix table
//     MicropodCore's ConnectCodeMapping.prefixed reads;
//   - the mock's "no such container: x".
//
// A guest shell's "sh: foo: not found" has the colon before the phrase and
// matches none of these.
func looksLikeNotFound(stderr string) bool {
	text := strings.ToLower(stderr)
	return strings.Contains(text, "no such ") ||
		strings.Contains(text, "not found:") ||
		strings.Contains(text, "notfound:") ||
		strings.Contains(text, "container not found") ||
		strings.Contains(text, "image not found") ||
		strings.Contains(text, "volume not found") ||
		strings.Contains(text, "network not found")
}

// runtimeDownSignatures are the CLI's own words for a down apiserver,
// lowercased — the same list as MicropodCore's
// ConnectCodeMapping.runtimeDownSignatures, sourced from `container` 1.3.1
// (SystemStatus.swift, Application.swift) and XPC's error strings. The bare
// "not running" is deliberately absent: `invalidState: container X is not
// running` is a stopped container, not a stopped runtime.
var runtimeDownSignatures = []string{
	"apiserver is not running",
	"not registered with launchd",
	"xpc connection error",
	"connection invalid",
	"connection interrupted",
	"ensure container system service has been started",
	`"status":"unregistered"`,
	`"status":"not running"`,
}

// stoppedStatusValues are the `status` words `system status --format json`
// renders when the apiserver is down (mirrors SystemService.stoppedStatusValues).
var stoppedStatusValues = map[string]bool{"unregistered": true, "not running": true}

// IndicatesRuntimeDown reports whether CLI output carries one of the
// runtime-down signatures.
func IndicatesRuntimeDown(text string) bool {
	lower := strings.ToLower(text)
	for _, signature := range runtimeDownSignatures {
		if strings.Contains(lower, signature) {
			return true
		}
	}
	return false
}

// IsRuntimeStopped reports whether err is the CLI telling us the Apple
// runtime is down. Callers surface this as status "stopped", not as an error.
//
// `container system status --format json` renders {"status":"unregistered"}
// or {"status":"not running"} on STDOUT and exits 1 with an EMPTY stderr (the
// "apiserver is not running …" sentence is table-mode only), so for that
// command the stdout payload — or simply exit 1 with nothing on stderr — is
// a stopped runtime (mirrors SystemService.isStoppedRuntime). Every other
// apiserver-backed command fails with the XPC "connection invalid" text on
// stderr, which matches runtimeDownSignatures.
func IsRuntimeStopped(err error) bool {
	var ce *CommandError
	if !errors.As(err, &ce) {
		return false
	}
	if IndicatesRuntimeDown(ce.Stderr) || IndicatesRuntimeDown(ce.Stdout) {
		return true
	}
	if !ce.isSystemStatus() {
		return false
	}
	var payload struct {
		Status string `json:"status"`
	}
	if json.Unmarshal([]byte(ce.Stdout), &payload) == nil && stoppedStatusValues[strings.ToLower(payload.Status)] {
		return true
	}
	// Usage errors exit 64 and print to stderr; a missing binary never
	// yields an exit status. Exit 1 with a silent stderr is the daemon down.
	return ce.ExitCode == 1 && strings.TrimSpace(ce.Stderr) == ""
}

// isSystemStatus reports whether the failed command was `system status`.
func (e *CommandError) isSystemStatus() bool {
	return len(e.Args) >= 2 && e.Args[0] == "system" && e.Args[1] == "status"
}

// Run executes a short command and returns trimmed stdout.
func (c *CLI) Run(ctx context.Context, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.Bin, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", &CommandError{Args: args, Stdout: stdout.String(), Stderr: stderr.String(), ExitCode: exitStatus(err), Err: err}
	}
	return stdout.String(), nil
}

// exitStatus extracts the process exit code from a cmd.Run error, or -1 when
// the process never produced one (binary missing, killed by the context).
func exitStatus(err error) int {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return -1
}

// Stream runs a long-lived command, yielding stdout/stderr chunks.
func (c *CLI) Stream(ctx context.Context, fn func(line string) error, args ...string) error {
	cmd := exec.CommandContext(ctx, c.Bin, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		if err := fn(scanner.Text()); err != nil {
			_ = cmd.Process.Kill()
			return err
		}
	}
	err = cmd.Wait()
	if err != nil {
		return fmt.Errorf("stream command failed: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func decode[T any](output string) (T, error) {
	var value T
	if err := json.Unmarshal([]byte(output), &value); err != nil {
		return value, fmt.Errorf("parse output: %w", err)
	}
	return value, nil
}

func decodeList[T any](output string) ([]T, error) {
	dec := json.NewDecoder(strings.NewReader(output))
	var list []T
	if err := dec.Decode(&list); err != nil {
		var single T
		if err2 := json.Unmarshal([]byte(output), &single); err2 == nil {
			return []T{single}, nil
		}
		return nil, fmt.Errorf("parse list: %w", err)
	}
	return list, nil
}

// --- DTOs (mirror the CLI --format json shapes) ---

type ContainerListEntry struct {
	ID            string `json:"id"`
	Configuration struct {
		CreationDate string `json:"creationDate"`
		Image        *struct {
			Reference string `json:"reference"`
		} `json:"image"`
		Labels         map[string]string `json:"labels"`
		PublishedPorts []PublishedPort   `json:"publishedPorts"`
		InitProcess    *struct {
			Environment []string `json:"environment"`
		} `json:"initProcess"`
		Mounts []struct {
			Destination string         `json:"destination"`
			Source      string         `json:"source"`
			Options     []string       `json:"options"`
			Type        map[string]any `json:"type"`
		} `json:"mounts"`
		Networks []struct {
			Network string `json:"network"`
		} `json:"networks"`
		Platform  *Platform `json:"platform"`
		Resources *struct {
			CPUs          float64 `json:"cpus"`
			MemoryInBytes int64   `json:"memoryInBytes"`
		} `json:"resources"`
		ReadOnly bool `json:"readOnly"`
		UseInit  bool `json:"useInit"`
		Rosetta  bool `json:"rosetta"`
	} `json:"configuration"`
	Status struct {
		State    string `json:"state"`
		Networks []struct {
			IPv4Address string `json:"ipv4Address"`
			Network     string `json:"network"`
		} `json:"networks"`
	} `json:"status"`
}

type PublishedPort struct {
	HostPort      int    `json:"hostPort"`
	ContainerPort int    `json:"containerPort"`
	Protocol      string `json:"protocol"`
}

type ImageListEntry struct {
	ID            string `json:"id"`
	Configuration struct {
		Name         string `json:"name"`
		CreationDate string `json:"creationDate"`
		Descriptor   *struct {
			Digest string `json:"digest"`
		} `json:"descriptor"`
	} `json:"configuration"`
	Variants []struct {
		Size     int64     `json:"size"`
		Platform *Platform `json:"platform"`
	} `json:"variants"`
}

// Platform is an OCI platform. Current CLI builds emit an object
// ({"os":"linux","architecture":"arm64","variant":"v8"}); older builds emit
// the string form "linux/arm64" — both decode.
type Platform struct {
	OS           string `json:"os"`
	Architecture string `json:"architecture"`
	Variant      string `json:"variant"`
}

func (p *Platform) UnmarshalJSON(data []byte) error {
	var legacy string
	if err := json.Unmarshal(data, &legacy); err == nil {
		parts := strings.Split(legacy, "/")
		*p = Platform{}
		if len(parts) > 0 {
			p.OS = parts[0]
		}
		if len(parts) > 1 {
			p.Architecture = parts[1]
		}
		if len(parts) > 2 {
			p.Variant = parts[2]
		}
		return nil
	}
	type object Platform
	var obj object
	if err := json.Unmarshal(data, &obj); err != nil {
		return err
	}
	*p = Platform(obj)
	return nil
}

// String renders "os/arch" (no variant), the form `--platform` accepts.
func (p Platform) String() string {
	var parts []string
	if p.OS != "" {
		parts = append(parts, p.OS)
	}
	if p.Architecture != "" {
		parts = append(parts, p.Architecture)
	}
	return strings.Join(parts, "/")
}

// Matches reports whether p satisfies a requested "os/arch[/variant]"
// string; a request without a variant matches any variant.
func (p Platform) Matches(requested string) bool {
	want := strings.Split(strings.ToLower(strings.TrimSpace(requested)), "/")
	if len(want) < 2 || want[0] == "" || want[1] == "" {
		return false
	}
	if !strings.EqualFold(p.OS, want[0]) || !strings.EqualFold(p.Architecture, want[1]) {
		return false
	}
	if len(want) > 2 && want[2] != "" && !strings.EqualFold(p.Variant, want[2]) {
		return false
	}
	return true
}

type VolumeListEntry struct {
	ID            string `json:"id"`
	Configuration struct {
		Name         string            `json:"name"`
		Driver       string            `json:"driver"`
		Format       string            `json:"format"`
		SizeInBytes  int64             `json:"sizeInBytes"`
		Source       string            `json:"source"`
		CreationDate string            `json:"creationDate"`
		Labels       map[string]string `json:"labels"`
	} `json:"configuration"`
}

type NetworkListEntry struct {
	ID            string `json:"id"`
	Configuration struct {
		Name         string            `json:"name"`
		Mode         string            `json:"mode"`
		Plugin       string            `json:"plugin"`
		CreationDate string            `json:"creationDate"`
		Labels       map[string]string `json:"labels"`
	} `json:"configuration"`
	Status struct {
		IPv4Gateway string `json:"ipv4Gateway"`
		IPv4Subnet  string `json:"ipv4Subnet"`
		IPv6Subnet  string `json:"ipv6Subnet"`
	} `json:"status"`
}

type StatsEntry struct {
	ID               string `json:"id"`
	CPUUsageUsec     int64  `json:"cpuUsageUsec"`
	MemoryUsageBytes int64  `json:"memoryUsageBytes"`
	MemoryLimitBytes int64  `json:"memoryLimitBytes"`
	NetworkRxBytes   int64  `json:"networkRxBytes"`
	NetworkTxBytes   int64  `json:"networkTxBytes"`
	BlockReadBytes   int64  `json:"blockReadBytes"`
	BlockWriteBytes  int64  `json:"blockWriteBytes"`
	NumProcesses     int64  `json:"numProcesses"`
}

type SystemStatus struct {
	Status           string `json:"status"`
	AppRoot          string `json:"appRoot"`
	InstallRoot      string `json:"installRoot"`
	APIServerVersion string `json:"apiServerVersion"`
}

type SystemVersionEntry struct {
	AppName string `json:"appName"`
	Version string `json:"version"`
}

type DiskUsage struct {
	Containers DiskCategory `json:"containers"`
	Images     DiskCategory `json:"images"`
	Volumes    DiskCategory `json:"volumes"`
}

type DiskCategory struct {
	Total       int64 `json:"total"`
	Active      int64 `json:"active"`
	SizeInBytes int64 `json:"sizeInBytes"`
	Reclaimable int64 `json:"reclaimable"`
}

// --- Operations ---

// SystemStatus runs `system status --format json`. A down apiserver comes
// back as a CommandError satisfying IsRuntimeStopped; should the CLI ever
// exit 0 with one of its stopped words, Status is normalised to "stopped" so
// callers compare against a single value (as SystemService.status does).
func (c *CLI) SystemStatus(ctx context.Context) (*SystemStatus, error) {
	out, err := c.Run(ctx, "system", "status", "--format", "json")
	if err != nil {
		return nil, err
	}
	status, err := decode[*SystemStatus](out)
	if err != nil {
		return nil, err
	}
	if stoppedStatusValues[strings.ToLower(status.Status)] {
		status.Status = "stopped"
	}
	return status, nil
}

func (c *CLI) SystemVersion(ctx context.Context) (string, error) {
	out, err := c.Run(ctx, "system", "version", "--format", "json")
	if err != nil {
		return "", err
	}
	entries, err := decodeList[SystemVersionEntry](out)
	if err != nil || len(entries) == 0 {
		return "unknown", err
	}
	for _, e := range entries {
		if e.AppName == "container" {
			return e.Version, nil
		}
	}
	return entries[0].Version, nil
}

func (c *CLI) DiskUsage(ctx context.Context) (*DiskUsage, error) {
	out, err := c.Run(ctx, "system", "df", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decode[*DiskUsage](out)
}

func (c *CLI) ListContainers(ctx context.Context) ([]ContainerListEntry, error) {
	out, err := c.Run(ctx, "list", "--all", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decodeList[ContainerListEntry](out)
}

// InspectContainer resolves one container by id or name. A missing container
// is reported as a CommandError satisfying IsNotFound.
func (c *CLI) InspectContainer(ctx context.Context, id string) (*ContainerListEntry, error) {
	out, err := c.Run(ctx, "inspect", id)
	if err != nil {
		return nil, err
	}
	entries, err := decodeList[ContainerListEntry](out)
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, &CommandError{Args: []string{"inspect", id}, Stderr: "no such container: " + id, Err: errors.New("empty inspect result")}
	}
	return &entries[0], nil
}

func (c *CLI) RunContainer(ctx context.Context, args ...string) (string, error) {
	out, err := c.Run(ctx, append([]string{"run"}, args...)...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

func (c *CLI) CreateContainer(ctx context.Context, args ...string) (string, error) {
	out, err := c.Run(ctx, append([]string{"create"}, args...)...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

func (c *CLI) SimpleAction(ctx context.Context, verb, id string) error {
	_, err := c.Run(ctx, verb, id)
	return err
}

func (c *CLI) DeleteContainer(ctx context.Context, id string, force bool) error {
	args := []string{"delete"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, id)
	_, err := c.Run(ctx, args...)
	return err
}

func (c *CLI) StreamLogs(ctx context.Context, id string, tail int, boot bool, fn func(string) error) error {
	args := []string{"logs", "-n", strconv.Itoa(tail)}
	if boot {
		args = append(args, "--boot")
	}
	args = append(args, "--follow", id)
	return c.Stream(ctx, fn, args...)
}

func (c *CLI) ListImages(ctx context.Context) ([]ImageListEntry, error) {
	out, err := c.Run(ctx, "image", "list", "--format", "json", "--verbose")
	if err != nil {
		return nil, err
	}
	return decodeList[ImageListEntry](out)
}

// InspectImage resolves one local image by reference or id without pulling.
// A missing image is reported as a CommandError satisfying IsNotFound.
func (c *CLI) InspectImage(ctx context.Context, reference string) (*ImageListEntry, error) {
	out, err := c.Run(ctx, "image", "inspect", reference)
	if err != nil {
		return nil, err
	}
	entries, err := decodeList[ImageListEntry](out)
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, &CommandError{Args: []string{"image", "inspect", reference}, Stderr: "no such image: " + reference, Err: errors.New("empty inspect result")}
	}
	return &entries[0], nil
}

func (c *CLI) PullImage(ctx context.Context, reference string, fn func(line string) error) error {
	return c.Stream(ctx, fn, "image", "pull", "--progress", "plain", reference)
}

func (c *CLI) DeleteImage(ctx context.Context, reference string, force bool) error {
	args := []string{"image", "delete"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, reference)
	_, err := c.Run(ctx, args...)
	return err
}

func (c *CLI) ListVolumes(ctx context.Context) ([]VolumeListEntry, error) {
	out, err := c.Run(ctx, "volume", "list", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decodeList[VolumeListEntry](out)
}

// InspectVolume resolves one named volume. A missing volume is reported as a
// CommandError satisfying IsNotFound.
func (c *CLI) InspectVolume(ctx context.Context, name string) (*VolumeListEntry, error) {
	out, err := c.Run(ctx, "volume", "inspect", name)
	if err != nil {
		return nil, err
	}
	entries, err := decodeList[VolumeListEntry](out)
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, &CommandError{Args: []string{"volume", "inspect", name}, Stderr: "no such volume: " + name, Err: errors.New("empty inspect result")}
	}
	return &entries[0], nil
}

// CreateVolume runs `volume create [-s size] [--label k=v]... name`.
func (c *CLI) CreateVolume(ctx context.Context, name, size string, labels ...string) error {
	args := []string{"volume", "create"}
	if size != "" {
		args = append(args, "-s", size)
	}
	for _, label := range labels {
		args = append(args, "--label", label)
	}
	args = append(args, name)
	_, err := c.Run(ctx, args...)
	return err
}

func (c *CLI) DeleteVolume(ctx context.Context, name string) error {
	_, err := c.Run(ctx, "volume", "delete", name)
	return err
}

func (c *CLI) ListNetworks(ctx context.Context) ([]NetworkListEntry, error) {
	out, err := c.Run(ctx, "network", "list", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decodeList[NetworkListEntry](out)
}

func (c *CLI) CreateNetwork(ctx context.Context, name, subnet string, internal bool) error {
	args := []string{"network", "create"}
	if internal {
		args = append(args, "--internal")
	}
	if subnet != "" {
		args = append(args, "--subnet", subnet)
	}
	args = append(args, name)
	_, err := c.Run(ctx, args...)
	return err
}

func (c *CLI) DeleteNetwork(ctx context.Context, name string) error {
	_, err := c.Run(ctx, "network", "delete", name)
	return err
}

func (c *CLI) Stats(ctx context.Context) ([]StatsEntry, error) {
	out, err := c.Run(ctx, "stats", "--no-stream", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decodeList[StatsEntry](out)
}

// ExecResult carries the guest process exit code alongside captured output.
type ExecResult struct {
	Output   string
	Error    string
	ExitCode int32
}

// ExecSpec describes one `container exec` invocation. Argv is passed through
// verbatim as separate arguments — no shell splitting happens here.
type ExecSpec struct {
	ID      string
	Workdir string
	Env     []string
	Argv    []string
}

// Args renders the CLI argv: exec [--workdir W] [--env E]... <id> <argv...>
// (the same shape MicropodCore's ContainerCommand.exec builds).
func (s ExecSpec) Args() []string {
	args := []string{"exec"}
	if s.Workdir != "" {
		args = append(args, "--workdir", s.Workdir)
	}
	for _, env := range s.Env {
		args = append(args, "--env", env)
	}
	args = append(args, s.ID)
	args = append(args, s.Argv...)
	return args
}

func (c *CLI) Exec(ctx context.Context, spec ExecSpec) (string, error) {
	out, err := c.Run(ctx, spec.Args()...)
	if err != nil {
		return "", err
	}
	return out, nil
}

// ExecDetailed runs `container exec` and reports the guest exit code rather
// than failing on non-zero exits. Because the CLI also exits non-zero when
// the container does not exist, callers that need to tell the two apart
// should confirm with InspectContainer (see LooksLikeNotFound).
func (c *CLI) ExecDetailed(ctx context.Context, spec ExecSpec) (*ExecResult, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	args := spec.Args()
	cmd := exec.CommandContext(ctx, c.Bin, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	res := &ExecResult{
		Output: stdout.String(),
		Error:  strings.TrimSpace(stderr.String()),
	}
	if err == nil {
		return res, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		res.ExitCode = int32(exitErr.ExitCode())
		if res.ExitCode < 0 {
			res.ExitCode = 128
		}
		return res, nil
	}
	return nil, &CommandError{Args: args, Stdout: res.Output, Stderr: res.Error, ExitCode: exitStatus(err), Err: err}
}

// LooksLikeNotFound is the exec-side pre-filter: does the stderr of a failed
// `container exec` mention a missing resource at all? It is deliberately
// broader than IsNotFound (any "not found", any "no such") because the exit
// status alone cannot distinguish "container with ID x not found" from a
// guest process exiting 1, and the caller confirms with InspectContainer
// before returning not_found — so a guest's own "sh: foo: not found" only
// costs one extra inspect and is never misclassified.
func LooksLikeNotFound(stderr string) bool {
	return looksLikeNotFound(stderr) || strings.Contains(strings.ToLower(stderr), "not found")
}
