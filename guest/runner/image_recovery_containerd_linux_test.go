package main

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	contentapi "github.com/containerd/containerd/api/services/content/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	leases "github.com/containerd/containerd/api/services/leases/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// A real containerd killed inside a snapshot commit, the way a kill of the VMM
// in the middle of a build cut BuildKit's commits short (I18-01). It needs
// the bundle's containerd:
//
//	MICROPOD_TEST_CONTAINERD=/path/to/containerd go test -run CommitCutShort
//
// containerd commits in its snapshotter inside the metadata transaction. The
// snapshotter's database is on a tmpfs here (MICROPOD_TEST_SNAPSHOT_TMPFS, a
// tmpfs the caller mounted, such as docker run --tmpfs; or one the test
// mounts as root) and the metadata's on the disk, so the metadata's commit
// (two fdatasyncs) is most of the call and a kill at a random point inside it
// often lands between the two: the snapshotter has the committed snapshot,
// the metadata still has the active record over it. The test kills until
// that happens, shows that the parent then cannot be removed (the error every
// start of I18-01 failed with), and that recovery removes it. Without the
// right to mount (a container) it uses the native snapshotter: the failure is
// in containerd's metadata, whatever the snapshotter.
func TestContainerdCommitCutShortLeavesAParentRecoveryRemoves(t *testing.T) {
	bin := os.Getenv("MICROPOD_TEST_CONTAINERD")
	if bin == "" {
		t.Skip("MICROPOD_TEST_CONTAINERD names no containerd binary")
	}
	t.Cleanup(func() { os.Remove(buildkitPrunePath); os.Remove(imageKeptPath) })
	cd := startTestContainerd(t, bin)
	ctx := imageMetadataContext(context.Background())
	lctx := metadata.AppendToOutgoingContext(ctx, "containerd-lease", "build")
	if _, err := cd.leases.Create(ctx, &leases.CreateRequest{ID: "build"}); err != nil {
		t.Fatal(err)
	}
	prepare := func(key, parent string) {
		t.Helper()
		if _, err := cd.snaps.Prepare(lctx, &snapshots.PrepareSnapshotRequest{Snapshotter: imageStoreSnapshotter, Key: key, Parent: parent}); err != nil {
			t.Fatalf("prepare %s: %v", key, err)
		}
	}
	commit := func(name, key string) error {
		_, err := cd.snaps.Commit(lctx, &snapshots.CommitSnapshotRequest{Snapshotter: imageStoreSnapshotter, Name: name, Key: key})
		return err
	}
	since := time.Now()
	prepare("parent-active", "")
	if err := commit("parent", "parent-active"); err != nil {
		t.Fatal(err)
	}
	// How long a commit over the parent takes, uninterrupted.
	var took []time.Duration
	for i := range 5 {
		key, name := fmt.Sprintf("probe-%d-active", i), fmt.Sprintf("probe-%d", i)
		prepare(key, "parent")
		begin := time.Now()
		if err := commit(name, key); err != nil {
			t.Fatal(err)
		}
		took = append(took, time.Since(begin))
		if _, err := cd.snaps.Remove(ctx, &snapshots.RemoveSnapshotRequest{Snapshotter: imageStoreSnapshotter, Key: name}); err != nil {
			t.Fatal(err)
		}
	}
	slices.Sort(took)
	span := took[len(took)/2] * 3 / 2
	t.Logf("a commit takes %v (median of %v); killing at random within %v", took[len(took)/2], took, span)

	hidden := ""
	for attempt := 0; attempt < 200 && hidden == ""; attempt++ {
		key, name := fmt.Sprintf("step-%d-active", attempt), fmt.Sprintf("step-%d", attempt)
		prepare(key, "parent")
		done := make(chan error, 1)
		go func() { done <- commit(name, key) }()
		time.Sleep(time.Duration(rand.Int64N(int64(span) + 1)))
		cd.kill(t)
		<-done
		cd.start(t)
		listed := cd.list(t)
		switch {
		case listed[name]:
			cd.remove(t, name)
		case listed[key]:
			cd.remove(t, key)
		default:
			hidden = key
			t.Logf("attempt %d: the commit of %s reached the snapshotter, not the metadata", attempt, key)
		}
	}
	if hidden == "" {
		t.Fatal("no kill in 200 landed inside a commit")
	}
	// The record is there (it can be removed by key) but not listed, and its
	// parent refuses to go: the error every start of I18-01 failed with.
	_, err := cd.snaps.Remove(ctx, &snapshots.RemoveSnapshotRequest{Snapshotter: imageStoreSnapshotter, Key: "parent"})
	if status.Code(err) != codes.FailedPrecondition || !strings.Contains(err.Error(), "cannot remove snapshot with child") {
		t.Fatalf("removing the parent: %v, want cannot remove snapshot with child", err)
	}
	c := imageStoreClients{snapshots: cd.snaps, content: cd.content, images: cd.images, leases: cd.leases}
	report, err := c.discardUndurableImages(context.Background(), since, nil)
	if err != nil {
		t.Fatalf("recovery after a commit cut short: %v", err)
	}
	if !slices.Equal(report.Hidden, []string{hidden}) || !slices.Contains(report.Snapshots, "parent") || len(report.Kept) != 0 {
		t.Fatalf("recovery: hidden %q, removed %q, kept %q", report.Hidden, report.Snapshots, report.Kept)
	}
	if listed := cd.list(t); listed["parent"] {
		t.Fatal("the parent is still listed after recovery")
	}
}

type testContainerd struct {
	bin, config, sock, log string
	proc                   *exec.Cmd
	conn                   *grpc.ClientConn
	snaps                  snapshots.SnapshotsClient
	content                contentapi.ContentClient
	images                 images.ImagesClient
	leases                 leases.LeasesClient
}

func startTestContainerd(t *testing.T, bin string) *testContainerd {
	t.Helper()
	dir := t.TempDir()
	root := filepath.Join(dir, "root")
	snapRoot := os.Getenv("MICROPOD_TEST_SNAPSHOT_TMPFS")
	if snapRoot == "" {
		snapRoot = filepath.Join(root, "snapshots")
		if err := os.MkdirAll(snapRoot, 0700); err != nil {
			t.Fatal(err)
		}
		if err := syscall.Mount("tmpfs", snapRoot, "tmpfs", 0, "mode=0700"); err != nil {
			t.Skipf("mount the snapshotter's tmpfs: %v (or name one in MICROPOD_TEST_SNAPSHOT_TMPFS)", err)
		}
		t.Cleanup(func() { syscall.Unmount(snapRoot, syscall.MNT_DETACH) })
	} else {
		snapRoot = filepath.Join(snapRoot, fmt.Sprintf("snapshots-%d", time.Now().UnixNano()))
		if err := os.MkdirAll(snapRoot, 0700); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.RemoveAll(snapRoot) })
	}
	// overlayfs only where this process may mount (its plugin probes with a
	// mount at start), native elsewhere.
	snapshotter := "native"
	probe := filepath.Join(dir, "probe")
	if os.Mkdir(probe, 0700) == nil && syscall.Mount("tmpfs", probe, "tmpfs", 0, "") == nil {
		syscall.Unmount(probe, syscall.MNT_DETACH)
		snapshotter = "overlayfs"
	}
	old := imageStoreSnapshotter
	imageStoreSnapshotter = snapshotter
	t.Cleanup(func() { imageStoreSnapshotter = old })
	t.Logf("containerd %s, snapshotter %s with its database on a tmpfs at %s", bin, snapshotter, snapRoot)
	cd := &testContainerd{bin: bin, config: filepath.Join(dir, "config.toml"), sock: filepath.Join(dir, "c.sock"), log: filepath.Join(dir, "containerd.log")}
	t.Cleanup(func() {
		if cd.proc != nil {
			cd.proc.Process.Kill()
			cd.proc.Wait()
		}
		if cd.conn != nil {
			cd.conn.Close()
		}
	})
	config := fmt.Sprintf(`version = 3
root = %q
state = %q
disabled_plugins = ["io.containerd.grpc.v1.cri", "io.containerd.cri.v1.images", "io.containerd.cri.v1.runtime", "io.containerd.nri.v1.nri"]
[grpc]
  address = %q
[ttrpc]
  address = %q
[plugins."io.containerd.snapshotter.v1.%s"]
  root_path = %q
`, root, filepath.Join(dir, "state"), cd.sock, cd.sock+".ttrpc", snapshotter, snapRoot)
	if err := os.WriteFile(cd.config, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	cd.start(t)
	return cd
}

func (cd *testContainerd) start(t *testing.T) {
	t.Helper()
	os.Remove(cd.sock)
	logf, err := os.OpenFile(cd.log, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer logf.Close()
	cd.proc = exec.Command(cd.bin, "--config", cd.config)
	cd.proc.Stdout, cd.proc.Stderr = logf, logf
	if err := cd.proc.Start(); err != nil {
		t.Fatal(err)
	}
	if cd.conn == nil {
		conn, err := grpc.NewClient("unix://"+cd.sock, grpc.WithTransportCredentials(insecure.NewCredentials()))
		if err != nil {
			t.Fatal(err)
		}
		cd.conn = conn
		cd.snaps, cd.content, cd.images, cd.leases = snapshots.NewSnapshotsClient(conn), contentapi.NewContentClient(conn), images.NewImagesClient(conn), leases.NewLeasesClient(conn)
	}
	ctx := imageMetadataContext(context.Background())
	deadline := time.Now().Add(20 * time.Second)
	for {
		cctx, cancel := context.WithTimeout(ctx, time.Second)
		_, err := cd.leases.List(cctx, &leases.ListRequest{})
		cancel()
		if err == nil {
			return
		}
		if time.Now().After(deadline) {
			b, _ := os.ReadFile(cd.log)
			t.Fatalf("containerd did not answer: %v\n%s", err, b)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (cd *testContainerd) kill(t *testing.T) {
	t.Helper()
	cd.proc.Process.Kill()
	cd.proc.Wait()
	cd.proc = nil
}

func (cd *testContainerd) list(t *testing.T) map[string]bool {
	t.Helper()
	c := imageStoreClients{snapshots: cd.snaps}
	infos, err := c.snapshotInfos(imageMetadataContext(context.Background()))
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	for _, info := range infos {
		out[info.GetName()] = true
	}
	return out
}

func (cd *testContainerd) remove(t *testing.T, key string) {
	t.Helper()
	_, err := cd.snaps.Remove(imageMetadataContext(context.Background()), &snapshots.RemoveSnapshotRequest{Snapshotter: imageStoreSnapshotter, Key: key})
	if err != nil && !errors.Is(err, os.ErrNotExist) && status.Code(err) != codes.NotFound {
		t.Fatalf("remove %s: %v", key, err)
	}
}
