package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"time"

	leases "github.com/containerd/containerd/api/services/leases/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	mounttypes "github.com/containerd/containerd/api/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

const archiveViewPrefix = "mp-archive-view-"
const archiveViewOwner = "io.micropod.docker.archive-view"
const archiveViewLease = "io.micropod.docker.archive-lease"
const archiveViewLeaseHeader = "containerd-lease"

// An in-use mount must finish before its image lease can expire. Expiration
// lets containerd reclaim resources if the engine or runtime goes away.
const archiveViewLifetime = time.Hour
const archiveLeaseLifetime = 2 * archiveViewLifetime

type archiveLeaseClient interface {
	Create(context.Context, *leases.CreateRequest, ...grpc.CallOption) (*leases.CreateResponse, error)
	AddResource(context.Context, *leases.AddResourceRequest, ...grpc.CallOption) (*emptypb.Empty, error)
	Delete(context.Context, *leases.DeleteRequest, ...grpc.CallOption) (*emptypb.Empty, error)
}

type archiveViewClient interface {
	dockerSnapshotClient
	View(context.Context, *snapshots.ViewSnapshotRequest, ...grpc.CallOption) (*snapshots.ViewSnapshotResponse, error)
}

type archiveImageView struct {
	snapshots     archiveViewClient
	leases        archiveLeaseClient
	key           string
	owner, parent string
	pending       bool
}

func (s *dockerEngine) openReadOnlyArchive(ctx context.Context, c *dockerContainer, view dockerArchiveView) (dockerArchiveView, func(), error) {
	ctx, cancel := context.WithTimeout(dockerRootFSContext(ctx), archiveViewLifetime)
	s.imageMu.RLock()
	parent, err := s.node.archiveImageParent(ctx, c.ImageID)
	if err != nil {
		s.imageMu.RUnlock()
		cancel()
		return dockerArchiveView{}, nil, err
	}
	snapshot, mounts, err := s.node.prepareArchiveImageView(ctx, c.ID, parent)
	s.imageMu.RUnlock()
	if err != nil {
		cancel()
		return dockerArchiveView{}, nil, err
	}
	root, err := mountArchiveSnapshot(mounts, true)
	if err != nil {
		cancel()
		return dockerArchiveView{}, nil, errors.Join(fmt.Errorf("mount the read-only image: %w", err), snapshot.close(ctx))
	}
	if parent != "" {
		// The detached mount uses only committed image layers, which the
		// lease now pins directly. Discard the temporary View before the
		// transfer so an interrupted download cannot strand its name.
		if err := snapshot.remove(snapshot.leased(ctx)); err != nil {
			root.Close()
			cancel()
			return dockerArchiveView{}, nil, errors.Join(err, snapshot.close(ctx))
		}
		snapshot.pending = false
	}
	view.root = root
	view.lifetime = ctx
	return view, func() {
		root.Close()
		cancel()
		if err := snapshot.close(ctx); err != nil {
			log.Printf("release Docker read-only archive %s: %v", snapshot.key, err)
		}
	}, nil
}

func (n node) prepareArchiveImageView(ctx context.Context, id, parent string) (archiveImageView, []*mounttypes.Mount, error) {
	client, ok := n.snapshots.(archiveViewClient)
	if !ok || n.leases == nil {
		return archiveImageView{}, nil, fail(http.StatusServiceUnavailable, "read-only image snapshots are unavailable")
	}
	if !fullContainerID.MatchString(id) {
		return archiveImageView{}, nil, errors.New("invalid read-only archive owner")
	}
	if parent != "" {
		res, err := client.Stat(ctx, &snapshots.StatSnapshotRequest{Snapshotter: dockerRootFSSnapshotter, Key: parent})
		if status.Code(err) == codes.NotFound {
			return archiveImageView{}, nil, fail(http.StatusConflict, "the container image snapshot is unavailable")
		}
		if err != nil {
			return archiveImageView{}, nil, err
		}
		if info := res.GetInfo(); info.GetKind() != snapshots.Kind_COMMITTED || info.GetName() != parent {
			return archiveImageView{}, nil, errors.New("read-only archive requires a committed image snapshot")
		}
	}

	v := archiveImageView{snapshots: client, leases: n.leases, key: archiveViewPrefix + engineID(), owner: id, parent: parent}
	res, err := v.leases.Create(ctx, &leases.CreateRequest{ID: v.key, Labels: map[string]string{
		archiveViewOwner:          id,
		"containerd.io/gc.expire": time.Now().UTC().Add(archiveLeaseLifetime).Format(time.RFC3339),
	}})
	if err != nil {
		// No View was requested. Any late lease creation is empty and expires.
		return archiveImageView{}, nil, fmt.Errorf("create read-only archive lease: %w", err)
	}
	if lease := res.GetLease(); lease.GetID() != v.key || lease.GetLabels()[archiveViewOwner] != id {
		return archiveImageView{}, nil, errors.New("containerd did not return the requested archive lease")
	}
	if parent != "" {
		// Retain the immutable parent after the named View is removed.
		_, err = v.leases.AddResource(ctx, &leases.AddResourceRequest{ID: v.key, Resource: &leases.Resource{
			Type: "snapshots/" + dockerRootFSSnapshotter, ID: parent,
		}})
		if err != nil {
			return archiveImageView{}, nil, errors.Join(fmt.Errorf("lease the committed image: %w", err), v.close(ctx))
		}
	}

	v.pending = true
	response, err := client.View(v.leased(ctx), &snapshots.ViewSnapshotRequest{
		Snapshotter: dockerRootFSSnapshotter, Key: v.key, Parent: parent,
		Labels: map[string]string{archiveViewOwner: id, archiveViewLease: v.key},
	})
	if err != nil {
		return archiveImageView{}, nil, errors.Join(fmt.Errorf("open read-only image view: %w", err), v.close(ctx))
	}
	return v, response.GetMounts(), nil
}

func (v archiveImageView) leased(ctx context.Context) context.Context {
	return metadata.AppendToOutgoingContext(ctx, archiveViewLeaseHeader, v.key)
}

func (v archiveImageView) remove(ctx context.Context) error {
	res, err := v.snapshots.Stat(ctx, &snapshots.StatSnapshotRequest{Snapshotter: dockerRootFSSnapshotter, Key: v.key})
	if status.Code(err) == codes.NotFound {
		return nil
	}
	if err != nil {
		return err
	}
	info := res.GetInfo()
	if info.GetKind() != snapshots.Kind_VIEW || info.GetName() != v.key || info.GetParent() != v.parent ||
		info.GetLabels()[archiveViewOwner] != v.owner || info.GetLabels()[archiveViewLease] != v.key {
		return errors.New("refusing to remove an unrelated read-only snapshot")
	}
	_, err = v.snapshots.Remove(ctx, &snapshots.RemoveSnapshotRequest{Snapshotter: dockerRootFSSnapshotter, Key: v.key})
	if status.Code(err) == codes.NotFound {
		return nil
	}
	return err
}

func (v archiveImageView) close(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	var err error
	for range 3 {
		try, cancel := context.WithTimeout(ctx, 3*time.Second)
		err = v.closeOnce(try)
		cancel()
		switch status.Code(err) {
		case codes.Unavailable, codes.DeadlineExceeded, codes.Aborted:
			if pause(ctx) != nil {
				return err
			}
		default:
			return err
		}
	}
	return err
}

func (v archiveImageView) closeOnce(ctx context.Context) error {
	// Containerd adds the reference to the lease in the same transaction
	// that publishes a named View. Deleting the lease first prevents a late
	// View from appearing after we find its name absent.
	if _, err := v.leases.Delete(ctx, &leases.DeleteRequest{ID: v.key}); err != nil && status.Code(err) != codes.NotFound {
		return err
	}
	if v.pending {
		return v.remove(ctx)
	}
	return nil
}
