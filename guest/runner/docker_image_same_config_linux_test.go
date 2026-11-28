package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"slices"
	"testing"
	"time"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	attestation "github.com/moby/buildkit/util/attestation"
	digest "github.com/opencontainers/go-digest"
	"github.com/opencontainers/image-spec/specs-go"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// sameConfigBuilds is what two `docker build`s of one final stage publish
// when an earlier stage (an ARG only it uses) makes their provenance differ:
// one config and one runnable manifest, and two indexes that differ only in
// their attestation manifest. CRI's one config-ID record for that config
// targets the index it indexed last (b).
type sameConfigBuilds struct {
	store    *buildxDeleteContent
	id       string
	a, b     ocispec.Descriptor
	tagA     string
	tagB     string
	criImage *cri.Image
}

func sameConfigBuildsFixture(t *testing.T) sameConfigBuilds {
	t.Helper()
	store := &buildxDeleteContent{blobs: make(map[string][]byte)}
	config := store.json(t, ocispec.MediaTypeImageConfig, ocispec.Image{
		Platform: ocispec.Platform{OS: "linux", Architecture: "arm64"},
		RootFS:   ocispec.RootFS{Type: "layers", DiffIDs: []digest.Digest{digest.FromString("final stage")}},
	})
	native := store.json(t, ocispec.MediaTypeImageManifest, ocispec.Manifest{
		Versioned: specs.Versioned{SchemaVersion: 2}, MediaType: ocispec.MediaTypeImageManifest, Config: config,
		Layers: []ocispec.Descriptor{{MediaType: ocispec.MediaTypeImageLayerGzip, Size: 10, Digest: digest.FromString("layer")}},
	})
	native.Platform = &ocispec.Platform{OS: "linux", Architecture: "arm64"}
	index := func(salt string) ocispec.Descriptor {
		provenance := store.json(t, inTotoLayerMediaType, map[string]any{"predicate": map[string]any{"salt": salt}})
		att := store.json(t, ocispec.MediaTypeImageManifest, ocispec.Manifest{
			Versioned: specs.Versioned{SchemaVersion: 2}, MediaType: ocispec.MediaTypeImageManifest,
			Config: ocispec.Descriptor{MediaType: ocispec.MediaTypeEmptyJSON, Size: 2, Digest: digest.FromString("{}")},
			Layers: []ocispec.Descriptor{provenance},
		})
		att.Platform = &ocispec.Platform{OS: "unknown", Architecture: "unknown"}
		att.Annotations = map[string]string{
			attestation.DockerAnnotationReferenceType:   attestation.DockerAnnotationReferenceTypeDefault,
			attestation.DockerAnnotationReferenceDigest: native.Digest.String(),
		}
		return store.json(t, ocispec.MediaTypeImageIndex, ocispec.Index{
			Versioned: specs.Versioned{SchemaVersion: 2}, MediaType: ocispec.MediaTypeImageIndex,
			Manifests: []ocispec.Descriptor{native, att},
		})
	}
	f := sameConfigBuilds{store: store, id: config.Digest.String(), a: index("1"), b: index("2"),
		tagA: "docker.io/library/same-1:1", tagB: "docker.io/library/same-2:1"}
	if f.a.Digest == f.b.Digest {
		t.Fatal("fixture indexes must differ")
	}
	f.criImage = &cri.Image{Id: f.id, RepoTags: []string{f.tagA, f.tagB}, Size: 10}
	return f
}

func descriptorOf(d ocispec.Descriptor) *types.Descriptor {
	return &types.Descriptor{MediaType: d.MediaType, Digest: d.Digest.String(), Size: d.Size}
}

// sameConfigCRI answers as CRI does once it has indexed both tags: one image,
// by config ID, with both tags.
type sameConfigCRI struct {
	cri.ImageServiceClient
	image *cri.Image
}

func (s sameConfigCRI) ImageStatus(_ context.Context, req *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	ref := req.GetImage().GetImage()
	if ref == s.image.GetId() || slices.Contains(s.image.GetRepoTags(), ref) {
		return &cri.ImageStatusResponse{Image: s.image}, nil
	}
	return &cri.ImageStatusResponse{}, nil
}

func TestDockerBuildOfAnotherIndexOfTheSameConfigIsVisibleAtOnce(t *testing.T) {
	f := sameConfigBuildsFixture(t)
	store := &fakeImageMetadata{t: t, refs: map[string]*images.Image{
		f.id:   {Name: f.id, Target: descriptorOf(f.b), Labels: map[string]string{criManagedImage: "managed"}},
		f.tagA: {Name: f.tagA, Target: descriptorOf(f.a)},
		f.tagB: {Name: f.tagB, Target: descriptorOf(f.b)},
	}}
	solver := dockerBuildSolver{node: node{content: f.store, imageStore: store, images: sameConfigCRI{image: f.criImage}}}
	for _, build := range []struct {
		tag   string
		index ocispec.Descriptor
	}{{f.tagA, f.a}, {f.tagB, f.b}} {
		raw, err := json.Marshal(build.index)
		if err != nil {
			t.Fatal(err)
		}
		response := map[string]string{
			"containerimage.digest": build.index.Digest.String(), "containerimage.descriptor": base64.StdEncoding.EncodeToString(raw),
		}
		begun := time.Now()
		if err := solver.finishLocalLoad(context.Background(), []string{build.tag}, response); err != nil {
			t.Fatalf("%s: %v", build.tag, err)
		}
		// The config-ID record targets index b: a wait for a record that
		// targets index a would last its whole 5 s bound and then fail.
		if response["containerimage.config.digest"] != f.id || time.Since(begun) > 2*time.Second {
			t.Fatalf("%s: config %q after %v", build.tag, response["containerimage.config.digest"], time.Since(begun))
		}
	}
}

func TestDockerImageListShowsEveryTagOfOneConfigAcrossIndexes(t *testing.T) {
	f := sameConfigBuildsFixture(t)
	catalog := &imageListTestCatalog{t: t, rows: map[string]*images.Image{
		f.id:   {Name: f.id, Target: descriptorOf(f.b), Labels: map[string]string{criManagedImage: "managed"}},
		f.tagA: {Name: f.tagA, Target: descriptorOf(f.a)},
		f.tagB: {Name: f.tagB, Target: descriptorOf(f.b)},
	}}
	n := node{content: f.store, imageStore: catalog}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	rows, err := n.visibleDockerImageRows(ctx, []*cri.Image{f.criImage})
	if err != nil || len(rows) != 1 {
		t.Fatalf("rows = %v, %v", rows, err)
	}
	if got := rows[0].GetRepoTags(); !slices.Equal(got, []string{f.tagA, f.tagB}) {
		t.Fatalf("tags of the one config = %q, want both", got)
	}

	// A tag moved to an index that runs no config here (only another
	// platform's manifest) stays off this ID's row.
	amd64 := f.store.json(t, ocispec.MediaTypeImageManifest, ocispec.Manifest{Versioned: specs.Versioned{SchemaVersion: 2},
		MediaType: ocispec.MediaTypeImageManifest, Config: ocispec.Descriptor{MediaType: ocispec.MediaTypeImageConfig, Size: 1, Digest: digest.FromString("x")}})
	amd64.Platform = &ocispec.Platform{OS: "linux", Architecture: "amd64"}
	moved := f.store.json(t, ocispec.MediaTypeImageIndex, ocispec.Index{Versioned: specs.Versioned{SchemaVersion: 2},
		MediaType: ocispec.MediaTypeImageIndex, Manifests: []ocispec.Descriptor{amd64}})
	catalog.rows[f.tagA] = &images.Image{Name: f.tagA, Target: descriptorOf(moved)}
	rows, err = n.visibleDockerImageRows(ctx, []*cri.Image{f.criImage})
	if err != nil || len(rows) != 1 || !slices.Equal(rows[0].GetRepoTags(), []string{f.tagB}) {
		t.Fatalf("a tag whose index runs no config here stayed visible: %v, %v", rows, err)
	}
}
