package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"

	content "github.com/containerd/containerd/api/services/content/v1"
	"github.com/containerd/containerd/api/types"
	attestation "github.com/moby/buildkit/util/attestation"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	verifiedImageBlobLimit  = 4 << 20
	buildxIndexMaxManifests = 32
	inTotoLayerMediaType    = "application/vnd.in-toto+json"
	buildxAttestationType   = "application/vnd.docker.attestation.manifest.v1+json"
)

func (n node) readVerifiedImageBlob(ctx context.Context, target *types.Descriptor, kind string) ([]byte, error) {
	size := target.GetSize()
	if size <= 0 || size > verifiedImageBlobLimit {
		return nil, fail(http.StatusConflict, kind+" size could not be verified")
	}
	if !fullDockerImageID(target.GetDigest()) {
		return nil, fail(http.StatusConflict, kind+" digest could not be verified")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stream, err := n.content.Read(ctx, &content.ReadContentRequest{Digest: target.GetDigest(), Size: size})
	if err != nil {
		return nil, imageBlobReadError(kind, err)
	}
	data := make([]byte, 0, int(size))
	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, imageBlobReadError(kind, err)
		}
		offset := int64(len(data))
		if chunk.GetOffset() != offset || len(chunk.GetData()) == 0 || int64(len(chunk.GetData())) > size-offset {
			return nil, fail(http.StatusConflict, kind+" content could not be verified")
		}
		data = append(data, chunk.GetData()...)
	}
	if int64(len(data)) != size || fmt.Sprintf("sha256:%x", sha256.Sum256(data)) != target.GetDigest() {
		return nil, fail(http.StatusConflict, kind+" content could not be verified")
	}
	return data, nil
}

func imageBlobReadError(kind string, err error) error {
	if status.Code(err) == codes.NotFound {
		return fail(http.StatusConflict, kind+" is unavailable")
	}
	return fmt.Errorf("read %s: %w", kind, err)
}

// verifyImageIDAttestationIndex admits the stock Buildx shape of one runnable
// Linux ARM64 image and its provenance manifests. The existing deletion path
// still removes references to the original index descriptor.
func (n node) verifyImageIDAttestationIndex(ctx context.Context, id string, target *types.Descriptor) (string, error) {
	if target.GetMediaType() != ocispec.MediaTypeImageIndex {
		return "", fail(http.StatusConflict, "image ID removal requires an OCI image index")
	}
	data, err := n.readVerifiedImageBlob(ctx, target, "image index")
	if err != nil {
		return "", err
	}
	var index ocispec.Index
	if json.Unmarshal(data, &index) != nil || index.SchemaVersion != 2 ||
		index.MediaType != ocispec.MediaTypeImageIndex || index.ArtifactType != "" || index.Subject != nil ||
		len(index.Manifests) < 2 || len(index.Manifests) > buildxIndexMaxManifests {
		return "", fail(http.StatusConflict, "image ID removal requires a single-platform Buildx attestation index")
	}

	var native *ocispec.Descriptor
	attestations := make([]ocispec.Descriptor, 0, len(index.Manifests)-1)
	seen := make(map[string]struct{}, len(index.Manifests))
	remaining := int64(verifiedImageBlobLimit) - target.GetSize()
	for i := range index.Manifests {
		descriptor := &index.Manifests[i]
		if !localImageDescriptor(*descriptor) || descriptor.MediaType != ocispec.MediaTypeImageManifest {
			return "", fail(http.StatusConflict, "image index has an incompatible manifest descriptor")
		}
		if descriptor.Size > remaining {
			return "", fail(http.StatusConflict, "image index manifest bytes exceed the verification limit")
		}
		remaining -= descriptor.Size
		digest := descriptor.Digest.String()
		if _, ok := seen[digest]; ok {
			return "", fail(http.StatusConflict, "image index repeats a manifest descriptor")
		}
		seen[digest] = struct{}{}
		switch {
		case buildxIndexPlatform(descriptor.Platform, "linux", "arm64") &&
			descriptor.Annotations[attestation.DockerAnnotationReferenceType] == "" &&
			descriptor.Annotations[attestation.DockerAnnotationReferenceDigest] == "":
			if native != nil {
				return "", fail(http.StatusConflict, "image index contains multiple runnable manifests")
			}
			native = descriptor
		case buildxIndexPlatform(descriptor.Platform, "unknown", "unknown") &&
			descriptor.Annotations[attestation.DockerAnnotationReferenceType] == attestation.DockerAnnotationReferenceTypeDefault:
			attestations = append(attestations, *descriptor)
		default:
			return "", fail(http.StatusConflict, "image index contains an unsupported platform or attestation")
		}
	}
	if native == nil || len(attestations) == 0 {
		return "", fail(http.StatusConflict, "image index lacks its runnable ARM64 manifest or attestations")
	}
	for _, descriptor := range attestations {
		if descriptor.Annotations[attestation.DockerAnnotationReferenceDigest] != native.Digest.String() {
			return "", fail(http.StatusConflict, "image attestation does not reference the runnable manifest")
		}
	}
	configID, err := n.manifestConfigID(ctx, imageBlobDescriptor(*native))
	if err != nil {
		return "", err
	}
	if configID != id {
		return "", fail(http.StatusConflict, "image manifest does not match the requested config ID")
	}
	for _, descriptor := range attestations {
		if err := n.verifyBuildxAttestationManifest(ctx, descriptor, *native); err != nil {
			return "", err
		}
	}
	return native.Digest.String(), nil
}

func localImageDescriptor(descriptor ocispec.Descriptor) bool {
	return fullDockerImageID(descriptor.Digest.String()) && descriptor.Size > 0 &&
		len(descriptor.URLs) == 0 && len(descriptor.Data) == 0 && descriptor.ArtifactType == ""
}

func buildxIndexPlatform(platform *ocispec.Platform, os, arch string) bool {
	return platform != nil && platform.OS == os && platform.Architecture == arch &&
		platform.OSVersion == "" && len(platform.OSFeatures) == 0 &&
		(platform.Variant == "" || arch == "arm64" && platform.Variant == "v8")
}

func imageBlobDescriptor(descriptor ocispec.Descriptor) *types.Descriptor {
	return &types.Descriptor{MediaType: descriptor.MediaType, Digest: descriptor.Digest.String(), Size: descriptor.Size}
}

func (n node) verifyBuildxAttestationManifest(ctx context.Context, descriptor, native ocispec.Descriptor) error {
	data, err := n.readVerifiedImageBlob(ctx, imageBlobDescriptor(descriptor), "image attestation manifest")
	if err != nil {
		return err
	}
	var manifest ocispec.Manifest
	if json.Unmarshal(data, &manifest) != nil || manifest.SchemaVersion != 2 ||
		manifest.MediaType != ocispec.MediaTypeImageManifest || len(manifest.Layers) == 0 {
		return fail(http.StatusConflict, "image attestation manifest is incompatible")
	}
	config := manifest.Config
	switch manifest.ArtifactType {
	case "":
		if manifest.Subject != nil || !localImageDescriptor(config) ||
			config.MediaType != ocispec.MediaTypeImageConfig || config.Platform != nil {
			return fail(http.StatusConflict, "legacy image attestation manifest is incompatible")
		}
	case buildxAttestationType:
		subject, empty := manifest.Subject, ocispec.DescriptorEmptyJSON
		if subject == nil || !localImageDescriptor(*subject) || subject.Platform != nil ||
			subject.Digest != native.Digest || subject.Size != native.Size || subject.MediaType != native.MediaType ||
			config.MediaType != empty.MediaType || config.Digest != empty.Digest || config.Size != empty.Size ||
			config.ArtifactType != "" || config.Platform != nil || len(config.URLs) != 0 ||
			len(config.Data) != 0 && !bytes.Equal(config.Data, empty.Data) {
			return fail(http.StatusConflict, "OCI image attestation does not describe the runnable manifest")
		}
	default:
		return fail(http.StatusConflict, "image attestation has an unsupported artifact type")
	}
	for _, layer := range manifest.Layers {
		if !localImageDescriptor(layer) || layer.Platform != nil || layer.MediaType != inTotoLayerMediaType {
			return fail(http.StatusConflict, "image attestation contains an incompatible layer descriptor")
		}
	}
	return nil
}
