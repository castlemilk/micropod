// Package server implements the micropod.v1 connect-go handlers on top of
// the `container` CLI client.
package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"connectrpc.com/connect"

	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
	"micropod/api/internal/clicli"
)

// runtimeBackend is what this server reports in `runtime_backend`: every
// call here is a `container` CLI spawn, never a native XPC call.
const runtimeBackend = "cli"

// WaitContainer polling bounds (spec §3.1: default 30 s, cap 300 s).
const (
	defaultWaitTimeout = 30 * time.Second
	maxWaitTimeout     = 300 * time.Second
	waitPollInterval   = 150 * time.Millisecond
)

// Server implements all six micropod.v1 domain services on top of the
// `container` CLI. App-owned RPCs it can't serve (volume policy, updates,
// compose, CommitVolumeClone — this server never creates per-container
// clones) fall through to the embedded unimplemented handlers.
type Server struct {
	micropodv1connect.UnimplementedContainerServiceHandler
	micropodv1connect.UnimplementedImageServiceHandler
	micropodv1connect.UnimplementedVolumeServiceHandler
	micropodv1connect.UnimplementedNetworkServiceHandler
	micropodv1connect.UnimplementedComposeServiceHandler
	micropodv1connect.UnimplementedSystemServiceHandler
	micropodv1connect.UnimplementedK8SServiceHandler
	micropodv1connect.UnimplementedMachineServiceHandler
	cli *clicli.CLI

	versionMu  sync.Mutex
	cliVersion string
}

func New(cli *clicli.CLI) *Server {
	return &Server{cli: cli}
}

// mapError turns a CLI failure into a Connect error: missing resources are
// not_found, a stopped runtime or any other CLI failure is unavailable, and
// an expired deadline is deadline_exceeded.
func mapError(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, context.DeadlineExceeded):
		return connect.NewError(connect.CodeDeadlineExceeded, err)
	case errors.Is(err, context.Canceled):
		return connect.NewError(connect.CodeCanceled, err)
	case clicli.IsNotFound(err):
		return connect.NewError(connect.CodeNotFound, err)
	default:
		return connect.NewError(connect.CodeUnavailable, err)
	}
}

// cachedCLIVersion memoises `container system version`; the binary does not
// change while the server runs and Ping must stay cheap.
func (s *Server) cachedCLIVersion(ctx context.Context) (string, error) {
	s.versionMu.Lock()
	defer s.versionMu.Unlock()
	if s.cliVersion != "" {
		return s.cliVersion, nil
	}
	version, err := s.cli.SystemVersion(ctx)
	if err != nil {
		return "", err
	}
	s.cliVersion = version
	return version, nil
}

// systemStatus runs `container system status` and folds every shape the CLI
// uses for a down apiserver — the {"status":"unregistered"|"not running"}
// stdout payload with exit 1 and an empty stderr, the table-mode sentence,
// the XPC transport text (see clicli.IsRuntimeStopped) — into stopped=true.
// Any other failure is returned as err.
func (s *Server) systemStatus(ctx context.Context) (status *clicli.SystemStatus, stopped bool, err error) {
	status, err = s.cli.SystemStatus(ctx)
	switch {
	case err == nil && status.Status == "stopped":
		return nil, true, nil
	case err == nil:
		return status, false, nil
	case clicli.IsRuntimeStopped(err):
		return nil, true, nil
	default:
		return nil, false, err
	}
}

// GetSystem reports status plus disk usage. A stopped runtime is a status
// ("stopped", no disk usage), not an error; use Ping when df is not needed.
func (s *Server) GetSystem(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.SystemSnapshot], error) {
	status, stopped, err := s.systemStatus(ctx)
	if err != nil {
		return nil, mapError(err)
	}
	if stopped {
		// `system version` never talks to the apiserver, so the CLI version
		// stays known while the daemon is down.
		version, _ := s.cachedCLIVersion(ctx)
		return connect.NewResponse(&micropodv1.SystemSnapshot{
			Status: &micropodv1.SystemStatus{Status: "stopped", CliVersion: version, RuntimeBackend: runtimeBackend},
		}), nil
	}
	version, err := s.cachedCLIVersion(ctx)
	if err != nil {
		return nil, mapError(err)
	}
	usage, err := s.cli.DiskUsage(ctx)
	if err != nil {
		return nil, mapError(err)
	}
	return connect.NewResponse(&micropodv1.SystemSnapshot{
		Status: &micropodv1.SystemStatus{
			Status:           status.Status,
			AppRoot:          status.AppRoot,
			InstallRoot:      status.InstallRoot,
			ApiServerVersion: status.APIServerVersion,
			CliVersion:       version,
			RuntimeBackend:   runtimeBackend,
		},
		DiskUsage: &micropodv1.DiskUsage{
			Containers: category(usage.Containers),
			Images:     category(usage.Images),
			Volumes:    category(usage.Volumes),
		},
	}), nil
}

// Ping is the cheap liveness probe: one `system status` spawn, no df. The
// CLI version is memoised so repeated pings cost a single process.
// Features are the optional RunContainerRequest capabilities this server
// honours (PingResponse.features). Mirrors MicropodCore's APIFeatures.
var Features = []string{"cap_add", "cap_drop", "rosetta", "privileged", "runtime"}

func (s *Server) Ping(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.PingResponse], error) {
	version, _ := s.cachedCLIVersion(ctx)
	res := &micropodv1.PingResponse{
		RuntimeBackend: runtimeBackend, CliVersion: version, Features: Features, DefaultRuntime: appleRuntime,
	}
	status, stopped, err := s.systemStatus(ctx)
	switch {
	case err != nil:
		return nil, mapError(err)
	case stopped:
		res.Status = "stopped"
	default:
		res.Status = "running"
		res.ApiServerVersion = status.APIServerVersion
	}
	return connect.NewResponse(res), nil
}

// appleRuntime is the only engine this server drives.
const appleRuntime = "apple"

// ListRuntimes reports the single apple engine this server drives.
func (s *Server) ListRuntimes(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.ListRuntimesResponse], error) {
	return connect.NewResponse(s.runtimes(ctx)), nil
}

func (s *Server) runtimes(ctx context.Context) *micropodv1.ListRuntimesResponse {
	info := &micropodv1.RuntimeInfo{
		Name:        appleRuntime,
		Kind:        "vm",
		Description: "Apple container runtime — one micro-VM per container",
		Endpoint:    s.cli.Bin,
		Default:     true,
		Enabled:     true,
		Capabilities: []string{
			"run", "create", "start", "stop", "restart", "kill", "delete", "exec", "logs", "stats", "ports", "volumes",
		},
	}
	if s.cli.Available() {
		info.Available = true
		info.Version, _ = s.cachedCLIVersion(ctx)
	} else {
		info.Reason = "container CLI not found at " + s.cli.Bin
	}
	return &micropodv1.ListRuntimesResponse{Runtimes: []*micropodv1.RuntimeInfo{info}, Default: appleRuntime}
}

// SetDefaultRuntime accepts only "apple" — the one engine this server has.
func (s *Server) SetDefaultRuntime(ctx context.Context, req *connect.Request[micropodv1.SetDefaultRuntimeRequest]) (*connect.Response[micropodv1.ListRuntimesResponse], error) {
	if req.Msg.Name != appleRuntime {
		return nil, connect.NewError(connect.CodeFailedPrecondition,
			fmt.Errorf("runtime %q is not available on this server (only %q)", req.Msg.Name, appleRuntime))
	}
	return connect.NewResponse(s.runtimes(ctx)), nil
}

// UpdateRuntime can't disable or re-point the apple engine.
func (s *Server) UpdateRuntime(ctx context.Context, req *connect.Request[micropodv1.UpdateRuntimeRequest]) (*connect.Response[micropodv1.ListRuntimesResponse], error) {
	switch {
	case req.Msg.Name != appleRuntime:
		return nil, connect.NewError(connect.CodeFailedPrecondition,
			fmt.Errorf("runtime %q is not available on this server (only %q)", req.Msg.Name, appleRuntime))
	case req.Msg.Enabled != nil && !*req.Msg.Enabled:
		return nil, connect.NewError(connect.CodeFailedPrecondition,
			errors.New("apple is the default runtime and cannot be disabled"))
	case req.Msg.Endpoint != nil && *req.Msg.Endpoint != "":
		return nil, connect.NewError(connect.CodeInvalidArgument,
			errors.New("runtime \"apple\" has no configurable endpoint"))
	}
	return connect.NewResponse(s.runtimes(ctx)), nil
}

func category(c clicli.DiskCategory) *micropodv1.DiskCategory {
	return &micropodv1.DiskCategory{
		Total:            uint64(c.Total),
		Active:           uint64(c.Active),
		SizeBytes:        uint64(c.SizeInBytes),
		ReclaimableBytes: uint64(c.Reclaimable),
	}
}

func (s *Server) ListContainers(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.ListContainersResponse], error) {
	entries, err := s.cli.ListContainers(ctx)
	if err != nil {
		return nil, mapError(err)
	}
	containers := make([]*micropodv1.Container, 0, len(entries))
	for _, e := range entries {
		containers = append(containers, containerFrom(e))
	}
	return connect.NewResponse(&micropodv1.ListContainersResponse{Containers: containers}), nil
}

// GetContainer inspects one container by id or name.
func (s *Server) GetContainer(ctx context.Context, req *connect.Request[micropodv1.ContainerRef]) (*connect.Response[micropodv1.Container], error) {
	entry, err := s.cli.InspectContainer(ctx, req.Msg.Id)
	if err != nil {
		return nil, mapError(err)
	}
	return connect.NewResponse(containerFrom(*entry)), nil
}

// WaitContainer polls `inspect` until the container leaves a non-terminal
// state (running, stopping, created) or the bounded timeout elapses. The CLI
// exposes no exit code, so `known` is always false here; `exited` is still
// authoritative. A container deleted mid-wait reports state "unknown".
func (s *Server) WaitContainer(ctx context.Context, req *connect.Request[micropodv1.WaitContainerRequest]) (*connect.Response[micropodv1.WaitContainerResponse], error) {
	timeout := time.Duration(req.Msg.TimeoutSeconds) * time.Second
	if timeout <= 0 {
		timeout = defaultWaitTimeout
	}
	if timeout > maxWaitTimeout {
		timeout = maxWaitTimeout
	}
	deadline := time.Now().Add(timeout)
	first := true
	for {
		entry, err := s.cli.InspectContainer(ctx, req.Msg.Id)
		var state string
		switch {
		case err == nil:
			state = strings.ToLower(entry.Status.State)
			if state == "" {
				state = "unknown"
			}
		case clicli.IsNotFound(err) && first:
			return nil, mapError(err)
		case clicli.IsNotFound(err):
			state = "unknown"
		default:
			return nil, mapError(err)
		}
		first = false

		switch state {
		case "running", "stopping", "created":
			// non-terminal: keep polling
		default:
			return connect.NewResponse(&micropodv1.WaitContainerResponse{Exited: true, Known: false, State: state}), nil
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return connect.NewResponse(&micropodv1.WaitContainerResponse{Exited: false, Known: false, State: state}), nil
		}
		wait := min(waitPollInterval, remaining)
		select {
		case <-ctx.Done():
			return nil, mapError(ctx.Err())
		case <-time.After(wait):
		}
	}
}

func containerFrom(e clicli.ContainerListEntry) *micropodv1.Container {
	c := &micropodv1.Container{
		Id:        e.ID,
		State:     e.Status.State,
		Image:     "",
		Env:       nil,
		Labels:    map[string]string{},
		Mounts:    nil,
		CreatedAt: e.Configuration.CreationDate,
	}
	if e.Configuration.Image != nil {
		c.Image = e.Configuration.Image.Reference
	}
	if e.Configuration.InitProcess != nil {
		c.Env = e.Configuration.InitProcess.Environment
	}
	for k, v := range e.Configuration.Labels {
		c.Labels[k] = v
	}
	if e.Configuration.Platform != nil {
		c.Platform = e.Configuration.Platform.String()
	}
	for _, p := range e.Configuration.PublishedPorts {
		c.PublishedPorts = append(c.PublishedPorts, &micropodv1.PortMapping{
			HostPort:      uint32(p.HostPort),
			ContainerPort: uint32(p.ContainerPort),
			Protocol:      p.Protocol,
		})
	}
	for _, m := range e.Configuration.Mounts {
		c.Mounts = append(c.Mounts, &micropodv1.Mount{
			Type:        firstKey(m.Type),
			Source:      m.Source,
			Destination: m.Destination,
		})
	}
	for _, n := range e.Configuration.Networks {
		c.Networks = append(c.Networks, n.Network)
	}
	for _, sn := range e.Status.Networks {
		if sn.Network == "default" && sn.IPv4Address != "" {
			c.Ipv4Address = strings.Split(sn.IPv4Address, "/")[0]
		}
	}
	if e.Configuration.Resources != nil {
		c.Resources = &micropodv1.ContainerResources{
			Cpus:        e.Configuration.Resources.CPUs,
			MemoryBytes: uint64(e.Configuration.Resources.MemoryInBytes),
		}
	}
	c.ReadOnly = e.Configuration.ReadOnly
	c.UseInit = e.Configuration.UseInit
	c.Rosetta = e.Configuration.Rosetta
	return c
}

func firstKey(m map[string]any) string {
	for k := range m {
		return k
	}
	return "unknown"
}

// runArgs renders `container run|create` flags. Optional strings are only
// emitted when set and non-empty; the image separates flags from the argv.
func runArgs(req *micropodv1.RunContainerRequest) []string {
	args := []string{"--detach"}
	if req.Name != nil && *req.Name != "" {
		args = append(args, "--name", *req.Name)
	}
	if req.Cpus != nil {
		args = append(args, "--cpus", fmtFloat(*req.Cpus))
	}
	if req.Memory != nil && *req.Memory != "" {
		args = append(args, "--memory", *req.Memory)
	}
	if v := req.GetEntrypoint(); v != "" {
		args = append(args, "--entrypoint", v)
	}
	if v := req.GetPlatform(); v != "" {
		args = append(args, "--platform", v)
	}
	if v := req.GetWorkdir(); v != "" {
		args = append(args, "--workdir", v)
	}
	if v := req.GetUser(); v != "" {
		args = append(args, "--user", v)
	}
	for _, env := range req.Env {
		args = append(args, "--env", env)
	}
	for _, port := range req.Ports {
		args = append(args, "--publish", fmt.Sprintf("%d:%d/%s", port.HostPort, port.ContainerPort, port.Protocol))
	}
	for _, vol := range req.Volumes {
		args = append(args, "--volume", vol)
	}
	for k, v := range req.Labels {
		args = append(args, "--label", k+"="+v)
	}
	if req.Init {
		args = append(args, "--init")
	}
	if req.GetRosetta() {
		args = append(args, "--rosetta")
	}
	for _, c := range effectiveCapAdd(req) {
		args = append(args, "--cap-add", c)
	}
	for _, c := range req.CapDrop {
		args = append(args, "--cap-drop", c)
	}
	if req.GetPrivileged() {
		// NONE clears the runtime's default read-only (/proc/sys, ...) and
		// masked paths.
		args = append(args, "--read-only-path", "NONE", "--masked-path", "NONE")
	}
	args = append(args, req.Image)
	args = append(args, req.Arguments...)
	return args
}

// orderedCapabilities is every capability Linux defines, in kernel order
// (CAP_CHOWN = 0 … CAP_CHECKPOINT_RESTORE = 40), without the CAP_ prefix.
// Mirrors MicropodCore's LinuxCapabilities.ordered.
var orderedCapabilities = []string{
	"CHOWN", "DAC_OVERRIDE", "DAC_READ_SEARCH", "FOWNER", "FSETID", "KILL",
	"SETGID", "SETUID", "SETPCAP", "LINUX_IMMUTABLE", "NET_BIND_SERVICE",
	"NET_BROADCAST", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "IPC_OWNER",
	"SYS_MODULE", "SYS_RAWIO", "SYS_CHROOT", "SYS_PTRACE", "SYS_PACCT",
	"SYS_ADMIN", "SYS_BOOT", "SYS_NICE", "SYS_RESOURCE", "SYS_TIME",
	"SYS_TTY_CONFIG", "MKNOD", "LEASE", "AUDIT_WRITE", "AUDIT_CONTROL",
	"SETFCAP", "MAC_OVERRIDE", "MAC_ADMIN", "SYSLOG", "WAKE_ALARM",
	"BLOCK_SUSPEND", "AUDIT_READ", "PERFMON", "BPF", "CHECKPOINT_RESTORE",
}

// linuxCapabilities is orderedCapabilities as a set.
var linuxCapabilities = func() map[string]bool {
	m := make(map[string]bool, len(orderedCapabilities))
	for _, c := range orderedCapabilities {
		m[c] = true
	}
	return m
}()

func bareCapability(name string) string {
	return strings.TrimPrefix(strings.ToUpper(name), "CAP_")
}

// normalizeCapabilities maps docker-style names (case-insensitive, CAP_
// prefix optional, "ALL" wildcard) to the CAP_* spelling, de-duplicated.
// Names match exactly — surrounding whitespace is invalid, as in the
// proto's buf.validate pattern (and MicropodCore's LinuxCapabilities).
// Unknown names fail invalid_argument.
func normalizeCapabilities(field string, names []string) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	for _, raw := range names {
		upper := strings.ToUpper(raw)
		norm := "ALL"
		if upper != "ALL" {
			bare := strings.TrimPrefix(upper, "CAP_")
			if !linuxCapabilities[bare] {
				return nil, connect.NewError(connect.CodeInvalidArgument,
					fmt.Errorf("%s: unknown Linux capability %q (use a name like NET_ADMIN or CAP_NET_ADMIN, or ALL)", field, raw))
			}
			norm = "CAP_" + bare
		}
		if !seen[norm] {
			seen[norm] = true
			out = append(out, norm)
		}
	}
	return out, nil
}

// effectiveCapAdd is what the runtime is asked to add. The runtime applies
// --cap-drop before --cap-add, so an ALL add (explicit, or implied by
// privileged) would silently re-grant every dropped capability: with drops
// present ALL expands to every capability except the dropped ones, so
// cap_drop really applies on top. Mirrors ContainerRunRequest.effectiveCapAdd.
func effectiveCapAdd(req *micropodv1.RunContainerRequest) []string {
	wantsAll := req.GetPrivileged()
	for _, c := range req.CapAdd {
		if bareCapability(c) == "ALL" {
			wantsAll = true
		}
	}
	if !wantsAll {
		return req.CapAdd
	}
	dropped := map[string]bool{}
	for _, c := range req.CapDrop {
		dropped[bareCapability(c)] = true
	}
	if len(dropped) == 0 || dropped["ALL"] {
		return []string{"ALL"}
	}
	var out []string
	for _, c := range orderedCapabilities {
		if !dropped[c] {
			out = append(out, "CAP_"+c)
		}
	}
	return out
}

// normalizeRunRequest validates and normalises the capability lists in
// place, and refuses cap_drop ALL together with privileged or cap_add ALL
// (the runtime would silently grant every capability).
func normalizeRunRequest(req *micropodv1.RunContainerRequest) error {
	// This server only drives the apple engine (the `container` CLI); the
	// docker and sandbox engines live in the Swift MicropodAPI.
	if req.Runtime != nil && *req.Runtime != appleRuntime {
		return connect.NewError(connect.CodeFailedPrecondition,
			fmt.Errorf("runtime %q is not available on this server (only %q)", *req.Runtime, appleRuntime))
	}
	var err error
	if req.CapAdd, err = normalizeCapabilities("cap_add", req.CapAdd); err != nil {
		return err
	}
	if req.CapDrop, err = normalizeCapabilities("cap_drop", req.CapDrop); err != nil {
		return err
	}
	dropAll, addAll := false, false
	for _, c := range req.CapDrop {
		dropAll = dropAll || c == "ALL"
	}
	for _, c := range req.CapAdd {
		addAll = addAll || c == "ALL"
	}
	switch {
	case dropAll && req.GetPrivileged():
		return connect.NewError(connect.CodeInvalidArgument, fmt.Errorf(
			"cap_drop ALL cannot be combined with privileged (privileged grants every capability); drop specific capabilities instead"))
	case dropAll && addAll:
		return connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("cap_drop ALL cannot be combined with cap_add ALL"))
	}
	return nil
}

func fmtFloat(f float64) string {
	return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.6f", f), "0"), ".")
}

// checkNoPull implements `no_pull`: when set, the image must already be
// present locally — for the requested platform when one was given — or the
// request fails not_found before `container run|create` (which would pull
// with no timeout) is ever spawned.
func (s *Server) checkNoPull(ctx context.Context, req *micropodv1.RunContainerRequest) error {
	if !req.NoPull {
		return nil
	}
	platform := req.GetPlatform()
	entry, err := s.cli.InspectImage(ctx, req.Image)
	if err != nil {
		if clicli.IsNotFound(err) {
			suffix := ""
			if platform != "" {
				suffix = " for " + platform
			}
			return connect.NewError(connect.CodeNotFound, fmt.Errorf("image %s not present locally%s (no_pull)", req.Image, suffix))
		}
		return mapError(err)
	}
	if platform == "" {
		return nil
	}
	var have []string
	for _, v := range entry.Variants {
		if v.Platform == nil {
			continue
		}
		if v.Platform.Matches(platform) {
			return nil
		}
		have = append(have, v.Platform.String())
	}
	present := "no platform variants recorded"
	if len(have) > 0 {
		present = "have " + strings.Join(have, ", ")
	}
	return connect.NewError(connect.CodeNotFound, fmt.Errorf("image %s not present locally for %s (%s; no_pull)", req.Image, platform, present))
}

func (s *Server) RunContainer(ctx context.Context, req *connect.Request[micropodv1.RunContainerRequest]) (*connect.Response[micropodv1.ContainerRef], error) {
	if err := normalizeRunRequest(req.Msg); err != nil {
		return nil, err
	}
	if err := s.checkNoPull(ctx, req.Msg); err != nil {
		return nil, err
	}
	id, err := s.cli.RunContainer(ctx, runArgs(req.Msg)...)
	if err != nil {
		return nil, mapError(err)
	}
	return connect.NewResponse(&micropodv1.ContainerRef{Id: id}), nil
}

func (s *Server) CreateContainer(ctx context.Context, req *connect.Request[micropodv1.RunContainerRequest]) (*connect.Response[micropodv1.ContainerRef], error) {
	if err := normalizeRunRequest(req.Msg); err != nil {
		return nil, err
	}
	if err := s.checkNoPull(ctx, req.Msg); err != nil {
		return nil, err
	}
	id, err := s.cli.CreateContainer(ctx, runArgs(req.Msg)...)
	if err != nil {
		return nil, mapError(err)
	}
	return connect.NewResponse(&micropodv1.ContainerRef{Id: id}), nil
}

func (s *Server) StartContainer(ctx context.Context, req *connect.Request[micropodv1.ContainerRef]) (*connect.Response[micropodv1.Empty], error) {
	return empty(s.cli.SimpleAction(ctx, "start", req.Msg.Id))
}

func (s *Server) StopContainer(ctx context.Context, req *connect.Request[micropodv1.ContainerRef]) (*connect.Response[micropodv1.Empty], error) {
	return empty(s.cli.SimpleAction(ctx, "stop", req.Msg.Id))
}

func (s *Server) RestartContainer(ctx context.Context, req *connect.Request[micropodv1.ContainerRef]) (*connect.Response[micropodv1.Empty], error) {
	if err := s.cli.SimpleAction(ctx, "stop", req.Msg.Id); err != nil {
		return empty(err)
	}
	return empty(s.cli.SimpleAction(ctx, "start", req.Msg.Id))
}

func (s *Server) KillContainer(ctx context.Context, req *connect.Request[micropodv1.ContainerRef]) (*connect.Response[micropodv1.Empty], error) {
	return empty(s.cli.SimpleAction(ctx, "kill", req.Msg.Id))
}

func (s *Server) DeleteContainer(ctx context.Context, req *connect.Request[micropodv1.DeleteContainerRequest]) (*connect.Response[micropodv1.Empty], error) {
	return empty(s.cli.DeleteContainer(ctx, req.Msg.Id, req.Msg.Force))
}

func empty(err error) (*connect.Response[micropodv1.Empty], error) {
	if err != nil {
		return nil, mapError(err)
	}
	return connect.NewResponse(&micropodv1.Empty{}), nil
}

// StreamContainerLogs follows the container log. `skip_lines` drops that many
// leading lines so a client can re-open after a transport error without
// replaying what it already delivered.
func (s *Server) StreamContainerLogs(ctx context.Context, req *connect.Request[micropodv1.StreamLogsRequest], stream *connect.ServerStream[micropodv1.LogChunk]) error {
	skip := req.Msg.SkipLines
	return s.cli.StreamLogs(ctx, req.Msg.Id, int(req.Msg.Tail), req.Msg.Boot, func(line string) error {
		if skip > 0 {
			skip--
			return nil
		}
		return stream.Send(&micropodv1.LogChunk{Text: line})
	})
}

func (s *Server) ListImages(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.ListImagesResponse], error) {
	entries, err := s.cli.ListImages(ctx)
	if err != nil {
		return nil, mapError(err)
	}
	images := make([]*micropodv1.Image, 0, len(entries))
	for _, e := range entries {
		images = append(images, imageFrom(e))
	}
	return connect.NewResponse(&micropodv1.ListImagesResponse{Images: images}), nil
}

func imageFrom(e clicli.ImageListEntry) *micropodv1.Image {
	img := &micropodv1.Image{
		Id:        e.ID,
		Names:     nil,
		CreatedAt: e.Configuration.CreationDate,
	}
	if e.Configuration.Name != "" {
		img.Names = []string{e.Configuration.Name}
	}
	if e.Configuration.Descriptor != nil {
		img.Digest = e.Configuration.Descriptor.Digest
	}
	for _, v := range e.Variants {
		img.SizeBytes += uint64(v.Size)
	}
	return img
}

func (s *Server) PullImage(ctx context.Context, req *connect.Request[micropodv1.PullImageRequest], stream *connect.ServerStream[micropodv1.ProgressLine]) error {
	return s.cli.PullImage(ctx, req.Msg.Reference, func(line string) error {
		return stream.Send(&micropodv1.ProgressLine{Line: line})
	})
}

func (s *Server) DeleteImage(ctx context.Context, req *connect.Request[micropodv1.DeleteImageRequest]) (*connect.Response[micropodv1.Empty], error) {
	return empty(s.cli.DeleteImage(ctx, req.Msg.Reference, req.Msg.Force))
}

func (s *Server) ListVolumes(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.ListVolumesResponse], error) {
	entries, err := s.cli.ListVolumes(ctx)
	if err != nil {
		return nil, mapError(err)
	}
	volumes := make([]*micropodv1.Volume, 0, len(entries))
	for _, e := range entries {
		volumes = append(volumes, volumeFrom(e))
	}
	return connect.NewResponse(&micropodv1.ListVolumesResponse{Volumes: volumes}), nil
}

func volumeFrom(e clicli.VolumeListEntry) *micropodv1.Volume {
	return &micropodv1.Volume{
		Id:             e.ID,
		Driver:         e.Configuration.Driver,
		Format:         e.Configuration.Format,
		SizeBytes:      uint64(e.Configuration.SizeInBytes),
		Source:         e.Configuration.Source,
		CreatedAt:      e.Configuration.CreationDate,
		Labels:         e.Configuration.Labels,
		AllocatedBytes: allocatedBytes(e.Configuration.Source),
	}
}

// allocatedBytes is st_blocks × 512 of the backing image — real on-disk
// usage, as opposed to the provisioned (sparse) size. 0 when the path
// cannot be stat'ed.
func allocatedBytes(path string) uint64 {
	if path == "" {
		return 0
	}
	var st syscall.Stat_t
	if err := syscall.Stat(path, &st); err != nil {
		return 0
	}
	if st.Blocks < 0 {
		return 0
	}
	return uint64(st.Blocks) * 512
}

func (s *Server) CreateVolume(ctx context.Context, req *connect.Request[micropodv1.CreateVolumeRequest]) (*connect.Response[micropodv1.Empty], error) {
	return empty(s.cli.CreateVolume(ctx, req.Msg.Name, req.Msg.GetSize(), req.Msg.Labels...))
}

func (s *Server) DeleteVolume(ctx context.Context, req *connect.Request[micropodv1.DeleteVolumeRequest]) (*connect.Response[micropodv1.Empty], error) {
	return empty(s.cli.DeleteVolume(ctx, req.Msg.Name))
}

// CloneVolume creates `name` (size defaults to the source's provisioned
// size) and clonefiles the source image over the new image: an O(1)
// copy-on-write fork on APFS. Refused with failed_precondition while the
// source is attached read-write to a running (or stopping) container, since
// the clone would capture a dirty filesystem. A failed clone deletes the
// half-made volume so no empty volume is left behind.
func (s *Server) CloneVolume(ctx context.Context, req *connect.Request[micropodv1.CloneVolumeRequest]) (*connect.Response[micropodv1.Volume], error) {
	source, err := s.cli.InspectVolume(ctx, req.Msg.Source)
	if err != nil {
		return nil, mapError(err)
	}
	writer, err := s.runningWriter(ctx, source)
	if err != nil {
		return nil, err
	}
	if writer != "" {
		return nil, connect.NewError(connect.CodeFailedPrecondition,
			fmt.Errorf("volume %s is attached read-write to running container %s", req.Msg.Source, writer))
	}
	if _, err := os.Stat(source.Configuration.Source); err != nil {
		return nil, connect.NewError(connect.CodeNotFound,
			fmt.Errorf("volume %s has no backing image at %q: %w", req.Msg.Source, source.Configuration.Source, err))
	}

	size := req.Msg.GetSize()
	if size == "" {
		size = sizeArg(source.Configuration.SizeInBytes)
	}
	labels := append(slices.Clone(req.Msg.Labels), "com.micropod.clone-of="+req.Msg.Source)
	if err := s.cli.CreateVolume(ctx, req.Msg.Name, size, labels...); err != nil {
		return nil, mapError(err)
	}
	clone, err := s.cli.InspectVolume(ctx, req.Msg.Name)
	if err != nil {
		return nil, mapError(err)
	}
	if err := cloneImage(source.Configuration.Source, clone.Configuration.Source); err != nil {
		err = fmt.Errorf("clone %s -> %s: %w", req.Msg.Source, req.Msg.Name, err)
		if derr := s.cli.DeleteVolume(ctx, req.Msg.Name); derr != nil {
			err = fmt.Errorf("%w (rollback of %s failed: %v)", err, req.Msg.Name, derr)
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	// volumeFrom stats the backing file now, so allocated_bytes reflects the
	// cloned image rather than the empty one `volume create` made.
	return connect.NewResponse(volumeFrom(*clone)), nil
}

// runningWriter returns the id of a running (or stopping) container that has
// `volume` mounted without the `ro` option, or "" when there is none.
func (s *Server) runningWriter(ctx context.Context, volume *clicli.VolumeListEntry) (string, error) {
	entries, err := s.cli.ListContainers(ctx)
	if err != nil {
		return "", mapError(err)
	}
	for _, e := range entries {
		state := strings.ToLower(e.Status.State)
		if state != "running" && state != "stopping" {
			continue
		}
		for _, m := range e.Configuration.Mounts {
			if !mountRefersTo(m.Source, volume) {
				continue
			}
			if slices.Contains(m.Options, "ro") {
				continue
			}
			return e.ID, nil
		}
	}
	return "", nil
}

// mountRefersTo matches a mount source against a volume by id, name or
// backing path — the CLI reports whichever form the container was created with.
func mountRefersTo(mountSource string, volume *clicli.VolumeListEntry) bool {
	if mountSource == "" {
		return false
	}
	return mountSource == volume.ID ||
		mountSource == volume.Configuration.Name ||
		mountSource == volume.Configuration.Source
}

// sizeArg renders a byte count for `volume create -s`: the largest exact
// binary unit (2097152 → "2M"), falling back to the raw byte count.
func sizeArg(n int64) string {
	units := []struct {
		suffix string
		size   int64
	}{{"T", 1 << 40}, {"G", 1 << 30}, {"M", 1 << 20}, {"K", 1 << 10}}
	for _, u := range units {
		if n > 0 && n%u.size == 0 {
			return strconv.FormatInt(n/u.size, 10) + u.suffix
		}
	}
	return strconv.FormatInt(n, 10)
}

func (s *Server) ListNetworks(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.ListNetworksResponse], error) {
	entries, err := s.cli.ListNetworks(ctx)
	if err != nil {
		return nil, mapError(err)
	}
	networks := make([]*micropodv1.Network, 0, len(entries))
	for _, e := range entries {
		builtin := e.Configuration.Labels["com.apple.container.resource.role"] == "builtin"
		networks = append(networks, &micropodv1.Network{
			Id:          e.ID,
			Mode:        e.Configuration.Mode,
			Plugin:      e.Configuration.Plugin,
			Ipv4Subnet:  e.Status.IPv4Subnet,
			Ipv4Gateway: e.Status.IPv4Gateway,
			Ipv6Subnet:  e.Status.IPv6Subnet,
			CreatedAt:   e.Configuration.CreationDate,
			Builtin:     builtin,
			Labels:      e.Configuration.Labels,
		})
	}
	return connect.NewResponse(&micropodv1.ListNetworksResponse{Networks: networks}), nil
}

func (s *Server) CreateNetwork(ctx context.Context, req *connect.Request[micropodv1.CreateNetworkRequest]) (*connect.Response[micropodv1.Empty], error) {
	subnet := ""
	if req.Msg.Subnet != nil {
		subnet = *req.Msg.Subnet
	}
	return empty(s.cli.CreateNetwork(ctx, req.Msg.Name, subnet, req.Msg.Internal))
}

func (s *Server) DeleteNetwork(ctx context.Context, req *connect.Request[micropodv1.DeleteNetworkRequest]) (*connect.Response[micropodv1.Empty], error) {
	return empty(s.cli.DeleteNetwork(ctx, req.Msg.Name))
}

// GetStats samples every running container (the CLI has no per-id form) and
// keeps only the requested ids when `ids` is non-empty. Ids are matched
// against the runtime's container id, as reported by `stats`.
func (s *Server) GetStats(ctx context.Context, req *connect.Request[micropodv1.GetStatsRequest]) (*connect.Response[micropodv1.GetStatsResponse], error) {
	entries, err := s.cli.Stats(ctx)
	if err != nil {
		return nil, mapError(err)
	}
	want := make(map[string]bool, len(req.Msg.Ids))
	for _, id := range req.Msg.Ids {
		want[id] = true
	}
	snapshot := &micropodv1.StatsSnapshot{}
	for _, e := range entries {
		if len(want) > 0 && !want[e.ID] {
			continue
		}
		snapshot.Containers = append(snapshot.Containers, &micropodv1.ContainerStats{
			Id:               e.ID,
			MemoryUsedBytes:  uint64(e.MemoryUsageBytes),
			MemoryLimitBytes: uint64(e.MemoryLimitBytes),
			NetworkRxBytes:   uint64(e.NetworkRxBytes),
			NetworkTxBytes:   uint64(e.NetworkTxBytes),
			BlockReadBytes:   uint64(e.BlockReadBytes),
			BlockWriteBytes:  uint64(e.BlockWriteBytes),
			Pids:             uint64(e.NumProcesses),
		})
	}
	return connect.NewResponse(&micropodv1.GetStatsResponse{Snapshot: snapshot}), nil
}

// GetUsage mirrors UsageService.report in the Swift daemon: join containers to
// images (by normalized reference) and volumes (by mount source or volume id),
// then derive reclaimable bytes and the stopped-container count.
func (s *Server) GetUsage(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.UsageReport], error) {
	containerEntries, err := s.cli.ListContainers(ctx)
	if err != nil {
		return nil, mapError(err)
	}
	imageEntries, err := s.cli.ListImages(ctx)
	if err != nil {
		return nil, mapError(err)
	}
	volumeEntries, err := s.cli.ListVolumes(ctx)
	if err != nil {
		return nil, mapError(err)
	}

	byNormalizedRef := map[string][]string{}
	mountsBySource := map[string][]string{}
	var stopped int32
	for _, e := range containerEntries {
		if e.Configuration.Image != nil {
			ref := normalizeRef(e.Configuration.Image.Reference)
			byNormalizedRef[ref] = append(byNormalizedRef[ref], e.ID)
		}
		for _, m := range e.Configuration.Mounts {
			if m.Source != "" {
				mountsBySource[m.Source] = append(mountsBySource[m.Source], e.ID)
			}
		}
		if !strings.EqualFold(e.Status.State, "running") {
			stopped++
		}
	}

	report := &micropodv1.UsageReport{StoppedContainerCount: stopped}
	for _, e := range imageEntries {
		img := imageFrom(e)
		users := append([]string{}, byNormalizedRef[normalizeRef(img.Id)]...)
		for _, name := range img.Names {
			users = append(users, byNormalizedRef[normalizeRef(name)]...)
		}
		users = unique(users)
		report.Images = append(report.Images, &micropodv1.UsageReport_ImageUsage{
			Image: img, UsedByContainerIds: users, InUse: len(users) > 0,
		})
		if len(users) == 0 {
			report.ReclaimableImageBytes += img.SizeBytes
		}
	}
	for _, e := range volumeEntries {
		vol := volumeFrom(e)
		users := unique(append(
			append([]string{}, mountsBySource[vol.Source]...),
			mountsBySource[vol.Id]...,
		))
		report.Volumes = append(report.Volumes, &micropodv1.UsageReport_VolumeUsage{
			Volume: vol, UsedByContainerIds: users, InUse: len(users) > 0,
		})
		if len(users) == 0 {
			report.ReclaimableVolumeBytes += vol.SizeBytes
		}
	}
	return connect.NewResponse(report), nil
}

// normalizeRef strips docker.io/library/ and any digest suffix so
// "docker.io/library/alpine:3.20" ≡ "alpine:3.20" — matches UsageService.
func normalizeRef(reference string) string {
	ref := strings.ToLower(reference)
	if at := strings.Index(ref, "@"); at >= 0 {
		ref = ref[:at]
	}
	for _, prefix := range []string{"docker.io/library/", "index.docker.io/library/", "docker.io/", "library/"} {
		if strings.HasPrefix(ref, prefix) {
			return ref[len(prefix):]
		}
	}
	return ref
}

func unique(in []string) []string {
	seen := map[string]struct{}{}
	out := in[:0]
	for _, s := range in {
		if _, ok := seen[s]; !ok {
			seen[s] = struct{}{}
			out = append(out, s)
		}
	}
	return out
}

// execSpec maps an ExecRequest onto the CLI argv. `arguments` is used
// verbatim when present; the legacy `command` string is whitespace-split for
// compatibility (the same rule the Swift server applies). One of the two is
// required.
func execSpec(req *micropodv1.ExecRequest) (clicli.ExecSpec, error) {
	argv := req.Arguments
	if len(argv) == 0 {
		argv = strings.Fields(req.Command)
	}
	if len(argv) == 0 {
		return clicli.ExecSpec{}, errors.New("exec requires `arguments` or a non-empty `command`")
	}
	return clicli.ExecSpec{ID: req.Id, Workdir: req.GetWorkdir(), Env: req.Env, Argv: argv}, nil
}

func (s *Server) Exec(ctx context.Context, req *connect.Request[micropodv1.ExecRequest]) (*connect.Response[micropodv1.ExecResponse], error) {
	spec, err := execSpec(req.Msg)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	}
	res, err := s.cli.ExecDetailed(ctx, spec)
	if err != nil {
		return nil, mapError(err)
	}
	if res.ExitCode != 0 && clicli.LooksLikeNotFound(res.Error) {
		// The CLI exits non-zero for a missing container too; confirm before
		// attributing the exit code to the guest process.
		if _, ierr := s.cli.InspectContainer(ctx, spec.ID); clicli.IsNotFound(ierr) {
			return nil, mapError(ierr)
		}
	}
	return connect.NewResponse(&micropodv1.ExecResponse{
		Output:   res.Output,
		ExitCode: res.ExitCode,
		Error:    res.Error,
	}), nil
}
