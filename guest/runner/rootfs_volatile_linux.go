package main

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
// So only the writable layers that live for one mount get it: the pod's
// pause container (every pod is removed when its container exits), and the
// rootfs of a container removed at its exit (AutoRemove) or with a read-only
// rootfs (nothing is written there). A container that keeps its rootfs runs
// on the engine's own snapshot instead (docker_rootfs_linux.go), mounted as
// before, so everything it wrote and synced is on the disk when its fsync
// returns. Durability lost: the content of a discarded rootfs on a machine
// crash, which no one can read afterwards (recovery removes AutoRemove
// containers and every pod).
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
