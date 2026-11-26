package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/distribution/reference"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type imageMetadataClient interface {
	Create(context.Context, *images.CreateImageRequest, ...grpc.CallOption) (*images.CreateImageResponse, error)
	Update(context.Context, *images.UpdateImageRequest, ...grpc.CallOption) (*images.UpdateImageResponse, error)
	Get(context.Context, *images.GetImageRequest, ...grpc.CallOption) (*images.GetImageResponse, error)
	List(context.Context, *images.ListImagesRequest, ...grpc.CallOption) (*images.ListImagesResponse, error)
	Delete(context.Context, *images.DeleteImageRequest, ...grpc.CallOption) (*emptypb.Empty, error)
}

var possibleImageID = regexp.MustCompile(`^(sha256:)?[0-9a-f]{1,64}$`)

func namedImageTag(raw string) (reference.Named, error) {
	if strings.Contains(raw, "@") || possibleImageID.MatchString(raw) {
		return nil, fail(501, "image removal requires a repository tag")
	}
	name, err := reference.ParseNormalizedNamed(raw)
	if err != nil {
		return nil, fail(400, "invalid image name")
	}
	return reference.TagNameOnly(name), nil
}

func bareHexImageTag(raw string) reference.Named {
	if len(raw) >= 64 || strings.HasPrefix(raw, "sha256:") || !possibleImageID.MatchString(raw) {
		return nil
	}
	tag, _ := namedImageTag(raw + ":latest")
	return tag
}

func imageMetadataContext(ctx context.Context) context.Context {
	return metadata.AppendToOutgoingContext(ctx, "containerd-namespace", dockerRuntimeNamespace)
}

func (n node) dockerImageStatus(ctx context.Context, ref string, verbose bool) (*cri.ImageStatusResponse, error) {
	if tag := bareHexImageTag(ref); tag != nil {
		return n.dockerBareHexImageStatus(ctx, ref, tag.String(), verbose)
	}
	if possibleImageID.MatchString(ref) {
		return n.dockerImageIDStatus(ctx, ref, verbose)
	}
	if strings.Contains(ref, "@") {
		if name, err := reference.ParseNormalizedNamed(ref); err == nil {
			if digested, ok := name.(reference.Canonical); ok {
				return n.dockerDigestImageStatus(ctx, ref, digested, verbose)
			}
		}
	}
	img, err := n.images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: ref}, Verbose: verbose})
	if err != nil || img.GetImage() == nil {
		return img, err
	}
	if tag, err := namedImageTag(ref); err == nil {
		// CRI indexes image changes from asynchronous containerd events.
		// Confirm a cached tag still exists before reporting it or recording a container.
		_, err := n.imageStore.Get(imageMetadataContext(ctx), &images.GetImageRequest{Name: tag.String()})
		if status.Code(err) == codes.NotFound {
			return &cri.ImageStatusResponse{}, nil
		}
		if err != nil {
			return nil, fmt.Errorf("verify image tag: %w", err)
		}
	}
	return img, nil
}

func (n node) dockerBareHexImageStatus(ctx context.Context, raw, tag string, verbose bool) (*cri.ImageStatusResponse, error) {
	req := &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: tag}, Verbose: verbose}
	_, err := n.imageStore.Get(imageMetadataContext(ctx), &images.GetImageRequest{Name: tag})
	if err == nil {
		return n.images.ImageStatus(ctx, req)
	}
	if status.Code(err) != codes.NotFound {
		return nil, fmt.Errorf("verify image tag: %w", err)
	}

	// Resolve the ID against authoritative metadata before asking for cached
	// details. CRI can still remember a removed hex tag or config-ID record.
	img, err := n.dockerImageIDStatus(ctx, raw, verbose)
	if err == nil && img.GetImage() != nil {
		img.Image.RepoTags = slices.DeleteFunc(img.Image.RepoTags, func(name string) bool { return name == tag })
	}
	return img, err
}

func (s *dockerEngine) deleteImage(w http.ResponseWriter, r *http.Request, name string) error {
	q := r.URL.Query()
	if q.Has("platform") || q.Has("platforms") {
		return fail(501, "platform-specific image deletion is unavailable")
	}
	force := false
	if raw := q.Get("force"); raw != "" {
		var err error
		force, err = strconv.ParseBool(raw)
		if err != nil {
			return fail(400, "invalid image force flag")
		}
	}
	s.imageMu.Lock()
	defer s.imageMu.Unlock()
	if ref, err := reference.ParseNormalizedNamed(name); err == nil {
		if canonical, ok := ref.(reference.Canonical); ok {
			removed, err := s.removeImageDigest(r.Context(), canonical, force)
			if err != nil {
				return err
			}
			writeJSON(w, http.StatusOK, removed)
			return nil
		}
	}
	untagged, err := s.removeImageTag(r.Context(), name, force)
	var problem apiError
	if possibleImageID.MatchString(name) && errors.As(err, &problem) && problem.code == http.StatusNotImplemented {
		removed, err := s.removeUnusedImageID(r.Context(), name, force)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, removed)
		return nil
	}
	if err != nil {
		return err
	}
	writeJSON(w, 200, []map[string]string{{"Untagged": untagged}})
	return nil
}

// The caller holds imageMu while selecting between a named tag and an ID.
func (s *dockerEngine) removeImageTag(ctx context.Context, raw string, force bool) (string, error) {
	tag := bareHexImageTag(raw)
	bareHex := tag != nil
	if !bareHex {
		var err error
		tag, err = namedImageTag(raw)
		if err != nil {
			return "", err
		}
	}
	name := tag.String()
	storeCtx := imageMetadataContext(ctx)
	res, err := s.node.imageStore.Get(storeCtx, &images.GetImageRequest{Name: name})
	if status.Code(err) == codes.NotFound {
		if bareHex {
			return "", fail(http.StatusNotImplemented, "image removal requires a repository tag")
		}
		return "", fail(404, "No such image: "+reference.FamiliarString(tag))
	}
	if err != nil {
		return "", fmt.Errorf("read image tag: %w", err)
	}
	img := res.GetImage()
	target := img.GetTarget()
	if target.GetDigest() == "" {
		return "", fmt.Errorf("missing target for image %q", name)
	}
	if img.GetLabels()["io.cri-containerd.pinned"] == "pinned" {
		return "", fail(409, "image is pinned by the worker")
	}
	if err := s.checkImageTagRemoval(ctx, name, target.GetDigest(), force); err != nil {
		return "", err
	}
	// Delete only this name. Other image records and content leases are left to containerd.
	_, err = s.node.imageStore.Delete(storeCtx, &images.DeleteImageRequest{Name: name, Target: target})
	if status.Code(err) == codes.NotFound {
		return "", fail(409, "image tag changed or disappeared during removal")
	}
	if err != nil {
		return "", fmt.Errorf("remove image tag: %w", err)
	}
	return reference.FamiliarString(tag), nil
}

func (s *dockerEngine) checkImageTagRemoval(ctx context.Context, name, digest string, force bool) error {
	s.mu.Lock()
	retained := make(map[string]string, len(s.containers))
	for _, c := range s.containers {
		retained[c.ImageID] = c.ID
	}
	s.mu.Unlock()
	if len(retained) == 0 {
		return nil
	}

	res, err := s.node.imageStore.List(imageMetadataContext(ctx), &images.ListImagesRequest{
		Filters: []string{"target.digest==" + strconv.Quote(digest)},
	})
	if err != nil {
		return fmt.Errorf("list image references: %w", err)
	}
	refs := make(map[string]bool, len(res.GetImages()))
	for _, img := range res.GetImages() {
		if img.GetTarget().GetDigest() != digest || img.GetName() == name {
			continue
		}
		if tag, err := namedImageTag(img.GetName()); err == nil && tag.String() == img.GetName() {
			return nil // A different repository tag will keep this image available.
		}
		refs[img.GetName()] = true
	}
	resolved, err := s.node.images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: name}})
	if err != nil {
		return fmt.Errorf("resolve image identity: %w", err)
	}
	id := resolved.GetImage().GetId()
	// The CRI config-ID reference must point to this target before trusting its
	// cached result. Forced untagging of a retained image leaves that record intact.
	if id == "" || !refs[id] {
		return fail(409, "cannot verify this image's identity and retention while the worker holds containers")
	}
	if c, ok := retained[id]; ok && !force {
		return fail(409, "image is used by retained container "+c+" (use --force to remove only its tag)")
	}
	return nil
}
