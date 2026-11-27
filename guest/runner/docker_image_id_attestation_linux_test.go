package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"testing"

	content "github.com/containerd/containerd/api/services/content/v1"
	"github.com/containerd/containerd/api/types"
	attestation "github.com/moby/buildkit/util/attestation"
	digest "github.com/opencontainers/go-digest"
	"github.com/opencontainers/image-spec/specs-go"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type buildxDeleteContent struct {
	content.ContentClient
	blobs map[string][]byte
	reads []string
}

func (s *buildxDeleteContent) Read(_ context.Context, request *content.ReadContentRequest, _ ...grpc.CallOption) (content.Content_ReadClient, error) {
	key := request.GetDigest()
	s.reads = append(s.reads, key)
	data, ok := s.blobs[key]
	if !ok {
		return nil, status.Error(codes.NotFound, "fixture blob missing")
	}
	return &deleteImageIDManifestStream{data: data}, nil
}

func (s *buildxDeleteContent) json(t *testing.T, mediaType string, value any) ocispec.Descriptor {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	desc := ocispec.Descriptor{MediaType: mediaType, Digest: digest.FromBytes(data), Size: int64(len(data))}
	s.blobs[desc.Digest.String()] = data
	return desc
}

type buildxDeleteFixture struct {
	store       *buildxDeleteContent
	native      ocispec.Descriptor
	attestation ocispec.Manifest
	id          string
}

func buildxIndexDeletionFixture(t *testing.T, legacy bool) buildxDeleteFixture {
	t.Helper()
	store := &buildxDeleteContent{blobs: make(map[string][]byte)}
	nativeConfig := store.json(t, ocispec.MediaTypeImageConfig, ocispec.Image{
		Platform: ocispec.Platform{OS: "linux", Architecture: "arm64"},
		RootFS:   ocispec.RootFS{Type: "layers", DiffIDs: []digest.Digest{digest.FromString("uncompressed layer")}},
	})
	native := store.json(t, ocispec.MediaTypeImageManifest, ocispec.Manifest{
		Versioned: specs.Versioned{SchemaVersion: 2},
		MediaType: ocispec.MediaTypeImageManifest,
		Config:    nativeConfig,
		Layers: []ocispec.Descriptor{{
			MediaType: ocispec.MediaTypeImageLayerGzip, Size: 100, Digest: digest.FromString("compressed layer"),
		}},
	})
	native.Platform = &ocispec.Platform{OS: "linux", Architecture: "arm64"}
	statement := store.json(t, inTotoLayerMediaType, map[string]any{
		"_type":         "https://in-toto.io/Statement/v1",
		"predicateType": "https://slsa.dev/provenance/v1",
		"predicate":     map[string]any{},
		"subject": []any{map[string]any{
			"name": "image", "digest": map[string]string{"sha256": native.Digest.Encoded()},
		}},
	})
	statement.Annotations = map[string]string{"in-toto.io/predicate-type": "https://slsa.dev/provenance/v1"}
	provenance := ocispec.Manifest{
		Versioned: specs.Versioned{SchemaVersion: 2},
		MediaType: ocispec.MediaTypeImageManifest,
		Layers:    []ocispec.Descriptor{statement},
	}
	if legacy {
		provenance.Config = store.json(t, ocispec.MediaTypeImageConfig, ocispec.Image{
			Platform: ocispec.Platform{OS: "unknown", Architecture: "unknown"},
			RootFS:   ocispec.RootFS{Type: "layers", DiffIDs: []digest.Digest{statement.Digest}},
		})
	} else {
		subject := native
		subject.Platform = nil
		empty := ocispec.DescriptorEmptyJSON
		store.blobs[empty.Digest.String()] = empty.Data
		provenance.ArtifactType, provenance.Subject, provenance.Config = buildxAttestationType, &subject, empty
	}
	return buildxDeleteFixture{store, native, provenance, nativeConfig.Digest.String()}
}

func (f buildxDeleteFixture) index(t *testing.T) ocispec.Index {
	t.Helper()
	provenance := f.store.json(t, ocispec.MediaTypeImageManifest, f.attestation)
	provenance.Platform = &ocispec.Platform{OS: "unknown", Architecture: "unknown"}
	provenance.Annotations = map[string]string{
		attestation.DockerAnnotationReferenceType:   attestation.DockerAnnotationReferenceTypeDefault,
		attestation.DockerAnnotationReferenceDigest: f.native.Digest.String(),
	}
	return ocispec.Index{
		Versioned: specs.Versioned{SchemaVersion: 2},
		MediaType: ocispec.MediaTypeImageIndex,
		Manifests: []ocispec.Descriptor{f.native, provenance},
	}
}

func (f buildxDeleteFixture) target(t *testing.T, index ocispec.Index) *types.Descriptor {
	t.Helper()
	return imageBlobDescriptor(f.store.json(t, ocispec.MediaTypeImageIndex, index))
}

func TestVerifiedBuildxAttestationIndex(t *testing.T) {
	for _, tt := range []struct {
		name   string
		legacy bool
	}{{"artifact", false}, {"legacy", true}} {
		t.Run(tt.name, func(t *testing.T) {
			fixture := buildxIndexDeletionFixture(t, tt.legacy)
			index := fixture.index(t)
			n := node{content: fixture.store}
			native, err := n.verifyImageIDAttestationIndex(t.Context(), fixture.id, fixture.target(t, index))
			if err != nil || native != fixture.native.Digest.String() {
				t.Fatalf("verify valid Buildx index: native %q, error %v", native, err)
			}
			if len(fixture.store.reads) != 3 {
				t.Fatalf("read %d graph metadata blobs, want 3", len(fixture.store.reads))
			}
		})
	}
}

func TestRejectUnverifiedBuildxAttestationIndex(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*buildxDeleteFixture, *ocispec.Index)
	}{
		{"runnable other architecture", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			i.Manifests[0].Platform = &ocispec.Platform{OS: "linux", Architecture: "amd64"}
		}},
		{"another runnable manifest", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			second := i.Manifests[0]
			second.Digest = digest.FromString("another platform image")
			i.Manifests = append(i.Manifests, second)
		}},
		{"no attestations", func(_ *buildxDeleteFixture, i *ocispec.Index) { i.Manifests = i.Manifests[:1] }},
		{"repeated attestation manifest", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			i.Manifests = append(i.Manifests, i.Manifests[1])
		}},
		{"over manifest count limit", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			i.Manifests = make([]ocispec.Descriptor, buildxIndexMaxManifests+1)
		}},
		{"over aggregate manifest byte limit", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			i.Manifests[1].Size = verifiedImageBlobLimit
		}},
		{"foreign reference", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			i.Manifests[1].Annotations[attestation.DockerAnnotationReferenceDigest] = digest.FromString("wrong target").String()
		}},
		{"invalid reference digest", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			i.Manifests[1].Annotations[attestation.DockerAnnotationReferenceDigest] = "sha256:bad"
		}},
		{"attestation marker absent", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			delete(i.Manifests[1].Annotations, attestation.DockerAnnotationReferenceType)
		}},
		{"invalid attestation digest", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			i.Manifests[1].Digest = "sha256:bad"
		}},
		{"incompatible attestation media", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			i.Manifests[1].MediaType = ocispec.MediaTypeImageIndex
		}},
		{"wrong config ID", func(f *buildxDeleteFixture, _ *ocispec.Index) { f.id = digest.FromString("different config").String() }},
		{"missing attestation content", func(f *buildxDeleteFixture, i *ocispec.Index) {
			delete(f.store.blobs, i.Manifests[1].Digest.String())
		}},
		{"tampered attestation manifest", func(f *buildxDeleteFixture, i *ocispec.Index) {
			corrupt := f.store.blobs[i.Manifests[1].Digest.String()]
			corrupt[0] ^= 1
		}},
		{"wrong artifact subject", func(f *buildxDeleteFixture, i *ocispec.Index) {
			f.attestation.Subject.Digest = digest.FromString("another native manifest")
			*i = f.index(t)
		}},
		{"executable layer in attestation", func(f *buildxDeleteFixture, i *ocispec.Index) {
			f.attestation.Layers[0].MediaType = ocispec.MediaTypeImageLayerGzip
			*i = f.index(t)
		}},
		{"incompatible index content", func(_ *buildxDeleteFixture, i *ocispec.Index) {
			i.MediaType = ocispec.MediaTypeImageManifest
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fixture := buildxIndexDeletionFixture(t, false)
			index := fixture.index(t)
			tt.mutate(&fixture, &index)
			n := node{content: fixture.store}
			_, err := n.verifyImageIDAttestationIndex(t.Context(), fixture.id, fixture.target(t, index))
			var conflict apiError
			if !errors.As(err, &conflict) || conflict.code != http.StatusConflict {
				t.Fatalf("verify malformed index = %v, want conflict", err)
			}
		})
	}
}

func TestDockerBuildxImageIDRemovalPreservesReferences(t *testing.T) {
	for _, tc := range []struct {
		name, refPrefix string
		named, running  bool
		raceAfterAlias  bool
	}{
		{name: "unused index"},
		{name: "named tag", named: true},
		{name: "runtime child digest", running: true},
		{name: "runtime named child digest", refPrefix: "registry.test/build@", running: true},
		{name: "child in use after alias delete", raceAfterAlias: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			graph := buildxIndexDeletionFixture(t, false)
			f := imageIDDeletionFixture(t)
			delete(f.store.refs, f.id)
			f.id, f.cri.image.Id = graph.id, graph.id
			f.manifest.target = graph.target(t, graph.index(t))
			f.node.content = graph.store
			f.addRef(f.id)
			other := f.addRef("registry.test/other:latest")
			other.Target = imageBlobDescriptor(graph.native)
			if tc.named {
				f.addRef("registry.test/build:latest")
			}
			child := &cri.Container{ImageRef: tc.refPrefix + graph.native.Digest.String()}
			if tc.running {
				f.cri.containers = []*cri.Container{child}
			}
			alias := "registry.test/build@" + f.manifest.target.GetDigest()
			if tc.raceAfterAlias {
				f.addRef(alias)
				f.store.onDelete = func(name string) {
					if name != alias {
						t.Fatalf("unexpected deletion of %q", name)
					}
					f.cri.containers = []*cri.Container{child}
				}
			}
			_, err := f.remove(f.id, "force=true")
			if f.store.refs[other.Name] != other {
				t.Fatal("deletion changed an unrelated reference to the runnable manifest")
			}
			if tc.named || tc.running || tc.raceAfterAlias {
				var conflict apiError
				deletions := 0
				if tc.raceAfterAlias {
					deletions = 1
				}
				if !errors.As(err, &conflict) || conflict.code != http.StatusConflict ||
					f.store.refs[f.id] == nil || len(f.store.deleted) != deletions {
					t.Fatalf("guarded removal = %v, remaining index = %v, deleted = %v", err, f.store.refs[f.id], f.store.deleted)
				}
				return
			}
			if err != nil || f.store.refs[f.id] != nil || len(f.store.deleted) != 1 || f.store.deleted[0] != f.id {
				t.Fatalf("unused index removal = %v, remaining index = %v, deleted = %v", err, f.store.refs[f.id], f.store.deleted)
			}
		})
	}
}

// registryIndex is a registry's multi-platform index as a pull stores it:
// only the linux/arm64 manifest (and its config) is in the store; the other
// platforms' manifests and the attestations were never fetched.
func registryIndex(t *testing.T, store *buildxDeleteContent, mediaType, manifestType string) (ocispec.Index, ocispec.Descriptor, string) {
	t.Helper()
	config := store.json(t, ocispec.MediaTypeImageConfig, ocispec.Image{
		Platform: ocispec.Platform{OS: "linux", Architecture: "arm64"},
		RootFS:   ocispec.RootFS{Type: "layers", DiffIDs: []digest.Digest{digest.FromString("registry layer")}},
	})
	native := store.json(t, manifestType, ocispec.Manifest{
		Versioned: specs.Versioned{SchemaVersion: 2}, MediaType: manifestType, Config: config,
		Layers: []ocispec.Descriptor{{MediaType: ocispec.MediaTypeImageLayerGzip, Size: 100, Digest: digest.FromString("registry blob")}},
	})
	native.Platform = &ocispec.Platform{OS: "linux", Architecture: "arm64", Variant: "v8"}
	entry := func(name string, platform ocispec.Platform) ocispec.Descriptor {
		return ocispec.Descriptor{MediaType: manifestType, Digest: digest.FromString(name), Size: 500, Platform: &platform}
	}
	amd64 := entry("amd64 manifest", ocispec.Platform{OS: "linux", Architecture: "amd64"})
	armv7 := entry("arm v7 manifest", ocispec.Platform{OS: "linux", Architecture: "arm", Variant: "v7"})
	attest := func(name string, of ocispec.Descriptor) ocispec.Descriptor {
		d := entry(name, ocispec.Platform{OS: "unknown", Architecture: "unknown"})
		d.Annotations = map[string]string{
			attestation.DockerAnnotationReferenceType:   attestation.DockerAnnotationReferenceTypeDefault,
			attestation.DockerAnnotationReferenceDigest: of.Digest.String(),
		}
		return d
	}
	return ocispec.Index{
		Versioned: specs.Versioned{SchemaVersion: 2}, MediaType: mediaType,
		Manifests: []ocispec.Descriptor{amd64, attest("amd64 attestation", amd64), armv7, native, attest("arm64 attestation", native)},
	}, native, config.Digest.String()
}

// A multi-platform image pulled from a registry (an OCI index or a Docker
// manifest list) can be removed by its ID: the arm64 manifest is verified
// against the ID, and the entries for other platforms are never read.
func TestVerifiedRegistryPlatformIndex(t *testing.T) {
	for _, tc := range []struct{ name, index, manifest string }{
		{"oci index", ocispec.MediaTypeImageIndex, ocispec.MediaTypeImageManifest},
		{"docker manifest list", "application/vnd.docker.distribution.manifest.list.v2+json", "application/vnd.docker.distribution.manifest.v2+json"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &buildxDeleteContent{blobs: make(map[string][]byte)}
			index, native, id := registryIndex(t, store, tc.index, tc.manifest)
			target := imageBlobDescriptor(store.json(t, tc.index, index))
			store.reads = nil
			got, err := node{content: store}.verifyImageIDManifest(t.Context(), id, target)
			if err != nil || got != native.Digest.String() {
				t.Fatalf("verify registry index: native %q, error %v", got, err)
			}
			if !slices.Equal(store.reads, []string{target.GetDigest(), native.Digest.String()}) {
				t.Fatalf("read %v, want only the index and its arm64 manifest", store.reads)
			}
		})
	}
}

func TestRejectUnverifiedRegistryPlatformIndex(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(index *ocispec.Index, id *string)
	}{
		{"no arm64 manifest", func(i *ocispec.Index, _ *string) { i.Manifests = slices.Delete(i.Manifests, 3, 4) }},
		{"two arm64 manifests", func(i *ocispec.Index, _ *string) {
			second := i.Manifests[3]
			second.Digest = digest.FromString("second arm64")
			i.Manifests = append(i.Manifests, second)
		}},
		{"wrong config ID", func(_ *ocispec.Index, id *string) { *id = digest.FromString("other config").String() }},
		{"nested index", func(i *ocispec.Index, _ *string) { i.Manifests[0].MediaType = ocispec.MediaTypeImageIndex }},
		{"repeated entry", func(i *ocispec.Index, _ *string) { i.Manifests = append(i.Manifests, i.Manifests[0]) }},
		{"remote entry", func(i *ocispec.Index, _ *string) { i.Manifests[0].URLs = []string{"https://example.test/blob"} }},
		{"subject", func(i *ocispec.Index, _ *string) { i.Subject = &i.Manifests[0] }},
		{"over the entry limit", func(i *ocispec.Index, _ *string) {
			for n := range platformIndexMaxManifests {
				extra := i.Manifests[0]
				extra.Digest = digest.FromString(fmt.Sprint("extra ", n))
				i.Manifests = append(i.Manifests, extra)
			}
		}},
		{"arm64 manifest missing", func(i *ocispec.Index, _ *string) { i.Manifests[3].Digest = digest.FromString("absent arm64") }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &buildxDeleteContent{blobs: make(map[string][]byte)}
			index, _, id := registryIndex(t, store, ocispec.MediaTypeImageIndex, ocispec.MediaTypeImageManifest)
			tc.mutate(&index, &id)
			target := imageBlobDescriptor(store.json(t, ocispec.MediaTypeImageIndex, index))
			_, err := node{content: store}.verifyImageIDManifest(t.Context(), id, target)
			var conflict apiError
			if !errors.As(err, &conflict) || conflict.code != http.StatusConflict {
				t.Fatalf("verify %s = %v, want conflict", tc.name, err)
			}
		})
	}
}
