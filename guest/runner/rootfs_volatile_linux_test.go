package main

import (
	"net"
	"path/filepath"
	"strings"
	"testing"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestOnlyCrunPodsAskForAVolatilePauseLayer(t *testing.T) {
	if got := sandboxConfig(strings.Repeat("a", 32), "/jobs/a", "crun").GetAnnotations(); got[volatileSnapshotAnnotation] != "true" || len(got) != 2 {
		t.Fatalf("crun pod annotations %v", got)
	}
	if got := sandboxConfig(strings.Repeat("b", 32), "/jobs/b", "kata").GetAnnotations(); len(got) != 0 {
		t.Fatalf("an untrusted Kata pod carries annotations %v", got)
	}
}

// A container whose writable mount is on the layers' filesystem keeps a plain
// rootfs (its exit syncs that filesystem, the volume with it); read-only
// mounts and mounts of other filesystems do not count, and a mount that
// cannot be examined does.
func TestAContainerThatWritesTheLayersFilesystemKeepsItsExitSync(t *testing.T) {
	layers, volume := t.TempDir(), t.TempDir()
	defer func(old string) { imageStoreRoot = old }(imageStoreRoot)
	imageStoreRoot = layers
	mount := func(path string, readOnly bool) *cri.Mount {
		return &cri.Mount{HostPath: path, ContainerPath: "/m", Readonly: readOnly}
	}
	socket := filepath.Join(volume, "docker.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	for _, tc := range []struct {
		name   string
		mounts []*cri.Mount
		want   bool
	}{
		{"no mounts", nil, false},
		{"a socket beside the layers", []*cri.Mount{mount(socket, false)}, false},
		{"a writable volume beside the layers", []*cri.Mount{mount(volume, false)}, true},
		{"the same volume read-only", []*cri.Mount{mount(volume, true)}, false},
		{"a writable mount of another filesystem", []*cri.Mount{mount("/proc", false)}, false},
		{"another filesystem, then the volume", []*cri.Mount{mount("/proc", false), mount(volume, false)}, true},
		{"a writable mount that is not there", []*cri.Mount{mount(filepath.Join(volume, "gone"), false)}, true},
	} {
		if got := writesLayerFilesystem(tc.mounts); got != tc.want {
			t.Errorf("%s: %v, want %v", tc.name, got, tc.want)
		}
	}
	imageStoreRoot = filepath.Join(layers, "gone")
	if !writesLayerFilesystem(nil) {
		t.Error("layers that cannot be examined: the container must keep its sync")
	}
}
