package main

import (
	"archive/tar"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"

	content "github.com/containerd/containerd/api/services/content/v1"
	leases "github.com/containerd/containerd/api/services/leases/v1"
	"github.com/containerd/containerd/api/types"
	containerdimages "github.com/containerd/containerd/images"
	"github.com/opencontainers/go-digest"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

type imageExportFixtureContent struct {
	content.ContentClient
	metadata *fakeImageMetadata
	blobs    map[string][]byte
	onRead   func()
}

func (s *imageExportFixtureContent) add(mediaType string, data []byte) ocispec.Descriptor {
	id := digest.FromBytes(data)
	s.blobs[id.String()] = data
	return ocispec.Descriptor{Digest: id, MediaType: mediaType, Size: int64(len(data))}
}

func (s *imageExportFixtureContent) Info(ctx context.Context, req *content.InfoRequest, _ ...grpc.CallOption) (*content.InfoResponse, error) {
	s.metadata.assertNamespace(ctx)
	data, ok := s.blobs[req.GetDigest()]
	if !ok {
		return nil, status.Error(codes.NotFound, "blob not found")
	}
	return &content.InfoResponse{Info: &content.Info{Digest: req.GetDigest(), Size: int64(len(data))}}, nil
}

func (s *imageExportFixtureContent) Read(ctx context.Context, req *content.ReadContentRequest, _ ...grpc.CallOption) (content.Content_ReadClient, error) {
	s.metadata.assertNamespace(ctx)
	if s.onRead != nil {
		s.onRead()
		s.onRead = nil
	}
	data, ok := s.blobs[req.GetDigest()]
	if !ok {
		return nil, status.Error(codes.NotFound, "blob not found")
	}
	start := req.GetOffset()
	end := min(int64(len(data)), start+req.GetSize())
	return &deleteImageIDManifestStream{data: data[start:end]}, nil
}

type imageExportFixtureLease struct {
	archiveLeaseClient
	metadata *fakeImageMetadata
	id       string
	roots    []string
	deleted  bool
}

func (f *imageExportFixtureLease) Create(ctx context.Context, req *leases.CreateRequest, _ ...grpc.CallOption) (*leases.CreateResponse, error) {
	f.metadata.assertNamespace(ctx)
	if !strings.HasPrefix(req.GetID(), "mp-image-export-") || req.GetLabels()["containerd.io/gc.expire"] == "" {
		f.metadata.t.Fatalf("image export lease needs its own expiring ID: %v", req)
	}
	f.id = req.GetID()
	return &leases.CreateResponse{}, nil
}

func (f *imageExportFixtureLease) AddResource(ctx context.Context, req *leases.AddResourceRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	f.metadata.assertNamespace(ctx)
	if req.GetID() != f.id || req.GetResource().GetType() != "content" {
		f.metadata.t.Fatalf("unexpected image export lease resource: %v", req)
	}
	f.roots = append(f.roots, req.GetResource().GetID())
	return &emptypb.Empty{}, nil
}

func (f *imageExportFixtureLease) Delete(ctx context.Context, req *leases.DeleteRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	f.metadata.assertNamespace(ctx)
	if req.GetID() != f.id {
		f.metadata.t.Fatalf("unexpected image export lease cleanup: %v", req)
	}
	f.deleted = true
	return &emptypb.Empty{}, nil
}

func TestDockerImageDigestSaveLeasesExactContentAndStripsNamedAnnotations(t *testing.T) {
	f := imageIDDeletionFixture(t)
	content := &imageExportFixtureContent{metadata: &f.store.fakeImageMetadata, blobs: make(map[string][]byte)}
	leases := &imageExportFixtureLease{metadata: &f.store.fakeImageMetadata}
	f.node.content = content
	f.node.leases = leases
	config := content.add(ocispec.MediaTypeImageConfig, []byte(`{"architecture":"arm64","os":"linux"}`))
	layer := content.add(ocispec.MediaTypeImageLayer, make([]byte, 1024))
	manifestData, err := json.Marshal(map[string]any{"schemaVersion": 2, "config": config, "layers": []ocispec.Descriptor{layer}})
	if err != nil {
		t.Fatal(err)
	}
	manifest := content.add(ocispec.MediaTypeImageManifest, manifestData)
	target := imageBlobDescriptor(manifest)
	target.Annotations = map[string]string{containerdimages.AnnotationImageName: "borrowed:latest", ocispec.AnnotationRefName: "latest"}
	const tag = "docker.io/team/archive:latest"
	f.addRef(tag).Target = target
	wrong := httptest.NewRecorder()
	f.ServeHTTP(wrong, httptest.NewRequest(http.MethodGet, "/v1.47/images/team/wrong@"+manifest.Digest.String()+"/get", nil))
	if wrong.Code != http.StatusNotFound || len(leases.roots) != 0 || !leases.deleted {
		t.Fatalf("wrong repository export = %d %s, roots %v, cleanup %v", wrong.Code, wrong.Body, leases.roots, leases.deleted)
	}
	leases.deleted = false
	content.onRead = func() {
		if !slices.Equal(leases.roots, []string{manifest.Digest.String()}) || leases.deleted {
			t.Fatalf("archive read started without the exact live content lease: %v", leases.roots)
		}
		if !f.imageMu.TryLock() {
			t.Fatal("streaming image data still holds the image mutation lock")
		}
		f.store.refs[tag].Target = &types.Descriptor{Digest: "sha256:" + strings.Repeat("d", 64)}
		f.imageMu.Unlock()
	}
	w := httptest.NewRecorder()
	args := url.Values{"names": {"team/archive@" + manifest.Digest.String()}}
	f.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/images/get?"+args.Encode(), nil))
	if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "application/x-tar" || !leases.deleted {
		t.Fatalf("archive export = %d, type %q, lease cleanup %v", w.Code, w.Header().Get("Content-Type"), leases.deleted)
	}

	entries := make(map[string][]byte)
	reader := tar.NewReader(w.Body)
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if header.Typeflag != tar.TypeReg {
			continue
		}
		data, err := io.ReadAll(reader)
		if err != nil {
			t.Fatal(err)
		}
		entries[header.Name] = data
	}
	var index ocispec.Index
	var compatibility []struct{ RepoTags []string }
	if json.Unmarshal(entries["index.json"], &index) != nil || len(index.Manifests) != 1 ||
		index.Manifests[0].Digest != manifest.Digest || len(index.Manifests[0].Annotations) != 0 ||
		json.Unmarshal(entries["manifest.json"], &compatibility) != nil || len(compatibility) != 1 || len(compatibility[0].RepoTags) != 0 {
		t.Fatalf("unexpected archive indexes: %s %s", entries["index.json"], entries["manifest.json"])
	}
	for _, expected := range []ocispec.Descriptor{manifest, config, layer} {
		actual := entries["blobs/sha256/"+expected.Digest.Encoded()]
		if int64(len(actual)) != expected.Size || digest.FromBytes(actual) != expected.Digest {
			t.Fatalf("archive changed content for %s", expected.Digest)
		}
	}
}
