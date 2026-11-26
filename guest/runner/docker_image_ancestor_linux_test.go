package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type ancestorImageStore struct {
	fakeImageMetadata
	engine *dockerEngine
}

func (s *ancestorImageStore) List(ctx context.Context, req *images.ListImagesRequest, opts ...grpc.CallOption) (*images.ListImagesResponse, error) {
	if !s.engine.mu.TryLock() {
		s.t.Fatal("image metadata lookup held the container catalog lock")
	}
	s.engine.mu.Unlock()
	if !slices.Equal(req.GetFilters(), []string{"labels." + strconv.Quote(dockerImageParentLabel)}) {
		return s.fakeImageMetadata.List(ctx, req, opts...)
	}
	s.assertNamespace(ctx)
	result := &images.ListImagesResponse{}
	for _, record := range s.refs {
		if _, ok := record.GetLabels()[dockerImageParentLabel]; ok {
			result.Images = append(result.Images, record)
		}
	}
	return result, nil
}

type ancestorCRIImages struct {
	cri.ImageServiceClient
	refs   map[string]*cri.Image
	errors map[string]error
}

func (s ancestorCRIImages) ImageStatus(_ context.Context, req *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	ref := req.GetImage().GetImage()
	return &cri.ImageStatusResponse{Image: s.refs[ref]}, s.errors[ref]
}

func TestDockerContainerListAncestorFilters(t *testing.T) {
	const repo = "registry.test/team/ancestry"
	const base = repo + ":latest"
	digest := func(value string) string { return "sha256:" + strings.Repeat(value, 64) }
	parent, child, grandchild, sibling, lookalike := digest("1"), digest("2"), digest("3"), digest("4"), digest("5")
	parentTarget, childTarget, grandTarget, siblingTarget, lookalikeTarget := digest("a"), digest("b"), digest("c"), digest("d"), digest("e")
	parentDigest := repo + "@" + parentTarget
	store := &ancestorImageStore{fakeImageMetadata: fakeImageMetadata{t: t, refs: make(map[string]*images.Image)}}
	criImages := ancestorCRIImages{refs: make(map[string]*cri.Image), errors: map[string]error{
		repo + ":z-backend-offline": status.Error(codes.Unavailable, "runtime unavailable"),
		repo + ":not-found":         status.Error(codes.NotFound, "image is absent"),
	}}
	add := func(name, id, target, parentLink string) {
		record := &images.Image{Name: name, Target: &types.Descriptor{Digest: target}}
		if parentLink != "" {
			record.Labels = map[string]string{dockerImageParentLabel: parentLink}
		}
		store.refs[name] = record
		criImages.refs[name] = &cri.Image{Id: id}
	}
	add(base, parent, parentTarget, "")
	add(repo+":child", child, childTarget, "")
	add(repo+":grandchild", grandchild, grandTarget, "")
	add(repo+":sibling", sibling, siblingTarget, parentTarget) // A mutable tag cannot attest to the edge.
	add(repo+":lookalike", lookalike, lookalikeTarget, "")
	add(parent, parent, parentTarget, "")
	add(child, child, childTarget, parentTarget)
	add(grandchild, grandchild, grandTarget, "")
	add(sibling, sibling, siblingTarget, "")
	add(lookalike, lookalike, lookalikeTarget, "")
	add(parentDigest, parent, parentTarget, "")
	add(repo+"@"+grandTarget, grandchild, grandTarget, childTarget)
	add(repo+"@"+digest("f"), lookalike, lookalikeTarget, childTarget) // A mismatched digest cannot attest to the edge.
	add(repo+":replaced", sibling, siblingTarget, "")
	criImages.refs[repo] = criImages.refs[base]
	criImages.refs[repo+":removed"] = criImages.refs[repo+":child"] // CRI still remembers a removed tag.

	store.engine = &dockerEngine{node: node{imageStore: store, images: criImages}, containers: map[string]*dockerContainer{}}
	for index, row := range []struct {
		name, id, ref, phase string
	}{
		{"parent", parent, base, "running"},
		{"child", child, repo + ":child", "exited"},
		{"grandchild", grandchild, repo + ":grandchild", "running"},
		{"sibling", sibling, repo + ":sibling", "running"},
		{"lookalike", lookalike, repo + ":lookalike", "exited"},
		{"retained", child, repo + ":replaced", "created"},
	} {
		id := "fixture-" + strconv.Itoa(index)
		store.engine.containers[id] = &dockerContainer{dockerRecord: dockerRecord{
			ID: id, Name: row.name, ImageID: row.id, Phase: row.phase,
			Created: time.Unix(100, int64(index)), Config: dockerConfig{Image: row.ref, Labels: map[string]string{"scope": "fixture"}},
		}}
	}
	for _, tc := range []struct {
		name    string
		filters map[string]any
		all     bool
		want    []string
		status  int
	}{
		{name: "no ancestor", want: []string{"sibling", "grandchild", "parent"}},
		{name: "tag running", filters: map[string]any{"ancestor": []string{base}}, want: []string{"grandchild", "parent"}},
		{name: "latest all", filters: map[string]any{"ancestor": []string{repo}}, all: true, want: []string{"retained", "grandchild", "child", "parent"}},
		{name: "full config ID", filters: map[string]any{"ancestor": []string{parent}}, want: []string{"grandchild", "parent"}},
		{name: "short ID", filters: map[string]any{"ancestor": []string{parent[7:19]}}, want: []string{"grandchild", "parent"}},
		{name: "child ID does not select parent", filters: map[string]any{"ancestor": []string{child}}, all: true, want: []string{"retained", "grandchild", "child"}},
		{name: "repo digest", filters: map[string]any{"ancestor": map[string]bool{parentDigest: true}}, want: []string{"grandchild", "parent"}},
		{name: "set key with false flag", filters: map[string]any{"ancestor": map[string]bool{base: false}}, want: []string{"grandchild", "parent"}},
		{name: "multiple ancestry keys", filters: map[string]any{"ancestor": []string{base, "no-image:exists", sibling, base}}, want: []string{"sibling", "grandchild", "parent"}},
		{name: "matching other filters", filters: map[string]any{"ancestor": []string{base}, "label": []string{"scope=fixture"}, "name": []string{"child"}, "id": []string{"fixture-1"}, "status": []string{"exited"}}, want: []string{"child"}},
		{name: "retag uses new identity", filters: map[string]any{"ancestor": []string{repo + ":replaced"}}, all: true, want: []string{"sibling"}},
		{name: "empty ancestor set", filters: map[string]any{"ancestor": map[string]bool{}}, all: true},
		{name: "invalid or absent images", filters: map[string]any{"ancestor": []string{"ref with whitespace", repo + ":missing", "absent@" + parentTarget, repo + ":removed"}}, all: true},
		{name: "runtime not found is unresolved", filters: map[string]any{"ancestor": []string{repo + ":not-found", base}}, want: []string{"grandchild", "parent"}},
		{name: "image lookup outage fails whole request", filters: map[string]any{"ancestor": []string{base, repo + ":z-backend-offline"}}, status: http.StatusInternalServerError},
		{name: "malformed filter", filters: map[string]any{"ancestor": 10}, status: http.StatusBadRequest},
		{name: "unknown filter", filters: map[string]any{"not-supported": []string{"a"}}, status: http.StatusBadRequest},
	} {
		t.Run(tc.name, func(t *testing.T) {
			query := url.Values{}
			if tc.all {
				query.Set("all", "1")
			}
			raw, err := json.Marshal(tc.filters)
			if err != nil {
				t.Fatal(err)
			}
			query.Set("filters", string(raw))
			response := httptest.NewRecorder()
			store.engine.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1.47/containers/json?"+query.Encode(), nil))
			if tc.status != 0 {
				var problem map[string]string
				if response.Code != tc.status || json.Unmarshal(response.Body.Bytes(), &problem) != nil || problem["message"] == "" {
					t.Fatalf("filter returned %d: %s, want %d and an Engine error", response.Code, response.Body, tc.status)
				}
				return
			}
			var rows []dockerContainerListRow
			if response.Code != http.StatusOK || json.Unmarshal(response.Body.Bytes(), &rows) != nil || rows == nil {
				t.Fatalf("container list returned %d: %s", response.Code, response.Body)
			}
			names := make([]string, 0, len(rows))
			for _, row := range rows {
				names = append(names, strings.TrimPrefix(row.Names[0], "/"))
			}
			if !slices.Equal(names, tc.want) {
				t.Fatalf("containers %v, want %v", names, tc.want)
			}
		})
	}
}
