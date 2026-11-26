package main

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"time"

	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

const dockerRootFSSnapshotter = "overlayfs"
const dockerRootFSOwner = "io.micropod.docker.rootfs"
const snapshotGCRoot = "containerd.io/gc.root"
const scratchSnapshotReference = "containerd.io/gc.ref.snapshot." + dockerRootFSSnapshotter

var fullContainerID = regexp.MustCompile(`^[a-f0-9]{64}$`)
var bootIDPattern = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

var errUnconfirmedRootFSAttach = errors.New("writable rootfs attachment was unconfirmed. Reboot the guest before cleanup")
var errUnconfirmedRootFSPrepare = errors.New("writable rootfs allocation is unconfirmed. Retry after the guest reboots")

// The initial intent is saved before Prepare. A missing ready layer must never
// be prepared again: it may have held data written by a previous process.
type dockerRootFS struct {
	Parent        string
	Ready         bool
	PrepareBootID string `json:",omitempty"`
	LegacyPrepare bool   `json:",omitempty"`
}

type dockerRootFSBinding struct {
	DockerID, JobID, PodID, ContainerID string
	BootID                              string `json:",omitempty"`
	AttachAcknowledged                  bool   `json:",omitempty"`
}

func (b dockerRootFSBinding) checkCleanupBoot(currentBoot string) error {
	if b.AttachAcknowledged {
		return nil
	}
	if !bootIDPattern.MatchString(b.BootID) || !bootIDPattern.MatchString(currentBoot) || b.BootID == currentBoot {
		return errUnconfirmedRootFSAttach
	}
	return nil
}

type dockerSnapshotClient interface {
	Stat(context.Context, *snapshots.StatSnapshotRequest, ...grpc.CallOption) (*snapshots.StatSnapshotResponse, error)
	Prepare(context.Context, *snapshots.PrepareSnapshotRequest, ...grpc.CallOption) (*snapshots.PrepareSnapshotResponse, error)
	Remove(context.Context, *snapshots.RemoveSnapshotRequest, ...grpc.CallOption) (*emptypb.Empty, error)
}

func dockerRootFSKey(id string) string { return "mp-rootfs-" + id }

func (r dockerRootFS) attest(ctx context.Context, client dockerSnapshotClient, id string) error {
	if !fullContainerID.MatchString(id) {
		return errors.New("invalid writable rootfs owner")
	}
	key := dockerRootFSKey(id)
	res, err := client.Stat(ctx, &snapshots.StatSnapshotRequest{Snapshotter: dockerRootFSSnapshotter, Key: key})
	if err != nil {
		return err
	}
	info := res.GetInfo()
	if info.GetName() != key || info.GetKind() != snapshots.Kind_ACTIVE || info.GetParent() != r.Parent ||
		info.GetLabels()[dockerRootFSOwner] != id || info.GetLabels()[snapshotGCRoot] == "" {
		return errors.New("writable rootfs ownership or parent differs from its Docker record")
	}
	return nil
}

func (r dockerRootFS) fenceLegacyPrepare(bootID string, save func(dockerRootFS) error) error {
	if r.Ready {
		return nil
	}
	if !bootIDPattern.MatchString(bootID) {
		return errUnconfirmedRootFSPrepare
	}
	if r.PrepareBootID == "" {
		// Older callers could issue another Prepare after a lost reply.
		r.PrepareBootID = bootID
		r.LegacyPrepare = true
		if err := save(r); err != nil {
			return err
		}
	}
	if r.LegacyPrepare && r.PrepareBootID == bootID {
		return errUnconfirmedRootFSPrepare
	}
	return nil
}

func (r dockerRootFS) ensure(ctx context.Context, client dockerSnapshotClient, id, bootID string, first bool, save func(dockerRootFS) error) error {
	if !first {
		if err := r.fenceLegacyPrepare(bootID, save); err != nil {
			return err
		}
	}
	err := r.attest(ctx, client, id)
	if status.Code(err) != codes.NotFound {
		return err
	}
	if r.Ready {
		return fmt.Errorf("recorded writable rootfs is missing: %w", err)
	}
	if !bootIDPattern.MatchString(bootID) || r.PrepareBootID == bootID {
		return errUnconfirmedRootFSPrepare
	}
	r.PrepareBootID = bootID
	r.LegacyPrepare = false
	if err := save(r); err != nil {
		return fmt.Errorf("record writable rootfs allocation: %w", err)
	}
	_, err = client.Prepare(ctx, &snapshots.PrepareSnapshotRequest{
		Snapshotter: dockerRootFSSnapshotter, Key: dockerRootFSKey(id), Parent: r.Parent,
		Labels: map[string]string{dockerRootFSOwner: id, snapshotGCRoot: time.Now().UTC().Format(time.RFC3339Nano)},
	})
	if err != nil && status.Code(err) != codes.AlreadyExists {
		return fmt.Errorf("prepare writable rootfs: %w", err)
	}
	return r.attest(ctx, client, id)
}

func (r dockerRootFS) remove(ctx context.Context, client dockerSnapshotClient, id, bootID string, save func(dockerRootFS) error) error {
	if err := r.fenceLegacyPrepare(bootID, save); err != nil {
		return err
	}
	if err := r.attest(ctx, client, id); status.Code(err) == codes.NotFound {
		if !r.Ready && r.PrepareBootID == bootID {
			return errUnconfirmedRootFSPrepare
		}
		return nil
	} else if err != nil {
		return err
	}
	_, err := client.Remove(ctx, &snapshots.RemoveSnapshotRequest{Snapshotter: dockerRootFSSnapshotter, Key: dockerRootFSKey(id)})
	if status.Code(err) == codes.NotFound {
		return nil
	}
	return err
}
