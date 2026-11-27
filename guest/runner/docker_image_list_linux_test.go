package main

import (
	"context"
	"encoding/json"
	"maps"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	digest "github.com/opencontainers/go-digest"
	"github.com/opencontainers/image-spec/specs-go"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type imageListLabelCRI struct {
	cri.ImageServiceClient
	t        *testing.T
	list     []*cri.Image
	status   map[string]*cri.ImageStatusResponse
	lists    int
	requests []string
	catalog  *imageListTestCatalog
}

type imageListTestCatalog struct {
	imageMetadataClient
	t     *testing.T
	rows  map[string]*images.Image
	lists int
	err   error
}

func (f *imageListTestCatalog) List(ctx context.Context, req *images.ListImagesRequest, _ ...grpc.CallOption) (*images.ListImagesResponse, error) {
	f.t.Helper()
	md, _ := metadata.FromOutgoingContext(ctx)
	if _, ok := ctx.Deadline(); !ok || !slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) ||
		len(req.GetFilters()) != 0 {
		f.t.Fatalf("expected a bounded catalog snapshot in %q", dockerRuntimeNamespace)
	}
	f.lists++
	if f.err != nil {
		return nil, f.err
	}
	rows := make([]*images.Image, 0, len(f.rows))
	for _, row := range f.rows {
		rows = append(rows, row)
	}
	return &images.ListImagesResponse{Images: rows}, nil
}

func (f *imageListLabelCRI) ListImages(_ context.Context, request *cri.ListImagesRequest, _ ...grpc.CallOption) (*cri.ListImagesResponse, error) {
	f.t.Helper()
	if request.GetFilter() != nil {
		f.t.Fatal("containerd CRI does not filter image config labels in ListImages")
	}
	f.lists++
	return &cri.ListImagesResponse{Images: f.list}, nil
}

func (f *imageListLabelCRI) ImageStatus(ctx context.Context, request *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	f.t.Helper()
	id := request.GetImage().GetImage()
	if _, ok := ctx.Deadline(); !ok || !request.GetVerbose() || !fullDockerImageID(id) {
		f.t.Fatalf("expected bounded verbose lookup by config ID, got %v", request)
	}
	f.requests = append(f.requests, id)
	return f.status[id], nil
}

func imageListLabelFixture(t *testing.T) (*dockerEngine, *imageListLabelCRI) {
	t.Helper()
	catalog := &imageListTestCatalog{t: t, rows: make(map[string]*images.Image)}
	f := &imageListLabelCRI{t: t, status: make(map[string]*cri.ImageStatusResponse), catalog: catalog}
	for _, row := range []struct {
		suffix, tag, config string
	}{
		{"a", "ci:alpha", `{"team":"ci","state":"","detail":"x=y","tier":"fast"}`},
		{"b", "ci:beta", `{"team":"ci","state":"ready","tier":"slow"}`},
		{"c", "ci:gamma", `{"team":"release","tier":"fast"}`},
		{"d", "ci:unlabeled", "null"},
	} {
		id := "sha256:" + strings.Repeat(row.suffix, 64)
		image := &cri.Image{Id: id, RepoTags: []string{row.tag}, Size: 123,
			Spec: &cri.ImageSpec{Annotations: map[string]string{"annotation-only": "fake-label"}}}
		f.list = append(f.list, image)
		f.status[id] = &cri.ImageStatusResponse{Image: image,
			Info: map[string]string{"info": `{"imageSpec":{"config":{"Labels":` + row.config + `}}}`}}
		target := &types.Descriptor{MediaType: ocispec.MediaTypeImageManifest, Digest: id, Size: 100}
		catalog.rows[id] = &images.Image{Name: id, Target: target}
		catalog.rows[row.tag] = &images.Image{Name: row.tag, Target: target}
	}
	return &dockerEngine{node: node{images: f, imageStore: catalog}}, f
}

func listImagesV147(engine *dockerEngine, filters string) *httptest.ResponseRecorder {
	query := url.Values{"all": {"1"}}
	if filters != "" {
		query.Set("filters", filters)
	}
	w := httptest.NewRecorder()
	engine.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/images/json?"+query.Encode(), nil))
	return w
}

func TestDockerImageListV147LabelFilters(t *testing.T) {
	// Positive label cases follow Moby's containerd setupLabelFilter and
	// classic MatchKVList in API v1.47. CLI sets and SDK arrays are both valid.
	for _, tc := range []struct {
		name, filter string
		tags         []string
		fast         bool
	}{
		{"unfiltered", "", []string{"ci:alpha", "ci:beta", "ci:gamma", "ci:unlabeled"}, true},
		{"empty object", `{}`, []string{"ci:alpha", "ci:beta", "ci:gamma", "ci:unlabeled"}, true},
		{"empty set", `{"label":{}}`, []string{"ci:alpha", "ci:beta", "ci:gamma", "ci:unlabeled"}, true},
		{"empty array", `{"label":[]}`, []string{"ci:alpha", "ci:beta", "ci:gamma", "ci:unlabeled"}, true},
		{"CLI key", `{"label":{"team":true}}`, []string{"ci:alpha", "ci:beta", "ci:gamma"}, false},
		{"set member with false value", `{"label":{"state=ready":false}}`, []string{"ci:beta"}, false},
		{"SDK exact value", `{"label":["team=ci"]}`, []string{"ci:alpha", "ci:beta"}, false},
		{"explicit empty value", `{"label":["state="]}`, []string{"ci:alpha"}, false},
		{"all label predicates", `{"label":{"team=ci":true,"tier=fast":true}}`, []string{"ci:alpha"}, false},
		{"conflicting values", `{"label":["team=ci","team=release"]}`, nil, false},
		{"equals inside value", `{"label":["detail=x=y"]}`, []string{"ci:alpha"}, false},
		{"missing label", `{"label":["missing"]}`, nil, false},
		{"annotations are not labels", `{"label":["annotation-only"]}`, nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			engine, cri := imageListLabelFixture(t)
			response := listImagesV147(engine, tc.filter)
			var rows []struct {
				RepoTags []string
				Size     uint64
				Labels   map[string]string
			}
			if response.Code != http.StatusOK || json.Unmarshal(response.Body.Bytes(), &rows) != nil || rows == nil {
				t.Fatalf("image list = %d %s", response.Code, response.Body)
			}
			var tags []string
			for _, row := range rows {
				tags = append(tags, row.RepoTags...)
				if row.Size != 123 || !tc.fast && row.Labels["team"] == "" {
					t.Fatalf("bad summary fields: %+v", row)
				}
			}
			// Each config is read once: for its labels, or (unfiltered) for
			// its creation time, which later listings remember.
			statusCalls := len(cri.list)
			if !slices.Equal(tags, tc.tags) || cri.lists != 1 || cri.catalog.lists != 1 || len(cri.requests) != statusCalls {
				t.Fatalf("rows %v, want %v; %d CRI lists, %d catalog lists and %v status calls",
					tags, tc.tags, cri.lists, cri.catalog.lists, cri.requests)
			}
		})
	}
}

func TestDockerImageListRejectsInvalidFiltersBeforeRuntimeRead(t *testing.T) {
	for _, filter := range []string{
		`{"label":["team"]`, `[]`, `{"label":"team"}`, `{"label":[2]}`, `{"label":[null]}`,
		`{"label":{"team":"true"}}`, `{"label":{"team":null}}`, `{"not-supported":["team"]}`,
		`{"reference":["ci:*"]}`, `{"label!":["team"]}`, `{"label":["team!=ci"]}`,
		`{"label":["k=` + strings.Repeat("v", 4096) + `"]}`,
	} {
		engine, cri := imageListLabelFixture(t)
		response := listImagesV147(engine, filter)
		if response.Code != http.StatusBadRequest || cri.lists != 0 || cri.catalog.lists != 0 || len(cri.requests) != 0 {
			t.Fatalf("invalid filter = %d %s, runtime calls = %d/%v", response.Code, response.Body, cri.lists, cri.requests)
		}
	}
}

func TestDockerImageListDerivesOnlyLiveTagDigestsAndPreservesActualAliases(t *testing.T) {
	engine, runtime := imageListLabelFixture(t)
	first, second := runtime.list[0], runtime.list[1]
	firstConfig, secondConfig := runtime.catalog.rows[first.GetId()], runtime.catalog.rows[second.GetId()]
	firstConfig.Labels = map[string]string{criManagedImage: "managed"}
	secondConfig.Labels = map[string]string{criManagedImage: "managed"}
	const historyRepo = "docker.io/library/import-2026-11-25"
	historical := historyRepo + "@" + firstConfig.GetTarget().GetDigest()
	first.RepoDigests = []string{historical}
	runtime.catalog.rows[historical] = &images.Image{Name: historical, Target: firstConfig.GetTarget()}
	first.RepoTags = append(first.RepoTags, "other:retargeted")
	runtime.catalog.rows["other:retargeted"] = &images.Image{Name: "other:retargeted", Target: secondConfig.GetTarget()}

	response := listImagesV147(engine, `{"label":["team=ci"]}`)
	var rows []struct {
		ID          string `json:"Id"`
		RepoTags    []string
		RepoDigests []string
	}
	if response.Code != http.StatusOK || json.Unmarshal(response.Body.Bytes(), &rows) != nil || len(rows) != 2 {
		t.Fatalf("image list returned %d %s", response.Code, response.Body)
	}
	for i, expected := range [][]string{
		{historical, "docker.io/library/ci@" + firstConfig.GetTarget().GetDigest()},
		{"docker.io/library/ci@" + secondConfig.GetTarget().GetDigest()},
	} {
		if rows[i].ID != runtime.list[i].GetId() || len(rows[i].RepoTags) != 1 || !slices.Equal(rows[i].RepoDigests, expected) {
			t.Fatalf("image summary %d = %v, want digests %v", i, rows[i], expected)
		}
	}
}

func TestDockerImageListUsesCurrentExactConfigLabels(t *testing.T) {
	t.Run("stale list row", func(t *testing.T) {
		engine, cri := imageListLabelFixture(t)
		delete(cri.status, cri.list[0].GetId())
		response := listImagesV147(engine, `{"label":["team=ci"]}`)
		if response.Code != http.StatusOK || strings.Contains(response.Body.String(), "ci:alpha") ||
			!strings.Contains(response.Body.String(), "ci:beta") {
			t.Fatalf("stale image result = %d %s", response.Code, response.Body)
		}
	})
	t.Run("metadata from a different ID", func(t *testing.T) {
		engine, cri := imageListLabelFixture(t)
		cri.status[cri.list[0].GetId()] = cri.status[cri.list[1].GetId()]
		response := listImagesV147(engine, `{"label":["team"]}`)
		if response.Code != http.StatusConflict {
			t.Fatalf("wrong config read = %d %s", response.Code, response.Body)
		}
	})
	t.Run("unreadable metadata", func(t *testing.T) {
		engine, cri := imageListLabelFixture(t)
		cri.status[cri.list[0].GetId()].Info = nil
		response := listImagesV147(engine, `{"label":["team"]}`)
		if response.Code != http.StatusServiceUnavailable {
			t.Fatalf("unverified labels = %d %s", response.Code, response.Body)
		}
	})
	t.Run("optional config absent", func(t *testing.T) {
		engine, cri := imageListLabelFixture(t)
		cri.status[cri.list[0].GetId()].Info["info"] =
			`{"imageSpec":{"os":"linux","architecture":"arm64","rootfs":{"type":"layers","diff_ids":[]}}}`
		response := listImagesV147(engine, `{"label":["team=ci"]}`)
		if response.Code != http.StatusOK || strings.Contains(response.Body.String(), "ci:alpha") ||
			!strings.Contains(response.Body.String(), "ci:beta") {
			t.Fatalf("valid unlabeled image = %d %s", response.Code, response.Body)
		}
	})
}

func TestDockerImageListReconcilesRuntimeAndLiveCatalog(t *testing.T) {
	for _, filter := range []string{"", `{"label":["team=ci"]}`} {
		t.Run("deleted image "+filter, func(t *testing.T) {
			engine, cri := imageListLabelFixture(t)
			id := cri.list[0].GetId()
			delete(cri.catalog.rows, id)
			delete(cri.catalog.rows, "ci:alpha")
			response := listImagesV147(engine, filter)
			if response.Code != http.StatusOK || strings.Contains(response.Body.String(), id) ||
				!strings.Contains(response.Body.String(), "ci:beta") || slices.Contains(cri.requests, id) {
				t.Fatalf("phantom image = %d %s, labels queried %v", response.Code, response.Body, cri.requests)
			}
		})
	}

	for _, tc := range []struct {
		name, storedSuffix string
		want               bool
	}{
		{"raw import alias", "@digest", true},
		{"same repository tag proves the digest", ":latest", true},
		{"retargeted repository tag", ":moved", false},
		{"live target is known to have another config", ":contradiction", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			engine, cri := imageListLabelFixture(t)
			old := cri.list[0]
			id := old.GetId()
			target := cri.catalog.rows[id].Target
			delete(cri.catalog.rows, id)
			delete(cri.catalog.rows, "ci:alpha")
			old.RepoTags = nil
			old.RepoDigests = []string{"docker.io/library/import-2026-11-26@" + target.GetDigest()}
			name := "import-2026-11-26" + tc.storedSuffix
			switch tc.storedSuffix {
			case "@digest":
				name = "import-2026-11-26@" + target.GetDigest()
			case ":moved":
				target = cri.catalog.rows[cri.list[1].GetId()].Target
			case ":contradiction":
				otherID := cri.list[1].GetId()
				cri.catalog.rows[otherID] = &images.Image{Name: otherID, Target: target}
			}
			cri.catalog.rows[name] = &images.Image{Name: name, Target: target}
			response := listImagesV147(engine, `{"label":["team=ci"]}`)
			if response.Code != http.StatusOK || strings.Contains(response.Body.String(), id) != tc.want ||
				strings.Contains(response.Body.String(), old.RepoDigests[0]) != tc.want {
				t.Fatalf("live digest binding = %d %s, want visibility %v", response.Code, response.Body, tc.want)
			}
		})
	}

	t.Run("retargeted tag on a still-live config", func(t *testing.T) {
		engine, cri := imageListLabelFixture(t)
		cri.catalog.rows["ci:alpha"].Target = cri.catalog.rows["ci:beta"].Target
		response := listImagesV147(engine, "")
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), cri.list[0].GetId()) ||
			strings.Contains(response.Body.String(), "ci:alpha") {
			t.Fatalf("retargeted tag = %d %s", response.Code, response.Body)
		}
	})
	t.Run("tag-only legacy image verified by manifest", func(t *testing.T) {
		engine, cri := imageListLabelFixture(t)
		id := cri.list[0].GetId()
		delete(cri.catalog.rows, id)
		store := &buildxDeleteContent{blobs: make(map[string][]byte)}
		manifest := store.json(t, ocispec.MediaTypeImageManifest, ocispec.Manifest{
			Versioned: specs.Versioned{SchemaVersion: 2}, MediaType: ocispec.MediaTypeImageManifest,
			Config: ocispec.Descriptor{Digest: digest.Digest(id)},
		})
		cri.catalog.rows["ci:alpha"].Target = imageBlobDescriptor(manifest)
		engine.node.content = store
		response := listImagesV147(engine, "")
		// The only CRI reads are the creation times, one per listed config.
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "ci:alpha") ||
			len(store.reads) != 1 || len(cri.requests) != len(cri.list) {
			t.Fatalf("verified legacy tag = %d %s; content reads %v", response.Code, response.Body, store.reads)
		}
		delete(store.blobs, manifest.Digest.String())
		response = listImagesV147(engine, "")
		if response.Code != http.StatusOK || strings.Contains(response.Body.String(), id) ||
			!strings.Contains(response.Body.String(), "ci:beta") {
			t.Fatalf("manifest removed after catalog snapshot = %d %s", response.Code, response.Body)
		}
	})
	t.Run("authoritative catalog unavailable", func(t *testing.T) {
		engine, cri := imageListLabelFixture(t)
		cri.catalog.err = status.Error(codes.Unavailable, "test catalog outage")
		response := listImagesV147(engine, "")
		if response.Code != http.StatusServiceUnavailable || len(cri.requests) != 0 ||
			strings.Contains(response.Body.String(), "ci:alpha") {
			t.Fatalf("unavailable catalog = %d %s", response.Code, response.Body)
		}
	})
}

// Created is each image's config time (Unix seconds), as Docker lists it, and
// 0 for a config that records none. A config is read once: later listings of
// the same ID make no runtime call, and an ID no longer listed is forgotten.
func TestDockerImageListReportsConfigCreated(t *testing.T) {
	engine, runtime := imageListLabelFixture(t)
	created := map[string]string{
		runtime.list[0].GetId(): `"2026-04-16T23:53:24.896953537Z"`,
		runtime.list[1].GetId(): `"1970-01-01T00:00:00Z"`,
		runtime.list[2].GetId(): `null`,
	}
	for id, at := range created {
		runtime.status[id].Info["info"] = `{"imageSpec":{"created":` + at +
			`,"config":{"Labels":{"team":"ci"}},"rootfs":{"type":"layers","diff_ids":[]}}}`
	}
	want := map[string]int64{
		runtime.list[0].GetId(): 1776383604, runtime.list[1].GetId(): 0, runtime.list[2].GetId(): 0, runtime.list[3].GetId(): 0,
	}
	read := func(filter string) map[string]int64 {
		t.Helper()
		response := listImagesV147(engine, filter)
		var rows []struct {
			ID      string `json:"Id"`
			Created *int64
		}
		if response.Code != http.StatusOK || json.Unmarshal(response.Body.Bytes(), &rows) != nil {
			t.Fatalf("image list = %d %s", response.Code, response.Body)
		}
		got := map[string]int64{}
		for _, row := range rows {
			if row.Created == nil {
				t.Fatalf("row %s has no Created: %s", row.ID, response.Body)
			}
			got[row.ID] = *row.Created
		}
		return got
	}
	if got := read(""); !maps.Equal(got, want) || len(runtime.requests) != len(runtime.list) {
		t.Fatalf("first listing Created = %v after %d status calls, want %v after %d", got, len(runtime.requests), want, len(runtime.list))
	}
	if got := read(""); !maps.Equal(got, want) || len(runtime.requests) != len(runtime.list) {
		t.Fatalf("second listing Created = %v after %d status calls; want the remembered times and no new call", got, len(runtime.requests))
	}
	// A filtered listing reports the same times from the labels' read.
	labeled := read(`{"label":["team=ci"]}`)
	if labeled[runtime.list[0].GetId()] != 1776383604 || len(labeled) != 3 {
		t.Fatalf("filtered listing Created = %v", labeled)
	}
	gone := runtime.list[0].GetId()
	runtime.list = runtime.list[1:]
	delete(runtime.catalog.rows, gone)
	delete(runtime.catalog.rows, "ci:alpha")
	read("")
	engine.imageConfigs.mu.Lock()
	_, kept := engine.imageConfigs.configs[gone]
	engine.imageConfigs.mu.Unlock()
	if kept {
		t.Fatal("a removed image's config is still remembered")
	}
}
