package main

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"strings"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/distribution/reference"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// dockerDigestTarget verifies the repository association in the containerd
// image store before accepting the descriptor. A missing association is nil.
func (n node) dockerDigestTarget(ctx context.Context, ref reference.Canonical) (*images.Image, error) {
	digest := ref.Digest()
	result, err := n.imageStore.List(imageMetadataContext(ctx), &images.ListImagesRequest{
		Filters: []string{"target.digest==" + strconv.Quote(digest.String())},
	})
	if err != nil {
		return nil, fmt.Errorf("list image references: %w", err)
	}
	var currentTag *images.Image
	for _, image := range result.GetImages() {
		if image.GetTarget().GetDigest() != digest.String() || fullDockerImageID(image.GetName()) {
			continue
		}
		name, err := reference.ParseNormalizedNamed(image.GetName())
		if err != nil || name.Name() != ref.Name() {
			continue
		}
		if namedDigest, ok := name.(reference.Digested); ok {
			if namedDigest.Digest() == digest {
				return image, nil
			}
		} else if currentTag == nil {
			currentTag = image
		}
	}
	return currentTag, nil
}

func (n node) dockerDigestImageStatus(ctx context.Context, raw string, ref reference.Canonical, verbose bool) (*cri.ImageStatusResponse, error) {
	target, err := n.dockerDigestTarget(ctx, ref)
	if err != nil {
		return nil, err
	}
	if target == nil {
		return &cri.ImageStatusResponse{}, nil
	}
	if !strings.Contains(target.GetName(), "@") {
		// A live tag attests to the repository association. Resolve its config
		// from the exact authoritative descriptor, even if CRI has a stale
		// cached entry for a digest reference that was never stored.
		resolved, err := n.dockerImageTargetStatus(ctx, target.GetTarget().GetDigest(), verbose)
		if err != nil || resolved.GetImage() != nil {
			return resolved, err
		}
		return n.legacyDockerTagDigestStatus(ctx, target, raw, verbose)
	}
	req := &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: raw}, Verbose: verbose}
	image, err := n.images.ImageStatus(ctx, req)
	if err != nil || image.GetImage() != nil {
		return image, err
	}
	// Imports can store the raw alias while CRI reports a normalized RepoDigest.
	// Once the image record attests to the descriptor, use its CRI config ID.
	cached, err := n.images.ListImages(ctx, &cri.ListImagesRequest{})
	if err != nil {
		return nil, err
	}
	repoDigest := ref.Name() + "@" + ref.Digest().String()
	var id string
	for _, entry := range cached.GetImages() {
		if entry.GetId() == "" || !slices.Contains(entry.GetRepoDigests(), repoDigest) {
			continue
		}
		if id != "" && id != entry.GetId() {
			return nil, fail(http.StatusConflict, "ambiguous image repository digest")
		}
		id = entry.GetId()
	}
	if id == "" {
		return image, nil
	}
	req.Image.Image = id
	return n.images.ImageStatus(ctx, req)
}

// Some older imports have a live tag but never wrote a managed config record.
// Match the CRI result to the content it claims, then recheck the live tag.
func (n node) legacyDockerTagDigestStatus(ctx context.Context, tag *images.Image, raw string, verbose bool) (*cri.ImageStatusResponse, error) {
	missing := &cri.ImageStatusResponse{}
	target := tag.GetTarget()
	if target.GetSize() <= 0 || (target.GetMediaType() != ocispec.MediaTypeImageManifest &&
		target.GetMediaType() != "application/vnd.docker.distribution.manifest.v2+json") {
		return missing, nil
	}
	storeCtx := imageMetadataContext(ctx)
	id, err := n.manifestConfigID(storeCtx, target)
	if err != nil {
		return nil, err
	}
	result, err := n.images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: raw}, Verbose: verbose})
	if err != nil {
		return nil, err
	}
	if result.GetImage().GetId() != id {
		return missing, nil
	}
	current, err := n.imageStore.Get(storeCtx, &images.GetImageRequest{Name: tag.GetName()})
	if status.Code(err) == codes.NotFound {
		return missing, nil
	}
	if err != nil {
		return nil, fmt.Errorf("recheck legacy image tag: %w", err)
	}
	desc := current.GetImage().GetTarget()
	if current.GetImage().GetName() != tag.GetName() || desc.GetDigest() != target.GetDigest() ||
		desc.GetMediaType() != target.GetMediaType() || desc.GetSize() != target.GetSize() {
		return missing, nil
	}
	return result, nil
}

func dockerTagReference(raw string) reference.NamedTagged {
	if fullDockerImageID(raw) {
		return nil
	}
	name, err := reference.ParseNormalizedNamed(raw)
	tag, tagged := name.(reference.NamedTagged)
	if _, digested := name.(reference.Digested); err != nil || !tagged || digested {
		return nil
	}
	return tag
}

func appendDockerTagDigest(digests []string, tag reference.NamedTagged, digest string) []string {
	if tag != nil && fullDockerImageID(digest) {
		qualified := tag.Name() + "@" + digest
		if !slices.Contains(digests, qualified) {
			digests = append(digests, qualified)
		}
	}
	return digests
}

func (n node) inspectDockerRepoDigests(ctx context.Context, image *cri.Image) ([]string, error) {
	digests := image.GetRepoDigests()
	tags := make(map[string]reference.NamedTagged)
	for _, raw := range image.GetRepoTags() {
		if tag := dockerTagReference(raw); tag != nil {
			tags[tag.String()] = tag
		}
	}
	if len(tags) == 0 || !fullDockerImageID(image.GetId()) {
		return digests, nil
	}
	storeCtx := imageMetadataContext(ctx)
	config, err := n.findDockerImageID(storeCtx, image.GetId())
	if err != nil || config == nil {
		return digests, err
	}
	target := config.GetTarget()
	if config.GetLabels()[criManagedImage] != "managed" || !fullDockerImageID(target.GetDigest()) ||
		target.GetMediaType() == "" || target.GetSize() <= 0 {
		return digests, nil
	}
	for raw, tag := range tags {
		if slices.Contains(digests, tag.Name()+"@"+target.GetDigest()) {
			delete(tags, raw)
		}
	}
	if len(tags) == 0 {
		return digests, nil
	}
	rows, err := n.imageIDTargetRecords(storeCtx, target.GetDigest())
	if err != nil {
		return nil, err
	}
	var named []string
	var foundConfig bool
	for _, row := range rows {
		ref, desc := dockerTagReference(row.GetName()), row.GetTarget()
		if desc.GetDigest() != target.GetDigest() || desc.GetSize() != target.GetSize() || desc.GetMediaType() != target.GetMediaType() {
			continue
		}
		if fullDockerImageID(row.GetName()) && row.GetLabels()[criManagedImage] == "managed" {
			if row.GetName() != image.GetId() {
				return digests, nil
			}
			foundConfig = true
		}
		if ref != nil && tags[ref.String()] != nil {
			named = appendDockerTagDigest(named, ref, desc.GetDigest())
		}
	}
	if !foundConfig {
		return digests, nil
	}
	slices.Sort(named)
	return append(slices.Clone(digests), named...), nil
}
