package main

import (
	"context"
	"fmt"
	"log"
	"maps"
	"net/http"
	"time"

	contentapi "github.com/containerd/containerd/api/services/content/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	leases "github.com/containerd/containerd/api/services/leases/v1"
	"github.com/containerd/containerd/content"
	"github.com/containerd/containerd/content/proxy"
	containerdimages "github.com/containerd/containerd/images"
	"github.com/containerd/containerd/images/archive"
	"github.com/containerd/platforms"
	"github.com/distribution/reference"
	"github.com/opencontainers/go-digest"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// This mirrors Moby's orphan lease expiry. The save follows the HTTP
// request lifetime without imposing a maximum transfer duration.
const dockerImageExportLeaseLifetime = 8 * time.Hour

func (s *dockerEngine) exportDigestImages(w http.ResponseWriter, r *http.Request, refs []string) error {
	if s.node.content == nil || s.node.leases == nil {
		return fail(http.StatusServiceUnavailable, "containerd image export is unavailable")
	}
	ctx := r.Context()
	storeCtx := imageMetadataContext(ctx)
	leaseID := "mp-image-export-" + engineID()
	leaseCtx, stop := context.WithTimeout(storeCtx, 5*time.Second)
	_, err := s.node.leases.Create(leaseCtx, &leases.CreateRequest{ID: leaseID, Labels: map[string]string{
		"containerd.io/gc.expire": time.Now().UTC().Add(dockerImageExportLeaseLifetime).Format(time.RFC3339),
	}})
	stop()
	if err != nil {
		return fmt.Errorf("create image export lease: %w", err)
	}
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(storeCtx), 5*time.Second)
		defer cancel()
		if _, err := s.node.leases.Delete(cleanupCtx, &leases.DeleteRequest{ID: leaseID}); err != nil && status.Code(err) != codes.NotFound {
			log.Printf("containerd image export lease cleanup failed (%s)", status.Code(err))
		}
	}()

	options, err := s.imageExportOptions(ctx, refs, leaseID)
	if err != nil {
		return err
	}
	response := &dockerImageExportWriter{ResponseWriter: w}
	options = append(options, archive.WithPlatform(platforms.Ordered(ocispec.Platform{OS: "linux", Architecture: "arm64"})),
		archive.WithSkipNonDistributableBlobs())
	// The archive library skips roots on Info errors when copying source
	// labels. Pass only the read interface so missing content fails the save.
	store := struct{ content.Provider }{proxy.NewContentStore(s.node.content)}
	if err := archive.Export(storeCtx, store, response, options...); err != nil {
		if response.started {
			panic(http.ErrAbortHandler)
		}
		return fmt.Errorf("export Docker image archive: %w", err)
	}
	return nil
}

// Select and lease immutable roots before this engine can move or remove
// their names. Containerd tracks the child blobs from each leased root.
func (s *dockerEngine) imageExportOptions(ctx context.Context, refs []string, leaseID string) ([]archive.ExportOpt, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	storeCtx := imageMetadataContext(ctx)
	s.imageMu.RLock()
	defer s.imageMu.RUnlock()

	options := make([]archive.ExportOpt, 0, len(refs))
	leased := make(map[string]bool)
	for _, raw := range refs {
		record, exportName, err := s.node.imageExportRecord(ctx, raw)
		if err != nil {
			return nil, err
		}
		target := record.GetTarget()
		desc := ocispec.Descriptor{
			Digest: digest.Digest(target.GetDigest()), Size: target.GetSize(), MediaType: target.GetMediaType(),
			Annotations: maps.Clone(target.GetAnnotations()),
		}
		if desc.Digest.Validate() != nil || desc.Size <= 0 ||
			(!containerdimages.IsManifestType(desc.MediaType) && !containerdimages.IsIndexType(desc.MediaType)) {
			return nil, fail(http.StatusConflict, "image export target is not a valid manifest or index")
		}
		if !leased[desc.Digest.String()] {
			info, err := s.node.content.Info(storeCtx, &contentapi.InfoRequest{Digest: desc.Digest.String()})
			if err != nil {
				return nil, fmt.Errorf("read image export target: %w", err)
			}
			if info.GetInfo().GetDigest() != desc.Digest.String() || info.GetInfo().GetSize() != desc.Size {
				return nil, fail(http.StatusConflict, "image export content does not match its descriptor")
			}
			_, err = s.node.leases.AddResource(storeCtx, &leases.AddResourceRequest{ID: leaseID, Resource: &leases.Resource{
				Type: "content", ID: desc.Digest.String(),
			}})
			if err != nil {
				return nil, fmt.Errorf("lease image export target: %w", err)
			}
			leased[desc.Digest.String()] = true
		}
		if exportName == "" {
			// An explicit digest exports the image bytes without assigning a tag.
			delete(desc.Annotations, containerdimages.AnnotationImageName)
			delete(desc.Annotations, ocispec.AnnotationRefName)
			options = append(options, archive.WithManifest(desc))
		} else {
			options = append(options, archive.WithManifest(desc, exportName))
		}
	}
	return options, nil
}

func (n node) imageExportRecord(ctx context.Context, raw string) (*images.Image, string, error) {
	ref, err := reference.ParseNormalizedNamed(raw)
	if err == nil {
		if canonical, ok := ref.(reference.Canonical); ok {
			record, err := n.dockerDigestTarget(ctx, canonical)
			if err == nil && record == nil {
				err = fail(http.StatusNotFound, "No such image: "+reference.FamiliarString(ref))
			}
			return record, "", err
		}
	}
	name, err := imageName(raw)
	if err != nil {
		return nil, "", fail(http.StatusBadRequest, err.Error())
	}
	result, err := n.imageStore.Get(imageMetadataContext(ctx), &images.GetImageRequest{Name: name})
	if status.Code(err) == codes.NotFound {
		return nil, "", fail(http.StatusNotFound, "No such image: "+raw)
	}
	if err != nil {
		return nil, "", fmt.Errorf("read local image for export: %w", err)
	}
	if result.GetImage().GetName() != name {
		return nil, "", fail(http.StatusConflict, "image export reference changed")
	}
	return result.GetImage(), name, nil
}

type dockerImageExportWriter struct {
	http.ResponseWriter
	started bool
}

func (w *dockerImageExportWriter) Write(p []byte) (int, error) {
	if !w.started {
		w.Header().Set("Content-Type", "application/x-tar")
		w.started = true
	}
	return w.ResponseWriter.Write(p)
}
