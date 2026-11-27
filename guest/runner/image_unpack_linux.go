package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"

	contentapi "github.com/containerd/containerd/api/services/content/v1"
	diffapi "github.com/containerd/containerd/api/services/diff/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	leases "github.com/containerd/containerd/api/services/leases/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"github.com/containerd/containerd/api/types"
	"github.com/containerd/platforms"
	"github.com/distribution/reference"
	"github.com/opencontainers/go-digest"
	"github.com/opencontainers/image-spec/identity"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/fieldmaskpb"
)

// Unpacking an image BuildKit stored for another platform.
//
// BuildKit's image exporter unpacks only the build's linux/arm64 result
// (exporter/containerimage: "current platform was not found, so skip
// unpacking"), and CRI unpacks for linux/arm64 only, so an image built with
// `--platform linux/amd64` (alone or beside linux/arm64) and loaded into the
// engine has its layers in the content store but no snapshots, and no
// container can start from it. The engine unpacks it as containerd's own
// unpacker does: each layer applied by containerd's diff service onto a
// snapshot prepared on the one below it, committed under its chain ID, the
// whole under a lease until the config's GC reference names the top snapshot.
// What it commits is made durable by the imageSync.Sync the build already
// makes before it answers (image_durability_linux.go).

type layerUnpacker interface {
	unpack(ctx context.Context, manifest *types.Descriptor) error
}

type layerDiffClient interface {
	Apply(context.Context, *diffapi.ApplyRequest, ...grpc.CallOption) (*diffapi.ApplyResponse, error)
}

type layerSnapshotClient interface {
	Stat(context.Context, *snapshots.StatSnapshotRequest, ...grpc.CallOption) (*snapshots.StatSnapshotResponse, error)
	Prepare(context.Context, *snapshots.PrepareSnapshotRequest, ...grpc.CallOption) (*snapshots.PrepareSnapshotResponse, error)
	Commit(context.Context, *snapshots.CommitSnapshotRequest, ...grpc.CallOption) (*emptypb.Empty, error)
	Remove(context.Context, *snapshots.RemoveSnapshotRequest, ...grpc.CallOption) (*emptypb.Empty, error)
}

type layerContentClient interface {
	Update(context.Context, *contentapi.UpdateRequest, ...grpc.CallOption) (*contentapi.UpdateResponse, error)
}

type grpcLayerUnpacker struct {
	node      node
	diff      layerDiffClient
	snapshots layerSnapshotClient
	content   layerContentClient
	leases    leases.LeasesClient
}

func newLayerUnpacker(conn grpc.ClientConnInterface, n node) grpcLayerUnpacker {
	return grpcLayerUnpacker{
		node: n, diff: diffapi.NewDiffClient(conn), snapshots: snapshots.NewSnapshotsClient(conn),
		content: contentapi.NewContentClient(conn), leases: leases.NewLeasesClient(conn),
	}
}

const gcSnapshotLabel = "containerd.io/gc.ref.snapshot." + dockerRootFSSnapshotter

func (u grpcLayerUnpacker) unpack(ctx context.Context, target *types.Descriptor) error {
	storeCtx := imageMetadataContext(ctx)
	raw, err := u.node.readVerifiedImageBlob(storeCtx, target, "image manifest")
	if err != nil {
		return err
	}
	var manifest ocispec.Manifest
	if err := json.Unmarshal(raw, &manifest); err != nil || manifest.Config.Digest == "" {
		return fail(http.StatusConflict, "image manifest could not be read")
	}
	configDesc := &types.Descriptor{MediaType: manifest.Config.MediaType, Digest: manifest.Config.Digest.String(), Size: manifest.Config.Size}
	raw, err = u.node.readVerifiedImageBlob(storeCtx, configDesc, "image config")
	if err != nil {
		return err
	}
	var config ocispec.Image
	if err := json.Unmarshal(raw, &config); err != nil {
		return fail(http.StatusConflict, "image config could not be read")
	}
	diffIDs := config.RootFS.DiffIDs
	if len(diffIDs) != len(manifest.Layers) {
		return fail(http.StatusConflict, fmt.Sprintf("image has %d layers and %d diff IDs", len(manifest.Layers), len(diffIDs)))
	}
	if len(diffIDs) == 0 {
		return nil
	}
	chains := identity.ChainIDs(slices.Clone(diffIDs))
	top := chains[len(chains)-1].String()
	if u.committed(storeCtx, top) {
		return u.labelConfig(storeCtx, configDesc.Digest, top)
	}
	// The snapshots exist only through the lease until the config's label
	// references the top one.
	leaseID := "mp-unpack-" + rand.Text()
	if _, err := u.leases.Create(storeCtx, &leases.CreateRequest{ID: leaseID, Labels: map[string]string{
		"containerd.io/gc.expire": time.Now().UTC().Add(time.Hour).Format(time.RFC3339),
	}}); err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(storeCtx), 5*time.Second)
		defer cancel()
		_, _ = u.leases.Delete(cleanup, &leases.DeleteRequest{ID: leaseID})
	}()
	leased := metadata.AppendToOutgoingContext(storeCtx, "containerd-lease", leaseID)
	parent := ""
	for i, layer := range manifest.Layers {
		chain := chains[i].String()
		if u.committed(leased, chain) {
			parent = chain
			continue
		}
		if err := u.applyLayer(leased, layer, diffIDs[i], parent, chain); err != nil {
			return fmt.Errorf("unpack layer %d of %s: %w", i+1, target.GetDigest(), err)
		}
		parent = chain
	}
	return u.labelConfig(leased, configDesc.Digest, top)
}

func (u grpcLayerUnpacker) committed(ctx context.Context, name string) bool {
	res, err := u.snapshots.Stat(ctx, &snapshots.StatSnapshotRequest{Snapshotter: dockerRootFSSnapshotter, Key: name})
	return err == nil && res.GetInfo().GetKind() == snapshots.Kind_COMMITTED
}

func (u grpcLayerUnpacker) applyLayer(ctx context.Context, layer ocispec.Descriptor, diffID digest.Digest, parent, chain string) error {
	key := "mp-extract-" + rand.Text() + "-" + chain
	prepared, err := u.snapshots.Prepare(ctx, &snapshots.PrepareSnapshotRequest{
		Snapshotter: dockerRootFSSnapshotter, Key: key, Parent: parent,
	})
	if err != nil {
		return fmt.Errorf("prepare: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			defer cancel()
			_, _ = u.snapshots.Remove(cleanup, &snapshots.RemoveSnapshotRequest{Snapshotter: dockerRootFSSnapshotter, Key: key})
		}
	}()
	applied, err := u.diff.Apply(ctx, &diffapi.ApplyRequest{
		Diff:   &types.Descriptor{MediaType: layer.MediaType, Digest: layer.Digest.String(), Size: layer.Size, Annotations: layer.Annotations},
		Mounts: prepared.GetMounts(),
	})
	if err != nil {
		return fmt.Errorf("apply: %w", err)
	}
	if got := applied.GetApplied().GetDigest(); got != diffID.String() {
		return fmt.Errorf("the layer's content is %s, its config names %s", got, diffID)
	}
	_, err = u.snapshots.Commit(ctx, &snapshots.CommitSnapshotRequest{Snapshotter: dockerRootFSSnapshotter, Name: chain, Key: key})
	if status.Code(err) == codes.AlreadyExists {
		return nil // a concurrent unpack committed it; ours goes with the key
	}
	if err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	committed = true
	return nil
}

func (u grpcLayerUnpacker) labelConfig(ctx context.Context, config, top string) error {
	_, err := u.content.Update(ctx, &contentapi.UpdateRequest{
		Info:       &contentapi.Info{Digest: config, Labels: map[string]string{gcSnapshotLabel: top}},
		UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"labels." + gcSnapshotLabel}},
	})
	if err != nil {
		return fmt.Errorf("reference the unpacked layers from the image config: %w", err)
	}
	return nil
}

// finishEmulatedLoad makes the images a build stored for platforms other than
// the engine's runnable. For each name: an index's non-native entries are
// unpacked and named <repository>@<digest> (labelled as an emulated pull
// labels them, so `--platform` finds them by the tag or the index digest);
// an index with no native entry (a single-platform build, with its
// attestation) is replaced by its one runnable manifest under the tag, as
// CRI can resolve only that shape for another platform; a single non-native
// manifest is unpacked in place. It answers once CRI shows every name.
func (s dockerBuildSolver) finishEmulatedLoad(ctx context.Context, tags []string, response map[string]string) error {
	if s.node.unpacker == nil {
		return errors.New("the engine cannot unpack images for another platform")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	storeCtx := imageMetadataContext(ctx)
	for _, tag := range tags {
		record, err := s.node.imageStore.Get(storeCtx, &images.GetImageRequest{Name: tag})
		if status.Code(err) == codes.NotFound {
			continue
		}
		if err != nil {
			return fmt.Errorf("read the built image %s: %w", tag, err)
		}
		target := record.GetImage().GetTarget()
		named, err := reference.ParseNormalizedNamed(tag)
		if err != nil {
			return err
		}
		switch {
		case isIndexDescriptor(target.GetMediaType()):
			id, err := s.finishEmulatedIndex(ctx, named, record.GetImage())
			if err != nil {
				return err
			}
			if id != "" {
				response["containerimage.config.digest"] = id
				if err := s.node.waitForDockerImageTag(ctx, tag, id); err != nil {
					return err
				}
			}
		case isManifestDescriptor(target.GetMediaType()):
			if err := s.node.unpacker.unpack(ctx, target); err != nil {
				return err
			}
			id, err := s.node.manifestConfigID(storeCtx, target)
			if err != nil {
				return err
			}
			response["containerimage.config.digest"] = id
			if err := s.node.waitForDockerImageTag(ctx, tag, id); err != nil {
				return err
			}
		}
	}
	return nil
}

// finishEmulatedIndex handles one built index. It returns the config ID the
// tag now names when the tag was moved to a single manifest, "" when the tag
// keeps the index (it has a native entry, which CRI resolves).
func (s dockerBuildSolver) finishEmulatedIndex(ctx context.Context, named reference.Named, record *images.Image) (string, error) {
	storeCtx := imageMetadataContext(ctx)
	target := record.GetTarget()
	raw, err := s.node.readVerifiedImageBlob(storeCtx, target, "image index")
	if err != nil {
		return "", err
	}
	var index ocispec.Index
	if err := json.Unmarshal(raw, &index); err != nil {
		return "", fail(http.StatusConflict, "built image index could not be read")
	}
	native := platforms.OnlyStrict(nativePlatform)
	var runnable []ocispec.Descriptor
	hasNative := false
	for _, m := range index.Manifests {
		if m.Platform == nil || !isManifestDescriptor(m.MediaType) || platformMatches(attestationEntry, *m.Platform) {
			continue
		}
		p := platforms.Normalize(*m.Platform)
		if native.Match(p) {
			hasNative = true
			continue
		}
		if runs, _ := runsHere(p); runs {
			runnable = append(runnable, m)
		}
	}
	tag, _ := named.(reference.NamedTagged)
	for _, m := range runnable {
		desc := &types.Descriptor{MediaType: m.MediaType, Digest: m.Digest.String(), Size: m.Size}
		if err := s.node.unpacker.unpack(ctx, desc); err != nil {
			return "", err
		}
		name := named.Name() + "@" + m.Digest.String()
		labels := map[string]string{emulatedPlatformLabel: platforms.Format(platforms.Normalize(*m.Platform)), emulatedIndexLabel: target.GetDigest()}
		if tag != nil {
			labels[emulatedTagLabel(tag.String())] = tag.String()
		}
		_, err := s.node.imageStore.Create(storeCtx, &images.CreateImageRequest{Image: &images.Image{Name: name, Target: desc, Labels: labels}})
		if status.Code(err) == codes.AlreadyExists {
			err = s.node.labelEmulatedImage(ctx, name, labels)
		}
		if err != nil {
			return "", fmt.Errorf("name the built %s image %s: %w", platforms.Format(*m.Platform), name, err)
		}
		if tag != nil {
			if err := s.node.moveEmulatedTagLabel(ctx, tag.String(), name); err != nil {
				return "", err
			}
		}
		if err := s.node.awaitEmulatedImage(ctx, name); err != nil {
			return "", err
		}
	}
	if hasNative || len(runnable) != 1 || tag == nil {
		return "", nil
	}
	// One runnable image and no native one: the tag names that manifest.
	only := runnable[0]
	desc := &types.Descriptor{MediaType: only.MediaType, Digest: only.Digest.String(), Size: only.Size}
	_, err = s.node.imageStore.Update(storeCtx, &images.UpdateImageRequest{
		Image:      &images.Image{Name: tag.String(), Target: desc},
		UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"target"}},
	})
	if err != nil {
		return "", fmt.Errorf("name the built image %s: %w", tag, err)
	}
	return s.node.manifestConfigID(storeCtx, desc)
}

// buildIsNative reads a build's platform attribute ("linux/amd64",
// "linux/amd64,linux/arm64"): native when it names only linux/arm64.
func buildIsNative(raw string) bool {
	if raw == "" {
		return true
	}
	for _, field := range strings.Split(raw, ",") {
		if field == "" {
			continue
		}
		p, err := platforms.Parse(field)
		if err != nil || !platforms.OnlyStrict(nativePlatform).Match(platforms.Normalize(p)) {
			return false
		}
	}
	return true
}
