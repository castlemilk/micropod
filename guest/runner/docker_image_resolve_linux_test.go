package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	"google.golang.org/grpc"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type digestStatusImages struct {
	cri.ImageServiceClient
	got        []string
	records    []*cri.Image
	byConfigID *cri.ImageStatusResponse
	byRef      map[string]*cri.ImageStatusResponse
	onStatus   func()
}

func (d *digestStatusImages) ImageStatus(_ context.Context, req *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	ref := req.GetImage().GetImage()
	d.got = append(d.got, ref)
	if d.onStatus != nil {
		d.onStatus()
	}
	if result := d.byRef[ref]; result != nil {
		return result, nil
	}
	if ref == d.byConfigID.GetImage().GetId() {
		return d.byConfigID, nil
	}
	return &cri.ImageStatusResponse{}, nil
}

func TestDockerImageDigestVerifiesLegacyTagWithoutManagedConfig(t *testing.T) {
	for _, tc := range []struct {
		name       string
		stale      bool
		removeTag  bool
		retarget   bool
		wantStatus int
	}{
		{name: "verified single platform", wantStatus: http.StatusOK},
		{name: "cached config from another image", stale: true, wantStatus: http.StatusNotFound},
		{name: "tag removed during CRI lookup", removeTag: true, wantStatus: http.StatusNotFound},
		{name: "tag moved during CRI lookup", retarget: true, wantStatus: http.StatusNotFound},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := imageIDDeletionFixture(t)
			delete(f.store.refs, f.id)
			const tag = "docker.io/micropod-qa/legacy:latest"
			f.addRef(tag)
			ref := "micropod-qa/legacy@" + f.manifest.target.GetDigest()
			id := f.id
			if tc.stale {
				id = "sha256:" + strings.Repeat("b", 64)
			}
			f.node.images = &digestStatusImages{
				byRef: map[string]*cri.ImageStatusResponse{ref: {Image: &cri.Image{Id: id}}},
				onStatus: func() {
					if tc.removeTag {
						delete(f.store.refs, tag)
					}
					if tc.retarget {
						f.store.refs[tag] = &images.Image{Name: tag, Target: &types.Descriptor{Digest: "sha256:" + strings.Repeat("d", 64)}}
					}
				},
			}
			w := httptest.NewRecorder()
			f.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/images/"+ref+"/json", nil))
			if w.Code != tc.wantStatus || (w.Code == http.StatusOK && !strings.Contains(w.Body.String(), f.id)) {
				t.Fatalf("legacy tag digest returned %d: %s", w.Code, w.Body)
			}
			if f.store.refs[f.id] != nil {
				t.Fatal("legacy lookup created a config record")
			}
		})
	}
}

func (d *digestStatusImages) ListImages(context.Context, *cri.ListImagesRequest, ...grpc.CallOption) (*cri.ListImagesResponse, error) {
	d.got = append(d.got, "list")
	return &cri.ListImagesResponse{Images: d.records}, nil
}

func TestDockerImageDigestResolutionBindsRepositoryToDescriptor(t *testing.T) {
	digest := "sha256:" + strings.Repeat("1", 64)
	configID := "sha256:" + strings.Repeat("2", 64)
	rawName := "import-2026-11-25@" + digest
	qualifiedName := "docker.io/library/" + rawName
	img := &cri.Image{Id: configID, RepoDigests: []string{qualifiedName}}
	for _, tc := range []struct {
		name, ref string
		target    string
		want      int
		lookups   []string
	}{
		{name: "normalized import alias", ref: qualifiedName, target: digest, want: http.StatusOK,
			lookups: []string{qualifiedName, "list", configID}},
		{name: "wrong repository", ref: "never-owned@" + digest, target: digest, want: http.StatusNotFound},
		{name: "alias disagrees with descriptor", ref: qualifiedName, target: configID, want: http.StatusNotFound},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeImageMetadata{t: t, refs: map[string]*images.Image{
				rawName: {Name: rawName, Target: &types.Descriptor{Digest: tc.target}},
			}}
			for _, endpoint := range []string{"json", "history"} {
				criImages := &digestStatusImages{records: []*cri.Image{img}, byConfigID: &cri.ImageStatusResponse{
					Image: img, Info: map[string]string{"info": `{"imageSpec":{"rootfs":{"type":"layers","diff_ids":[]},"history":[{"created_by":"CMD []","empty_layer":true}]}}`},
				}}
				engine := &dockerEngine{node: node{images: criImages, imageStore: store}}
				w := httptest.NewRecorder()
				engine.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/images/"+tc.ref+"/"+endpoint, nil))
				if w.Code != tc.want || !slices.Equal(criImages.got, tc.lookups) {
					t.Fatalf("%s returned %d: %s, CRI lookups %v, want %d and %v", endpoint, w.Code, w.Body, criImages.got, tc.want, tc.lookups)
				}
				if w.Code == http.StatusOK && !strings.Contains(w.Body.String(), configID) {
					t.Fatalf("%s did not return the resolved config ID: %s", endpoint, w.Body)
				}
			}
		})
	}
}

func TestDockerImageDigestNamedLoadUsesVerifiedTagAndKeepsHistoricalAlias(t *testing.T) {
	f := imageIDDeletionFixture(t)
	digest := f.manifest.target.GetDigest()
	const tag = "docker.io/micropod-qa/archive:stable"
	const repo = "docker.io/micropod-qa/archive"
	const otherTag = "docker.io/micropod-qa/moved:stable"
	const shaTag = "docker.io/library/sha256:real"
	f.addRef(tag)
	f.addRef(otherTag).Target = &types.Descriptor{Digest: "sha256:" + strings.Repeat("b", 64)}
	historical := "import-2026-11-25@" + digest
	sameRepoPast := repo + "@sha256:" + strings.Repeat("a", 64)
	unrelatedID := "sha256:" + strings.Repeat("c", 64)
	f.addRef(historical)
	image := &cri.Image{Id: f.id, RepoTags: []string{tag, otherTag}, RepoDigests: []string{"docker.io/library/" + historical, sameRepoPast}}
	criImages := &digestStatusImages{records: []*cri.Image{image}, byConfigID: &cri.ImageStatusResponse{Image: image},
		byRef: map[string]*cri.ImageStatusResponse{repo + "@" + digest: {Image: &cri.Image{Id: unrelatedID}}}}
	f.node.images = criImages

	for _, tc := range []struct {
		name, ref string
		code      int
		lookups   []string
	}{
		{"named target ignores wrong cached repo digest config", repo + "@" + digest, http.StatusOK, []string{f.id}},
		{"actual historical alias", historical, http.StatusOK, []string{historical, "list", f.id}},
		{"cached past digest without a live reference", sameRepoPast, http.StatusNotFound, nil},
		{"wrong repository with same digest", "unrelated@" + digest, http.StatusNotFound, nil},
		{"config ID is not a sha256 repo tag", "sha256@" + digest, http.StatusNotFound, nil},
		{"moved tag does not advertise old digest", "micropod-qa/moved@" + digest, http.StatusNotFound, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			criImages.got = nil
			w := httptest.NewRecorder()
			f.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/images/"+tc.ref+"/json", nil))
			if w.Code != tc.code || !slices.Equal(criImages.got, tc.lookups) {
				t.Fatalf("inspect returned %d %s, CRI reads %v", w.Code, w.Body, criImages.got)
			}
			if w.Code == http.StatusOK {
				var row struct {
					ID          string `json:"Id"`
					RepoDigests []string
				}
				if err := json.Unmarshal(w.Body.Bytes(), &row); err != nil || row.ID != f.id ||
					!slices.Equal(row.RepoDigests, []string{"docker.io/library/" + historical, sameRepoPast, repo + "@" + digest}) {
					t.Fatalf("inspect did not report the verified and historical digests: %s", w.Body)
				}
			}
			if f.store.refs[repo+"@"+digest] != nil || !slices.Equal(image.GetRepoDigests(), []string{"docker.io/library/" + historical, sameRepoPast}) {
				t.Fatal("inspect changed persisted records or cached CRI metadata")
			}
		})
	}
	f.addRef(shaTag)
	qualified, err := f.node.dockerImageStatus(context.Background(), "sha256@"+digest, false)
	if err != nil || qualified.GetImage().GetId() != f.id {
		t.Fatalf("real sha256 repository failed to resolve: %v %v", qualified, err)
	}
	delete(f.store.refs, f.id)
	qualified, err = f.node.dockerImageStatus(context.Background(), repo+"@"+digest, false)
	if err != nil || qualified.GetImage() != nil {
		t.Fatalf("missing authoritative config resolved stale CRI metadata: %v %v", qualified, err)
	}
}
