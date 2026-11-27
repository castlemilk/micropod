package main

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	containers "github.com/containerd/containerd/api/services/containers/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// observeRecordIO replaces writeOut and syncRecordDir with recorders that log
// each step and what the directory holds at that moment.
func observeRecordIO(t *testing.T) *[]string {
	t.Helper()
	var steps []string
	oldOut, oldSync := writeOut, syncRecordDir
	t.Cleanup(func() { writeOut, syncRecordDir = oldOut, oldSync })
	writeOut = func(f *os.File) error {
		b, err := os.ReadFile(f.Name())
		if err != nil {
			t.Fatal(err)
		}
		steps = append(steps, "out "+filepath.Base(f.Name())+" "+string(b))
		return nil
	}
	syncRecordDir = func(dir string) error {
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		steps = append(steps, "commit "+filepath.Base(dir)+" "+strings.Join(names, ","))
		return nil
	}
	return &steps
}

// A durable record save writes its data out before the rename and commits
// once, by syncing its directory after the rename; no fsync of the file. One
// that need only be whole (an AutoRemove container's, saveVisible) writes its
// data out before the rename too, so a crash never leaves it torn or empty,
// and commits nothing.
func TestRecordSavesWriteOutBeforeRenameAndCommitOnlyWhenDurable(t *testing.T) {
	steps := observeRecordIO(t)
	dir := t.TempDir()
	commits, writes := recordCommits.Load(), recordWrites.Load()
	c := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("a", 64), Name: "kept", Phase: "created"}}
	if err := c.dockerRecord.saveIn(dir); err != nil {
		t.Fatal(err)
	}
	if len(*steps) != 2 || !strings.HasPrefix((*steps)[0], "out state.tmp {") || (*steps)[1] != "commit "+filepath.Base(dir)+" state" {
		t.Fatalf("durable save steps %q, want the data out, the rename, then one directory commit", *steps)
	}
	*steps = nil
	c.Config.HostConfig.AutoRemove = true
	c.Phase = "starting"
	if err := c.dockerRecord.saveIn(dir); err != nil {
		t.Fatal(err)
	}
	c.Config.HostConfig.AutoRemove = false
	if _, err := writeRecord(c.dockerRecord, dir, false); err != nil {
		t.Fatal(err)
	}
	if len(*steps) != 2 || !strings.HasPrefix((*steps)[0], "out state.tmp {") || !strings.HasPrefix((*steps)[1], "out state.tmp {") {
		t.Fatalf("whole-only saves %q, want each record's data out before its rename and no commit", *steps)
	}
	b, err := os.ReadFile(filepath.Join(dir, "state"))
	if err != nil || !strings.Contains(string(b), `"Phase":"starting"`) {
		t.Fatalf("record after the saves: %s (%v)", b, err)
	}
	if got := [2]int64{recordCommits.Load() - commits, recordWrites.Load() - writes}; got != [2]int64{1, 2} {
		t.Fatalf("metrics counted %d commits and %d whole-only writes, want 1 and 2", got[0], got[1])
	}
}

// observeRecordSaves replaces writeRecord: nothing reaches a disk, and each
// save is logged with its durability and the record it would have written.
type observedSave struct {
	durable bool
	record  dockerRecord
}

func observeRecordSaves(t *testing.T) *[]observedSave {
	t.Helper()
	var saves []observedSave
	old := writeRecord
	t.Cleanup(func() { writeRecord = old })
	writeRecord = func(r dockerRecord, _ string, durable bool) (bool, error) {
		if r.RootFS != nil {
			root := *r.RootFS
			r.RootFS = &root
		}
		if r.RootFSBinding != nil {
			b := *r.RootFSBinding
			r.RootFSBinding = &b
		}
		saves = append(saves, observedSave{durable, r})
		return true, nil
	}
	return &saves
}

// The start intent is durable before the process can run. With a retained
// rootfs the attachment's durable save carries it, so the intent's own save
// need only be whole; without one (a read-only rootfs) it is durable itself.
func TestDockerStartIntentIsDurableUnlessTheRootFSAttachmentCarriesIt(t *testing.T) {
	saves := observeRecordSaves(t)
	for _, tt := range []struct {
		name    string
		host    dockerHost
		durable bool
	}{
		{"retained rootfs", dockerHost{}, false},
		{"read-only rootfs", dockerHost{ReadonlyRootfs: true}, true},
		{"AutoRemove", dockerHost{AutoRemove: true}, false},
	} {
		*saves = nil
		c := &dockerContainer{dockerRecord: dockerRecord{Phase: "starting", Config: dockerConfig{HostConfig: tt.host}}}
		if err := c.saveStartIntent(); err != nil {
			t.Fatal(err)
		}
		if len(*saves) != 1 || (*saves)[0].durable != tt.durable || (*saves)[0].record.Phase != "starting" {
			t.Fatalf("%s: start intent saves %+v, want one with durable=%v", tt.name, *saves, tt.durable)
		}
	}
}

type keyedRootFSSnapshots struct{ infos map[string]*snapshots.Info }

func (s *keyedRootFSSnapshots) Stat(_ context.Context, r *snapshots.StatSnapshotRequest, _ ...grpc.CallOption) (*snapshots.StatSnapshotResponse, error) {
	if info := s.infos[r.Key]; info != nil {
		return &snapshots.StatSnapshotResponse{Info: info}, nil
	}
	return nil, status.Error(codes.NotFound, "missing snapshot")
}

func (s *keyedRootFSSnapshots) Prepare(_ context.Context, r *snapshots.PrepareSnapshotRequest, _ ...grpc.CallOption) (*snapshots.PrepareSnapshotResponse, error) {
	s.infos[r.Key] = &snapshots.Info{Name: r.Key, Kind: snapshots.Kind_ACTIVE, Parent: r.Parent, Labels: r.Labels}
	return &snapshots.PrepareSnapshotResponse{}, nil
}

func (s *keyedRootFSSnapshots) Remove(_ context.Context, r *snapshots.RemoveSnapshotRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	delete(s.infos, r.Key)
	return &emptypb.Empty{}, nil
}

// A first start's rootfs attachment writes its prepare intent and its binding
// durably, each before the containerd write it fences; the acknowledgement
// after the attach need only be whole (the boot fence covers a lost one).
func TestDockerRootFSAttachDurablyFencesContainerdAndKeepsTheAckWhole(t *testing.T) {
	boot, err := readGuestBootID()
	if err != nil {
		t.Fatal(err)
	}
	saves := observeRecordSaves(t)
	dockerID, criID := strings.Repeat("a", 64), strings.Repeat("d", 64)
	pod := ownedPod{id: strings.Repeat("b", 32), pod: strings.Repeat("c", 64)}
	parent := "sha256:" + strings.Repeat("e", 64)
	client := &rootFSRuntimeContainers{t: t, current: &containers.Container{ID: criID, Sandbox: pod.pod,
		Snapshotter: dockerRootFSSnapshotter, SnapshotKey: criID, Labels: map[string]string{owner: pod.id}}}
	snaps := &keyedRootFSSnapshots{infos: map[string]*snapshots.Info{
		criID: {Name: criID, Kind: snapshots.Kind_ACTIVE, Parent: parent}}}
	s := &dockerEngine{node: node{containers: client, snapshots: snaps}}
	c := &dockerContainer{dockerRecord: dockerRecord{ID: dockerID, Name: "kept", Phase: "starting"}, changed: make(chan struct{})}
	got, err := s.bindDockerRootFS(t.Context(), c, pod, criID)
	if err != nil {
		t.Fatal(err)
	}
	if !got.AttachAcknowledged || client.current.GetSnapshotKey() != dockerRootFSKey(dockerID) {
		t.Fatalf("attachment %+v, CRI key %s", got, client.current.GetSnapshotKey())
	}
	var shape []string
	for _, sv := range *saves {
		r := sv.record
		step := "whole"
		if sv.durable {
			step = "durable"
		}
		switch {
		case r.RootFS != nil && !r.RootFS.Ready && r.RootFS.PrepareBootID == boot && r.RootFSBinding == nil:
			step += " prepare-intent"
		case r.RootFS != nil && r.RootFS.Ready && r.RootFSBinding != nil && !r.RootFSBinding.AttachAcknowledged:
			step += " binding"
		case r.RootFS != nil && r.RootFS.Ready && r.RootFSBinding != nil && r.RootFSBinding.AttachAcknowledged:
			step += " ack"
		default:
			step += " other"
		}
		if r.Phase != "starting" {
			step += " phase=" + r.Phase
		}
		shape = append(shape, step)
	}
	if want := []string{"durable prepare-intent", "durable binding", "whole ack"}; !slices.Equal(shape, want) {
		t.Fatalf("rootfs attachment saves %q, want %q", shape, want)
	}
}

// A new named volume is durable when the create returns: its metadata is out
// on the disk before its rename, and both directories are synced after.
func TestNewVolumeIsDurableWhenCreated(t *testing.T) {
	old := volumeStore
	volumeStore = t.TempDir()
	t.Cleanup(func() { volumeStore = old })
	for _, d := range []string{"volumes", "volume-meta"} {
		if err := os.Mkdir(filepath.Join(volumeStore, d), 0755); err != nil {
			t.Fatal(err)
		}
	}
	steps := observeRecordIO(t)
	if err := ensureVolume("data", map[string]string{"k": "v"}); err != nil {
		t.Fatal(err)
	}
	if len(*steps) != 3 || !strings.HasPrefix((*steps)[0], "out data.json.tmp {") || !strings.Contains((*steps)[0], `"k":"v"`) ||
		(*steps)[1] != "commit volume-meta data.json" || (*steps)[2] != "commit volumes data" {
		t.Fatalf("volume create steps %q, want the metadata out, then both directories synced", *steps)
	}
	*steps = nil
	if err := ensureVolume("data", nil); err != nil || len(*steps) != 0 {
		t.Fatalf("an existing volume was written again: %q (%v)", *steps, err)
	}
	v, err := inspectVolume("data")
	if err != nil || v.Labels["k"] != "v" {
		t.Fatalf("volume %+v (%v)", v, err)
	}
}

// writeOut takes the commit-free path only on a journaled ext4 filesystem;
// anywhere else it is fsync. A device without a jbd2 journal is not one.
func TestWriteOutNeedsAJournal(t *testing.T) {
	if journaled(^uint64(0)) {
		t.Fatal("an unknown device counts as journaled")
	}
	f, err := os.Create(filepath.Join(t.TempDir(), "f"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString("data"); err != nil {
		t.Fatal(err)
	}
	if err := writeOut(f); err != nil {
		t.Fatal(err)
	}
}
