package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strconv"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/distribution/reference"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const dockerImageParentLabel = "org.mobyproject.image.parent"

func (s *dockerEngine) matchContainerAncestorImages(ctx context.Context, refs []string, ids map[string]bool) (map[string]bool, error) {
	matching := make(map[string]bool)
	if len(refs) == 0 || len(ids) == 0 {
		return matching, nil
	}
	// Tag replacement waits for the CRI index while holding the write lock.
	// Keep image lookup out of the container catalog lock.
	s.imageMu.RLock()
	defer s.imageMu.RUnlock()
	storeCtx := imageMetadataContext(ctx)
	roots := make(map[string]bool)
	slices.Sort(refs)
	for _, ref := range slices.Compact(refs) {
		if _, err := reference.ParseAnyReference(ref); err != nil && !possibleImageID.MatchString(ref) {
			continue
		}
		resolved, err := s.node.dockerImageStatus(ctx, ref, false)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if err != nil {
			if unresolvedAncestorImage(err) {
				continue
			}
			return nil, fmt.Errorf("resolve container ancestor: %w", err)
		}
		image := resolved.GetImage()
		if !fullDockerImageID(image.GetId()) {
			continue
		}
		record, err := s.node.tagSourceRecord(ctx, ref, image)
		if err != nil {
			if unresolvedAncestorImage(err) {
				continue
			}
			return nil, err
		}
		if target := record.GetTarget().GetDigest(); fullDockerImageID(target) {
			roots[target] = true
			if ids[image.GetId()] {
				matching[image.GetId()] = true
			}
		}
	}
	if len(roots) == 0 || len(matching) == len(ids) {
		return matching, nil
	}

	descendants, err := s.node.dockerImageDescendants(storeCtx, roots)
	if err != nil || len(descendants) == 0 {
		return matching, err
	}
	for id := range ids {
		if matching[id] || !fullDockerImageID(id) {
			continue
		}
		record, err := s.node.findDockerImageID(storeCtx, id)
		if err != nil {
			return nil, err
		}
		if descendants[record.GetTarget().GetDigest()] {
			matching[id] = true
		}
	}
	return matching, nil
}

func unresolvedAncestorImage(err error) bool {
	switch status.Code(err) {
	case codes.InvalidArgument, codes.NotFound:
		return true
	}
	var problem apiError
	if errors.As(err, &problem) {
		return problem.code == http.StatusBadRequest || problem.code == http.StatusNotFound || problem.code == http.StatusConflict
	}
	return false
}

func (n node) dockerImageDescendants(ctx context.Context, roots map[string]bool) (map[string]bool, error) {
	// Containerd parent labels address image target digests. An immutable
	// record keeps the edge attached to that image across tag replacement.
	result, err := n.imageStore.List(ctx, &images.ListImagesRequest{Filters: []string{"labels." + strconv.Quote(dockerImageParentLabel)}})
	if err != nil {
		return nil, fmt.Errorf("read image parent records: %w", err)
	}
	children := make(map[string][]string)
	for _, image := range result.GetImages() {
		child, parent := image.GetTarget().GetDigest(), image.GetLabels()[dockerImageParentLabel]
		if !fullDockerImageID(parent) || !fullDockerImageID(child) {
			continue
		}
		if _, alias := immutableImageIDAlias(image.GetName(), child); fullDockerImageID(image.GetName()) || alias {
			children[parent] = append(children[parent], child)
		}
	}
	// The visited set also bounds a cycle in legacy or externally written
	// metadata. Shared filesystem layers alone carry no parent record.
	pending := make([]string, 0, len(roots))
	for root := range roots {
		pending = append(pending, root)
	}
	descendants := make(map[string]bool)
	for len(pending) != 0 {
		parent := pending[0]
		pending = pending[1:]
		for _, child := range children[parent] {
			if !roots[child] && !descendants[child] {
				descendants[child] = true
				pending = append(pending, child)
			}
		}
	}
	return descendants, nil
}
