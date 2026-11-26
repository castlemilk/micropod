package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	content "github.com/containerd/containerd/api/services/content/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type inspectImageStatus struct {
	cri.ImageServiceClient
	t         *testing.T
	reference string
	response  *cri.ImageStatusResponse
	err       error
}

func (s inspectImageStatus) ImageStatus(_ context.Context, req *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	s.t.Helper()
	if req.GetImage().GetImage() != s.reference || !req.GetVerbose() {
		s.t.Fatalf("ImageStatus request = %v, want verbose lookup of %q", req, s.reference)
	}
	return s.response, s.err
}

func TestDockerImageInspectRootFS(t *testing.T) {
	const alpine = "alpine:3.23"
	const alpineTag = "docker.io/library/alpine:3.23"
	const layer = "sha256:4154419d13c4db5f2e910214abf684812a6cc507f3e8d77e793da4ce07adedfd"
	const config = `{"WorkingDir":"/","Cmd":["/bin/sh"]}`
	const created = "2026-11-24T08:07:06Z"
	rawConfig := []byte(`{"config":` + config + `}`)
	imageID := healthConfigDigest(rawConfig)
	baseLayer := "sha256:" + strings.Repeat("f", 64)
	scratchManifest := "sha256:" + strings.Repeat("2", 64)
	scratchRef := "registry.example/team/scratch@" + scratchManifest
	for _, tc := range []struct {
		name       string
		reference  string
		rootFS     string
		wantRootFS string
	}{
		{
			name: "tag", reference: alpine,
			rootFS:     `{"type":"layers","diff_ids":["` + layer + `"]}`,
			wantRootFS: `{"Type":"layers","Layers":["` + layer + `"]}`,
		},
		{
			name: "image ID keeps layer order", reference: imageID,
			rootFS:     `{"type":"layers","diff_ids":["` + baseLayer + `","` + layer + `"]}`,
			wantRootFS: `{"Type":"layers","Layers":["` + baseLayer + `","` + layer + `"]}`,
		},
		{
			name: "scratch by manifest digest", reference: scratchRef,
			rootFS: `{"type":"layers","diff_ids":[]}`, wantRootFS: `{"Type":"layers"}`,
		},
		{
			name: "scratch with nil layers", reference: imageID,
			rootFS: `{"type":"layers","diff_ids":null}`, wantRootFS: `{"Type":"layers"}`,
		},
		{name: "legacy metadata without rootfs", reference: imageID},
		{name: "invalid rootfs leaves other metadata", reference: imageID, rootFS: `{"type":"layers","diff_ids":"invalid"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			info := `{"imageSpec":{"config":` + config + `,"created":"` + created + `"`
			if tc.rootFS != "" {
				info += `,"rootfs":` + tc.rootFS
			}
			info += `}}`
			manifest := &types.Descriptor{Digest: "sha256:" + strings.Repeat("3", 64)}
			imageStore := &fakeImageMetadata{t: t, refs: map[string]*images.Image{
				alpineTag:  {Name: alpineTag, Target: manifest},
				imageID:    {Name: imageID, Target: manifest},
				scratchRef: {Name: scratchRef, Target: &types.Descriptor{Digest: scratchManifest}},
			}}
			engine := &dockerEngine{node: node{
				images: inspectImageStatus{t: t, reference: tc.reference, response: &cri.ImageStatusResponse{
					Image: &cri.Image{Id: imageID}, Info: map[string]string{"info": info},
				}},
				imageStore: imageStore,
				content: healthContentFixture{read: func(_ context.Context, req *content.ReadContentRequest) (content.Content_ReadClient, error) {
					if req.GetDigest() != imageID {
						t.Fatalf("inspect requested config %s, expected %s", req.GetDigest(), imageID)
					}
					return &healthContentStream{data: rawConfig}, nil
				}},
			}}
			response := httptest.NewRecorder()
			engine.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1.47/images/"+tc.reference+"/json", nil))
			if response.Code != http.StatusOK || imageStore.deleteRequested != nil {
				t.Fatalf("read-only inspect returned %d: %s", response.Code, response.Body)
			}
			var got map[string]json.RawMessage
			if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
				t.Fatal(err)
			}
			for key, want := range map[string]string{
				"Id": `"` + imageID + `"`, "Architecture": `"arm64"`, "Config": config,
				"Created": `"` + created + `"`, "RootFS": tc.wantRootFS,
			} {
				if string(got[key]) != want {
					t.Errorf("%s = %s, want %s", key, got[key], want)
				}
			}
		})
	}
}

func TestDockerImageInspectPreservesLookupErrors(t *testing.T) {
	for _, tc := range []struct {
		name     string
		response *cri.ImageStatusResponse
		err      error
		wantCode int
		wantBody string
	}{
		{
			name: "missing image", response: &cri.ImageStatusResponse{},
			wantCode: http.StatusNotFound, wantBody: `{"message":"No such image"}`,
		},
		{
			name: "stale tag", response: &cri.ImageStatusResponse{Image: &cri.Image{Id: "stale"}},
			wantCode: http.StatusNotFound, wantBody: `{"message":"No such image"}`,
		},
		{
			name: "CRI error", err: status.Error(codes.Unavailable, "image store offline"),
			wantCode: http.StatusInternalServerError,
			wantBody: `{"message":"rpc error: code = Unavailable desc = image store offline"}`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			engine := &dockerEngine{node: node{
				images:     inspectImageStatus{t: t, reference: "missing:tag", response: tc.response, err: tc.err},
				imageStore: &fakeImageMetadata{t: t},
			}}
			response := httptest.NewRecorder()
			engine.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1.47/images/missing:tag/json", nil))
			if response.Code != tc.wantCode || strings.TrimSpace(response.Body.String()) != tc.wantBody {
				t.Fatalf("inspect returned %d: %s, want %d: %s", response.Code, response.Body, tc.wantCode, tc.wantBody)
			}
		})
	}
}
