package main

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/distribution/reference"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// containerd 2.4 resolves its first cached reference before creating any
// container. An old ctr import can leave only the unnormalized spelling in
// metadata after the last tag moves. Every healthy start takes one CRI call.
func (n node) createImageContainer(ctx context.Context, req *cri.CreateContainerRequest) (*cri.CreateContainerResponse, error) {
	made, err := n.runtime.CreateContainer(ctx, req)
	if status.Code(err) != codes.NotFound {
		return made, err
	}
	id := req.GetConfig().GetImage().GetImage()
	prefix := fmt.Sprintf("failed to get image from containerd %q: image ", id)
	quoted, ok := strings.CutPrefix(status.Convert(err).Message(), prefix)
	if !ok {
		return made, err
	}
	quoted, ok = strings.CutSuffix(quoted, ": not found")
	raw, decodeErr := strconv.Unquote(quoted)
	if !ok || decodeErr != nil {
		return made, err
	}
	name, parseErr := reference.ParseNormalizedNamed(raw)
	ref, canonical := name.(reference.Canonical)
	if parseErr != nil || !canonical || ref.String() != raw {
		return made, err
	}
	repaired, repairErr := n.repairImportedDigest(ctx, id, ref)
	if repairErr != nil {
		return nil, repairErr
	}
	if !repaired {
		return made, err
	}
	return n.runtime.CreateContainer(ctx, req)
}

func (n node) repairImportedDigest(ctx context.Context, id string, ref reference.Canonical) (bool, error) {
	cached, err := n.images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: id}})
	if err != nil {
		return false, err
	}
	image := cached.GetImage()
	if image.GetId() != id || !slices.Contains(image.GetRepoDigests(), ref.String()) {
		return false, nil
	}
	storeCtx := imageMetadataContext(ctx)
	byID, err := n.imageStore.Get(storeCtx, &images.GetImageRequest{Name: id})
	if status.Code(err) == codes.NotFound {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	digest := ref.Digest().String()
	if byID.GetImage().GetTarget().GetDigest() != digest {
		return false, nil
	}
	records, err := n.imageStore.List(storeCtx, &images.ListImagesRequest{Filters: []string{"target.digest==" + strconv.Quote(digest)}})
	if err != nil {
		return false, err
	}
	for _, record := range records.GetImages() {
		if record.GetTarget().GetDigest() != digest {
			continue
		}
		if record.Name == ref.String() {
			return true, nil // A concurrent start already repaired this name.
		}
		raw, err := reference.ParseNormalizedNamed(record.Name)
		if err != nil || raw.String() != ref.String() {
			continue
		}
		// Materialize the immutable name that CRI already advertised. The raw
		// alias and every other reference keep their own names and labels.
		alias := &images.Image{Name: ref.String(), Target: record.Target,
			Labels: map[string]string{criManagedImage: "managed"}}
		_, err = n.imageStore.Create(storeCtx, &images.CreateImageRequest{Image: alias})
		if status.Code(err) == codes.AlreadyExists {
			present, checkErr := n.imageStore.Get(storeCtx, &images.GetImageRequest{Name: alias.Name})
			if checkErr != nil {
				return false, checkErr
			}
			return present.GetImage().GetTarget().GetDigest() == digest, nil
		}
		if err != nil {
			return false, fmt.Errorf("restore imported image digest record: %w", err)
		}
		return true, nil
	}
	return false, nil
}
