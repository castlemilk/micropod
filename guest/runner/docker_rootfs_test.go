package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

const rootFSFirstBoot = "d5ac2213-d71c-4f3d-8966-8da752afd919"
const rootFSSecondBoot = "195f39de-2372-42a4-b2fc-5e59e6f975b4"

func TestDockerRootFSBindingCleanupBoot(t *testing.T) {
	for _, tt := range []struct {
		name        string
		binding     dockerRootFSBinding
		currentBoot string
		wantAllowed bool
	}{
		{"pending on same boot", dockerRootFSBinding{BootID: rootFSFirstBoot}, rootFSFirstBoot, false},
		{"pending on a verified new boot", dockerRootFSBinding{BootID: rootFSFirstBoot}, rootFSSecondBoot, true},
		{"unknown original boot", dockerRootFSBinding{}, rootFSSecondBoot, false},
		{"unverified current boot", dockerRootFSBinding{BootID: rootFSFirstBoot}, "unknown", false},
		{"acknowledged on same boot", dockerRootFSBinding{BootID: rootFSFirstBoot, AttachAcknowledged: true}, rootFSFirstBoot, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.binding.checkCleanupBoot(tt.currentBoot)
			if tt.wantAllowed && err != nil || !tt.wantAllowed && !errors.Is(err, errUnconfirmedRootFSAttach) {
				t.Fatalf("cleanup returned %v, allowed = %v", err, tt.wantAllowed)
			}
		})
	}
}

type rootFSSnapshots struct {
	info            *snapshots.Info
	prepared        []*snapshots.PrepareSnapshotRequest
	removed         []*snapshots.RemoveSnapshotRequest
	prepareResponse error
	delayPrepare    bool
	pending         *snapshots.Info
}

func (s *rootFSSnapshots) Stat(_ context.Context, _ *snapshots.StatSnapshotRequest, _ ...grpc.CallOption) (*snapshots.StatSnapshotResponse, error) {
	if s.info == nil {
		return nil, status.Error(codes.NotFound, "missing snapshot")
	}
	return &snapshots.StatSnapshotResponse{Info: s.info}, nil
}

func (s *rootFSSnapshots) Prepare(_ context.Context, r *snapshots.PrepareSnapshotRequest, _ ...grpc.CallOption) (*snapshots.PrepareSnapshotResponse, error) {
	s.prepared = append(s.prepared, r)
	info := &snapshots.Info{Name: r.Key, Kind: snapshots.Kind_ACTIVE, Parent: r.Parent, Labels: r.Labels}
	if s.delayPrepare {
		s.pending = info
		return nil, status.Error(codes.DeadlineExceeded, "prepare reply deadline")
	}
	s.info = info
	return &snapshots.PrepareSnapshotResponse{}, s.prepareResponse
}

func (s *rootFSSnapshots) Remove(_ context.Context, r *snapshots.RemoveSnapshotRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	s.removed = append(s.removed, r)
	s.info = nil
	return &emptypb.Empty{}, nil
}

func unexpectedRootFSSave(t *testing.T) func(dockerRootFS) error {
	return func(r dockerRootFS) error {
		t.Helper()
		t.Fatalf("unexpected rootfs intent write: %+v", r)
		return nil
	}
}

func TestDockerWritableRootFSReuseAndRemove(t *testing.T) {
	id := strings.Repeat("d", 64)
	root := dockerRootFS{Parent: "sha256:" + strings.Repeat("b", 64)}
	s := &rootFSSnapshots{}
	if err := root.ensure(t.Context(), s, id, rootFSFirstBoot, true, func(pending dockerRootFS) error {
		root = pending
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(s.prepared) != 1 {
		t.Fatalf("snapshot preparations = %d, want 1", len(s.prepared))
	}
	request := s.prepared[0]
	if request.Snapshotter != dockerRootFSSnapshotter || request.Key != dockerRootFSKey(id) || request.Parent != root.Parent ||
		request.Labels[dockerRootFSOwner] != id || request.Labels[snapshotGCRoot] == "" {
		t.Fatalf("snapshot was not pinned under the Docker owner: %v", request)
	}
	// A crash after allocation may leave only the durable intent. The next
	// start adopts the exact already-owned snapshot rather than replacing it.
	if err := root.ensure(t.Context(), s, id, rootFSFirstBoot, false, unexpectedRootFSSave(t)); err != nil {
		t.Fatal(err)
	}
	root.Ready = true
	root.PrepareBootID = ""
	if err := root.ensure(t.Context(), s, id, rootFSSecondBoot, false, unexpectedRootFSSave(t)); err != nil {
		t.Fatal(err)
	}
	if len(s.prepared) != 1 {
		t.Fatal("subsequent start replaced its writable snapshot")
	}
	for range 2 {
		if err := root.remove(t.Context(), s, id, "", unexpectedRootFSSave(t)); err != nil {
			t.Fatal(err)
		}
	}
	if len(s.removed) != 1 || s.removed[0].Key != request.Key {
		t.Fatalf("removed snapshots = %v", s.removed)
	}
	if err := root.ensure(t.Context(), s, id, rootFSSecondBoot, false, unexpectedRootFSSave(t)); err == nil || !strings.Contains(err.Error(), "recorded writable rootfs is missing") {
		t.Fatalf("missing ready layer returned %v", err)
	}
	if len(s.prepared) != 1 {
		t.Fatal("missing ready layer was recreated")
	}
}

func TestDockerWritableRootFSRejectsForeignSnapshot(t *testing.T) {
	id := strings.Repeat("a", 64)
	root := dockerRootFS{Ready: true, Parent: "parent"}
	for name, corrupt := range map[string]func(*snapshots.Info){
		"owner":    func(info *snapshots.Info) { info.Labels[dockerRootFSOwner] = strings.Repeat("b", 64) },
		"parent":   func(info *snapshots.Info) { info.Parent = "other-parent" },
		"kind":     func(info *snapshots.Info) { info.Kind = snapshots.Kind_COMMITTED },
		"GC lease": func(info *snapshots.Info) { delete(info.Labels, snapshotGCRoot) },
	} {
		t.Run(name, func(t *testing.T) {
			info := &snapshots.Info{Name: dockerRootFSKey(id), Parent: root.Parent, Kind: snapshots.Kind_ACTIVE,
				Labels: map[string]string{dockerRootFSOwner: id, snapshotGCRoot: "pinned"}}
			corrupt(info)
			s := &rootFSSnapshots{info: info}
			if err := root.ensure(t.Context(), s, id, rootFSFirstBoot, false, unexpectedRootFSSave(t)); err == nil {
				t.Fatal("accepted a snapshot with incorrect ownership metadata")
			}
			if err := root.remove(t.Context(), s, id, "", unexpectedRootFSSave(t)); err == nil || len(s.removed) != 0 || len(s.prepared) != 0 {
				t.Fatalf("incorrectly altered a foreign snapshot: %v", err)
			}
		})
	}
}

func TestDockerWritableRootFSAttestsPrepareConflict(t *testing.T) {
	id := strings.Repeat("a", 64)
	s := &rootFSSnapshots{prepareResponse: status.Error(codes.AlreadyExists, "completion was ambiguous")}
	if err := (dockerRootFS{Parent: "parent"}).ensure(t.Context(), s, id, rootFSFirstBoot, true, func(dockerRootFS) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if len(s.prepared) != 1 {
		t.Fatalf("snapshot preparations = %d, want 1", len(s.prepared))
	}
}

func TestDockerWritableRootFSLatePrepareKeepsTombstoneUntilResolved(t *testing.T) {
	id := strings.Repeat("a", 64)
	root := dockerRootFS{Parent: "parent"}
	s := &rootFSSnapshots{delayPrepare: true}
	ctx := t.Context()
	err := root.ensure(ctx, s, id, rootFSFirstBoot, true, func(pending dockerRootFS) error {
		if len(s.prepared) != 0 || pending.PrepareBootID != rootFSFirstBoot || pending.Ready {
			t.Fatalf("invalid pre-Prepare record: %+v, prepares: %d", pending, len(s.prepared))
		}
		root = pending
		return nil
	})
	if status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("Prepare did not lose its reply: %v", err)
	}
	if err := root.ensure(ctx, s, id, rootFSFirstBoot, false, unexpectedRootFSSave(t)); !errors.Is(err, errUnconfirmedRootFSPrepare) {
		t.Fatalf("same-boot start returned %v", err)
	}
	if err := root.remove(ctx, s, id, rootFSFirstBoot, unexpectedRootFSSave(t)); !errors.Is(err, errUnconfirmedRootFSPrepare) {
		t.Fatalf("same-boot missing layer permitted dropping the tombstone: %v", err)
	}
	if len(s.prepared) != 1 || len(s.removed) != 0 {
		t.Fatal("a second snapshot mutation ran while Prepare was outstanding")
	}
	// The only in-flight Prepare can now publish its owned key. A later
	// cleanup may remove it even on the same boot.
	s.info = s.pending
	if err := root.remove(ctx, s, id, rootFSFirstBoot, unexpectedRootFSSave(t)); err != nil || len(s.removed) != 1 {
		t.Fatalf("observed allocation was not reclaimed: %v", err)
	}
	if err := root.remove(ctx, s, id, rootFSSecondBoot, unexpectedRootFSSave(t)); err != nil {
		t.Fatalf("a verified new boot cannot finish absent-root removal: %v", err)
	}
}

func TestDockerWritableRootFSLegacyUnfinishedIntentNeedsNewBoot(t *testing.T) {
	id := strings.Repeat("a", 64)
	root := dockerRootFS{Parent: "parent"}
	s := &rootFSSnapshots{info: &snapshots.Info{Name: dockerRootFSKey(id), Kind: snapshots.Kind_ACTIVE, Parent: root.Parent,
		Labels: map[string]string{dockerRootFSOwner: id, snapshotGCRoot: "pinned"}}}
	if err := root.remove(t.Context(), s, id, rootFSFirstBoot, func(pending dockerRootFS) error {
		root = pending
		return nil
	}); !errors.Is(err, errUnconfirmedRootFSPrepare) || !root.LegacyPrepare || root.PrepareBootID != rootFSFirstBoot {
		t.Fatalf("unknown legacy allocation was not fenced: %v, %+v", err, root)
	}
	if err := root.remove(t.Context(), s, id, rootFSFirstBoot, unexpectedRootFSSave(t)); !errors.Is(err, errUnconfirmedRootFSPrepare) || len(s.removed) != 0 {
		t.Fatalf("legacy allocation removed before pending writes were fenced: %v", err)
	}
	if err := root.remove(t.Context(), s, id, rootFSSecondBoot, unexpectedRootFSSave(t)); err != nil || len(s.removed) != 1 {
		t.Fatalf("legacy allocation not removed after a new boot: %v", err)
	}
}
