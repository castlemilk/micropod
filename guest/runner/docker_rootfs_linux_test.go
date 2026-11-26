package main

import (
	"context"
	"errors"
	"maps"
	"slices"
	"strings"
	"testing"
	"time"

	containers "github.com/containerd/containerd/api/services/containers/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type rootFSRuntimeContainers struct {
	containers.ContainersClient
	current *containers.Container
	updates int
	gets    int
	delay   bool
	pending *containers.UpdateContainerRequest
	t       *testing.T
}

func (s *rootFSRuntimeContainers) Get(ctx context.Context, _ *containers.GetContainerRequest, _ ...grpc.CallOption) (*containers.GetContainerResponse, error) {
	s.t.Helper()
	md, _ := metadata.FromOutgoingContext(ctx)
	if !slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) {
		s.t.Fatalf("unexpected rootfs namespace: %v", md)
	}
	s.gets++
	if s.current == nil {
		return nil, status.Error(codes.NotFound, "CRI container is gone")
	}
	return &containers.GetContainerResponse{Container: s.current}, nil
}

func (s *rootFSRuntimeContainers) Update(_ context.Context, r *containers.UpdateContainerRequest, _ ...grpc.CallOption) (*containers.UpdateContainerResponse, error) {
	s.t.Helper()
	if r.Container.GetID() != s.current.GetID() || r.Container.GetLabels()[scratchSnapshotReference] != s.current.GetID() ||
		!slices.Equal(r.GetUpdateMask().GetPaths(), []string{"snapshotkey", "labels." + scratchSnapshotReference}) {
		s.t.Fatalf("unexpected runtime snapshot update: %v", r)
	}
	s.updates++
	if s.delay {
		s.delay = false
		s.pending = r
		return nil, status.Error(codes.DeadlineExceeded, "attach reply deadline")
	}
	s.commit(r)
	return &containers.UpdateContainerResponse{Container: s.current}, nil
}

func (s *rootFSRuntimeContainers) commit(r *containers.UpdateContainerRequest) {
	s.current.SnapshotKey = r.Container.GetSnapshotKey()
	maps.Copy(s.current.Labels, r.Container.GetLabels())
}

func TestDockerWritableRootFSDetachesOnlyOwnedScratch(t *testing.T) {
	b := dockerRootFSBinding{DockerID: strings.Repeat("a", 64), JobID: strings.Repeat("b", 32),
		PodID: strings.Repeat("c", 64), ContainerID: strings.Repeat("d", 64)}
	current := &containers.Container{ID: b.ContainerID, Sandbox: b.PodID, Snapshotter: dockerRootFSSnapshotter,
		SnapshotKey: dockerRootFSKey(b.DockerID), Labels: map[string]string{owner: b.JobID}}
	client := &rootFSRuntimeContainers{current: current, t: t}
	n := node{containers: client}

	for range 2 {
		if err := n.detachDockerRootFS(t.Context(), b); err != nil {
			t.Fatal(err)
		}
	}
	if current.GetSnapshotKey() != b.ContainerID || client.updates != 1 {
		t.Fatalf("cleanup key=%s with %d updates", current.GetSnapshotKey(), client.updates)
	}
	current.SnapshotKey = dockerRootFSKey(strings.Repeat("e", 64))
	if err := n.detachDockerRootFS(t.Context(), b); err == nil || client.updates != 1 {
		t.Fatal("changed unrelated snapshot")
	}
	current.SnapshotKey = dockerRootFSKey(b.DockerID)
	current.Labels[owner] = strings.Repeat("0", 32)
	if err := n.detachDockerRootFS(t.Context(), b); err == nil || client.updates != 1 {
		t.Fatal("changed foreign CRI container")
	}
	client.current = nil
	if err := n.verifyRootFSCleanup(t.Context(), b); err != nil {
		t.Fatal(err)
	}
}

// Stop before n.remove reaches its host filesystem cleanup. This observes the
// exact key that CRI's RemovePodSandbox would remove on each attempt.
var errRootFSPodRemovalObserved = errors.New("observed CRI pod removal")

type rootFSPodRuntime struct {
	cri.RuntimeServiceClient
	containers  *rootFSRuntimeContainers
	binding     dockerRootFSBinding
	lists       int
	removedKeys []string
}

func (r *rootFSPodRuntime) ListPodSandbox(context.Context, *cri.ListPodSandboxRequest, ...grpc.CallOption) (*cri.ListPodSandboxResponse, error) {
	r.lists++
	return &cri.ListPodSandboxResponse{Items: []*cri.PodSandbox{{Id: r.binding.PodID,
		Metadata: &cri.PodSandboxMetadata{Namespace: "micropod-ci", Uid: r.binding.JobID},
		Labels:   map[string]string{owner: r.binding.JobID}}}}, nil
}

func (r *rootFSPodRuntime) StopPodSandbox(context.Context, *cri.StopPodSandboxRequest, ...grpc.CallOption) (*cri.StopPodSandboxResponse, error) {
	return &cri.StopPodSandboxResponse{}, nil
}

func (r *rootFSPodRuntime) RemovePodSandbox(context.Context, *cri.RemovePodSandboxRequest, ...grpc.CallOption) (*cri.RemovePodSandboxResponse, error) {
	r.removedKeys = append(r.removedKeys, r.containers.current.GetSnapshotKey())
	return nil, errRootFSPodRemovalObserved
}

func TestDockerWritableRootFSLateAttachFencesCRIOnlyUntilReboot(t *testing.T) {
	boot, err := readGuestBootID()
	if err != nil {
		t.Fatal(err)
	}
	b := dockerRootFSBinding{DockerID: strings.Repeat("a", 64), JobID: strings.Repeat("b", 32),
		PodID: strings.Repeat("c", 64), ContainerID: strings.Repeat("d", 64), BootID: boot}
	client := &rootFSRuntimeContainers{t: t, delay: true, current: &containers.Container{
		ID: b.ContainerID, Sandbox: b.PodID, Snapshotter: dockerRootFSSnapshotter, SnapshotKey: b.ContainerID,
		Labels: map[string]string{owner: b.JobID},
	}}
	runtime := &rootFSPodRuntime{containers: client, binding: b}
	n := node{containers: client, runtime: runtime}
	ctx := dockerRootFSContext(t.Context())
	if err := n.setSnapshotKey(ctx, b.ContainerID, dockerRootFSKey(b.DockerID)); status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("attach did not lose the reply: %v", err)
	}
	// The stored key is still scratch until the delayed write commits. Both
	// the run's defer and recovery must fence before querying or removing CRI.
	if err := n.cleanupDockerRootFSBinding(t.Context(), b, true); !errors.Is(err, errUnconfirmedRootFSAttach) {
		t.Fatalf("same-boot cleanup returned %v", err)
	}
	client.commit(client.pending)
	c := &dockerContainer{dockerRecord: dockerRecord{RootFSBinding: &b}}
	if err := n.recoverDockerRootFSBinding(t.Context(), c); !errors.Is(err, errUnconfirmedRootFSAttach) {
		t.Fatalf("same-boot recovery returned %v", err)
	}
	if client.gets != 0 || runtime.lists != 0 || c.RootFSBinding != &b {
		t.Fatal("unacknowledged attachment reached CRI cleanup")
	}
	b.BootID = "aa000000-d71c-4f3d-8966-8da752afd919"
	if b.BootID == boot {
		b.BootID = "bb000000-d71c-4f3d-8966-8da752afd919"
	}
	if err := n.cleanupDockerRootFSBinding(t.Context(), b, true); !errors.Is(err, errRootFSPodRemovalObserved) {
		t.Fatalf("new-boot cleanup returned %v", err)
	}
	if !slices.Equal(runtime.removedKeys, []string{b.ContainerID}) {
		t.Fatalf("CRI cleanup used %v, want only scratch %s", runtime.removedKeys, b.ContainerID)
	}
}

func TestDockerWritableRootFSUnpersistedAcknowledgementLeavesFence(t *testing.T) {
	boot, err := readGuestBootID()
	if err != nil {
		t.Fatal(err)
	}
	pending := &dockerRootFSBinding{BootID: boot}
	acknowledged := *pending
	acknowledged.AttachAcknowledged = true
	// A time outside JSON's range makes the real record save fail before I/O.
	c := &dockerContainer{dockerRecord: dockerRecord{RootFSBinding: pending, Created: time.Date(10000, 1, 1, 0, 0, 0, 0, time.UTC)}}
	if err := saveRootFSBinding(c, &acknowledged); err == nil || c.RootFSBinding != pending {
		t.Fatalf("failed acknowledgement save replaced the fence: %v", err)
	}
	if err := (node{}).cleanupDockerRootFSBinding(t.Context(), *c.RootFSBinding, true); !errors.Is(err, errUnconfirmedRootFSAttach) {
		t.Fatalf("unpersisted acknowledgement permitted cleanup: %v", err)
	}
}

func TestDockerWritableRootFSAcknowledgedRunsReuseRootAcrossStopAndStart(t *testing.T) {
	boot, err := readGuestBootID()
	if err != nil {
		t.Fatal(err)
	}
	dockerID := strings.Repeat("a", 64)
	durable := dockerRootFSKey(dockerID)
	client := &rootFSRuntimeContainers{t: t}
	runtime := &rootFSPodRuntime{containers: client}
	n := node{containers: client, runtime: runtime}
	for _, runID := range []string{strings.Repeat("d", 64), strings.Repeat("e", 64)} {
		b := dockerRootFSBinding{DockerID: dockerID, JobID: strings.Repeat("b", 32),
			PodID: strings.Repeat("c", 64), ContainerID: runID, BootID: boot, AttachAcknowledged: true}
		client.current = &containers.Container{ID: runID, Sandbox: b.PodID, Snapshotter: dockerRootFSSnapshotter,
			SnapshotKey: runID, Labels: map[string]string{owner: b.JobID}}
		runtime.binding = b
		if err := n.setSnapshotKey(dockerRootFSContext(t.Context()), runID, durable); err != nil || client.current.GetSnapshotKey() != durable {
			t.Fatalf("start did not attach the same writable snapshot: %v", err)
		}
		if err := n.detachDockerRootFS(t.Context(), b); err != nil {
			t.Fatal(err)
		}
		if err := n.cleanupDockerRootFSBinding(t.Context(), b, false); !errors.Is(err, errRootFSPodRemovalObserved) {
			t.Fatalf("acknowledged stop returned %v", err)
		}
		if got := runtime.removedKeys[len(runtime.removedKeys)-1]; got != runID {
			t.Fatalf("retired %s instead of scratch %s", got, runID)
		}
	}
}
