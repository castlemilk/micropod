package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
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

func (f *fakeImageMetadata) Create(ctx context.Context, req *images.CreateImageRequest, _ ...grpc.CallOption) (*images.CreateImageResponse, error) {
	f.assertNamespace(ctx)
	img := req.GetImage()
	if f.refs[img.Name] != nil {
		return nil, status.Error(codes.AlreadyExists, "already exists")
	}
	f.refs[img.Name] = img
	return &images.CreateImageResponse{Image: img}, nil
}

func (f *fakeImageMetadata) Update(ctx context.Context, req *images.UpdateImageRequest, _ ...grpc.CallOption) (*images.UpdateImageResponse, error) {
	f.assertNamespace(ctx)
	if !slices.Equal(req.GetUpdateMask().GetPaths(), []string{"target", "labels." + criManagedImage}) {
		f.t.Fatalf("update mask = %v", req.GetUpdateMask())
	}
	dst := f.refs[req.GetImage().GetName()]
	if dst == nil {
		return nil, status.Error(codes.NotFound, "not found")
	}
	dst.Target = req.Image.Target
	if dst.Labels == nil {
		dst.Labels = make(map[string]string)
	}
	dst.Labels[criManagedImage] = req.Image.Labels[criManagedImage]
	return &images.UpdateImageResponse{Image: dst}, nil
}

type tagCRI struct {
	cri.ImageServiceClient
	sourceID, target string
	staleReads       int
	repoDigests      []string
	transientReads   int
	blockUntilDone   bool
}

func (c *tagCRI) ImageStatus(ctx context.Context, req *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	ref := req.Image.Image
	if ref == "unknown" {
		return &cri.ImageStatusResponse{}, nil
	}
	if ref == c.target && c.blockUntilDone {
		<-ctx.Done()
		return nil, status.FromContextError(ctx.Err()).Err()
	}
	if ref == c.target && c.transientReads > 0 {
		c.transientReads--
		return nil, status.Error(codes.Unavailable, "image index temporarily unavailable")
	}
	if ref == c.target && c.staleReads > 0 {
		c.staleReads--
		return &cri.ImageStatusResponse{Image: &cri.Image{Id: "old-id"}}, nil
	}
	return &cri.ImageStatusResponse{
		Image: &cri.Image{Id: c.sourceID, RepoTags: []string{c.target}, RepoDigests: c.repoDigests},
		Info:  map[string]string{"info": `{"imageSpec":{"config":{"Labels":{"ci":"yes"}}}}`},
	}, nil
}

func TestDockerImageTag(t *testing.T) {
	id := "sha256:" + strings.Repeat("a", 64)
	src := "docker.io/library/source:latest"
	dest := "registry.local:5000/team/dst:v2"
	target := &types.Descriptor{Digest: "sha256:" + strings.Repeat("b", 64), MediaType: "application/vnd.oci.image.index.v1+json"}
	old := &types.Descriptor{Digest: "sha256:" + strings.Repeat("c", 64)}
	for _, tc := range []struct {
		name, ref        string
		existing, pinned bool
		want             int
	}{
		{"name", "source", false, false, 201}, {"id", id, false, false, 201},
		{"short id", "aaaaaaaaaaaa", false, false, 201}, {"retag", "source", true, false, 201},
		{"protected", "source", true, true, 409}, {"missing", "unknown", false, false, 404},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeImageMetadata{t: t, refs: map[string]*images.Image{src: {Name: src, Target: target}, id: {Name: id, Target: target}}}
			if tc.existing {
				labels := map[string]string{"preserve": "1"}
				if tc.pinned {
					labels["io.cri-containerd.pinned"] = "pinned"
				}
				store.refs[dest] = &images.Image{Name: dest, Target: old, Labels: labels}
			}
			c := &tagCRI{sourceID: id, target: dest, staleReads: 1}
			e := &dockerEngine{node: node{images: c, imageStore: store}}
			req := httptest.NewRequest(http.MethodPost, "/v1.47/images/"+tc.ref+"/tag?repo="+url.QueryEscape("registry.local:5000/team/dst")+"&tag=v2", nil)
			w := httptest.NewRecorder()
			err := e.images(w, req, tc.ref+"/tag")
			got := w.Code
			if err != nil {
				var problem apiError
				if !errors.As(err, &problem) {
					t.Fatalf("tag error: %v", err)
				}
				got = problem.code
			}
			if got != tc.want {
				t.Fatalf("HTTP %d, %s, %v", got, w.Body.String(), err)
			}
			if got != 201 {
				if tc.pinned && store.refs[dest].Target != old {
					t.Fatal("pinned target changed")
				}
				return
			}
			img := store.refs[dest]
			if img.Target != target || img.Labels[criManagedImage] != "managed" || w.Body.Len() != 0 || c.staleReads != 0 {
				t.Fatalf("wrong tag result: %v", img)
			}
			if tc.existing && img.Labels["preserve"] != "1" {
				t.Fatal("unrelated label disappeared")
			}
			event := e.events.history[0].event
			if event.Actor.ID != id || event.Actor.Attributes["ci"] != "yes" || !matchesDockerEvent(event, map[string][]string{"image": {dest}, "event": {"tag"}}) {
				t.Fatalf("tag event = %+v", event)
			}
		})
	}
}

func TestDockerTagDestination(t *testing.T) {
	for _, x := range []struct{ repo, tag, want string }{
		{"abc", "", "docker.io/library/abc:latest"}, {"localhost:4000/x:old", "new", "localhost:4000/x:new"},
		{"lower:old", "", "docker.io/library/lower:old"}, {"", "v1", ""}, {"sha256", "latest", ""},
		{"a", "_bad space", ""}, {"x@sha256:" + strings.Repeat("a", 64), "v1", ""},
	} {
		got, err := destinationImageTag(x.repo, x.tag)
		if x.want == "" {
			if err == nil {
				t.Errorf("accepted %s %s", x.repo, x.tag)
			}
		} else if err != nil || got.String() != x.want {
			t.Errorf("destination %s %s = %v %v", x.repo, x.tag, got, err)
		}
	}
}

func TestDockerImageTagSourceIdentityAndConvergence(t *testing.T) {
	configID := "sha256:" + strings.Repeat("a", 64)
	index := &types.Descriptor{Digest: "sha256:" + strings.Repeat("b", 64), MediaType: "application/vnd.oci.image.index.v1+json"}
	manifest := &types.Descriptor{Digest: "sha256:" + strings.Repeat("c", 64), MediaType: "application/vnd.oci.image.manifest.v1+json"}
	const source = "docker.io/library/face"
	const dest = "docker.io/library/target:checked"
	for _, tc := range []struct {
		name                        string
		proven, transient, deadline bool
		want                        int
	}{
		{"hex repository preserves multi-platform index", true, false, false, 201},
		{"stale CRI source refuses mutation", false, false, false, 409},
		{"temporary CRI lag retries", true, true, false, 201},
		{"deadline after mutation reports convergence", true, false, true, 503},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeImageMetadata{t: t, refs: map[string]*images.Image{
				source + ":latest": {Name: source + ":latest", Target: index},
				configID:           {Name: configID, Target: manifest},
			}}
			criIndex := &tagCRI{sourceID: configID, target: dest, blockUntilDone: tc.deadline}
			if tc.proven {
				criIndex.repoDigests = []string{source + "@" + index.Digest}
			}
			if tc.transient {
				criIndex.transientReads = 1
			}
			e := &dockerEngine{node: node{images: criIndex, imageStore: store}}
			req := httptest.NewRequest(http.MethodPost, "/images/face/tag?repo=target&tag=checked", nil)
			if tc.deadline {
				ctx, cancel := context.WithTimeout(req.Context(), 25*time.Millisecond)
				defer cancel()
				req = req.WithContext(ctx)
			}
			w := httptest.NewRecorder()
			err := e.images(w, req, "face/tag")
			code := w.Code
			if err != nil {
				var problem apiError
				if !errors.As(err, &problem) {
					t.Fatalf("non-API failure: %v", err)
				}
				code = problem.code
			}
			if code != tc.want {
				t.Fatalf("HTTP %d, error %v", code, err)
			}
			if tc.want == 409 {
				if store.refs[dest] != nil || e.events.next != 0 {
					t.Fatal("stale lookup changed an image or emitted a tag event")
				}
				return
			}
			if got := store.refs[dest].GetTarget(); got != index {
				t.Fatalf("tag target = %v, want original index", got)
			}
			if tc.deadline && e.events.next != 0 {
				t.Fatal("unconfirmed tag published a success event")
			}
		})
	}
}

func TestDockerImageTagAcceptsResolvedFullTarget(t *testing.T) {
	const dest = "docker.io/library/target:checked"
	configID := "sha256:" + strings.Repeat("a", 64)
	digest := "sha256:" + strings.Repeat("b", 64)
	index := &types.Descriptor{Digest: digest, Size: 100, MediaType: "application/vnd.oci.image.index.v1+json"}
	for _, ref := range []string{digest, strings.TrimPrefix(digest, "sha256:")} {
		t.Run(ref, func(t *testing.T) {
			store := &fakeImageMetadata{t: t, refs: map[string]*images.Image{
				configID: {Name: configID, Target: index, Labels: map[string]string{criManagedImage: "managed"}},
			}}
			engine := &dockerEngine{node: node{imageStore: store, images: &tagCRI{sourceID: configID, target: dest}}}
			w := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/v1.47/images/"+ref+"/tag?repo=target&tag=checked", nil)
			if err := engine.images(w, req, ref+"/tag"); err != nil || w.Code != http.StatusCreated || store.refs[dest].GetTarget() != index {
				t.Fatalf("tag by index digest returned %d %s, error %v, target %v", w.Code, w.Body, err, store.refs[dest].GetTarget())
			}
		})
	}
}

func TestDockerImageTagDoesNotUseRetargetedFullDigest(t *testing.T) {
	configID := "sha256:" + strings.Repeat("a", 64)
	digest := "sha256:" + strings.Repeat("b", 64)
	store := &fakeImageMetadata{t: t, refs: map[string]*images.Image{
		configID: {Name: configID, Target: &types.Descriptor{Digest: "sha256:" + strings.Repeat("c", 64), Size: 100},
			Labels: map[string]string{criManagedImage: "managed"}},
	}}
	n := node{imageStore: store}
	var problem apiError
	record, err := n.tagSourceRecord(context.Background(), digest, &cri.Image{Id: configID})
	if record != nil || !errors.As(err, &problem) || problem.code != http.StatusConflict {
		t.Fatalf("changed digest source returned %v, %v", record, err)
	}
}
