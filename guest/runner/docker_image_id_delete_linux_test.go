package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	content "github.com/containerd/containerd/api/services/content/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type deleteImageIDStore struct {
	fakeImageMetadata
	deleted  []string
	onDelete func(string)
}

func (s *deleteImageIDStore) Delete(ctx context.Context, r *images.DeleteImageRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	s.assertNamespace(ctx)
	if r.GetSync() || r.GetTarget().GetDigest() == "" {
		s.t.Fatal("image deletion needs a target guard and asynchronous GC")
	}
	if s.onDelete != nil {
		s.onDelete(r.GetName())
	}
	if s.refs[r.GetName()].GetTarget().GetDigest() != r.GetTarget().GetDigest() {
		return nil, status.Error(codes.NotFound, "target changed")
	}
	s.deleted = append(s.deleted, r.GetName())
	delete(s.refs, r.GetName())
	return &emptypb.Empty{}, nil
}

type deleteImageIDManifest struct {
	content.ContentClient
	t      *testing.T
	target *types.Descriptor
	data   []byte
}

func (s *deleteImageIDManifest) Read(_ context.Context, r *content.ReadContentRequest, _ ...grpc.CallOption) (content.Content_ReadClient, error) {
	s.t.Helper()
	if r.GetDigest() != s.target.GetDigest() || r.GetSize() != s.target.GetSize() {
		s.t.Fatal("read did not address the exact target manifest")
	}
	return &deleteImageIDManifestStream{data: s.data}, nil
}

type deleteImageIDManifestStream struct {
	content.Content_ReadClient
	data []byte
}

func (s *deleteImageIDManifestStream) Recv() (*content.ReadContentResponse, error) {
	if s.data == nil {
		return nil, io.EOF
	}
	data := s.data
	s.data = nil
	return &content.ReadContentResponse{Data: data}, nil
}

type deleteImageIDCRI struct {
	cri.RuntimeServiceClient
	cri.ImageServiceClient
	image      *cri.Image
	containers []*cri.Container
}

func (s *deleteImageIDCRI) ImageStatus(context.Context, *cri.ImageStatusRequest, ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	return &cri.ImageStatusResponse{Image: s.image}, nil
}

func (s *deleteImageIDCRI) ListContainers(context.Context, *cri.ListContainersRequest, ...grpc.CallOption) (*cri.ListContainersResponse, error) {
	return &cri.ListContainersResponse{Containers: s.containers}, nil
}

type deleteImageIDFixture struct {
	*dockerEngine
	store    *deleteImageIDStore
	cri      *deleteImageIDCRI
	manifest *deleteImageIDManifest
	id       string
}

func imageIDDeletionFixture(t *testing.T) deleteImageIDFixture {
	t.Helper()
	id := "sha256:" + strings.Repeat("a", 64)
	data := fmt.Appendf(nil, `{"schemaVersion":2,"config":{"digest":%q}}`, id)
	target := &types.Descriptor{MediaType: ocispec.MediaTypeImageManifest, Digest: fmt.Sprintf("sha256:%x", sha256.Sum256(data)), Size: int64(len(data))}
	store := &deleteImageIDStore{fakeImageMetadata: fakeImageMetadata{t: t, refs: make(map[string]*images.Image)}}
	runtime := &deleteImageIDCRI{image: &cri.Image{Id: id}}
	manifest := &deleteImageIDManifest{t: t, target: target, data: data}
	f := deleteImageIDFixture{
		dockerEngine: &dockerEngine{node: node{imageStore: store, images: runtime, runtime: runtime, content: manifest}},
		store:        store, cri: runtime, manifest: manifest, id: id,
	}
	f.addRef(id)
	return f
}

func (f deleteImageIDFixture) addRef(name string) *images.Image {
	entry := &images.Image{Name: name, Target: f.manifest.target, Labels: map[string]string{criManagedImage: "managed"}}
	f.store.refs[name] = entry
	return entry
}

func (f deleteImageIDFixture) remove(name, query string) (*httptest.ResponseRecorder, error) {
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodDelete, "/v1.47/images/"+name+"?"+query, nil)
	return w, f.deleteImage(w, r, name)
}

type targetLookupCRI struct {
	cri.ImageServiceClient
	t       *testing.T
	id      string
	image   *cri.Image
	onRead  func()
	lookups int
}

func (s *targetLookupCRI) ImageStatus(_ context.Context, req *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	s.t.Helper()
	s.lookups++
	if req.GetImage().GetImage() != s.id || !req.GetVerbose() {
		s.t.Fatalf("expected verbose status for selected config ID %q, got %v", s.id, req)
	}
	if s.onRead != nil {
		s.onRead()
	}
	return &cri.ImageStatusResponse{Image: s.image}, nil
}

func TestDockerImageIDStatusResolvesFullManifestAndIndexTargets(t *testing.T) {
	for _, tc := range []struct {
		name, mediaType string
		bare            bool
	}{
		{"OCI manifest", ocispec.MediaTypeImageManifest, false},
		{"Docker manifest by bare digest", "application/vnd.docker.distribution.manifest.v2+json", true},
		{"attestation index", ocispec.MediaTypeImageIndex, false},
		{"Docker manifest list", "application/vnd.docker.distribution.manifest.list.v2+json", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := imageIDDeletionFixture(t)
			f.manifest.target.MediaType = tc.mediaType
			if tc.mediaType == ocispec.MediaTypeImageIndex || tc.mediaType == "application/vnd.docker.distribution.manifest.list.v2+json" {
				f.node.content = nil // The runtime's exact index record selects its platform.
			}
			digest := f.manifest.target.GetDigest()
			f.addRef("registry.test/kit@" + digest)
			f.addRef("registry.test/kit:latest")
			status := &targetLookupCRI{t: t, id: f.id, image: &cri.Image{Id: f.id}}
			f.node.images = status
			ref := digest
			if tc.bare {
				ref = strings.TrimPrefix(ref, "sha256:")
			}
			w := httptest.NewRecorder()
			f.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/images/"+ref+"/json", nil))
			var result struct {
				ID string `json:"Id"`
			}
			if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &result) != nil || result.ID != f.id || status.lookups != 1 {
				t.Fatalf("target inspect = %d %s, CRI lookups = %d", w.Code, w.Body, status.lookups)
			}
		})
	}
}

func TestDockerImageIDStatusKeepsExactConfigPrecedence(t *testing.T) {
	f := imageIDDeletionFixture(t)
	digest := f.manifest.target.GetDigest()
	// A record with the exact requested ID always wins before target lookup.
	f.addRef(digest).Target = &types.Descriptor{Digest: f.id}
	status := &targetLookupCRI{t: t, id: digest, image: &cri.Image{Id: digest}}
	f.node.images = status
	f.node.content = nil
	response, err := f.node.dockerImageStatus(context.Background(), digest, true)
	if err != nil || response.GetImage().GetId() != digest || status.lookups != 1 {
		t.Fatalf("exact ID lookup returned %v, %v, CRI calls %d", response, err, status.lookups)
	}
}

func TestDockerImageIDStatusWillNotGoThroughStaleOrUnboundTarget(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(deleteImageIDFixture, *targetLookupCRI)
		code   int
		calls  int
	}{
		{"only named aliases", func(f deleteImageIDFixture, _ *targetLookupCRI) { delete(f.store.refs, f.id) }, http.StatusNotFound, 0},
		{"unmanaged full record", func(f deleteImageIDFixture, _ *targetLookupCRI) { delete(f.store.refs[f.id].Labels, criManagedImage) }, http.StatusNotFound, 0},
		{"ambiguous config IDs", func(f deleteImageIDFixture, _ *targetLookupCRI) { f.addRef("sha256:" + strings.Repeat("b", 64)) }, http.StatusConflict, 0},
		{"manifest has another config ID", func(f deleteImageIDFixture, _ *targetLookupCRI) {
			f.addRef("sha256:" + strings.Repeat("b", 64))
			delete(f.store.refs, f.id)
		}, http.StatusConflict, 0},
		{"CRI does not confirm a live ID", func(_ deleteImageIDFixture, s *targetLookupCRI) { s.image = nil }, http.StatusNotFound, 1},
		{"CRI returns another ID", func(_ deleteImageIDFixture, s *targetLookupCRI) {
			s.image = &cri.Image{Id: "sha256:" + strings.Repeat("b", 64)}
		}, http.StatusConflict, 1},
		{"record removed while CRI answers", func(f deleteImageIDFixture, s *targetLookupCRI) {
			s.onRead = func() { delete(f.store.refs, f.id) }
		}, http.StatusNotFound, 1},
		{"record target moved while CRI answers", func(f deleteImageIDFixture, s *targetLookupCRI) {
			s.onRead = func() { f.addRef(f.id).Target = &types.Descriptor{Digest: "sha256:" + strings.Repeat("b", 64)} }
		}, http.StatusConflict, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := imageIDDeletionFixture(t)
			digest := f.manifest.target.GetDigest()
			f.addRef("registry.test/kit:latest")
			status := &targetLookupCRI{t: t, id: f.id, image: &cri.Image{Id: f.id}}
			f.node.images = status
			tc.mutate(f, status)
			w := httptest.NewRecorder()
			f.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/images/"+digest+"/json", nil))
			if w.Code != tc.code || status.lookups != tc.calls || len(f.store.deleted) != 0 {
				t.Fatalf("target inspect = %d %s, CRI lookups = %d, deletions = %v", w.Code, w.Body, status.lookups, f.store.deleted)
			}
		})
	}
}

func TestDockerImageIDStatusDoesNotAcceptShortTargetOrDeleteByTarget(t *testing.T) {
	f := imageIDDeletionFixture(t)
	digest := f.manifest.target.GetDigest()
	short := strings.TrimPrefix(digest, "sha256:")[:12]
	w := httptest.NewRecorder()
	err := f.images(w, httptest.NewRequest(http.MethodGet, "/v1.47/images/"+short+"/json", nil), short+"/json")
	var problem apiError
	if !errors.As(err, &problem) || problem.code != http.StatusNotFound || len(f.store.deleted) != 0 || f.store.refs[f.id] == nil {
		t.Fatalf("inspect by short target returned %v, deletions = %v", err, f.store.deleted)
	}
	_, err = f.remove(digest, "force=1")
	if !errors.As(err, &problem) || problem.code != http.StatusNotFound || len(f.store.deleted) != 0 || f.store.refs[f.id] == nil {
		t.Fatalf("forced removal by full target returned %v, deletions = %v", err, f.store.deleted)
	}
}

func TestDockerImageIDDeleteReportsImmediateAbsence(t *testing.T) {
	for _, form := range []string{"full", "bare-full", "short", "prefixed-short"} {
		t.Run(form, func(t *testing.T) {
			f := imageIDDeletionFixture(t)
			short := strings.TrimPrefix(f.id, "sha256:")[:12]
			refs := map[string]string{"full": f.id, "bare-full": strings.TrimPrefix(f.id, "sha256:"), "short": short, "prefixed-short": "sha256:" + short}
			w, err := f.remove(refs[form], "noprune=1")
			var removed []map[string]string
			if err != nil || w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &removed) != nil || len(removed) != 1 || removed[0]["Deleted"] != f.id {
				t.Fatalf("delete returned %v status %d, response %s", err, w.Code, w.Body)
			}
			// The cached CRI result deliberately remains present through all
			// authoritative GETs. None can return the deleted ID.
			for _, ref := range []string{f.id, short, f.id} {
				response, err := f.node.dockerImageStatus(context.Background(), ref, true)
				if err != nil || response.GetImage() != nil {
					t.Fatalf("inspect %q returned %v %v after deletion", ref, response, err)
				}
			}
			if !slices.Equal(f.store.deleted, []string{f.id}) {
				t.Fatalf("unexpected deletions: %q", f.store.deleted)
			}
		})
	}
}

func TestDockerImageIDDeleteForcesOnlyVerifiedImmutableAliases(t *testing.T) {
	f := imageIDDeletionFixture(t)
	digest := f.manifest.target.GetDigest()
	importAlias, repoAlias := "import-2026-11-26@"+digest, "registry.test/fixture@"+digest
	normalizedImport := "docker.io/library/" + importAlias
	f.addRef(importAlias)
	f.addRef(normalizedImport)
	f.addRef(repoAlias)
	f.cri.image.RepoDigests = []string{normalizedImport, repoAlias}
	var problem apiError
	if _, err := f.remove(f.id, ""); !errors.As(err, &problem) || problem.code != http.StatusConflict || len(f.store.deleted) != 0 {
		t.Fatalf("plain ID removal with aliases returned %v", err)
	}
	w, err := f.remove(f.id, "force=1")
	if err != nil || !slices.Equal(f.store.deleted, []string{normalizedImport, importAlias, repoAlias, f.id}) {
		t.Fatalf("forced ID removal returned %v with deletions %v", err, f.store.deleted)
	}
	var records []map[string]string
	if json.Unmarshal(w.Body.Bytes(), &records) != nil || len(records) != 3 || records[0]["Untagged"] != importAlias ||
		records[1]["Untagged"] != repoAlias || records[2]["Deleted"] != f.id {
		t.Fatalf("unexpected delete receipt %s", w.Body)
	}
}

func TestDockerImageIDDeleteDoesNotChooseIDOverLegacyHexTag(t *testing.T) {
	for _, name := range []string{"aaaa", "aaaa:latest", "library/aaaa:latest", "index.docker.io/aaaa:latest"} {
		t.Run(name, func(t *testing.T) {
			f := imageIDDeletionFixture(t)
			f.addRef(name).Target = &types.Descriptor{Digest: "sha256:" + strings.Repeat("b", 64)}

			var problem apiError
			if _, err := f.remove("aaaa", "force=1"); !errors.As(err, &problem) || problem.code != http.StatusConflict || len(f.store.deleted) != 0 {
				t.Fatalf("legacy tag collision returned %v with deletions %v", err, f.store.deleted)
			}
			if _, err := f.remove("sha256:aaaa", ""); err != nil || !slices.Equal(f.store.deleted, []string{f.id}) || f.store.refs[name] == nil {
				t.Fatalf("explicit ID removal returned %v with deletions %v", err, f.store.deleted)
			}
		})
	}
}

func TestDockerImageIDDeleteRejectsUseProtectedRefsAndAmbiguity(t *testing.T) {
	for _, tc := range []struct {
		name   string
		short  bool
		mutate func(deleteImageIDFixture)
	}{
		{"retained stopped Docker container", false, func(f deleteImageIDFixture) {
			f.containers = map[string]*dockerContainer{"held": {dockerRecord: dockerRecord{ID: "held", ImageID: f.id, Phase: "exited"}}}
		}},
		{"runtime image config ID", false, func(f deleteImageIDFixture) {
			f.cri.containers = []*cri.Container{{Id: "runtime", ImageId: f.id}}
		}},
		{"legacy runtime manifest ref", false, func(f deleteImageIDFixture) {
			f.cri.containers = []*cri.Container{{Id: "runtime", ImageRef: "registry.test/image@" + f.manifest.target.GetDigest()}}
		}},
		{"immutable reference pinned", false, func(f deleteImageIDFixture) {
			f.addRef("registry.test/hold@" + f.manifest.target.GetDigest()).Labels["io.cri-containerd.pinned"] = "pinned"
		}},
		{"runtime image pinned", false, func(f deleteImageIDFixture) { f.cri.image.Pinned = true }},
		{"expiring reference", false, func(f deleteImageIDFixture) {
			f.addRef("registry.test/hold@" + f.manifest.target.GetDigest()).Labels["containerd.io/gc.expire"] = "2030-01-01T00:00:00Z"
		}},
		{"named tag", false, func(f deleteImageIDFixture) { f.addRef("registry.test/hold:current") }},
		{"cached sibling target", false, func(f deleteImageIDFixture) {
			f.cri.image.RepoDigests = []string{"registry.test/sibling@sha256:" + strings.Repeat("b", 64)}
		}},
		{"contradictory manifest", false, func(f deleteImageIDFixture) { f.manifest.data = append(f.manifest.data, ' ') }},
		{"ambiguous short ID", true, func(f deleteImageIDFixture) {
			f.addRef("sha256:aaaa" + strings.Repeat("b", 60))
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := imageIDDeletionFixture(t)
			tc.mutate(f)
			ref := f.id
			if tc.short {
				ref = "aaaa"
			}
			var problem apiError
			if _, err := f.remove(ref, "force=true"); !errors.As(err, &problem) || problem.code != http.StatusConflict || len(f.store.deleted) != 0 {
				t.Fatalf("protected removal returned %v with deletions %v", err, f.store.deleted)
			}
		})
	}
}

func TestDockerImageIDDeleteKeepsIDOnPartialRaceAndRetries(t *testing.T) {
	f := imageIDDeletionFixture(t)
	digest := f.manifest.target.GetDigest()
	first, second := "import-2026-11-26@"+digest, "registry.test/fixture@"+digest
	f.addRef(first)
	original := f.addRef(second)
	replacement := &images.Image{Name: second, Target: &types.Descriptor{Digest: "sha256:" + strings.Repeat("b", 64)}}
	f.store.onDelete = func(name string) {
		if name == second {
			f.store.refs[second] = replacement
		}
	}
	var problem apiError
	if _, err := f.remove(f.id, "force=true"); !errors.As(err, &problem) || problem.code != http.StatusConflict ||
		!slices.Equal(f.store.deleted, []string{first}) || f.store.refs[second] != replacement || f.store.refs[f.id] == nil {
		t.Fatalf("partial race returned %v with deletions %v", err, f.store.deleted)
	}
	// A subsequent writer restores the immutable association. Retrying uses
	// its fresh state and does not recreate the first alias.
	f.store.onDelete = nil
	f.store.refs[second] = original
	if _, err := f.remove(f.id, "force=true"); err != nil || !slices.Equal(f.store.deleted, []string{first, second, f.id}) {
		t.Fatalf("retry returned %v with removals %v", err, f.store.deleted)
	}
}

func TestDockerImageIDDeleteRechecksLiveNamedReferences(t *testing.T) {
	f := imageIDDeletionFixture(t)
	alias := "import-2026-11-26@" + f.manifest.target.GetDigest()
	f.addRef(alias)
	const fresh = "registry.test/concurrent:recent"
	f.store.onDelete = func(name string) {
		if name == alias {
			f.addRef(fresh)
		}
	}
	var problem apiError
	if _, err := f.remove(f.id, "force=true"); !errors.As(err, &problem) || problem.code != http.StatusConflict ||
		!slices.Equal(f.store.deleted, []string{alias}) || f.store.refs[f.id] == nil || f.store.refs[fresh] == nil {
		t.Fatalf("concurrent tag returned %v with deletions %v", err, f.store.deleted)
	}
}
