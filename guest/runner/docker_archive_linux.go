package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	mounttypes "github.com/containerd/containerd/api/types"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const archiveStatHeader = "X-Docker-Container-Path-Stat"
const archiveIdleTimeout = 30 * time.Second

// These descriptors stay open until CRI retires the task. A bind source can be
// renamed after start, so reopening its configured host path would copy to a
// different filesystem view from the container's.
type dockerLiveArchive struct {
	mounts map[string]*os.File
	users  sync.WaitGroup
	ctx    context.Context
	cancel context.CancelFunc
}

func newDockerLiveArchive(files []*os.File, mounts []*cri.Mount) *dockerLiveArchive {
	ctx, cancel := context.WithCancel(context.Background())
	view := &dockerLiveArchive{ctx: ctx, cancel: cancel}
	if len(files) == 0 {
		return view
	}
	view.mounts = make(map[string]*os.File, len(files))
	for _, mount := range mounts {
		if mount.HostPath == dockerMountFDPath(files[0]) {
			view.mounts[mount.ContainerPath] = files[0]
			files = files[1:]
			if len(files) == 0 {
				break
			}
		}
	}
	return view
}

func (s *dockerEngine) retireDockerArchive(c *dockerContainer) {
	s.mu.Lock()
	live := c.archive
	c.archive = nil
	s.mu.Unlock()
	if live != nil {
		live.cancel()
		live.users.Wait()
	}
}

func (s *dockerEngine) serveArchive(w http.ResponseWriter, r *http.Request, c *dockerContainer) error {
	requestPath, err := parseArchivePath(r.URL.Query().Get("path"))
	if err != nil {
		return err
	}
	preserveOwner := false
	if r.Method == http.MethodPut {
		if raw := r.URL.Query().Get("copyUIDGID"); raw != "" {
			preserveOwner, err = strconv.ParseBool(raw)
			if err != nil {
				return fail(http.StatusBadRequest, "invalid copyUIDGID value")
			}
		}
	}
	lease, err := engineLease()
	if err != nil {
		return err
	}
	defer lease.Close()
	view, closeView, err := s.openArchive(r.Context(), c, requestPath.absolute, r.Method == http.MethodPut)
	if err != nil {
		return err
	}
	defer closeView()
	return serveArchiveView(w, r, view, requestPath, preserveOwner)
}

func serveArchiveView(w http.ResponseWriter, r *http.Request, view dockerArchiveView, requestPath dockerArchivePath, preserveOwner bool) error {
	controller := http.NewResponseController(w)
	ctx := r.Context()
	if view.lifetime != nil {
		if err := view.lifetime.Err(); err != nil {
			return fail(http.StatusConflict, "the container filesystem view has closed")
		}
		var cancel context.CancelFunc
		ctx, cancel = context.WithCancel(ctx)
		unlink := context.AfterFunc(view.lifetime, cancel)
		defer unlink()
		defer cancel()
	}
	deadlinesDone := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		_ = controller.SetReadDeadline(time.Now())
		_ = controller.SetWriteDeadline(time.Now())
		close(deadlinesDone)
	})
	defer func() {
		if !stop() {
			<-deadlinesDone
		}
		_ = controller.SetReadDeadline(time.Time{})
		_ = controller.SetWriteDeadline(time.Time{})
	}()

	if r.Method == http.MethodPut {
		// The server-wide read deadline covers regular requests. Archive bodies
		// may take longer, so extend the deadline only when they make progress.
		if err := view.extract(ctx, requestPath, &archiveBody{r.Body, controller, ctx}, preserveOwner); err != nil {
			return err
		}
		w.WriteHeader(http.StatusOK)
		return nil
	}

	file, stat, resolved, err := view.stat(requestPath)
	if err != nil {
		return err
	}
	defer file.Close()
	data, err := json.Marshal(stat)
	if err != nil {
		return err
	}
	w.Header().Set(archiveStatHeader, base64.StdEncoding.EncodeToString(data))
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return nil
	}
	if !archiveReadable(stat.Mode) {
		return fail(http.StatusBadRequest, "the archive path must be a regular file, directory or symbolic link")
	}
	w.Header().Set("Content-Type", "application/x-tar")
	w.WriteHeader(http.StatusOK)
	if err := view.writeTar(ctx, &archiveResponse{w, controller, ctx}, resolved, file, stat); err != nil {
		// Once a tar response starts, reporting an error as JSON would look like
		// a successful archive to clients that already read its headers.
		panic(http.ErrAbortHandler)
	}
	return nil
}

type archiveBody struct {
	io.Reader
	*http.ResponseController
	ctx context.Context
}

func (r *archiveBody) Read(p []byte) (int, error) {
	_ = r.SetReadDeadline(time.Now().Add(archiveIdleTimeout))
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.Reader.Read(p)
}

type archiveResponse struct {
	io.Writer
	*http.ResponseController
	ctx context.Context
}

func (w *archiveResponse) Write(p []byte) (int, error) {
	_ = w.SetWriteDeadline(time.Now().Add(archiveIdleTimeout))
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	return w.Writer.Write(p)
}

func archivePathContains(base, absolute string) bool {
	return base == "/" || absolute == base || strings.HasPrefix(absolute, base+"/")
}

func archiveReservedPath(absolute string) bool {
	// CRI supplies these paths outside the writable layer. Access to procfs,
	// sysfs, devices and worker-generated configuration is never archived.
	switch absolute {
	case "/etc/hosts", "/etc/hostname", "/etc/resolv.conf":
		return true
	}
	return archivePathContains("/proc", absolute) || archivePathContains("/sys", absolute) || archivePathContains("/dev", absolute)
}

func archiveMountAt(mounts []dockerMount, absolute string) dockerMount {
	var best dockerMount
	for _, mount := range mounts {
		if len(mount.Target) > len(best.Target) && archivePathContains(mount.Target, absolute) {
			best = mount
		}
	}
	return best
}

type dockerArchiveView struct {
	root       *os.File
	mount      string
	configured []dockerMount
	lifetime   context.Context
	running    bool
}

func (v dockerArchiveView) includes(absolute string) bool {
	return !archiveReservedPath(absolute) && archiveMountAt(v.configured, absolute).Target == v.mount
}

func (v dockerArchiveView) relative(absolute string) string {
	return strings.TrimPrefix(strings.TrimPrefix(absolute, v.mount), "/")
}

func (s *dockerEngine) openArchive(ctx context.Context, c *dockerContainer, absolute string, write bool) (dockerArchiveView, func(), error) {
	unlock, err := s.lockContainerLifecycle(ctx, c)
	if err != nil {
		return dockerArchiveView{}, nil, err
	}
	view, closeView, err := s.pinArchive(ctx, c, absolute, write)
	if unlock == nil {
		return view, closeView, err
	}
	if err != nil || view.running {
		// The running view is registered with the task's retirement guard.
		// Stop must be able to cancel a slow transfer before task cleanup.
		unlock()
		return view, closeView, err
	}
	return view, func() {
		defer unlock()
		closeView()
	}, nil
}

func (s *dockerEngine) pinArchive(ctx context.Context, c *dockerContainer, absolute string, write bool) (dockerArchiveView, func(), error) {
	if archiveReservedPath(absolute) {
		return dockerArchiveView{}, nil, fail(http.StatusForbidden, "the archive path is managed by the runtime")
	}
	mounts, err := c.Config.mounts() // Config is immutable after creation.
	if err != nil {
		return dockerArchiveView{}, nil, err
	}
	mount := archiveMountAt(mounts, absolute)
	if write && ((mount.Target == "" && c.Config.HostConfig.ReadonlyRootfs) || mount.ReadOnly) {
		return dockerArchiveView{}, nil, fail(http.StatusForbidden, "the archive path is on a read-only filesystem")
	}
	if mount.tmpfs != nil || c.Config.cleanupMount(mount) || privateRootless() && dockerSocketMount(mount) {
		return dockerArchiveView{}, nil, fail(http.StatusNotImplemented, "archive access to the requested mount type is unavailable")
	}

	s.mu.Lock()
	if c.removed || c.Phase == "removing" {
		s.mu.Unlock()
		return dockerArchiveView{}, nil, fail(http.StatusNotFound, "container removed")
	}
	phase, id, live, binding := c.Phase, c.RuntimeID, c.archive, c.RootFSBinding
	if phase == "running" && live != nil {
		live.users.Add(1)
	}
	s.mu.Unlock()

	view := dockerArchiveView{mount: mount.Target, configured: mounts}
	switch phase {
	case "running":
		if live == nil {
			return dockerArchiveView{}, nil, fail(http.StatusConflict, "the container filesystem is retiring")
		}
		view.lifetime = live.ctx
		view.running = true
		if mount.Target != "" {
			view.root = live.mounts[mount.Target]
			if view.root == nil {
				live.users.Done()
				return dockerArchiveView{}, nil, fail(http.StatusConflict, "the configured mount is unavailable")
			}
			return view, live.users.Done, nil
		}
		view.root, err = openLiveArchiveRoot(id)
		if err != nil {
			live.users.Done()
			return dockerArchiveView{}, nil, fmt.Errorf("open the running container filesystem: %w", err)
		}
		return view, func() { view.root.Close(); live.users.Done() }, nil
	case "created", "exited":
		if binding != nil {
			return dockerArchiveView{}, nil, fail(http.StatusConflict, "the writable filesystem has an unresolved runtime attachment")
		}
		if mount.Target != "" {
			view.root, err = s.openDockerMount(mount, false)
		} else if c.retainsRootFS() {
			view.root, err = s.openStoppedArchiveRoot(ctx, c)
		} else if c.Config.HostConfig.ReadonlyRootfs && !c.Config.HostConfig.AutoRemove {
			return s.openReadOnlyArchive(ctx, c, view)
		} else {
			return dockerArchiveView{}, nil, fail(http.StatusNotImplemented, "archive access to this stopped container filesystem is unavailable")
		}
		if err != nil {
			return dockerArchiveView{}, nil, err
		}
		return view, func() { view.root.Close() }, nil
	default:
		return dockerArchiveView{}, nil, fail(http.StatusConflict, "the container filesystem is unavailable in its current state")
	}
}

// The managed crun handler uses containerd's runc-v2 shim. Its bundle already
// holds the live overlay. Opening it avoids a second writer on the same
// overlay upperdir and keeps namespace-managed mounts out of the archive view.
func openLiveArchiveRoot(id string) (*os.File, error) {
	if !fullContainerID.MatchString(id) {
		return nil, errors.New("invalid runtime identity")
	}
	bundle := filepath.Join("/run/containerd/io.containerd.runtime.v2.task", dockerRuntimeNamespace, id)
	dir, err := unix.Open(bundle, unix.O_PATH|unix.O_CLOEXEC|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer unix.Close(dir)
	fd, err := unix.Openat(dir, "rootfs", unix.O_PATH|unix.O_CLOEXEC|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	var parent, root unix.Statx_t
	for _, entry := range []struct {
		fd   int
		stat *unix.Statx_t
	}{{dir, &parent}, {fd, &root}} {
		err = unix.Statx(entry.fd, "", unix.AT_EMPTY_PATH, unix.STATX_MNT_ID, entry.stat)
		if err != nil || entry.stat.Mask&unix.STATX_MNT_ID == 0 {
			unix.Close(fd)
			return nil, errors.New("cannot verify the runtime root mount")
		}
	}
	if root.Mnt_id == parent.Mnt_id {
		unix.Close(fd)
		return nil, errors.New("runtime root is not mounted")
	}
	return os.NewFile(uintptr(fd), "rootfs"), nil
}

type archiveSnapshotMountClient interface {
	Mounts(context.Context, *snapshots.MountsRequest, ...grpc.CallOption) (*snapshots.MountsResponse, error)
}

func (s *dockerEngine) openStoppedArchiveRoot(ctx context.Context, c *dockerContainer) (*os.File, error) {
	ctx = dockerRootFSContext(ctx)
	client, ok := s.node.snapshots.(archiveSnapshotMountClient)
	if !ok {
		return nil, errors.New("snapshot mount service is unavailable")
	}
	bootID, err := readGuestBootID()
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	record := c.RootFS
	s.mu.Unlock()
	var root dockerRootFS
	if record != nil {
		root = *record
	} else {
		s.imageMu.RLock()
		defer s.imageMu.RUnlock()
		root.Parent, err = s.node.archiveImageParent(ctx, c.ImageID)
		if err != nil {
			return nil, err
		}
	}

	if err := root.ensure(ctx, s.node.snapshots, c.ID, bootID, record == nil, func(root dockerRootFS) error {
		return s.saveArchiveRootFS(c, root)
	}); err != nil {
		return nil, err
	}
	if !root.Ready {
		if err := s.saveArchiveRootFS(c, dockerRootFS{Parent: root.Parent, Ready: true}); err != nil {
			return nil, fmt.Errorf("record archive filesystem: %w", err)
		}
	}
	res, err := client.Mounts(ctx, &snapshots.MountsRequest{Snapshotter: dockerRootFSSnapshotter, Key: dockerRootFSKey(c.ID)})
	if err != nil {
		return nil, err
	}
	file, err := mountArchiveSnapshot(res.GetMounts(), false)
	if err != nil {
		return nil, fmt.Errorf("mount the stopped container filesystem: %w", err)
	}
	return file, nil
}

func (n node) archiveImageParent(ctx context.Context, imageID string) (string, error) {
	res, err := n.dockerImageStatus(ctx, imageID, true)
	if err != nil {
		return "", err
	}
	if res.GetImage().GetId() != imageID {
		return "", fail(http.StatusConflict, "the container image is unavailable")
	}
	return archiveImageParent(res.GetInfo()["info"])
}

func archiveImageParent(raw string) (string, error) {
	var info struct{ ChainID *string }
	if err := json.Unmarshal([]byte(raw), &info); err != nil || info.ChainID == nil {
		return "", errors.New("containerd image metadata lacks a snapshot parent")
	}
	parent := *info.ChainID
	digest, ok := strings.CutPrefix(parent, "sha256:")
	if parent != "" && (!ok || !fullContainerID.MatchString(digest)) {
		return "", errors.New("containerd image metadata has an invalid snapshot parent")
	}
	return parent, nil
}

func (s *dockerEngine) saveArchiveRootFS(c *dockerContainer, root dockerRootFS) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := c.RootFS
	c.RootFS = &root
	if err := c.save(); err != nil {
		c.RootFS = previous
		return err
	}
	return nil
}

// Keep overlayfs snapshots detached from the shared mount namespace.
// A one-layer read-only view is a bind from its committed parent.
func mountArchiveSnapshot(mounts []*mounttypes.Mount, readonly bool) (*os.File, error) {
	if len(mounts) != 1 || mounts[0].GetTarget() != "" {
		return nil, errors.New("unexpected overlayfs snapshot mount layout")
	}
	m := mounts[0]
	if m.GetType() == "bind" {
		return mountArchiveBind(m, readonly)
	}
	if m.GetType() != "overlay" || m.GetSource() != "overlay" {
		return nil, errors.New("unexpected snapshot filesystem")
	}
	if readonly {
		if err := validateReadOnlyOverlay(m.GetOptions()); err != nil {
			return nil, err
		}
	}
	fsfd, err := unix.Fsopen("overlay", unix.FSOPEN_CLOEXEC)
	if err != nil {
		return nil, err
	}
	defer unix.Close(fsfd)
	for _, opt := range m.GetOptions() {
		key, value, hasValue := strings.Cut(opt, "=")
		switch {
		case key == "lowerdir" && len(value) >= 256:
			err = configureArchiveLowerLayers(fsfd, value)
		case hasValue:
			err = unix.FsconfigSetString(fsfd, key, value)
		default:
			err = unix.FsconfigSetFlag(fsfd, key)
		}
		if err != nil {
			return nil, fmt.Errorf("configure overlay option %s: %w", key, err)
		}
	}
	if err := unix.FsconfigCreate(fsfd); err != nil {
		return nil, err
	}
	attrs := unix.MOUNT_ATTR_NOSUID | unix.MOUNT_ATTR_NODEV
	if readonly {
		attrs |= unix.MOUNT_ATTR_RDONLY
	}
	fd, err := unix.Fsmount(fsfd, unix.FSMOUNT_CLOEXEC, attrs)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), "snapshot"), nil
}

func configureArchiveLowerLayers(fsfd int, value string) error {
	// FSCONFIG_SET_STRING accepts at most 256 bytes including the NUL.
	// Containerd joins absolute snapshot paths with colons, highest layer
	// first. The incremental API accepts each directory in that same order.
	for layer := range strings.SplitSeq(value, ":") {
		if !filepath.IsAbs(layer) || strings.Contains(layer, "\\") {
			return errors.New("invalid containerd lower layer path")
		}
		if err := unix.FsconfigSetString(fsfd, "lowerdir+", layer); err != nil {
			return err
		}
	}
	return nil
}

func mountArchiveBind(m *mounttypes.Mount, readonly bool) (*os.File, error) {
	mode := "rw"
	if readonly {
		mode = "ro"
	}
	options := m.GetOptions()
	if !filepath.IsAbs(m.GetSource()) || len(options) != 2 || options[0] != mode || options[1] != "rbind" {
		return nil, errors.New("unexpected snapshot bind options")
	}
	fd, err := unix.Open(m.GetSource(), unix.O_PATH|unix.O_CLOEXEC|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	if !readonly {
		return os.NewFile(uintptr(fd), "snapshot"), nil
	}
	defer unix.Close(fd)
	tree, err := unix.OpenTree(fd, "", unix.AT_EMPTY_PATH|unix.OPEN_TREE_CLONE|unix.OPEN_TREE_CLOEXEC)
	if err != nil {
		return nil, err
	}
	attr := unix.MountAttr{Attr_set: unix.MOUNT_ATTR_RDONLY | unix.MOUNT_ATTR_NOSUID | unix.MOUNT_ATTR_NODEV}
	if err := unix.MountSetattr(tree, "", unix.AT_EMPTY_PATH, &attr); err != nil {
		unix.Close(tree)
		return nil, err
	}
	return os.NewFile(uintptr(tree), "snapshot"), nil
}

func validateReadOnlyOverlay(options []string) error {
	lower := false
	for _, opt := range options {
		key, value, _ := strings.Cut(opt, "=")
		switch {
		case key == "lowerdir" && !lower && value != "":
			lower = true
		case opt == "userxattr", opt == "index=off":
		default:
			return errors.New("unexpected read-only overlay option: " + key)
		}
	}
	if !lower {
		return errors.New("read-only overlay has no lower layers")
	}
	return nil
}
