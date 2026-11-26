package main

import (
	"cmp"
	"context"
	"net/http"
	"slices"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	"github.com/distribution/reference"
)

// The caller holds imageMu. Independent containerd writers are guarded by
// each target-specific delete, while the config record stays until the end.
func (s *dockerEngine) removeImageDigest(ctx context.Context, ref reference.Canonical, force bool) ([]map[string]string, error) {
	storeCtx := imageMetadataContext(ctx)
	digest := ref.Digest().String()
	records, err := s.node.imageIDTargetRecords(storeCtx, digest)
	if err != nil {
		return nil, err
	}
	var selected []*images.Image
	var config *images.Image
	otherReference := false
	selectedNames := make(map[string]bool)
	for _, row := range records {
		if row.GetTarget().GetDigest() != digest {
			return nil, fail(http.StatusConflict, "image digest references changed during removal")
		}
		name := row.GetName()
		if fullDockerImageID(name) {
			if config != nil {
				return nil, fail(http.StatusConflict, "image target has multiple local config IDs")
			}
			config = row
			continue
		}
		parsed, err := reference.ParseNormalizedNamed(name)
		if err != nil || !sameImageDigestRemovalReference(ref, parsed) {
			otherReference = true
			continue
		}
		selected = append(selected, row)
		selectedNames[reference.TagNameOnly(parsed).String()] = true
	}
	if len(selected) == 0 {
		return nil, fail(http.StatusNotFound, "No such image: "+reference.FamiliarString(ref))
	}
	target := selected[0].GetTarget()
	if target.GetSize() <= 0 || target.GetMediaType() == "" {
		return nil, fail(http.StatusConflict, "image digest has an incomplete local descriptor")
	}
	for _, row := range selected {
		if err := checkImageIDRemovalRecord(row, target); err != nil {
			return nil, err
		}
	}

	var runnable string
	if !otherReference {
		runnable, err = s.preflightLastDigestRemoval(ctx, storeCtx, config, target, selectedNames, force)
		if err != nil {
			return nil, err
		}
	}

	slices.SortFunc(selected, func(a, b *images.Image) int { return cmp.Compare(a.GetName(), b.GetName()) })
	removed := make([]map[string]string, 0, len(selected)+1)
	reported := make(map[string]bool, len(selected))
	for _, row := range selected {
		if err := s.node.deleteImageIDRecord(storeCtx, row.GetName(), target); err != nil {
			return nil, err
		}
		name, _ := reference.ParseNormalizedNamed(row.GetName())
		familiar := reference.FamiliarString(reference.TagNameOnly(name))
		if !reported[familiar] {
			removed = append(removed, map[string]string{"Untagged": familiar})
			reported[familiar] = true
		}
	}
	if runnable == "" {
		return removed, nil
	}

	id := config.GetName()
	remaining, err := s.node.imageIDTargetRecords(storeCtx, digest)
	if err != nil {
		return nil, err
	}
	if len(remaining) != 1 || remaining[0].GetName() != id {
		return nil, fail(http.StatusConflict, "image references changed during removal; retry by ID")
	}
	if err := s.checkImageIDUsage(ctx, id, digest, runnable); err != nil {
		return nil, err
	}
	if err := s.node.deleteImageIDRecord(storeCtx, id, target); err != nil {
		return nil, err
	}
	return append(removed, map[string]string{"Deleted": id}), nil
}

func sameImageDigestRemovalReference(request reference.Canonical, stored reference.Named) bool {
	if stored.Name() != request.Name() {
		return false
	}
	if digested, ok := stored.(reference.Digested); ok && digested.Digest() != request.Digest() {
		return false
	}
	if tag, ok := request.(reference.Tagged); ok {
		current, tagged := reference.TagNameOnly(stored).(reference.Tagged)
		return tagged && current.Tag() == tag.Tag()
	}
	return true
}

func (s *dockerEngine) preflightLastDigestRemoval(ctx, storeCtx context.Context, config *images.Image, target *types.Descriptor, selected map[string]bool, force bool) (string, error) {
	if config == nil {
		return "", fail(http.StatusConflict, "image config could not be verified before removing its last repository reference")
	}
	if err := checkImageIDRemovalRecord(config, target); err != nil {
		return "", err
	}
	id := config.GetName()
	runnable, err := s.node.verifyImageIDManifest(storeCtx, id, target)
	if err != nil {
		return "", err
	}
	res, err := s.node.dockerConfigImageStatus(ctx, id, false)
	if err != nil {
		return "", err
	}
	image := res.GetImage()
	if image == nil || image.GetPinned() {
		return "", fail(http.StatusConflict, "runtime image is pinned or could not be verified")
	}
	for _, raw := range slices.Concat(image.GetRepoTags(), image.GetRepoDigests()) {
		// The same config may be shared by manifests with distinct content
		// descriptors. Keep the ID if another such reference still uses it.
		ref, err := reference.ParseNormalizedNamed(raw)
		if err != nil || !selected[reference.TagNameOnly(ref).String()] {
			return "", nil
		}
	}
	retained, err := s.imageIDRemovalUsage(ctx, id, force, target.GetDigest(), runnable)
	if err != nil || retained {
		return "", err
	}
	return runnable, nil
}
