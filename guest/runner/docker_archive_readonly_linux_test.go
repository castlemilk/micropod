package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	leases "github.com/containerd/containerd/api/services/leases/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	mounttypes "github.com/containerd/containerd/api/types"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

const archiveTestContainer = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const archiveTestParent = "sha256:4bff2b958d3fac73fb5a75e0d0b4df86470d880b0b3d856f426c05ac879548ef"

type archiveTestMetadata struct {
	// Any accidental Prepare call is a test failure.
	dockerSnapshotClient
	t                              *testing.T
	lease                          *leases.Lease
	view                           *snapshots.Info
	events                         []string
	cancelView                     context.CancelFunc
	later                          *snapshots.Info
	parentPinned, lateCommitDenied bool
	removeInterrupted              bool
}

func (m *archiveTestMetadata) namespace(ctx context.Context) metadata.MD {
	m.t.Helper()
	if err := ctx.Err(); err != nil {
		m.t.Fatalf("metadata operation used canceled context: %v", err)
	}
	md, _ := metadata.FromOutgoingContext(ctx)
	if !slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) {
		m.t.Fatalf("snapshot operation used metadata %v", md)
	}
	return md
}

func (m *archiveTestMetadata) Stat(ctx context.Context, r *snapshots.StatSnapshotRequest, _ ...grpc.CallOption) (*snapshots.StatSnapshotResponse, error) {
	m.namespace(ctx)
	if r.Snapshotter != dockerRootFSSnapshotter {
		m.t.Fatalf("wrong snapshotter: %q", r.Snapshotter)
	}
	if r.Key == archiveTestParent {
		return &snapshots.StatSnapshotResponse{Info: &snapshots.Info{Name: r.Key, Kind: snapshots.Kind_COMMITTED}}, nil
	}
	m.events = append(m.events, "stat-view")
	if m.view == nil {
		return nil, status.Error(codes.NotFound, "view is absent")
	}
	return &snapshots.StatSnapshotResponse{Info: m.view}, nil
}

func (m *archiveTestMetadata) Create(ctx context.Context, r *leases.CreateRequest, _ ...grpc.CallOption) (*leases.CreateResponse, error) {
	m.namespace(ctx)
	expiry, err := time.Parse(time.RFC3339, r.Labels["containerd.io/gc.expire"])
	if err != nil || time.Until(expiry) < archiveViewLifetime || !strings.HasPrefix(r.ID, archiveViewPrefix) || r.Labels[archiveViewOwner] != archiveTestContainer {
		m.t.Fatalf("unexpected archive lease: %v", r)
	}
	m.lease = &leases.Lease{ID: r.ID, Labels: r.Labels}
	m.events = append(m.events, "create-lease")
	return &leases.CreateResponse{Lease: m.lease}, nil
}

func (m *archiveTestMetadata) AddResource(ctx context.Context, r *leases.AddResourceRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	m.namespace(ctx)
	if r.GetID() != m.lease.GetID() || r.GetResource().GetType() != "snapshots/"+dockerRootFSSnapshotter || r.GetResource().GetID() != archiveTestParent {
		m.t.Fatalf("unexpected leased resource: %v", r)
	}
	m.parentPinned = true
	m.events = append(m.events, "pin-parent")
	return &emptypb.Empty{}, nil
}

func (m *archiveTestMetadata) View(ctx context.Context, r *snapshots.ViewSnapshotRequest, _ ...grpc.CallOption) (*snapshots.ViewSnapshotResponse, error) {
	md := m.namespace(ctx)
	if !slices.Equal(md.Get(archiveViewLeaseHeader), []string{m.lease.GetID()}) || r.Key != m.lease.GetID() ||
		r.Parent != archiveTestParent || !m.parentPinned || r.Snapshotter != dockerRootFSSnapshotter {
		m.t.Fatalf("View lacks an immutable parent or scoped lease: %v, %v", r, md)
	}
	m.events = append(m.events, "view")
	info := &snapshots.Info{Name: r.Key, Kind: snapshots.Kind_VIEW, Parent: r.Parent, Labels: r.Labels}
	if m.cancelView != nil {
		m.later = info
		m.cancelView()
		return nil, status.Error(codes.Canceled, "view reply lost")
	}
	m.view = info
	return &snapshots.ViewSnapshotResponse{}, nil
}

func (m *archiveTestMetadata) Delete(ctx context.Context, r *leases.DeleteRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	m.namespace(ctx)
	m.events = append(m.events, "delete-lease")
	if m.lease == nil {
		return nil, status.Error(codes.NotFound, "lease already gone")
	}
	if r.ID != m.lease.GetID() || r.Sync {
		m.t.Fatalf("unexpected lease delete: %v", r)
	}
	m.lease = nil
	m.parentPinned = false
	if m.later != nil {
		// Containerd publishes the View and its lease reference together.
		// This models an operation reaching that transaction after fencing.
		m.lateCommitDenied = true
		m.later = nil
	}
	return &emptypb.Empty{}, nil
}

func (m *archiveTestMetadata) Remove(ctx context.Context, r *snapshots.RemoveSnapshotRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	m.namespace(ctx)
	m.events = append(m.events, "remove-view")
	if m.view == nil || r.Key != m.view.GetName() || r.Snapshotter != dockerRootFSSnapshotter {
		m.t.Fatalf("archive removed an unrelated snapshot: %v", r)
	}
	if m.removeInterrupted {
		m.removeInterrupted = false
		return nil, status.Error(codes.Unavailable, "containerd connection interrupted")
	}
	m.view = nil
	return &emptypb.Empty{}, nil
}

func TestDockerArchiveReadOnlyViewRetainsOnlyImageDuringTransfer(t *testing.T) {
	ctx := dockerRootFSContext(t.Context())
	fake := &archiveTestMetadata{t: t}
	n := node{snapshots: fake, leases: fake}
	v, _, err := n.prepareArchiveImageView(ctx, archiveTestContainer, archiveTestParent)
	if err != nil {
		t.Fatal(err)
	}
	if err := v.remove(v.leased(ctx)); err != nil {
		t.Fatal(err)
	}
	v.pending = false
	if fake.view != nil || !fake.parentPinned {
		t.Fatalf("transfer must pin the parent and leave no named View: %+v", fake)
	}
	if err := v.close(ctx); err != nil {
		t.Fatal(err)
	}
	if fake.lease != nil || fake.parentPinned {
		t.Fatalf("archive release left an owned lease: %+v", fake)
	}
}

func TestDockerArchiveReadOnlyViewLateCommitIsFenced(t *testing.T) {
	ctx, cancel := context.WithCancel(dockerRootFSContext(t.Context()))
	defer cancel()
	fake := &archiveTestMetadata{t: t, cancelView: cancel}
	n := node{snapshots: fake, leases: fake}
	if _, _, err := n.prepareArchiveImageView(ctx, archiveTestContainer, archiveTestParent); status.Code(err) != codes.Canceled {
		t.Fatalf("wanted the View cancellation, got %v", err)
	}
	want := []string{"create-lease", "pin-parent", "view", "delete-lease", "stat-view"}
	if !fake.lateCommitDenied || fake.lease != nil || fake.view != nil || !slices.Equal(fake.events, want) {
		t.Fatalf("late View was not fenced: %+v", fake)
	}
}

func TestDockerArchiveReadOnlyViewCleanupRetriesAndChecksOwnership(t *testing.T) {
	for _, mismatch := range []bool{false, true} {
		t.Run(map[bool]string{false: "transient failure", true: "different owner"}[mismatch], func(t *testing.T) {
			ctx := dockerRootFSContext(t.Context())
			fake := &archiveTestMetadata{t: t, removeInterrupted: true}
			n := node{snapshots: fake, leases: fake}
			v, _, err := n.prepareArchiveImageView(ctx, archiveTestContainer, archiveTestParent)
			if err != nil {
				t.Fatal(err)
			}
			if mismatch {
				fake.view.Labels[archiveViewOwner] = "different owner"
			}
			err = v.close(ctx)
			if mismatch {
				if err == nil || slices.Contains(fake.events, "remove-view") || fake.view == nil {
					t.Fatalf("cleanup must refuse the unrelated View: %v, %+v", err, fake)
				}
			} else if err != nil || fake.view != nil || fake.removeInterrupted {
				t.Fatalf("cleanup did not recover: %v, %+v", err, fake)
			}
			if fake.lease != nil {
				t.Fatal("cleanup left its own lease")
			}
		})
	}
}

func TestDockerArchiveReadOnlyImageMounts(t *testing.T) {
	dir := t.TempDir()
	layers := make([]string, 8)
	for i := range layers {
		layers[i] = filepath.Join(dir, "io.containerd.snapshotter.v1.overlayfs", "snapshots", strconv.Itoa(i+1), "fs")
		if err := os.MkdirAll(layers[i], 0700); err != nil {
			t.Fatal(err)
		}
	}
	lowerdirs := strings.Join(layers, ":")
	if len(lowerdirs) < 256 {
		t.Fatal("fixture must exceed the fsconfig string limit")
	}
	top, bottom := layers[0], layers[len(layers)-1]
	const base = "NAME=ArchiveFixture\n"
	const topVersion = "NAME=LayeredArchiveFixture\n"
	if err := os.WriteFile(filepath.Join(bottom, "os-release"), []byte(base), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(top, "os-release"), []byte(topVersion), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bottom, "base-only"), []byte(base), 0644); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		mount   *mounttypes.Mount
		payload string
	}{
		{mount: &mounttypes.Mount{Type: "bind", Source: bottom, Options: []string{"ro", "rbind"}}, payload: base},
		{mount: &mounttypes.Mount{Type: "overlay", Source: "overlay", Options: []string{"lowerdir=" + lowerdirs, "index=off"}}, payload: topVersion},
	} {
		t.Run(tc.mount.Type, func(t *testing.T) {
			root, err := mountArchiveSnapshot([]*mounttypes.Mount{tc.mount}, true)
			if errors.Is(err, unix.EPERM) || errors.Is(err, unix.EACCES) {
				t.Skip("mount namespace lacks permission for an isolated image view")
			}
			if err != nil {
				t.Fatal(err)
			}
			defer root.Close()
			view := dockerArchiveView{root: root}
			file, stat, _, err := view.stat(dockerArchivePath{absolute: "/os-release", name: "os-release"})
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()
			src, err := archiveReadFD(file)
			if err != nil {
				t.Fatal(err)
			}
			defer src.Close()
			b, err := io.ReadAll(src)
			if err != nil || string(b) != tc.payload || stat.Size != int64(len(tc.payload)) {
				t.Fatalf("image archive data: %q %v, stat %+v", b, err, stat)
			}
			file, _, _, err = view.stat(dockerArchivePath{absolute: "/base-only", name: "base-only"})
			if err != nil {
				t.Fatalf("base image file is missing: %v", err)
			}
			file.Close()
			fd, err := unix.Openat(int(root.Fd()), "probe", unix.O_CREAT|unix.O_WRONLY|unix.O_CLOEXEC, 0600)
			if err == nil {
				unix.Close(fd)
			}
			if !errors.Is(err, unix.EROFS) {
				t.Fatalf("read-only image view allowed mutation: %v", err)
			}
		})
	}
}

func TestDockerArchiveReadOnlyOverlayRejectsWritableOptions(t *testing.T) {
	for _, key := range []string{"upperdir", "workdir"} {
		err := validateReadOnlyOverlay([]string{"lowerdir=/layers/top:/layers/bottom", key + "=/layers/writable"})
		if err == nil {
			t.Fatalf("read-only overlay accepted %s", key)
		}
	}
}

func TestDockerArchiveRunningReadOnlyAutoRemoveUsesLiveRoot(t *testing.T) {
	c := &dockerContainer{archive: newDockerLiveArchive(nil, nil)}
	c.Phase = "running"
	c.RuntimeID = "unavailable-test-bundle"
	c.Config.HostConfig.ReadonlyRootfs = true
	c.Config.HostConfig.AutoRemove = true
	s := &dockerEngine{}
	defer s.retireDockerArchive(c)
	// No managed bundle in the unit environment. Reaching the bundle identity
	// check demonstrates the running path does not depend on image services.
	if _, _, err := s.openArchive(t.Context(), c, "/etc/os-release", false); err == nil || !strings.Contains(err.Error(), "invalid runtime identity") {
		t.Fatalf("live read-only archive did not use its task bundle: %v", err)
	}
	_, _, err := s.openArchive(t.Context(), c, "/etc/os-release", true)
	var problem apiError
	if !errors.As(err, &problem) || problem.code != http.StatusForbidden {
		t.Fatalf("live read-only archive accepted a root upload: %v", err)
	}
}
