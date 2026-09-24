// Package server implements the MicropodService connect-go handlers on top
// of the `container` CLI client.
package server

import (
	"context"
	"fmt"
	"strings"

	"connectrpc.com/connect"

	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
	"micropod/api/internal/clicli"
)

// Server implements all six micropod.v1 domain services on top of the
// `container` CLI. App-owned RPCs it can't serve (volume policy, updates,
// compose) fall through to the embedded unimplemented handlers.
type Server struct {
	micropodv1connect.UnimplementedContainerServiceHandler
	micropodv1connect.UnimplementedImageServiceHandler
	micropodv1connect.UnimplementedVolumeServiceHandler
	micropodv1connect.UnimplementedNetworkServiceHandler
	micropodv1connect.UnimplementedComposeServiceHandler
	micropodv1connect.UnimplementedSystemServiceHandler
	cli *clicli.CLI
}

func New(cli *clicli.CLI) *Server {
	return &Server{cli: cli}
}

func (s *Server) GetSystem(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.SystemSnapshot], error) {
	status, err := s.cli.SystemStatus(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	version, err := s.cli.SystemVersion(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	usage, err := s.cli.DiskUsage(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	return connect.NewResponse(&micropodv1.SystemSnapshot{
		Status: &micropodv1.SystemStatus{
			Status:           status.Status,
			AppRoot:          status.AppRoot,
			InstallRoot:      status.InstallRoot,
			ApiServerVersion: status.APIServerVersion,
			CliVersion:       version,
		},
		DiskUsage: &micropodv1.DiskUsage{
			Containers: category(usage.Containers),
			Images:     category(usage.Images),
			Volumes:    category(usage.Volumes),
		},
	}), nil
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
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	containers := make([]*micropodv1.Container, 0, len(entries))
	for _, e := range entries {
		containers = append(containers, containerFrom(e))
	}
	return connect.NewResponse(&micropodv1.ListContainersResponse{Containers: containers}), nil
}

func containerFrom(e clicli.ContainerListEntry) *micropodv1.Container {
	c := &micropodv1.Container{
		Id:      e.ID,
		State:   e.Status.State,
		Image:   "",
		Env:     nil,
		Labels:  map[string]string{},
		Mounts:  nil,
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
		var parts []string
		if os := e.Configuration.Platform.OS; os != "" {
			parts = append(parts, os)
		}
		if arch := e.Configuration.Platform.Architecture; arch != "" {
			parts = append(parts, arch)
		}
		c.Platform = strings.Join(parts, "/")
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
	args = append(args, req.Image)
	args = append(args, req.Arguments...)
	return args
}

func fmtFloat(f float64) string {
	return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.6f", f), "0"), ".")
}

func (s *Server) RunContainer(ctx context.Context, req *connect.Request[micropodv1.RunContainerRequest]) (*connect.Response[micropodv1.ContainerRef], error) {
	id, err := s.cli.RunContainer(ctx, runArgs(req.Msg)...)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	return connect.NewResponse(&micropodv1.ContainerRef{Id: id}), nil
}

func (s *Server) CreateContainer(ctx context.Context, req *connect.Request[micropodv1.RunContainerRequest]) (*connect.Response[micropodv1.ContainerRef], error) {
	id, err := s.cli.CreateContainer(ctx, runArgs(req.Msg)...)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
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
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	return connect.NewResponse(&micropodv1.Empty{}), nil
}

func (s *Server) StreamContainerLogs(ctx context.Context, req *connect.Request[micropodv1.StreamLogsRequest], stream *connect.ServerStream[micropodv1.LogChunk]) error {
	return s.cli.StreamLogs(ctx, req.Msg.Id, int(req.Msg.Tail), req.Msg.Boot, func(line string) error {
		if err := stream.Send(&micropodv1.LogChunk{Text: line}); err != nil {
			return err
		}
		return nil
	})
}

func (s *Server) ListImages(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.ListImagesResponse], error) {
	entries, err := s.cli.ListImages(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
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
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	volumes := make([]*micropodv1.Volume, 0, len(entries))
	for _, e := range entries {
		volumes = append(volumes, volumeFrom(e))
	}
	return connect.NewResponse(&micropodv1.ListVolumesResponse{Volumes: volumes}), nil
}

func volumeFrom(e clicli.VolumeListEntry) *micropodv1.Volume {
	return &micropodv1.Volume{
		Id:        e.ID,
		Driver:    e.Configuration.Driver,
		Format:    e.Configuration.Format,
		SizeBytes: uint64(e.Configuration.SizeInBytes),
		Source:    e.Configuration.Source,
		CreatedAt: e.Configuration.CreationDate,
		Labels:    e.Configuration.Labels,
	}
}

func (s *Server) CreateVolume(ctx context.Context, req *connect.Request[micropodv1.CreateVolumeRequest]) (*connect.Response[micropodv1.Empty], error) {
	size := ""
	if req.Msg.Size != nil {
		size = *req.Msg.Size
	}
	return empty(s.cli.CreateVolume(ctx, req.Msg.Name, size))
}

func (s *Server) DeleteVolume(ctx context.Context, req *connect.Request[micropodv1.DeleteVolumeRequest]) (*connect.Response[micropodv1.Empty], error) {
	return empty(s.cli.DeleteVolume(ctx, req.Msg.Name))
}

func (s *Server) ListNetworks(ctx context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.ListNetworksResponse], error) {
	entries, err := s.cli.ListNetworks(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	networks := make([]*micropodv1.Network, 0, len(entries))
	for _, e := range entries {
		builtin := e.Configuration.Labels["com.apple.container.resource.role"] == "builtin"
		networks = append(networks, &micropodv1.Network{
			Id:         e.ID,
			Mode:       e.Configuration.Mode,
			Plugin:     e.Configuration.Plugin,
			Ipv4Subnet: e.Status.IPv4Subnet,
			Ipv4Gateway: e.Status.IPv4Gateway,
			Ipv6Subnet: e.Status.IPv6Subnet,
			CreatedAt:  e.Configuration.CreationDate,
			Builtin:    builtin,
			Labels:     e.Configuration.Labels,
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

func (s *Server) GetStats(ctx context.Context, req *connect.Request[micropodv1.GetStatsRequest]) (*connect.Response[micropodv1.GetStatsResponse], error) {
	entries, err := s.cli.Stats(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	snapshot := &micropodv1.StatsSnapshot{}
	for _, e := range entries {
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
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	imageEntries, err := s.cli.ListImages(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	volumeEntries, err := s.cli.ListVolumes(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
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

func (s *Server) Exec(ctx context.Context, req *connect.Request[micropodv1.ExecRequest]) (*connect.Response[micropodv1.ExecResponse], error) {
	res, err := s.cli.ExecDetailed(ctx, req.Msg.Id, req.Msg.Command)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, err)
	}
	return connect.NewResponse(&micropodv1.ExecResponse{
		Output:   res.Output,
		ExitCode: res.ExitCode,
		Error:    res.Error,
	}), nil
}
