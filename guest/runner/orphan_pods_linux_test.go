package main

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"google.golang.org/grpc"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type orphanPodRuntime struct {
	cri.RuntimeServiceClient
	pods    []*cri.PodSandbox
	removed []string
}

func (r *orphanPodRuntime) ListPodSandbox(_ context.Context, req *cri.ListPodSandboxRequest, _ ...grpc.CallOption) (*cri.ListPodSandboxResponse, error) {
	var out []*cri.PodSandbox
	for _, p := range r.pods {
		if slices.Contains(r.removed, p.GetId()) {
			continue
		}
		f := req.GetFilter()
		if f.GetId() != "" && p.GetId() != f.GetId() {
			continue
		}
		match := true
		for k, v := range f.GetLabelSelector() {
			match = match && p.GetLabels()[k] == v
		}
		if match {
			out = append(out, p)
		}
	}
	return &cri.ListPodSandboxResponse{Items: out}, nil
}

func (r *orphanPodRuntime) StopPodSandbox(context.Context, *cri.StopPodSandboxRequest, ...grpc.CallOption) (*cri.StopPodSandboxResponse, error) {
	return &cri.StopPodSandboxResponse{}, nil
}

func (r *orphanPodRuntime) RemovePodSandbox(_ context.Context, req *cri.RemovePodSandboxRequest, _ ...grpc.CallOption) (*cri.RemovePodSandboxResponse, error) {
	r.removed = append(r.removed, req.GetPodSandboxId())
	return &cri.RemovePodSandboxResponse{}, nil
}

func scheduledPod(id, pod, uid, namespace string) *cri.PodSandbox {
	return &cri.PodSandbox{Id: pod, Labels: map[string]string{owner: id}, Metadata: &cri.PodSandboxMetadata{Uid: uid, Namespace: namespace}}
}

// A pod whose job directory a crash lost (newPod makes it without a sync,
// CRI commits the pod durably) is retired by recovery like any owned pod; a
// pod another CRI client made, or one whose labels do not hold the
// scheduler's ownership, is not touched.
func TestRecoveryRetiresAScheduledPodWhoseJobDirectoryIsGone(t *testing.T) {
	if _, err := os.Stat(filepath.Join(dataRoot, "jobs")); err == nil {
		t.Skip("this machine has scheduler job directories; the test needs none")
	}
	orphan, foreign := strings.Repeat("a", 32), strings.Repeat("b", 32)
	r := &orphanPodRuntime{pods: []*cri.PodSandbox{
		scheduledPod(orphan, strings.Repeat("1", 64), orphan, "micropod-ci"),
		scheduledPod(orphan, strings.Repeat("2", 64), orphan, "micropod-ci"), // the same job: one removal retires both
		scheduledPod(foreign, strings.Repeat("3", 64), foreign, "default"),
		scheduledPod(foreign, strings.Repeat("4", 64), "someone-else", "micropod-ci"),
		{Id: strings.Repeat("5", 64), Metadata: &cri.PodSandboxMetadata{Uid: orphan, Namespace: "micropod-ci"}},
		scheduledPod("not-a-job-id", strings.Repeat("6", 64), "not-a-job-id", "micropod-ci"),
	}}
	if err := (node{runtime: r}).recover(context.Background()); err != nil {
		t.Fatal(err)
	}
	slices.Sort(r.removed)
	if want := []string{strings.Repeat("1", 64), strings.Repeat("2", 64)}; !slices.Equal(r.removed, want) {
		t.Fatalf("recovery removed %q, want only the scheduler's pods of the lost job directory %q", r.removed, want)
	}
}
