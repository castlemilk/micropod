package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/distribution/reference"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/fieldmaskpb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const criManagedImage = "io.cri-containerd.image"

func destinationImageTag(repo, tag string) (reference.NamedTagged, error) {
	name, err := reference.ParseNormalizedNamed(repo)
	if err != nil || reference.FamiliarName(name) == "sha256" {
		return nil, fail(400, "invalid destination image repository")
	}
	if _, digested := name.(reference.Digested); digested {
		return nil, fail(400, "cannot tag a digest as the destination")
	}
	if tag != "" {
		tagged, err := reference.WithTag(name, tag)
		if err != nil {
			return nil, fail(400, "invalid destination image tag")
		}
		return tagged, nil
	}
	return reference.TagNameOnly(name).(reference.NamedTagged), nil
}

func (s *dockerEngine) tagImage(w http.ResponseWriter, r *http.Request, source string) error {
	if err := r.ParseForm(); err != nil {
		return fail(400, "invalid tag parameters")
	}
	dest, err := destinationImageTag(r.Form.Get("repo"), r.Form.Get("tag"))
	if err != nil {
		return err
	}
	s.imageMu.Lock()
	defer s.imageMu.Unlock()

	ctx := r.Context()
	sourceStatus, err := s.node.dockerImageStatus(ctx, source, true)
	if err != nil {
		return err
	}
	id := sourceStatus.GetImage().GetId()
	if id == "" {
		return fail(404, "No such image: "+source)
	}

	record, err := s.node.tagSourceRecord(ctx, source, sourceStatus.GetImage())
	if err != nil {
		return err
	}
	if record == nil {
		return fail(404, "No such image: "+source)
	}
	target := record.GetTarget()
	if target.GetDigest() == "" {
		return fmt.Errorf("source image %q has no target", source)
	}
	store := s.node.imageStore
	storeCtx := imageMetadataContext(ctx)
	newImage := &images.Image{Name: dest.String(), Target: target, Labels: map[string]string{criManagedImage: "managed"}}
	_, err = store.Create(storeCtx, &images.CreateImageRequest{Image: newImage})
	if status.Code(err) == codes.AlreadyExists {
		existing, err := store.Get(storeCtx, &images.GetImageRequest{Name: dest.String()})
		if err != nil {
			return fmt.Errorf("read existing image tag: %w", err)
		}
		old := existing.GetImage()
		if old.GetTarget().GetDigest() != target.GetDigest() || old.GetLabels()[criManagedImage] != "managed" {
			if old.GetLabels()["io.cri-containerd.pinned"] == "pinned" {
				return fail(409, "destination image is pinned by the worker")
			}
			// Updating the descriptor in place preserves the old image's other
			// records, running containers and unrelated destination labels.
			_, err = store.Update(storeCtx, &images.UpdateImageRequest{
				Image: newImage, UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"target", "labels." + criManagedImage}},
			})
			if err != nil {
				return fmt.Errorf("replace image tag: %w", err)
			}
		}
	} else if err != nil {
		return fmt.Errorf("create image tag: %w", err)
	}

	if err := s.node.waitForDockerImageTag(ctx, dest.String(), id); err != nil {
		return err
	}
	name := reference.FamiliarString(dest)
	var details struct {
		ImageSpec struct {
			Config struct{ Labels map[string]string }
		}
	}
	_ = json.Unmarshal([]byte(sourceStatus.GetInfo()["info"]), &details)
	attrs := details.ImageSpec.Config.Labels
	if attrs == nil {
		attrs = make(map[string]string)
	}
	attrs["name"] = name
	s.events.publish(dockerEvent{
		Type: "image", Action: "tag", Scope: "local", Actor: dockerEventActor{ID: id, Attributes: attrs},
		Status: "tag", ID: id,
	})
	w.WriteHeader(http.StatusCreated)
	return nil
}

func (n node) waitForDockerImageTag(ctx context.Context, tag, id string) error {
	ref := tag
	if ref == "" {
		ref = id
	}
	return waitForDockerImageIndex(ctx, func(visible context.Context) (bool, error) {
		lookup, err := n.images.ImageStatus(visible, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: ref}})
		img := lookup.GetImage()
		return img.GetId() == id && (tag == "" || slices.Contains(img.GetRepoTags(), tag)), err
	})
}

// CRI indexes containerd image events asynchronously. Bound the wait for
// authoritative visibility so the next stock client can use the published ID.
func waitForDockerImageIndex(ctx context.Context, lookup func(context.Context) (bool, error)) error {
	visible, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	delay := 5 * time.Millisecond
	for {
		found, err := lookup(visible)
		if err == nil && found {
			return nil
		}
		if err != nil && visible.Err() == nil && status.Code(err) != codes.Unavailable && status.Code(err) != codes.DeadlineExceeded {
			return fail(503, "published image visibility could not be verified: "+err.Error())
		}
		select {
		case <-visible.Done():
			return fail(503, "published image is not yet visible in the runtime image index")
		case <-time.After(delay):
		}
		delay = min(2*delay, 100*time.Millisecond)
	}
}

// Preserve the descriptor addressed by the source name, including a multi-platform index.
// For a short ID, CRI supplies its full config ID, also a containerd image record.
func (n node) tagSourceRecord(ctx context.Context, source string, image *cri.Image) (*images.Image, error) {
	storeCtx := imageMetadataContext(ctx)
	get := func(key string) (*images.Image, error) {
		result, err := n.imageStore.Get(storeCtx, &images.GetImageRequest{Name: key})
		if status.Code(err) == codes.NotFound {
			return nil, nil
		}
		if err != nil {
			return nil, fmt.Errorf("resolve source image record: %w", err)
		}
		return result.GetImage(), nil
	}
	id := image.GetId()
	if source == id || source == strings.TrimPrefix(id, "sha256:") {
		return get(id)
	}
	targetID := "sha256:" + strings.TrimPrefix(source, "sha256:")
	if fullDockerImageID(targetID) {
		// A full target digest has already resolved through ImageStatus.
		// Confirm the config record still points to that exact target before
		// using it. A bare short hex name continues through named lookup.
		byID, err := get(id)
		if err != nil || byID == nil {
			return byID, err
		}
		if !fullDockerImageID(id) || byID.GetName() != id || byID.GetLabels()[criManagedImage] != "managed" ||
			byID.GetTarget().GetDigest() != targetID || byID.GetTarget().GetSize() <= 0 {
			return nil, fail(409, "source image identity could not be confirmed before tagging")
		}
		return byID, nil
	}
	name, err := reference.ParseNormalizedNamed(source)
	if err != nil {
		return nil, fail(400, "invalid source image reference")
	}
	// CRI tries a normalized repository name before a bare ID prefix. In
	// particular, a repository such as "face" can address an OCI index whose
	// native config-ID record points to a different manifest.
	var named *images.Image
	if ref, ok := name.(reference.Canonical); ok {
		named, err = n.dockerDigestTarget(ctx, ref)
	} else if !strings.HasPrefix(source, "sha256:") {
		named, err = get(reference.TagNameOnly(name).String())
	}
	if err != nil {
		return nil, err
	}
	if named == nil {
		if possibleImageID.MatchString(source) && strings.HasPrefix(strings.TrimPrefix(id, "sha256:"), strings.TrimPrefix(source, "sha256:")) {
			return get(id)
		}
		return nil, nil
	}
	// A pull or import can move the source between the CRI lookup and the
	// metadata read. Establish their association before writing any tag.
	target := named.GetTarget().GetDigest()
	if target != "" && slices.Contains(image.GetRepoDigests(), name.Name()+"@"+target) {
		return named, nil
	}
	byID, err := get(id)
	if err != nil {
		return nil, err
	}
	if target == "" || byID.GetTarget().GetDigest() != target {
		return nil, fail(409, "source image identity could not be confirmed before tagging")
	}
	return named, nil
}
