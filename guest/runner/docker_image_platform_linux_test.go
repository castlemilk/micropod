package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// Every spelling of linux/arm64 that Docker accepts selects the engine's
// platform; anything else is refused with the platform named, and a platform
// that does not parse is a bad request of its own.
func TestCheckEnginePlatform(t *testing.T) {
	for _, p := range []string{"", "linux/arm64", "linux/arm64/v8", "linux/aarch64", "LINUX/ARM64", "arm64", "aarch64", "linux"} {
		if err := checkEnginePlatform(p); err != nil {
			t.Errorf("platform %q refused: %v", p, err)
		}
	}
	for p, named := range map[string]string{
		"linux/amd64": "linux/amd64", "amd64": "linux/amd64", "linux/x86_64": "linux/amd64",
		"linux/arm/v7": "linux/arm/v7", "linux/arm64/v9": "linux/arm64/v9", "windows/arm64": "windows/arm64",
		"linux/s390x": "linux/s390x",
	} {
		err := checkEnginePlatform(p)
		var problem apiError
		if !errors.As(err, &problem) || problem.code != http.StatusBadRequest ||
			!strings.HasPrefix(problem.message, "unsupported platform "+named+": this engine runs linux/arm64 images only") {
			t.Errorf("platform %q: %v, want a 400 naming %s and linux/arm64", p, err, named)
		}
	}
	for _, p := range []string{"*", "linux/arm64/v8/extra", "linux/a b", "bogus"} {
		var problem apiError
		if err := checkEnginePlatform(p); !errors.As(err, &problem) || problem.code != http.StatusBadRequest ||
			!strings.HasPrefix(problem.message, "invalid platform ") {
			t.Errorf("platform %q: %v, want a 400 invalid platform", p, err)
		}
	}
}

type platformPullCRI struct {
	cri.ImageServiceClient
	pulls []string
	err   error
}

func (f *platformPullCRI) PullImage(_ context.Context, req *cri.PullImageRequest, _ ...grpc.CallOption) (*cri.PullImageResponse, error) {
	f.pulls = append(f.pulls, req.GetImage().GetImage())
	if f.err != nil {
		return nil, f.err
	}
	return &cri.PullImageResponse{ImageRef: "sha256:" + strings.Repeat("a", 64)}, nil
}

const indexDigest = "sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"

// A pull by index digest, by tag@digest or by tag asks CRI for the reference
// as given, whatever spelling of linux/arm64 the request names; CRI picks the
// index's linux/arm64 entry. Another platform never reaches CRI.
func TestImageCreateResolvesThePlatformBeforePulling(t *testing.T) {
	var steps []string
	observeImageSync(t, &steps, nil)
	for _, tc := range []struct {
		query, pulled string
	}{
		{"fromImage=alpine&tag=" + indexDigest, "alpine@" + indexDigest},
		{"fromImage=alpine@" + indexDigest, "alpine@" + indexDigest},
		{"fromImage=alpine:3.20@" + indexDigest, "alpine:3.20@" + indexDigest},
		{"fromImage=alpine&tag=" + indexDigest + "&platform=linux/arm64", "alpine@" + indexDigest},
		{"fromImage=alpine&tag=" + indexDigest + "&platform=linux/arm64/v8", "alpine@" + indexDigest},
		{"fromImage=alpine:3.20@" + indexDigest + "&platform=arm64", "alpine:3.20@" + indexDigest},
		{"fromImage=alpine&tag=3.20&platform=linux", "alpine:3.20"},
	} {
		images := &platformPullCRI{}
		s := &dockerEngine{node: node{images: images}}
		steps = nil
		w := httptest.NewRecorder()
		err := s.images(w, httptest.NewRequest(http.MethodPost, "/v1.47/images/create?"+tc.query, nil), "create")
		if err != nil || w.Code != http.StatusOK || !slices.Equal(images.pulls, []string{tc.pulled}) || !slices.Equal(steps, []string{"sync"}) {
			t.Errorf("%s: %v %d %s, pulled %v then %v; want %s pulled and synced", tc.query, err, w.Code, w.Body, images.pulls, steps, tc.pulled)
		}
	}
	for _, platform := range []string{"linux/amd64", "linux%2Famd64", "amd64"} {
		images := &platformPullCRI{}
		s := &dockerEngine{node: node{images: images}}
		w := httptest.NewRecorder()
		err := s.images(w, httptest.NewRequest(http.MethodPost, "/v1.47/images/create?fromImage=alpine&tag="+indexDigest+"&platform="+platform, nil), "create")
		var problem apiError
		if !errors.As(err, &problem) || problem.code != http.StatusBadRequest ||
			!strings.Contains(problem.message, "unsupported platform linux/amd64") || !strings.Contains(problem.message, "linux/arm64") ||
			len(images.pulls) != 0 || w.Body.Len() != 0 {
			t.Errorf("platform %s: %v after pulls %v; want a 400 naming both platforms and no pull", platform, err, images.pulls)
		}
	}
}

// An image with no linux/arm64 entry is Docker's 404 "no matching manifest",
// naming the image and the platform; any other pull failure is passed on.
func TestImageCreateNamesAMissingPlatform(t *testing.T) {
	var steps []string
	observeImageSync(t, &steps, nil)
	images := &platformPullCRI{err: status.Error(codes.NotFound,
		"get image config descriptor: no match for platform in manifest sha256:0d2a3e86a16d902509fb9dc0aea896f7689506be44b0ba6f12bb72252aaa276f: not found")}
	s := &dockerEngine{node: node{images: images}}
	err := s.images(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/v1.47/images/create?fromImage=amd64/alpine&tag=3.20", nil), "create")
	var problem apiError
	if !errors.As(err, &problem) || problem.code != http.StatusNotFound ||
		!strings.HasPrefix(problem.message, "no matching manifest for linux/arm64 in the manifest list entries: amd64/alpine:3.20 has no linux/arm64 image") ||
		len(steps) != 0 {
		t.Fatalf("missing platform = %v (synced %v)", err, steps)
	}
	for _, err := range []error{
		status.Error(codes.NotFound, "failed to resolve reference \"docker.io/library/nope:1\": not found"),
		status.Error(codes.Unknown, "no match for platform"),
		errors.New("no match for platform"),
	} {
		if got := pullPlatformError("nope:1", err); got != err {
			t.Errorf("pullPlatformError(%v) = %v, want the error unchanged", err, got)
		}
	}
}
