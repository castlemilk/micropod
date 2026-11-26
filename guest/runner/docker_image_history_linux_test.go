package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"slices"
	"strings"
	"testing"

	images "github.com/containerd/containerd/api/services/images/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"github.com/containerd/containerd/api/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type imageHistoryUsage struct {
	t     *testing.T
	keys  []string
	sizes map[string]int64
}

func (u *imageHistoryUsage) Usage(ctx context.Context, req *snapshots.UsageRequest, _ ...grpc.CallOption) (*snapshots.UsageResponse, error) {
	u.t.Helper()
	md, _ := metadata.FromOutgoingContext(ctx)
	if req.Snapshotter != "overlayfs" || !slices.Equal(md.Get("containerd-namespace"), []string{"k8s.io"}) {
		u.t.Fatalf("unexpected snapshot lookup: %v, %v", req, md)
	}
	u.keys = append(u.keys, req.Key)
	size, ok := u.sizes[req.Key]
	if !ok {
		return nil, status.Error(codes.NotFound, "snapshot is absent")
	}
	return &snapshots.UsageResponse{Size: size}, nil
}

func requestImageHistory(t *testing.T, ref string, image *cri.ImageStatusResponse, err error, usage *imageHistoryUsage) *httptest.ResponseRecorder {
	t.Helper()
	const tag = "docker.io/library/alpine:3.23"
	manifest := &types.Descriptor{Digest: "sha256:" + strings.Repeat("4", 64)}
	repoDigest := "docker.io/library/alpine@" + manifest.GetDigest()
	refs := map[string]*images.Image{
		tag:        {Name: tag, Target: manifest},
		repoDigest: {Name: repoDigest, Target: manifest},
	}
	if id := image.GetImage().GetId(); fullDockerImageID(id) {
		refs[id] = &images.Image{Name: id, Target: manifest}
	}
	engine := &dockerEngine{node: node{
		images:     inspectImageStatus{t: t, reference: ref, response: image, err: err},
		imageStore: &fakeImageMetadata{t: t, refs: refs},
		imageUsage: usage,
	}}
	response := httptest.NewRecorder()
	engine.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1.47/images/"+ref+"/history", nil))
	return response
}

func TestDockerImageHistoryUsesCommittedLayerSizes(t *testing.T) {
	base := "sha256:" + strings.Repeat("1", 64)
	top := "sha256:" + strings.Repeat("2", 64)
	chain := fmt.Sprintf("sha256:%x", sha256.Sum256([]byte(base+" "+top)))
	id := "sha256:" + strings.Repeat("3", 64)
	image := &cri.ImageStatusResponse{
		Image: &cri.Image{Id: id, Size: 23, RepoTags: []string{"registry.example/ci/base:cache", "docker.io/library/alpine:3.23"}},
		Info: map[string]string{"info": `{"imageSpec":{"rootfs":{"type":"layers","diff_ids":["` + base + `","` + top + `"]},"history":[
			{"created":"1970-01-01T00:00:02Z","created_by":"ADD base /","comment":"first"},
			{"created_by":"LABEL fixture=1","empty_layer":true,"comment":"metadata only"},
			{"created":"1970-01-01T00:00:04.012Z","created_by":"COPY top /"},
			{"created_by":"CMD [\"/bin/sh\"]","empty_layer":true}
		]}}`},
	}
	want := `[
		{"Id":"` + id + `","Created":0,"CreatedBy":"CMD [\"/bin/sh\"]","Tags":["alpine:3.23","registry.example/ci/base:cache"],"Size":0,"Comment":""},
		{"Id":"<missing>","Created":4,"CreatedBy":"COPY top /","Tags":null,"Size":16384,"Comment":""},
		{"Id":"<missing>","Created":0,"CreatedBy":"LABEL fixture=1","Tags":null,"Size":0,"Comment":"metadata only"},
		{"Id":"<missing>","Created":2,"CreatedBy":"ADD base /","Tags":null,"Size":8192,"Comment":"first"}
	]`
	for _, ref := range []string{"alpine:3.23", id, "alpine@sha256:" + strings.Repeat("4", 64)} {
		t.Run(ref, func(t *testing.T) {
			usage := &imageHistoryUsage{t: t, sizes: map[string]int64{base: 8192, chain: 16384}}
			response := requestImageHistory(t, ref, image, nil, usage)
			if response.Code != http.StatusOK || !slices.Equal(usage.keys, []string{base, chain}) {
				t.Fatalf("history returned %d: %s, snapshot lookups %v", response.Code, response.Body, usage.keys)
			}
			var got, expected []map[string]any
			if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal([]byte(want), &expected); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, expected) {
				t.Errorf("history = %s, want %s", response.Body, want)
			}
		})
	}
}

func TestDockerImageHistoryAllowsEmptyAndPartialMetadata(t *testing.T) {
	base := "sha256:" + strings.Repeat("a", 64)
	other := "sha256:" + strings.Repeat("b", 64)
	for _, tc := range []struct {
		name        string
		spec        string
		want        string
		wantLookups []string
	}{
		{
			name: "history omitted", spec: `{"rootfs":{"type":"layers","diff_ids":["` + base + `"]}}`,
			want: `[]`,
		},
		{
			name: "metadata-only scratch", spec: `{"rootfs":{"type":"layers","diff_ids":[]},"history":[{"empty_layer":true,"created_by":"LABEL fixture=1"}]}`,
			want: `[{"Id":"image","Created":0,"CreatedBy":"LABEL fixture=1","Tags":null,"Size":0,"Comment":""}]`,
		},
		{
			name: "partial layer history", spec: `{"rootfs":{"type":"layers","diff_ids":["` + base + `","` + other + `"]},"history":[{"created_by":"ADD base /"}]}`,
			want:        `[{"Id":"image","Created":0,"CreatedBy":"ADD base /","Tags":null,"Size":8192,"Comment":""}]`,
			wantLookups: []string{base},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			image := &cri.ImageStatusResponse{
				Image: &cri.Image{Id: "image"}, Info: map[string]string{"info": `{"imageSpec":` + tc.spec + `}`},
			}
			usage := &imageHistoryUsage{t: t, sizes: map[string]int64{base: 8192}}
			response := requestImageHistory(t, "alpine:3.23", image, nil, usage)
			if response.Code != http.StatusOK || strings.TrimSpace(response.Body.String()) != tc.want || !slices.Equal(usage.keys, tc.wantLookups) {
				t.Fatalf("history returned %d: %s, snapshot lookups %v", response.Code, response.Body, usage.keys)
			}
		})
	}
}

func TestDockerImageHistoryRejectsUnavailableMetadataAndLayerUsage(t *testing.T) {
	const emptyFS = `{"type":"layers","diff_ids":[]}`
	layerFS := `{"type":"layers","diff_ids":["sha256:` + strings.Repeat("1", 64) + `"]}`
	for _, tc := range []struct {
		name, rootFS, history, want string
		wantLookups                 int
	}{
		{name: "history entries without layers", rootFS: emptyFS, history: `[{}]`, want: "1 filesystem entries for 0 layers"},
		{name: "missing snapshot", rootFS: layerFS, history: `[{}]`, want: "snapshot is absent", wantLookups: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			info := `{"imageSpec":{"rootfs":` + tc.rootFS + `,"history":` + tc.history + `}}`
			image := &cri.ImageStatusResponse{Image: &cri.Image{Id: "image"}, Info: map[string]string{"info": info}}
			usage := &imageHistoryUsage{t: t}
			response := requestImageHistory(t, "alpine:3.23", image, nil, usage)
			if response.Code != http.StatusInternalServerError || !strings.Contains(response.Body.String(), tc.want) || len(usage.keys) != tc.wantLookups {
				t.Fatalf("history returned %d: %s, snapshot lookups %v", response.Code, response.Body, usage.keys)
			}
		})
	}
}

func TestDockerImageHistoryPreservesLookupErrors(t *testing.T) {
	for _, tc := range []struct {
		name, want string
		image      *cri.ImageStatusResponse
		err        error
		code       int
	}{
		{name: "missing", image: &cri.ImageStatusResponse{}, code: http.StatusNotFound, want: "No such image"},
		{name: "stale tag", image: &cri.ImageStatusResponse{Image: &cri.Image{Id: "stale"}}, code: http.StatusNotFound, want: "No such image"},
		{name: "CRI unavailable", err: status.Error(codes.Unavailable, "image store offline"), code: http.StatusInternalServerError, want: "image store offline"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			usage := &imageHistoryUsage{t: t}
			response := requestImageHistory(t, "missing:tag", tc.image, tc.err, usage)
			if response.Code != tc.code || !strings.Contains(response.Body.String(), tc.want) || len(usage.keys) != 0 {
				t.Fatalf("history returned %d: %s, snapshot lookups %v", response.Code, response.Body, usage.keys)
			}
		})
	}
}
