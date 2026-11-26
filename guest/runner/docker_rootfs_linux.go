package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	containers "github.com/containerd/containerd/api/services/containers/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/fieldmaskpb"
)

func (r *dockerRecord) retainsRootFS() bool {
	return !r.Config.HostConfig.AutoRemove && !r.Config.HostConfig.ReadonlyRootfs
}

func dockerRootFSContext(ctx context.Context) context.Context {
	return metadata.AppendToOutgoingContext(ctx, "containerd-namespace", dockerRuntimeNamespace)
}

func loadDockerRecord(directory, id string) (*dockerContainer, error) {
	b, err := os.ReadFile(filepath.Join(directory, id, "state"))
	if err != nil {
		return nil, err
	}
	c := &dockerContainer{changed: make(chan struct{})}
	if err := json.Unmarshal(b, &c.dockerRecord); err != nil {
		return nil, err
	}
	if c.ID != id || !fullContainerID.MatchString(id) || !dockerName.MatchString(c.Name) {
		return nil, errors.New("invalid Docker ownership record")
	}
	if root := c.RootFS; root != nil {
		knownIntent := bootIDPattern.MatchString(root.PrepareBootID)
		if !c.retainsRootFS() || (root.PrepareBootID != "" && (!knownIntent || root.Ready)) || (root.LegacyPrepare && !knownIntent) {
			return nil, errors.New("invalid writable rootfs record")
		}
	}
	if b := c.RootFSBinding; b != nil && (c.RootFS == nil || !c.RootFS.Ready || b.DockerID != id || !b.valid()) {
		return nil, errors.New("invalid Docker rootfs attachment record")
	}
	if bridge := c.BridgeGeneration; bridge != nil && (!bridge.valid() || c.NetworkID == "" ||
		(c.RootFSBinding != nil && (bridge.JobID != c.RootFSBinding.JobID || bridge.PodID != c.RootFSBinding.PodID))) {
		return nil, errors.New("invalid Docker bridge generation record")
	}
	return c, nil
}

func (b dockerRootFSBinding) valid() bool {
	return fullContainerID.MatchString(b.DockerID) && fullContainerID.MatchString(b.PodID) &&
		fullContainerID.MatchString(b.ContainerID) && jobID.MatchString(b.JobID) &&
		(bootIDPattern.MatchString(b.BootID) || (b.BootID == "" && !b.AttachAcknowledged))
}

func readGuestBootID() (string, error) {
	raw, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return "", fmt.Errorf("read guest boot ID: %w", err)
	}
	id := strings.TrimSpace(string(raw))
	if !bootIDPattern.MatchString(id) {
		return "", errors.New("invalid guest boot ID")
	}
	return id, nil
}

func (n node) rootFSContainer(ctx context.Context, b dockerRootFSBinding) (*containers.Container, error) {
	if !b.valid() {
		return nil, errors.New("invalid rootfs attachment identity")
	}
	response, err := n.containers.Get(ctx, &containers.GetContainerRequest{ID: b.ContainerID})
	if err != nil {
		return nil, err
	}
	c := response.GetContainer()
	if c.GetID() != b.ContainerID || c.GetSandbox() != b.PodID || c.GetLabels()[owner] != b.JobID ||
		c.GetSnapshotter() != dockerRootFSSnapshotter {
		return nil, errors.New("CRI container does not match the owned rootfs attachment")
	}
	return c, nil
}

func (n node) setSnapshotKey(ctx context.Context, id, key string) error {
	// Retain the disposable layer until the CRI container is removed, even
	// while its primary snapshot reference points at the durable layer.
	res, err := n.containers.Update(ctx, &containers.UpdateContainerRequest{
		Container: &containers.Container{ID: id, SnapshotKey: key, Labels: map[string]string{scratchSnapshotReference: id}},
		// Containerd's metadata service names this field "snapshotkey".
		UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"snapshotkey", "labels." + scratchSnapshotReference}},
	})
	if err != nil {
		return err
	}
	if updated := res.GetContainer(); updated.GetID() != id || updated.GetSnapshotKey() != key || updated.GetLabels()[scratchSnapshotReference] != id {
		return errors.New("containerd returned an unexpected rootfs attachment")
	}
	return nil
}

func (s *dockerEngine) bindDockerRootFS(ctx context.Context, c *dockerContainer, pod ownedPod, id string) (*dockerRootFSBinding, error) {
	ctx = dockerRootFSContext(ctx)
	bootID, err := readGuestBootID()
	if err != nil {
		return nil, err
	}
	binding := &dockerRootFSBinding{DockerID: c.ID, JobID: pod.id, PodID: pod.pod, ContainerID: id, BootID: bootID}
	runtime, err := s.node.rootFSContainer(ctx, *binding)
	if err != nil {
		return nil, fmt.Errorf("read CRI rootfs identity: %w", err)
	}
	if runtime.GetSnapshotKey() != id {
		return nil, errors.New("CRI container has an unexpected scratch snapshot")
	}
	res, err := s.node.snapshots.Stat(ctx, &snapshots.StatSnapshotRequest{Snapshotter: dockerRootFSSnapshotter, Key: id})
	if err != nil {
		return nil, fmt.Errorf("read CRI scratch snapshot: %w", err)
	}
	scratch := res.GetInfo()
	if scratch.GetName() != id || scratch.GetKind() != snapshots.Kind_ACTIVE || scratch.GetLabels()[dockerRootFSOwner] != "" {
		return nil, errors.New("CRI scratch snapshot differs from the expected active layer")
	}

	s.mu.Lock()
	root := dockerRootFS{Parent: scratch.GetParent()}
	first := c.RootFS == nil
	if !first {
		root = *c.RootFS
	}
	s.mu.Unlock()
	if root.Parent != scratch.GetParent() {
		return nil, errors.New("image parent changed for the recorded writable rootfs")
	}
	savePrepare := func(pending dockerRootFS) error {
		s.mu.Lock()
		defer s.mu.Unlock()
		previous := c.RootFS
		c.RootFS = &pending
		if err := c.save(); err != nil {
			c.RootFS = previous
			return err
		}
		return nil
	}
	if err := root.ensure(ctx, s.node.snapshots, c.ID, bootID, first, savePrepare); err != nil {
		return nil, err
	}

	// Save the ready layer and the cleanup plan in one durable write before
	// containerd can attach the layer to a task or remove it during cleanup.
	s.mu.Lock()
	c.RootFS = &dockerRootFS{Parent: root.Parent, Ready: true}
	err = saveRootFSBinding(c, binding)
	s.mu.Unlock()
	if err != nil {
		return binding, fmt.Errorf("record writable rootfs attachment: %w", err)
	}
	if err := s.node.setSnapshotKey(ctx, id, dockerRootFSKey(c.ID)); err != nil {
		return binding, fmt.Errorf("attach writable rootfs: %w", err)
	}
	// Containerd commits the update before replying. Save that acknowledgement
	// before starting the task or allowing cleanup on this boot.
	acknowledged := *binding
	acknowledged.AttachAcknowledged = true
	s.mu.Lock()
	err = saveRootFSBinding(c, &acknowledged)
	s.mu.Unlock()
	if err != nil {
		return binding, fmt.Errorf("record writable rootfs attachment acknowledgement: %w", err)
	}
	return &acknowledged, nil
}

// CRI uses the live key both when it builds the task's mount request and
// when it removes a container. Restore the scratch key without disturbing the
// already mounted rootfs. The durable binding still fences another writer.
func (n node) detachDockerRootFS(ctx context.Context, b dockerRootFSBinding) error {
	ctx = dockerRootFSContext(ctx)
	runtime, err := n.rootFSContainer(ctx, b)
	if status.Code(err) == codes.NotFound {
		return nil
	}
	if err != nil {
		return err
	}
	switch runtime.GetSnapshotKey() {
	case b.ContainerID:
		return nil
	case dockerRootFSKey(b.DockerID):
		return n.setSnapshotKey(ctx, b.ContainerID, b.ContainerID)
	default:
		return errors.New("refusing to change an unrelated CRI snapshot key")
	}
}

func (n node) verifyRootFSCleanup(ctx context.Context, b dockerRootFSBinding) error {
	_, err := n.containers.Get(dockerRootFSContext(ctx), &containers.GetContainerRequest{ID: b.ContainerID})
	if status.Code(err) == codes.NotFound {
		return nil
	}
	if err != nil {
		return err
	}
	return errors.New("CRI container remains after rootfs cleanup")
}

func saveRootFSBinding(c *dockerContainer, binding *dockerRootFSBinding) error {
	previous := c.RootFSBinding
	c.RootFSBinding = binding
	if err := c.save(); err != nil {
		c.RootFSBinding = previous
		return err
	}
	return nil
}

func (n node) recoverDockerRootFSBinding(ctx context.Context, c *dockerContainer) error {
	b := c.RootFSBinding
	if b == nil {
		return nil
	}
	if b.BootID == "" {
		var err error
		b, err = n.recoverLegacyRootFSBinding(ctx, c, *b)
		if err != nil {
			return err
		}
	}
	if err := n.cleanupDockerRootFSBinding(ctx, *b, true); err != nil {
		return err
	}
	return saveRootFSBinding(c, nil)
}

func (n node) recoverLegacyRootFSBinding(ctx context.Context, c *dockerContainer, b dockerRootFSBinding) (*dockerRootFSBinding, error) {
	bootID, err := readGuestBootID()
	if err != nil {
		return nil, err
	}
	b.BootID = bootID
	runtime, err := n.rootFSContainer(dockerRootFSContext(ctx), b)
	if err != nil && status.Code(err) != codes.NotFound {
		return nil, err
	}
	// A missing container can't receive an update. The durable key or the
	// scratch reference proves that the legacy attachment already committed.
	if status.Code(err) == codes.NotFound || runtime.GetSnapshotKey() == dockerRootFSKey(b.DockerID) ||
		(runtime.GetSnapshotKey() == b.ContainerID && runtime.GetLabels()[scratchSnapshotReference] == b.ContainerID) {
		b.AttachAcknowledged = true
		return &b, nil
	}
	if runtime.GetSnapshotKey() != b.ContainerID {
		return nil, errors.New("refusing to change an unrelated CRI snapshot key")
	}
	if err := saveRootFSBinding(c, &b); err != nil {
		return nil, err
	}
	return nil, errUnconfirmedRootFSAttach
}

func (n node) cleanupDockerRootFSBinding(ctx context.Context, b dockerRootFSBinding, needsDetach bool) error {
	// A lost attach reply can leave a containerd Bolt write in flight. An
	// earlier scratch-key read cannot fence that write from CRI removal.
	if !b.AttachAcknowledged {
		bootID, err := readGuestBootID()
		if err != nil {
			return err
		}
		if err := b.checkCleanupBoot(bootID); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	if needsDetach {
		if err := n.detachDockerRootFS(ctx, b); err != nil {
			return fmt.Errorf("detach writable rootfs before removing its pod: %w", err)
		}
	}
	if err := n.remove(ctx, b.JobID); err != nil {
		return err
	}
	return n.verifyRootFSCleanup(ctx, b)
}

// The job reaper runs before the Docker socket opens. Detach retained snapshots
// before it removes CRI pods, including a pod whose job directory was lost.
func (n node) recoverDockerRootFSBindings(ctx context.Context) error {
	dir := filepath.Join(engineRoot, "containers")
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !entry.IsDir() || !fullContainerID.MatchString(entry.Name()) {
			continue
		}
		c, err := loadDockerRecord(dir, entry.Name())
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if err := n.recoverDockerRootFSBinding(ctx, c); err != nil {
			return fmt.Errorf("recover Docker container %s: %w", c.ID, err)
		}
	}
	return nil
}

func (s *dockerEngine) reclaimDockerRootFS(ctx context.Context, c *dockerContainer, retired string) error {
	if c.RootFSBinding != nil {
		return errors.New("cannot reclaim an attached writable rootfs")
	}
	if root := c.RootFS; root != nil {
		ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
		defer cancel()
		var bootID string
		if !root.Ready {
			var err error
			bootID, err = readGuestBootID()
			if err != nil {
				return err
			}
		}
		savePrepare := func(pending dockerRootFS) error {
			record := c.dockerRecord
			record.RootFS = &pending
			return record.saveIn(retired)
		}
		if err := root.remove(dockerRootFSContext(ctx), s.node.snapshots, c.ID, bootID, savePrepare); err != nil {
			return fmt.Errorf("remove writable rootfs: %w", err)
		}
	}
	return os.RemoveAll(retired)
}
