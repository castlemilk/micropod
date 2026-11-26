package main

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	"github.com/distribution/reference"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func fullDockerImageID(name string) bool {
	value, ok := strings.CutPrefix(name, "sha256:")
	return ok && fullContainerID.MatchString(value)
}

func (n node) findDockerImageID(ctx context.Context, raw string) (*images.Image, error) {
	if !possibleImageID.MatchString(raw) {
		return nil, fail(http.StatusBadRequest, "invalid image ID")
	}
	prefix := "sha256:" + strings.TrimPrefix(raw, "sha256:")
	if fullDockerImageID(prefix) {
		result, err := n.imageStore.Get(ctx, &images.GetImageRequest{Name: prefix})
		if status.Code(err) == codes.NotFound {
			return nil, nil
		}
		if err != nil {
			return nil, fmt.Errorf("read image ID: %w", err)
		}
		if result.GetImage().GetName() != prefix {
			return nil, fail(http.StatusConflict, "image ID record is inconsistent")
		}
		return result.GetImage(), nil
	}
	// The trailing digits restrict the search to config-ID records. Digest
	// aliases and named tags must never match an explicit short-ID request.
	pattern := fmt.Sprintf(`^%s[0-9a-f]{%d}$`, prefix, len("sha256:")+64-len(prefix))
	result, err := n.imageStore.List(ctx, &images.ListImagesRequest{Filters: []string{"name~=" + strconv.Quote(pattern)}})
	if err != nil {
		return nil, fmt.Errorf("list image IDs: %w", err)
	}
	var found *images.Image
	for _, record := range result.GetImages() {
		name := record.GetName()
		if !fullDockerImageID(name) || !strings.HasPrefix(name, prefix) {
			continue
		}
		if found != nil {
			return nil, fail(http.StatusConflict, "ambiguous image ID")
		}
		found = record
	}
	return found, nil
}

func (n node) dockerImageIDStatus(ctx context.Context, raw string, verbose bool) (*cri.ImageStatusResponse, error) {
	storeCtx := imageMetadataContext(ctx)
	record, err := n.findDockerImageID(storeCtx, raw)
	if err != nil {
		return nil, err
	}
	if record != nil {
		return n.dockerConfigImageStatus(ctx, record.GetName(), verbose)
	}
	digest := "sha256:" + strings.TrimPrefix(raw, "sha256:")
	if !fullDockerImageID(digest) {
		return &cri.ImageStatusResponse{}, nil
	}

	// Buildx publishes a manifest or index digest in --iidfile. Resolve only
	// its exact local target. A short ID and DELETE still use config IDs only.
	return n.dockerImageTargetStatus(ctx, digest, verbose)
}

func (n node) dockerImageTargetStatus(ctx context.Context, digest string, verbose bool) (*cri.ImageStatusResponse, error) {
	if !fullDockerImageID(digest) {
		return &cri.ImageStatusResponse{}, nil
	}
	storeCtx := imageMetadataContext(ctx)
	record, err := n.dockerConfigRecordForTarget(storeCtx, digest)
	if err != nil {
		return nil, err
	}
	if record == nil {
		return &cri.ImageStatusResponse{}, nil
	}
	img, err := n.dockerConfigImageStatus(ctx, record.GetName(), verbose)
	if err != nil || img.GetImage() == nil {
		return img, err
	}
	// The CRI index can retain a removed image while its events drain.
	current, err := n.findDockerImageID(storeCtx, record.GetName())
	if err != nil {
		return nil, err
	}
	if current == nil {
		return &cri.ImageStatusResponse{}, nil
	}
	old, target := record.GetTarget(), current.GetTarget()
	if current.GetLabels()[criManagedImage] != "managed" || target.GetDigest() != digest ||
		target.GetMediaType() != old.GetMediaType() || target.GetSize() != old.GetSize() {
		return nil, fail(http.StatusConflict, "image target changed during ID lookup")
	}
	return img, nil
}

func (n node) dockerConfigImageStatus(ctx context.Context, id string, verbose bool) (*cri.ImageStatusResponse, error) {
	img, err := n.images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: id}, Verbose: verbose})
	if err == nil && img.GetImage() != nil && img.GetImage().GetId() != id {
		return nil, fail(http.StatusConflict, "runtime image ID could not be verified")
	}
	return img, err
}

func (n node) dockerConfigRecordForTarget(ctx context.Context, digest string) (*images.Image, error) {
	rows, err := n.imageIDTargetRecords(ctx, digest)
	if err != nil {
		return nil, err
	}
	var record *images.Image
	for _, row := range rows {
		target := row.GetTarget()
		if target.GetDigest() != digest || target.GetSize() <= 0 || !fullDockerImageID(row.GetName()) ||
			row.GetLabels()[criManagedImage] != "managed" {
			continue
		}
		if record != nil {
			return nil, fail(http.StatusConflict, "image target has multiple local config IDs")
		}
		record = row
	}
	if record == nil {
		return nil, nil
	}
	target := record.GetTarget()
	switch target.GetMediaType() {
	case ocispec.MediaTypeImageManifest, "application/vnd.docker.distribution.manifest.v2+json":
		id, err := n.manifestConfigID(ctx, target)
		if err != nil {
			return nil, err
		}
		if id != record.GetName() {
			return nil, fail(http.StatusConflict, "image manifest does not match its local config ID")
		}
	case ocispec.MediaTypeImageIndex, "application/vnd.docker.distribution.manifest.list.v2+json":
		// CRI's config-ID record for the exact index supplies its selected
		// platform. Attestation manifests never take part in that lookup.
	default:
		return nil, nil
	}
	return record, nil
}

// removeUnusedImageID operates only on an ID and its immutable aliases with
// the same verified manifest. The caller holds imageMu across the checks and
// mutations; independent containerd clients are guarded only per record.
func (s *dockerEngine) removeUnusedImageID(ctx context.Context, raw string, force bool) ([]map[string]string, error) {
	storeCtx := imageMetadataContext(ctx)
	if err := s.node.checkBareHexDeleteFallback(storeCtx, raw); err != nil {
		return nil, err
	}
	idRecord, err := s.node.findDockerImageID(storeCtx, raw)
	if err != nil {
		return nil, err
	}
	if idRecord == nil {
		return nil, fail(http.StatusNotFound, "No such image: "+raw)
	}
	id, target := idRecord.GetName(), idRecord.GetTarget()
	if err := checkImageIDRemovalRecord(idRecord, target); err != nil {
		return nil, err
	}
	runnable, err := s.node.verifyImageIDManifest(storeCtx, id, target)
	if err != nil {
		return nil, err
	}
	refs, err := s.node.imageIDTargetRecords(storeCtx, target.GetDigest())
	if err != nil {
		return nil, err
	}
	aliases := make([]*images.Image, 0, len(refs))
	foundID := false
	for _, record := range refs {
		if err := checkImageIDRemovalRecord(record, target); err != nil {
			return nil, err
		}
		if record.GetName() == id {
			foundID = true
			continue
		}
		if _, ok := immutableImageIDAlias(record.GetName(), target.GetDigest()); !ok {
			return nil, fail(http.StatusConflict, "image still has a named or unverified reference")
		}
		aliases = append(aliases, record)
	}
	if !foundID {
		return nil, fail(http.StatusConflict, "image ID changed during removal")
	}
	if err := s.checkImageIDUsage(ctx, id, target.GetDigest(), runnable); err != nil {
		return nil, err
	}
	cached, err := s.node.images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: id}})
	if err != nil {
		return nil, fmt.Errorf("verify runtime image references: %w", err)
	}
	image := cached.GetImage()
	if image.GetId() != id || image.GetPinned() || len(image.GetRepoTags()) != 0 {
		return nil, fail(http.StatusConflict, "runtime image is pinned, tagged, or could not be verified")
	}
	for _, value := range image.GetRepoDigests() {
		if _, ok := immutableImageIDAlias(value, target.GetDigest()); !ok {
			return nil, fail(http.StatusConflict, "image has a reference to another descriptor")
		}
	}
	if len(aliases) != 0 && !force {
		// Old ctr imports have no provenance marker, even when the name has
		// the generated import-date shape. Treat them as real digest refs.
		for _, row := range aliases {
			prefix, _, _ := strings.Cut(row.GetName(), "@")
			if day, ok := strings.CutPrefix(prefix, "import-"); ok {
				if _, err := time.Parse("2006-01-02", day); err == nil {
					return nil, fail(http.StatusConflict, "image has an import digest reference; use --force to remove its immutable references")
				}
			}
		}
		return nil, fail(http.StatusConflict, "image has a repository digest reference; use --force to remove its immutable references")
	}

	slices.SortFunc(aliases, func(a, b *images.Image) int { return cmp.Compare(a.GetName(), b.GetName()) })
	removed := make([]map[string]string, 0, len(aliases)+1)
	reported := make(map[string]bool, len(aliases))
	for _, alias := range aliases {
		if err := s.node.deleteImageIDRecord(storeCtx, alias.GetName(), target); err != nil {
			return nil, err
		}
		ref, _ := immutableImageIDAlias(alias.GetName(), target.GetDigest())
		name := reference.FamiliarString(ref)
		if !reported[name] {
			removed = append(removed, map[string]string{"Untagged": name})
			reported[name] = true
		}
	}
	// Keep the ID until the end so an interrupted or partial alias deletion
	// remains reachable by its exact ID and can be retried safely.
	remaining, err := s.node.imageIDTargetRecords(storeCtx, target.GetDigest())
	if err != nil {
		return nil, err
	}
	if len(remaining) != 1 || remaining[0].GetName() != id {
		return nil, fail(http.StatusConflict, "image references changed during removal; retry by ID")
	}
	if err := s.checkImageIDUsage(ctx, id, target.GetDigest(), runnable); err != nil {
		return nil, err
	}
	if err := s.node.checkBareHexDeleteFallback(storeCtx, raw); err != nil {
		return nil, err
	}
	if err := s.node.deleteImageIDRecord(storeCtx, id, target); err != nil {
		return nil, err
	}
	return append(removed, map[string]string{"Deleted": id}), nil
}

// Legacy imports can keep an unnormalized tag that the ordinary named removal
// does not find. A bare hex request must not fall through to a different image.
func (n node) checkBareHexDeleteFallback(ctx context.Context, raw string) error {
	tag := bareHexImageTag(raw)
	if tag == nil {
		return nil
	}
	pattern := `^((index\.)?docker\.io/)?(library/)?` + raw + `(:latest)?$`
	result, err := n.imageStore.List(ctx, &images.ListImagesRequest{Filters: []string{"name~=" + strconv.Quote(pattern)}})
	if err != nil {
		return fmt.Errorf("verify competing image tags: %w", err)
	}
	for _, image := range result.GetImages() {
		name, err := reference.ParseNormalizedNamed(image.GetName())
		if err == nil && reference.TagNameOnly(name).String() == tag.String() {
			return fail(http.StatusConflict, "image name resolves to a legacy repository tag; use an explicit image ID")
		}
	}
	return nil
}

func immutableImageIDAlias(name, digest string) (reference.Canonical, bool) {
	parsed, err := reference.ParseNormalizedNamed(name)
	ref, canonical := parsed.(reference.Canonical)
	_, tagged := parsed.(reference.Tagged)
	return ref, err == nil && canonical && !tagged && ref.Digest().String() == digest
}

func checkImageIDRemovalRecord(record *images.Image, target *types.Descriptor) error {
	current := record.GetTarget()
	if !fullDockerImageID(target.GetDigest()) || current.GetDigest() != target.GetDigest() ||
		current.GetMediaType() != target.GetMediaType() || current.GetSize() != target.GetSize() {
		return fail(http.StatusConflict, "image descriptor changed during removal")
	}
	labels := record.GetLabels()
	if _, pinned := labels["io.cri-containerd.pinned"]; pinned {
		return fail(http.StatusConflict, "image is pinned by the worker")
	}
	if labels[criManagedImage] != "managed" {
		return fail(http.StatusConflict, "image reference is not managed by the worker runtime")
	}
	for key := range labels {
		if key == "containerd.io/gc.expire" || strings.HasPrefix(key, "containerd.io/gc.bref.") {
			return fail(http.StatusConflict, "image reference is managed by a runtime retention policy")
		}
	}
	return nil
}

func (n node) imageIDTargetRecords(ctx context.Context, digest string) ([]*images.Image, error) {
	response, err := n.imageStore.List(ctx, &images.ListImagesRequest{Filters: []string{"target.digest==" + strconv.Quote(digest)}})
	if err != nil {
		return nil, fmt.Errorf("verify image reference records: %w", err)
	}
	return response.GetImages(), nil
}

func (n node) deleteImageIDRecord(ctx context.Context, name string, target *types.Descriptor) error {
	current, err := n.imageStore.Get(ctx, &images.GetImageRequest{Name: name})
	if status.Code(err) == codes.NotFound {
		return fail(http.StatusConflict, "image reference disappeared during removal; retry by ID")
	}
	if err != nil {
		return fmt.Errorf("read image reference before removal: %w", err)
	}
	if current.GetImage().GetName() != name {
		return fail(http.StatusConflict, "image reference changed during removal; retry by ID")
	}
	if err := checkImageIDRemovalRecord(current.GetImage(), target); err != nil {
		return err
	}
	_, err = n.imageStore.Delete(ctx, &images.DeleteImageRequest{Name: name, Target: target})
	if status.Code(err) == codes.NotFound {
		return fail(http.StatusConflict, "image reference changed during removal; retry by ID")
	}
	if err != nil {
		return fmt.Errorf("remove image reference: %w", err)
	}
	return nil
}

func (s *dockerEngine) checkImageIDUsage(ctx context.Context, id string, manifestDigests ...string) error {
	_, err := s.imageIDRemovalUsage(ctx, id, false, manifestDigests...)
	return err
}

// With permission to remove only repository references, stopped containers
// retain the config record. Running and unverified containers still conflict.
func (s *dockerEngine) imageIDRemovalUsage(ctx context.Context, id string, allowStopped bool, manifestDigests ...string) (bool, error) {
	var retained bool
	s.mu.Lock()
	for _, c := range s.containers {
		if c.ImageID == id {
			if !allowStopped || (c.Phase != "created" && c.Phase != "exited") {
				s.mu.Unlock()
				return false, fail(http.StatusConflict, "image is used by retained container "+c.ID)
			}
			retained = true
		}
	}
	s.mu.Unlock()
	listed, err := s.node.runtime.ListContainers(ctx, &cri.ListContainersRequest{})
	if err != nil {
		return false, fmt.Errorf("verify runtime containers before image removal: %w", err)
	}
	if listed == nil {
		return false, fail(http.StatusConflict, "runtime container inventory could not be verified")
	}
	for _, c := range listed.GetContainers() {
		imageRef := c.GetImageRef()
		named, _ := reference.ParseNormalizedNamed(imageRef)
		canonical, digested := named.(reference.Digested)
		if c.GetImageId() == id || imageRef == id || slices.Contains(manifestDigests, imageRef) ||
			digested && slices.Contains(manifestDigests, canonical.Digest().String()) {
			if !allowStopped || (c.GetState() != cri.ContainerState_CONTAINER_CREATED && c.GetState() != cri.ContainerState_CONTAINER_EXITED) {
				return false, fail(http.StatusConflict, "image is used by a runtime container")
			}
			retained = true
			continue
		}
		if !fullDockerImageID(c.GetImageId()) && !fullDockerImageID(imageRef) {
			return false, fail(http.StatusConflict, "runtime container image identity could not be verified")
		}
	}
	return retained, nil
}

func (n node) verifyImageIDManifest(ctx context.Context, id string, target *types.Descriptor) (string, error) {
	if target.GetMediaType() == ocispec.MediaTypeImageIndex {
		return n.verifyImageIDAttestationIndex(ctx, id, target)
	}
	if target.GetMediaType() != ocispec.MediaTypeImageManifest && target.GetMediaType() != "application/vnd.docker.distribution.manifest.v2+json" {
		return "", fail(http.StatusConflict, "image ID removal requires a single image manifest")
	}
	configID, err := n.manifestConfigID(ctx, target)
	if err != nil {
		return "", err
	}
	if configID != id {
		return "", fail(http.StatusConflict, "image manifest does not match the requested config ID")
	}
	return target.GetDigest(), nil
}

// Read the published single-platform manifest by its immutable content address.
// A tag may move while a build is finishing or an image is being removed.
func (n node) manifestConfigID(ctx context.Context, target *types.Descriptor) (string, error) {
	manifest, err := n.readVerifiedImageBlob(ctx, target, "image manifest")
	if err != nil {
		return "", err
	}
	var parsed ocispec.Manifest
	if json.Unmarshal(manifest, &parsed) != nil || parsed.SchemaVersion != 2 ||
		(parsed.MediaType != "" && parsed.MediaType != target.GetMediaType()) || !fullDockerImageID(parsed.Config.Digest.String()) {
		return "", fail(http.StatusConflict, "image manifest does not match the requested config ID")
	}
	return parsed.Config.Digest.String(), nil
}
