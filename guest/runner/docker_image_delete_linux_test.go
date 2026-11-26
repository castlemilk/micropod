package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type fakeImageMetadata struct {
	t               *testing.T
	refs            map[string]*images.Image
	retagOnDelete   *types.Descriptor
	deleteRequested *images.DeleteImageRequest
}

func (f *fakeImageMetadata) assertNamespace(ctx context.Context) {
	f.t.Helper()
	md, _ := metadata.FromOutgoingContext(ctx)
	if namespace := md.Get("containerd-namespace"); len(namespace) != 1 || namespace[0] != "k8s.io" {
		f.t.Fatalf("image request namespace = %v", namespace)
	}
}

func (f *fakeImageMetadata) Get(ctx context.Context, req *images.GetImageRequest, _ ...grpc.CallOption) (*images.GetImageResponse, error) {
	f.assertNamespace(ctx)
	if img := f.refs[req.Name]; img != nil {
		return &images.GetImageResponse{Image: img}, nil
	}
	return nil, status.Error(codes.NotFound, "tag does not exist")
}

func (f *fakeImageMetadata) List(ctx context.Context, req *images.ListImagesRequest, _ ...grpc.CallOption) (*images.ListImagesResponse, error) {
	f.assertNamespace(ctx)
	if len(req.Filters) != 1 {
		f.t.Fatalf("image reference filter = %q", req.Filters)
	}
	if filter, ok := strings.CutPrefix(req.Filters[0], "name~="); ok {
		pattern, err := strconv.Unquote(filter)
		if err != nil {
			f.t.Fatal(err)
		}
		match := regexp.MustCompile(pattern)
		result := &images.ListImagesResponse{}
		for _, img := range f.refs {
			if match.MatchString(img.GetName()) {
				result.Images = append(result.Images, img)
			}
		}
		return result, nil
	}
	if !strings.HasPrefix(req.Filters[0], "target.digest==") {
		f.t.Fatalf("image reference filter = %q", req.Filters)
	}
	digest, err := strconv.Unquote(strings.TrimPrefix(req.Filters[0], "target.digest=="))
	if err != nil {
		f.t.Fatal(err)
	}
	result := &images.ListImagesResponse{}
	for _, img := range f.refs {
		if img.GetTarget().GetDigest() == digest {
			result.Images = append(result.Images, img)
		}
	}
	return result, nil
}

func (f *fakeImageMetadata) Delete(ctx context.Context, req *images.DeleteImageRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	f.assertNamespace(ctx)
	if f.deleteRequested != nil || req.GetTarget().GetDigest() == "" || req.Sync {
		f.t.Fatalf("expected one conditional name deletion without synchronous GC, got %v", req)
	}
	f.deleteRequested = req
	if f.retagOnDelete != nil {
		f.refs[req.Name] = &images.Image{Name: req.Name, Target: f.retagOnDelete}
	}
	if img := f.refs[req.Name]; img == nil || img.Target.Digest != req.Target.Digest {
		return nil, status.Error(codes.NotFound, "tag changed")
	}
	delete(f.refs, req.Name)
	return &emptypb.Empty{}, nil
}

type cachedCRIImage struct {
	cri.ImageServiceClient
	id string
}

func (f cachedCRIImage) ImageStatus(context.Context, *cri.ImageStatusRequest, ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	return &cri.ImageStatusResponse{Image: &cri.Image{Id: f.id}}, nil
}

func TestDockerImageRemoveOnlyDeletesTheRequestedTag(t *testing.T) {
	const tag = "docker.io/library/sample:latest"
	const alias = "registry.example:5000/team/image:preserved"
	id := "sha256:" + strings.Repeat("1", 64)
	target := &types.Descriptor{Digest: "sha256:" + strings.Repeat("2", 64)}
	replacement := &types.Descriptor{Digest: "sha256:" + strings.Repeat("3", 64)}
	for _, tc := range []struct {
		name, ref, query                 string
		other, byID, retained, unrelated bool
		pinned, retag                    bool
		want                             int
	}{
		{name: "unused tag default", ref: "index.docker.io/sample", want: 200},
		{name: "alias preserves retained image", ref: "sample", other: true, retained: true, want: 200},
		{name: "unrelated container", ref: "sample", retained: true, unrelated: true, byID: true, want: 200},
		{name: "last tag of retained image", ref: "sample", retained: true, byID: true, query: "force=false", want: 409},
		{name: "forced untag preserves config ID", ref: "sample", retained: true, byID: true, query: "force=True&noprune=1", want: 200},
		{name: "force cannot drop retained data", ref: "sample", retained: true, query: "force=1", want: 409},
		{name: "concurrent retag wins", ref: "sample", retag: true, query: "force=1", want: 409},
		{name: "missing tag", ref: "sample:missing", want: 404},
		{name: "pinned image", ref: "sample", pinned: true, query: "force=1", want: 409},
		{name: "digest with incomplete local descriptor", ref: "sample@" + target.Digest, want: 409},
		{name: "missing image ID", ref: id, query: "force=1", want: 404},
		{name: "missing short image ID", ref: "abcdef", want: 404},
		{name: "unsupported variant", ref: "sample", query: "platforms=linux/arm64", want: 501},
		{name: "invalid image name", ref: "sample bad:latest", want: 400},
		{name: "invalid force option", ref: "sample", query: "force=invalid", want: 400},
	} {
		t.Run(tc.name, func(t *testing.T) {
			original := &images.Image{Name: tag, Target: target}
			if tc.pinned {
				original.Labels = map[string]string{"io.cri-containerd.pinned": "pinned"}
			}
			store := &fakeImageMetadata{t: t, refs: map[string]*images.Image{tag: original}}
			if tc.other {
				store.refs[alias] = &images.Image{Name: alias, Target: target}
			}
			if tc.byID {
				store.refs[id] = &images.Image{Name: id, Target: target}
			}
			if tc.retag {
				store.retagOnDelete = replacement
			}
			engine := &dockerEngine{node: node{imageStore: store, images: cachedCRIImage{id: id}}}
			if tc.retained {
				imageID := id
				if tc.unrelated {
					imageID = "sha256:" + strings.Repeat("4", 64)
				}
				engine.containers = map[string]*dockerContainer{"held": {dockerRecord: dockerRecord{
					ID: "held", ImageID: imageID, Phase: "exited",
				}}}
			}
			w := httptest.NewRecorder()
			r := httptest.NewRequest(http.MethodDelete, "/images?"+tc.query, nil)
			err := engine.deleteImage(w, r, tc.ref)
			if tc.want == 200 {
				var records []map[string]string
				if err != nil || w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &records) != nil ||
					len(records) != 1 || len(records[0]) != 1 || records[0]["Untagged"] != "sample:latest" {
					t.Fatalf("expected Docker untag response, got HTTP %d %s, error = %v", w.Code, w.Body, err)
				}
			} else {
				var failure apiError
				if !errors.As(err, &failure) || failure.code != tc.want {
					t.Fatalf("remove returned %v, want status %d", err, tc.want)
				}
			}
			if tc.want == 200 || tc.retag {
				if req := store.deleteRequested; req.GetName() != tag || req.GetTarget().GetDigest() != target.Digest {
					t.Fatalf("expected exact delete for original target, got %v", req)
				}
			} else if store.deleteRequested != nil || store.refs[tag] != original {
				t.Fatal("refused deletion modified the original tag")
			}
			if tc.retag && store.refs[tag].GetTarget() != replacement || tc.want == 200 && store.refs[tag] != nil {
				t.Fatalf("unexpected stored target after removal attempt %v", store.refs[tag])
			}
			if tc.other && store.refs[alias].GetTarget() != target || tc.byID && store.refs[id].GetTarget() != target {
				t.Fatal("untagging changed a retained image reference")
			}
		})
	}
}

func TestDockerImageStatusDoesNotResurrectDeletedTag(t *testing.T) {
	const name = "docker.io/library/sample:latest"
	id := "sha256:" + strings.Repeat("1", 64)
	target := &types.Descriptor{Digest: "sha256:" + strings.Repeat("2", 64)}
	store := &fakeImageMetadata{t: t, refs: map[string]*images.Image{
		name: {Name: name, Target: target},
		id:   {Name: id, Target: target},
	}}
	engine := &dockerEngine{node: node{imageStore: store, images: cachedCRIImage{id: id}}}
	ctx := context.Background()
	if img, err := engine.node.dockerImageStatus(ctx, "sample", true); err != nil || img.GetImage().GetId() != id {
		t.Fatalf("existing tag resolved to %v, %v", img, err)
	}
	if _, err := engine.removeImageTag(ctx, "sample", false); err != nil {
		t.Fatal(err)
	}
	if img, err := engine.node.dockerImageStatus(ctx, "sample", true); err != nil || img.GetImage() != nil {
		t.Fatalf("deleted tag resolved to stale CRI image %v, %v", img, err)
	}
	if img, err := engine.node.dockerImageStatus(ctx, id, true); err != nil || img.GetImage().GetId() != id {
		t.Fatalf("existing image-ID lookup returned %v, %v", img, err)
	}
}

type bareHexCRIImages struct {
	cri.ImageServiceClient
	t        *testing.T
	statuses map[string]*cri.Image
	lookups  []string
}

func (f *bareHexCRIImages) ImageStatus(_ context.Context, req *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	f.t.Helper()
	if !req.GetVerbose() {
		f.t.Fatal("image status lost verbose metadata")
	}
	ref := req.GetImage().GetImage()
	f.lookups = append(f.lookups, ref)
	return &cri.ImageStatusResponse{Image: f.statuses[ref]}, nil
}

func TestDockerImageStatusBareHex(t *testing.T) {
	const raw = "abc"
	const tag = "docker.io/library/abc:latest"
	id := "sha256:" + raw + strings.Repeat("1", 61)
	collision := "sha256:" + raw + strings.Repeat("2", 61)
	tagImage := &cri.Image{Id: "sha256:" + strings.Repeat("3", 64), RepoTags: []string{tag}}
	idImage := &cri.Image{Id: id, RepoTags: []string{"docker.io/library/other:latest"}}
	staleIDImage := &cri.Image{Id: id, RepoTags: []string{tag, "docker.io/library/other:latest"}}
	for _, tc := range []struct {
		name        string
		tagExists   bool
		idExists    bool
		ambiguous   bool
		staleTag    bool
		wantID      string
		wantLookups []string
		wantCode    int
	}{
		{name: "named record wins", tagExists: true, idExists: true, wantID: tagImage.Id, wantLookups: []string{tag}},
		{name: "short ID without named record", idExists: true, wantID: id, wantLookups: []string{id}},
		{name: "removed tag and cached but deleted ID"},
		{name: "removed tag shadows an ambiguous short ID", idExists: true, ambiguous: true, wantCode: http.StatusConflict},
		{name: "removed tag itself has the short ID", idExists: true, staleTag: true, wantID: id, wantLookups: []string{id}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeImageMetadata{t: t, refs: map[string]*images.Image{}}
			if tc.tagExists {
				store.refs[tag] = &images.Image{Name: tag}
			}
			if tc.idExists {
				store.refs[id] = &images.Image{Name: id}
			}
			if tc.ambiguous {
				store.refs[collision] = &images.Image{Name: collision}
			}
			criImages := &bareHexCRIImages{t: t, statuses: map[string]*cri.Image{tag: tagImage, raw: tagImage, id: idImage}}
			if tc.staleTag {
				criImages.statuses[id] = staleIDImage
			}
			n := node{imageStore: store, images: criImages}
			img, err := n.dockerImageStatus(context.Background(), raw, true)
			if tc.wantCode != 0 {
				var failure apiError
				if !errors.As(err, &failure) || failure.code != tc.wantCode {
					t.Fatalf("resolved image %v, error %v, want status %d", img, err, tc.wantCode)
				}
			} else if err != nil || img.GetImage().GetId() != tc.wantID {
				t.Fatalf("resolved image %v, error %v, want ID %q", img, err, tc.wantID)
			}
			if !tc.tagExists && slices.Contains(img.GetImage().GetRepoTags(), tag) {
				t.Fatal("resolved image reports the removed tag")
			}
			if !slices.Equal(criImages.lookups, tc.wantLookups) {
				t.Fatalf("CRI lookups = %v, want %v", criImages.lookups, tc.wantLookups)
			}
		})
	}
}

func TestDockerImageRemoveBareHexPrefersNamedRecord(t *testing.T) {
	const tag = "docker.io/library/abc:latest"
	id := "sha256:abc" + strings.Repeat("1", 61)
	target := &types.Descriptor{Digest: "sha256:" + strings.Repeat("2", 64)}
	idRecord := &images.Image{Name: id, Target: &types.Descriptor{Digest: "sha256:" + strings.Repeat("3", 64)}}
	store := &fakeImageMetadata{t: t, refs: map[string]*images.Image{
		tag: {Name: tag, Target: target},
		id:  idRecord,
	}}
	engine := &dockerEngine{node: node{imageStore: store}}
	ctx := context.Background()
	if untagged, err := engine.removeImageTag(ctx, "abc", false); err != nil || untagged != "abc:latest" {
		t.Fatalf("removeImageTag returned %q, %v", untagged, err)
	}
	if store.refs[tag] != nil || store.refs[id] != idRecord || store.deleteRequested.GetTarget() != target {
		t.Fatalf("untag modified the wrong records: %v", store.refs)
	}
}
