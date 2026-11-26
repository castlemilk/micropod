package main

import (
	"context"
	"fmt"
	"strings"
	"testing"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type importStartRuntime struct {
	cri.RuntimeServiceClient
	first error
	calls int
}

func (r *importStartRuntime) CreateContainer(_ context.Context, _ *cri.CreateContainerRequest, _ ...grpc.CallOption) (*cri.CreateContainerResponse, error) {
	r.calls++
	if r.calls == 1 && r.first != nil {
		return nil, r.first
	}
	return &cri.CreateContainerResponse{ContainerId: "created"}, nil
}

func TestDockerImportedDigestStart(t *testing.T) {
	id := "sha256:" + strings.Repeat("4", 64)
	digest := "sha256:" + strings.Repeat("5", 64)
	unqualified := "import-2026-11-25@" + digest
	qualified := "docker.io/library/" + unqualified
	target := &types.Descriptor{Digest: digest, MediaType: "application/vnd.oci.image.manifest.v1+json"}
	missing := status.Error(codes.NotFound, fmt.Sprintf("failed to get image from containerd %q: image %q: not found", id, qualified))
	for _, tc := range []struct {
		name                             string
		cause                            error
		includeRaw, advertised, idAgrees bool
		wantCalls                        int
		success                          bool
	}{
		{"normal start", nil, false, false, false, 1, true},
		{"restore actual imported alias", missing, true, true, true, 2, true},
		{"different repository", missing, false, true, true, 1, false},
		{"CRI does not advertise", missing, true, false, true, 1, false},
		{"unrelated ID descriptor", missing, true, true, false, 1, false},
		{"unrelated create failure", status.Error(codes.NotFound, "sandbox unavailable"), true, true, true, 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			primary := target
			if !tc.idAgrees {
				primary = &types.Descriptor{Digest: id}
			}
			f := &fakeImageMetadata{t: t, refs: map[string]*images.Image{
				id:                    {Name: id, Target: primary},
				"elsewhere@" + digest: {Name: "elsewhere@" + digest, Target: target},
			}}
			if tc.includeRaw {
				f.refs[unqualified] = &images.Image{Name: unqualified, Target: target}
			}
			idx := &tagCRI{sourceID: id}
			if tc.advertised {
				idx.repoDigests = []string{qualified}
			}
			run := &importStartRuntime{first: tc.cause}
			n := node{runtime: run, images: idx, imageStore: f}
			ctx := context.Background()
			req := &cri.CreateContainerRequest{Config: &cri.ContainerConfig{Image: &cri.ImageSpec{Image: id}}}
			c, err := n.createImageContainer(ctx, req)
			if (err == nil) != tc.success || run.calls != tc.wantCalls {
				t.Fatalf("result %v %v, %d calls", c, err, run.calls)
			}
			if tc.wantCalls == 2 {
				if f.refs[qualified].GetTarget() != target || f.refs[unqualified].GetTarget() != target {
					t.Fatal("matching canonical and original references were not retained")
				}
			} else if f.refs[qualified] != nil {
				t.Fatal("unrelated create mutated the image catalog")
			}
		})
	}
}
