package main

import (
	"context"
	"slices"
	"testing"

	leases "github.com/containerd/containerd/api/services/leases/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type leaseRecorder struct {
	archiveLeaseClient
	t                *testing.T
	created, deleted []string
	createErr        error
}

func (l *leaseRecorder) namespace(ctx context.Context) {
	l.t.Helper()
	md, _ := metadata.FromOutgoingContext(ctx)
	if !slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) {
		l.t.Fatalf("lease request outside CRI's namespace: %v", md)
	}
}

func (l *leaseRecorder) Create(ctx context.Context, req *leases.CreateRequest, _ ...grpc.CallOption) (*leases.CreateResponse, error) {
	l.namespace(ctx)
	l.created = append(l.created, req.GetID())
	if l.createErr != nil {
		return nil, l.createErr
	}
	return &leases.CreateResponse{Lease: &leases.Lease{ID: req.GetID()}}, nil
}

func (l *leaseRecorder) Delete(ctx context.Context, req *leases.DeleteRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	l.namespace(ctx)
	l.deleted = append(l.deleted, req.GetID())
	return &emptypb.Empty{}, nil
}

// leaseHeaderRuntime records the lease each CRI request named, and answers a
// request that names a lease in missing as containerd does.
type leaseHeaderRuntime struct {
	cri.RuntimeServiceClient
	named   []string
	missing map[string]bool
}

func (r *leaseHeaderRuntime) lease(ctx context.Context) (string, error) {
	md, _ := metadata.FromOutgoingContext(ctx)
	id := ""
	if v := md.Get(runtimeLeaseHeader); len(v) == 1 {
		id = v[0]
	}
	r.named = append(r.named, id)
	if r.missing[id] {
		return id, status.Error(codes.NotFound, `failed to create containerd container: failed to prepare snapshot: lease does not exist: not found`)
	}
	return id, nil
}

func (r *leaseHeaderRuntime) CreateContainer(ctx context.Context, _ *cri.CreateContainerRequest, _ ...grpc.CallOption) (*cri.CreateContainerResponse, error) {
	_, err := r.lease(ctx)
	if err != nil {
		return nil, err
	}
	return &cri.CreateContainerResponse{ContainerId: "c"}, nil
}

func (r *leaseHeaderRuntime) RunPodSandbox(ctx context.Context, _ *cri.RunPodSandboxRequest, _ ...grpc.CallOption) (*cri.RunPodSandboxResponse, error) {
	_, err := r.lease(ctx)
	if err != nil {
		return nil, err
	}
	return &cri.RunPodSandboxResponse{PodSandboxId: "p"}, nil
}

func resetSandboxLeaseState(t *testing.T) {
	t.Helper()
	sandboxLease.Lock()
	sandboxLease.ready = false
	sandboxLease.Unlock()
	t.Cleanup(func() {
		sandboxLease.Lock()
		sandboxLease.ready = false
		sandboxLease.Unlock()
	})
}

func TestCreateContainerNamesItsPodsLease(t *testing.T) {
	r := &leaseHeaderRuntime{}
	n := node{runtime: r}
	if _, err := n.createImageContainer(context.Background(), &cri.CreateContainerRequest{PodSandboxId: "pod-1"}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(r.named, []string{"pod-1"}) {
		t.Fatalf("leases named %q, want the pod's own", r.named)
	}
	// A pod without its lease: the request goes again without one, and CRI's
	// client makes its own.
	r = &leaseHeaderRuntime{missing: map[string]bool{"pod-2": true}}
	n = node{runtime: r}
	made, err := n.createImageContainer(context.Background(), &cri.CreateContainerRequest{PodSandboxId: "pod-2"})
	if err != nil || made.GetContainerId() != "c" || !slices.Equal(r.named, []string{"pod-2", ""}) {
		t.Fatalf("missing pod lease: %v %v, leases named %q", made, err, r.named)
	}
}

func TestSandboxLeaseIsMadeOnceAndNamedByPods(t *testing.T) {
	resetSandboxLeaseState(t)
	l := &leaseRecorder{t: t, createErr: status.Error(codes.AlreadyExists, "lease exists")}
	n := node{leases: l}
	for range 3 {
		md, _ := metadata.FromOutgoingContext(n.sandboxLeaseContext(context.Background()))
		if !slices.Equal(md.Get(runtimeLeaseHeader), []string{runtimeSandboxLease}) {
			t.Fatalf("pod request names %v", md)
		}
	}
	if !slices.Equal(l.created, []string{runtimeSandboxLease}) {
		t.Fatalf("lease creations %q, want one (an existing lease is used as is)", l.created)
	}
	if err := n.resetSandboxLease(context.Background()); err != nil || !slices.Equal(l.deleted, []string{runtimeSandboxLease}) {
		t.Fatalf("reset: %v, deleted %q", err, l.deleted)
	}
	n.sandboxLeaseContext(context.Background())
	if len(l.created) != 2 {
		t.Fatalf("the lease was not made again after its reset: %q", l.created)
	}
}

func TestPodsGoWithoutTheSandboxLeaseWhenItCannotBeMade(t *testing.T) {
	resetSandboxLeaseState(t)
	l := &leaseRecorder{t: t, createErr: status.Error(codes.Unavailable, "containerd restarting")}
	n := node{leases: l}
	for range 2 {
		md, _ := metadata.FromOutgoingContext(n.sandboxLeaseContext(context.Background()))
		if len(md.Get(runtimeLeaseHeader)) != 0 {
			t.Fatalf("a lease that could not be made was named: %v", md)
		}
	}
	if len(l.created) != 2 {
		t.Fatalf("a failed creation was not retried by the next pod: %q", l.created)
	}
	if md, _ := metadata.FromOutgoingContext((node{}).sandboxLeaseContext(context.Background())); len(md) != 0 {
		t.Fatalf("no lease service, but the request carries %v", md)
	}
	// RunPodSandbox goes again without the lease if containerd lost it.
	l.createErr = nil
	r := &leaseHeaderRuntime{missing: map[string]bool{runtimeSandboxLease: true}}
	n = node{leases: l, runtime: r}
	result, err := n.runPodSandbox(context.Background(), &cri.RunPodSandboxRequest{})
	if err != nil || result.GetPodSandboxId() != "p" || !slices.Equal(r.named, []string{runtimeSandboxLease, ""}) {
		t.Fatalf("retry without the lease: %v %v %q", result, err, r.named)
	}
}
