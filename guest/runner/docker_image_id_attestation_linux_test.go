package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
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
