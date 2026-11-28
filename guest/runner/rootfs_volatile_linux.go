package main

import (
	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// A container's writable layer that is discarded at its exit is mounted
// volatile.
//
// Every overlay unmount syncs the whole filesystem its upper directory is on
// (ovl_sync_fs from the shim's unmount at exit): a container that wrote
// 256 MB spent 0.16-0.62 s outside its own process, and under a burst of 32
// builds 364 such syncs summed 40-68 s, each also flushing everyone else's
// writes (profiling CONFIRMED.md §3). A volatile overlay skips that sync
// (and turns fsync inside it into a no-op), and the kernel refuses to mount
// its upper a second time.
//
// So only the writable layers that live for one mount get it: a crun pod's
// pause container (every pod is removed when its container exits; an
// untrusted Kata job's pod carries no annotation), and the
// rootfs of a container removed at its exit (AutoRemove) or with a read-only
// rootfs (nothing is written there). A container that keeps its rootfs runs
// on the engine's own snapshot instead (docker_rootfs_linux.go), mounted as
// before, so everything it wrote and synced is on the disk when its fsync
// returns. Durability lost: the content of a discarded rootfs on a machine
// crash, which no one can read afterwards (recovery removes AutoRemove
// containers and every pod).
//
// That same sync is what put a container's volume on the disk at its exit:
// a named volume is a directory of the filesystem the layers are on, so
// what a container wrote there without an fsync was durable once it had
// exited and been removed. With a volatile rootfs it stays in the page cache
// until writeback: in 5 of 5 kill trials a 48 MiB file that an exited
// `docker run --rm -v vol:/d` had written was empty after the machine's VMM
// was killed as the run answered, and whole in 5 of 5 with the sync. So a
// container with a writable mount on that filesystem (a named volume, a bind
// of a guest directory) keeps a plain rootfs, and its exit syncs as before
// (writesLayerFilesystem). A workspace bind is the Mac's filesystem, the
// cache stores are on the cache disk and sockets are on tmpfs: none of them
// was ever covered by that sync, and none of them keeps a container from a
// volatile rootfs.
//
// The engine asks with an annotation; containerd as the runner bundle builds
// it (ci/patches/containerd/0001-overlay-volatile-label.patch) turns it into
// the overlay snapshotter's label and the label into the mount option. A
// containerd without the patch ignores it.
const volatileSnapshotAnnotation = "containerd.io/snapshot/overlay.volatile"

// withVolatileRootFS adds the annotation to a pod's or container's
// annotations.
func withVolatileRootFS(annotations map[string]string) map[string]string {
	if annotations == nil {
		annotations = map[string]string{}
	}
	annotations[volatileSnapshotAnnotation] = "true"
	return annotations
}

// writesLayerFilesystem reports whether one of a container's writable mounts
// is on the filesystem that holds containerd's snapshots, which a plain
// overlay's unmount syncs and a volatile one's does not. A mount it cannot
// examine counts: the container then keeps the sync. A socket does not.
func writesLayerFilesystem(mounts []*cri.Mount) bool {
	var layers unix.Stat_t
	if err := unix.Stat(imageStoreRoot, &layers); err != nil {
		return true
	}
	for _, m := range mounts {
		if m.GetReadonly() {
			continue
		}
		var st unix.Stat_t
		if err := unix.Stat(m.GetHostPath(), &st); err != nil {
			return true
		}
		if st.Mode&unix.S_IFMT == unix.S_IFSOCK {
			continue // a socket (the Docker socket) holds no data
		}
		if st.Dev == layers.Dev {
			return true
		}
	}
	return false
}
