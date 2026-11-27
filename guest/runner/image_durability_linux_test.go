package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	contentapi "github.com/containerd/containerd/api/services/content/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"github.com/containerd/containerd/api/types"
	control "github.com/moby/buildkit/api/services/control"
	"github.com/opencontainers/go-digest"
	"github.com/opencontainers/image-spec/identity"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// The package's tests never sync or record the real image store: every test
// that reaches imageSync does so against a scratch root, and those that care
// observe it (observeImageSync).
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "image-store-")
	if err != nil {
		panic(err)
	}
	imageStoreRoot = dir
	imageSyncPath = filepath.Join(dir, "image-sync")
	buildkitPrunePath = filepath.Join(dir, "buildkit-prune")
	buildkitRoot = filepath.Join(dir, "no-buildkit")
	syncFilesystem = func(*os.File) error { return nil }
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// observeImageSync replaces imageSync with one that logs each sync into
// steps and fails with err.
func observeImageSync(t *testing.T, steps *[]string, err error) {
	t.Helper()
	old := imageSync
	t.Cleanup(func() { imageSync = old })
	var mu sync.Mutex
	imageSync = newImageSyncer(func() error {
		mu.Lock()
		*steps = append(*steps, "sync")
		mu.Unlock()
		return err
	})
}

// A sync writes everything out first and only then records, durably, the
// time it began: written before, a journal commit the sync started early
// could carry the record ahead of the allocations its later writeback made.
func TestImageSyncRecordsWhenItBeganOnlyAfterTheSync(t *testing.T) {
	dir := t.TempDir()
	oldRoot, oldPath, oldSync, oldNow, oldSyncDir := imageStoreRoot, imageSyncPath, syncFilesystem, imageSyncNow, syncRecordDir
	t.Cleanup(func() {
		imageStoreRoot, imageSyncPath, syncFilesystem, imageSyncNow, syncRecordDir = oldRoot, oldPath, oldSync, oldNow, oldSyncDir
	})
	imageStoreRoot, imageSyncPath = dir, filepath.Join(dir, "engine", "image-sync")
	if err := os.Mkdir(filepath.Dir(imageSyncPath), 0700); err != nil {
		t.Fatal(err)
	}
	began := time.Unix(1_800_000_000, 123)
	imageSyncNow = func() time.Time { return began }
	var steps []string
	syncFilesystem = func(f *os.File) error {
		if f.Name() != dir {
			t.Fatalf("synced %s, want the image store's root %s", f.Name(), dir)
		}
		_, err := os.Stat(imageSyncPath)
		steps = append(steps, fmt.Sprintf("syncfs (record present: %v)", err == nil))
		return nil
	}
	syncs := imageSyncs.Load()
	if err := syncImageStore(); err != nil {
		t.Fatal(err)
	}
	rec, err := readImageSyncRecord()
	if err != nil {
		t.Fatal(err)
	}
	if len(steps) != 1 || steps[0] != "syncfs (record present: false)" {
		t.Fatalf("steps %q, want one syncfs before any record", steps)
	}
	if rec.DurableBefore != began.UnixNano() || rec.Boot != currentBootID() {
		t.Fatalf("record %+v, want the sync's start %d and this boot", rec, began.UnixNano())
	}
	if imageSyncs.Load() != syncs+1 {
		t.Fatal("the sync was not counted")
	}
	// A failed sync records nothing and says so.
	if err := os.Remove(imageSyncPath); err != nil {
		t.Fatal(err)
	}
	syncFilesystem = func(*os.File) error { return errors.New("EIO") }
	if err := syncImageStore(); err == nil || !strings.Contains(err.Error(), "EIO") {
		t.Fatalf("a failed syncfs answered %v", err)
	}
	if _, err := os.Stat(imageSyncPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a failed sync left a record: %v", err)
	}
}

// One sync serves every caller that arrived before it began; a caller that
// finds one running cannot use it (it may have begun before the caller's
// commit) and gets the next one.
func TestImageSyncServesCallersThatArrivedBeforeItBegan(t *testing.T) {
	var runs atomic.Int32
	release := make(chan struct{})
	entered := make(chan struct{}, 4)
	s := newImageSyncer(func() error {
		n := runs.Add(1)
		if n == 1 {
			entered <- struct{}{}
			<-release
		}
		return nil
	})
	done := make(chan error, 4)
	go func() { done <- s.Sync() }()
	<-entered
	// Three callers arrive while the first sync runs: they need a later one.
	for range 3 {
		go func() { done <- s.Sync() }()
	}
	time.Sleep(50 * time.Millisecond)
	if got := runs.Load(); got != 1 {
		t.Fatalf("%d syncs ran while the first was still running", got)
	}
	close(release)
	for range 4 {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
	if got := runs.Load(); got != 2 {
		t.Fatalf("%d syncs ran, want 2: the first, then one for the three that waited", got)
	}
	failed := newImageSyncer(func() error { return errors.New("EIO") })
	if err := failed.Sync(); err == nil {
		t.Fatal("a failed sync answered nil")
	}
}

type pullFixture struct {
	cri.ImageServiceClient
	steps *[]string
}

func (f pullFixture) PullImage(_ context.Context, req *cri.PullImageRequest, _ ...grpc.CallOption) (*cri.PullImageResponse, error) {
	*f.steps = append(*f.steps, "pull "+req.GetImage().GetImage())
	return &cri.PullImageResponse{ImageRef: "sha256:" + strings.Repeat("a", 64)}, nil
}

// A pull answers only once what CRI unpacked is on the disk, and a sync that
// fails fails the pull.
func TestPullAnswersAfterTheImageStoreSync(t *testing.T) {
	var steps []string
	observeImageSync(t, &steps, nil)
	s := &dockerEngine{node: node{images: pullFixture{steps: &steps}}}
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/images/create?fromImage=busybox&tag=1.36", nil)
	if err := s.images(w, r, "create"); err != nil {
		t.Fatal(err)
	}
	if w.Code != 200 || !slices.Equal(steps, []string{"pull busybox:1.36", "sync"}) {
		t.Fatalf("answered %d after %q, want the pull, then the sync", w.Code, steps)
	}
	steps = nil
	observeImageSync(t, &steps, errors.New("EIO"))
	w = httptest.NewRecorder()
	if err := s.images(w, httptest.NewRequest(http.MethodPost, "/images/create?fromImage=busybox&tag=1.36", nil), "create"); err == nil || w.Body.Len() != 0 {
		t.Fatalf("a pull whose sync failed answered %d %q (%v)", w.Code, w.Body.String(), err)
	}
}

// A load answers only once what ctr imported and unpacked is on the disk.
func TestLoadAnswersAfterTheImageStoreSync(t *testing.T) {
	var steps []string
	observeImageSync(t, &steps, nil)
	dir := t.TempDir()
	fake := filepath.Join(dir, "ctr")
	marker := filepath.Join(dir, "imported")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\ncat >/dev/null\necho unpacked > "+marker+"\n"), 0755); err != nil {
		t.Fatal(err)
	}
	old := ctrPath
	t.Cleanup(func() { ctrPath = old })
	ctrPath = fake
	observeImageSync(t, &steps, nil)
	imageSync = newImageSyncer(func() error {
		_, err := os.Stat(marker)
		steps = append(steps, fmt.Sprintf("sync (imported: %v)", err == nil))
		return nil
	})
	w := httptest.NewRecorder()
	if err := importImages(w, httptest.NewRequest(http.MethodPost, "/images/load", strings.NewReader("archive"))); err != nil {
		t.Fatal(err)
	}
	if w.Code != 200 || !slices.Equal(steps, []string{"sync (imported: true)"}) {
		t.Fatalf("answered %d after %q, want the import, then the sync", w.Code, steps)
	}
	imageSync = newImageSyncer(func() error { return errors.New("EIO") })
	w = httptest.NewRecorder()
	if err := importImages(w, httptest.NewRequest(http.MethodPost, "/images/load", strings.NewReader("archive"))); err == nil || w.Body.Len() != 0 {
		t.Fatalf("a load whose sync failed answered %d %q (%v)", w.Code, w.Body.String(), err)
	}
}

// A scheduler job's own pull is synced before the job uses it: the next job
// of that image skips the pull.
func TestJobImagePullIsSyncedBeforeItIsUsed(t *testing.T) {
	var steps []string
	observeImageSync(t, &steps, nil)
	n := node{images: jobPullFixture{pullFixture{steps: &steps}}}
	if _, hit, err := n.image(context.Background(), "busybox:1.36"); err != nil || hit {
		t.Fatalf("image: hit %v, %v", hit, err)
	}
	if !slices.Equal(steps, []string{"pull busybox:1.36", "sync"}) {
		t.Fatalf("steps %q, want the pull, then the sync", steps)
	}
}

type jobPullFixture struct{ pullFixture }

func (jobPullFixture) ImageStatus(context.Context, *cri.ImageStatusRequest, ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	return &cri.ImageStatusResponse{}, nil
}

// A build's Solve answers once what it stored is on the disk; a sync that
// fails fails the Solve, and a failed Solve syncs nothing.
func TestBuildSolveAnswersAfterTheImageStoreSync(t *testing.T) {
	var steps []string
	observeImageSync(t, &steps, nil)
	solver := dockerBuildSolver{backend: &recordingBuildkitSolver{}}
	if _, err := solver.Solve(context.Background(), &control.SolveRequest{}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(steps, []string{"sync"}) {
		t.Fatalf("steps %q, want one sync before the answer", steps)
	}
	steps = nil
	observeImageSync(t, &steps, errors.New("EIO"))
	if _, err := solver.Solve(context.Background(), &control.SolveRequest{}); status.Code(err) != codes.Unavailable {
		t.Fatalf("a Solve whose sync failed answered %v", err)
	}
	steps = nil
	observeImageSync(t, &steps, nil)
	if _, err := (dockerBuildSolver{backend: failingBuildkitSolver{}}).Solve(context.Background(), &control.SolveRequest{}); err == nil || len(steps) != 0 {
		t.Fatalf("a failed Solve: %v, steps %q", err, steps)
	}
}

type failingBuildkitSolver struct{ control.ControlClient }

func (failingBuildkitSolver) Solve(context.Context, *control.SolveRequest, ...grpc.CallOption) (*control.SolveResponse, error) {
	return nil, status.Error(codes.Internal, "build failed")
}

// --- recovery -------------------------------------------------------------

type storeFixture struct {
	snaps    []*snapshots.Info
	removed  []string
	blobs    map[string][]byte // present files
	infos    []*contentapi.Info
	deleted  []string
	imgs     []*images.Image
	imgGone  []string
	listings int
	// pruneAt is buildkitPrunePath's IDs when the first snapshot went.
	pruneAt []string
}

func (f *storeFixture) List(context.Context, *snapshots.ListSnapshotsRequest, ...grpc.CallOption) (snapshots.Snapshots_ListClient, error) {
	return &snapList{items: [][]*snapshots.Info{f.snaps}}, nil
}

func (f *storeFixture) Remove(_ context.Context, req *snapshots.RemoveSnapshotRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	for _, s := range f.snaps {
		if s.GetParent() == req.GetKey() && !slices.Contains(f.removed, s.GetName()) {
			return nil, status.Errorf(codes.FailedPrecondition, "cannot remove %s: %s is its child", req.GetKey(), s.GetName())
		}
	}
	if len(f.removed) == 0 {
		f.pruneAt = readBuildKitPrune().IDs
	}
	f.removed = append(f.removed, req.GetKey())
	return &emptypb.Empty{}, nil
}

type snapList struct {
	snapshots.Snapshots_ListClient
	items [][]*snapshots.Info
}

func (s *snapList) Recv() (*snapshots.ListSnapshotsResponse, error) {
	if len(s.items) == 0 {
		return nil, io.EOF
	}
	r := &snapshots.ListSnapshotsResponse{Info: s.items[0]}
	s.items = s.items[1:]
	return r, nil
}

type storeContent struct {
	contentapi.ContentClient
	f *storeFixture
}

func (c storeContent) List(context.Context, *contentapi.ListContentRequest, ...grpc.CallOption) (contentapi.Content_ListClient, error) {
	return &contentList{items: c.f.infos}, nil
}

func (c storeContent) Read(_ context.Context, req *contentapi.ReadContentRequest, _ ...grpc.CallOption) (contentapi.Content_ReadClient, error) {
	data, ok := c.f.blobs[req.GetDigest()]
	if !ok || slices.Contains(c.f.deleted, req.GetDigest()) {
		return &errStream{err: status.Error(codes.NotFound, "no such file")}, nil
	}
	if req.GetSize() > 0 {
		end := min(req.GetOffset()+req.GetSize(), int64(len(data)))
		if req.GetOffset() >= int64(len(data)) {
			return &errStream{err: status.Error(codes.OutOfRange, "past the end")}, nil
		}
		data = data[req.GetOffset():end]
	}
	return &healthContentStream{data: data}, nil
}

func (c storeContent) Delete(_ context.Context, req *contentapi.DeleteContentRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	c.f.deleted = append(c.f.deleted, req.GetDigest())
	return &emptypb.Empty{}, nil
}

type errStream struct {
	contentapi.Content_ReadClient
	err error
}

func (s *errStream) Recv() (*contentapi.ReadContentResponse, error) { return nil, s.err }

type contentList struct {
	contentapi.Content_ListClient
	items []*contentapi.Info
	done  bool
}

func (s *contentList) Recv() (*contentapi.ListContentResponse, error) {
	if s.done {
		return nil, io.EOF
	}
	s.done = true
	return &contentapi.ListContentResponse{Info: s.items}, nil
}

type storeImages struct {
	imageMetadataClient
	f *storeFixture
}

func (s storeImages) List(context.Context, *images.ListImagesRequest, ...grpc.CallOption) (*images.ListImagesResponse, error) {
	s.f.listings++
	return &images.ListImagesResponse{Images: s.f.imgs}, nil
}

func (s storeImages) Delete(_ context.Context, req *images.DeleteImageRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	s.f.imgGone = append(s.f.imgGone, req.GetName())
	return &emptypb.Empty{}, nil
}

// fixtureImage adds a one-platform image of layers (their diff IDs) to f, its
// blobs committed at when, and returns its chain IDs.
func (f *storeFixture) fixtureImage(name string, when time.Time, layers ...string) (*images.Image, []string) {
	return f.fixtureImageFor(name, "arm64", when, layers...)
}

// fixtureImageFor is fixtureImage for an image of another architecture.
func (f *storeFixture) fixtureImageFor(name, arch string, when time.Time, layers ...string) (*images.Image, []string) {
	var diffs []digest.Digest
	for _, l := range layers {
		diffs = append(diffs, digest.FromString(l))
	}
	config, _ := json.Marshal(map[string]any{"architecture": arch, "os": "linux", "rootfs": map[string]any{"type": "layers", "diff_ids": diffs}})
	cd := digest.FromBytes(config)
	manifest, _ := json.Marshal(map[string]any{"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
		"config": map[string]any{"mediaType": "application/vnd.oci.image.config.v1+json", "digest": cd, "size": len(config)},
		"layers": []map[string]any{{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": digest.FromString("blob of " + name), "size": 1}}})
	md := digest.FromBytes(manifest)
	f.blobs[cd.String()], f.blobs[md.String()] = config, manifest
	for _, d := range []string{cd.String(), md.String()} {
		f.infos = append(f.infos, &contentapi.Info{Digest: d, Size: int64(len(f.blobs[d])), CreatedAt: timestamppb.New(when)})
	}
	img := &images.Image{Name: name, Target: &types.Descriptor{MediaType: "application/vnd.oci.image.manifest.v1+json", Digest: md.String(), Size: int64(len(manifest))},
		CreatedAt: timestamppb.New(when), UpdatedAt: timestamppb.New(when)}
	f.imgs = append(f.imgs, img)
	var chains []string
	for _, c := range identity.ChainIDs(diffs) {
		chains = append(chains, c.String())
	}
	return img, chains
}

func committed(name, parent string, at time.Time) *snapshots.Info {
	return &snapshots.Info{Name: name, Parent: parent, Kind: snapshots.Kind_COMMITTED, CreatedAt: timestamppb.New(at)}
}

func active(name, parent string, at time.Time) *snapshots.Info {
	return &snapshots.Info{Name: name, Parent: parent, Kind: snapshots.Kind_ACTIVE, CreatedAt: timestamppb.New(at)}
}

// After an unclean stop, recovery removes the snapshots committed after the
// last sync and everything above them (children first), the blob records
// whose files are gone, and every image that names any of it or that was
// written since and names a layer that is not there; what was committed
// before the sync stays, whatever uses it.
func TestDiscardUndurableImagesRemovesWhatTheLastSyncDidNotCover(t *testing.T) {
	t.Cleanup(func() { os.Remove(buildkitPrunePath) })
	since := time.Unix(1_800_000_000, 0)
	before, after := since.Add(-time.Minute), since.Add(time.Second)
	f := &storeFixture{blobs: map[string][]byte{}}
	old, oldChain := f.fixtureImage("docker.io/library/old:1", before, "base")
	_ = old
	pulled, pulledChain := f.fixtureImage("docker.io/library/pulled:1", after, "base", "new layer")
	pause, pauseChain := f.fixtureImage("registry.k8s.io/pause:3.10", after, "pause layer")
	pause.Labels = map[string]string{criPinnedLabel: "pinned"}
	loaded, loadedChain := f.fixtureImage("docker.io/library/loaded:1", after, "never unpacked")
	tagged, _ := f.fixtureImage("docker.io/library/tagged:1", after, "base") // a new tag of a durable layer
	lost, _ := f.fixtureImage("docker.io/library/lost:1", before, "lost layer")
	_ = tagged
	_ = loadedChain
	// lost:1's manifest blob lost its rename: its record is newer than the sync.
	for _, info := range f.infos {
		if info.GetDigest() == lost.GetTarget().GetDigest() {
			info.CreatedAt = timestamppb.New(after)
			delete(f.blobs, info.GetDigest())
		}
	}
	buildkitID := "abcdefghijklmnopqrstuvwxy"
	f.snaps = []*snapshots.Info{
		committed(oldChain[0], "", before),
		active("mp-rootfs-"+strings.Repeat("1", 64), oldChain[0], after), // a container on a durable image
		committed(pulledChain[1], oldChain[0], after),
		active(strings.Repeat("2", 64), pulledChain[1], after), // a container on the undurable layer
		committed(buildkitID, pulledChain[1], after),
		committed(pauseChain[0], "", after),
		active("extract-1-"+pauseChain[0], pauseChain[0], after),
	}
	c := imageStoreClients{snapshots: f, content: storeContent{f: f}, images: storeImages{f: f}}
	report, err := c.discardUndurableImages(context.Background(), since)
	if err != nil {
		t.Fatal(err)
	}
	wantSnaps := []string{pauseChain[0] + "", "extract-1-" + pauseChain[0], pulledChain[1], strings.Repeat("2", 64), buildkitID}
	slices.Sort(wantSnaps)
	got := slices.Clone(f.removed)
	slices.Sort(got)
	if !slices.Equal(got, wantSnaps) {
		t.Fatalf("removed snapshots %q, want %q", f.removed, wantSnaps)
	}
	for i, name := range f.removed {
		for _, kid := range f.removed[i+1:] {
			for _, s := range f.snaps {
				if s.GetName() == kid && s.GetParent() == name {
					t.Fatalf("removed %s before its child %s", name, kid)
				}
			}
		}
	}
	if !slices.Equal(f.deleted, []string{lost.GetTarget().GetDigest()}) || !slices.Equal(report.Blobs, f.deleted) {
		t.Fatalf("deleted blobs %q (report %q), want only lost:1's missing manifest", f.deleted, report.Blobs)
	}
	wantImages := []string{pulled.GetName(), pause.GetName(), loaded.GetName(), lost.GetName()}
	slices.Sort(wantImages)
	gotImages := slices.Clone(f.imgGone)
	slices.Sort(gotImages)
	if !slices.Equal(gotImages, wantImages) {
		t.Fatalf("removed images %q, want %q (old:1 and the new tag of its durable layer stay)", f.imgGone, wantImages)
	}
	if !slices.Equal(report.Pinned, []string{pause.GetName()}) {
		t.Fatalf("pinned images to pull again %q, want the sandbox image", report.Pinned)
	}
	if !slices.Equal(report.BuildKit, []string{buildkitID}) || !slices.Equal(f.pruneAt, []string{buildkitID}) {
		t.Fatalf("BuildKit records %q (on disk before the first removal: %q), want %s named before its snapshot went", report.BuildKit, f.pruneAt, buildkitID)
	}
}

// Nothing committed since the last sync: no image is even looked at.
func TestDiscardUndurableImagesLeavesASyncedStoreAlone(t *testing.T) {
	since := time.Unix(1_800_000_000, 0)
	before := since.Add(-time.Second)
	f := &storeFixture{blobs: map[string][]byte{}}
	_, chain := f.fixtureImage("docker.io/library/old:1", before, "base")
	f.snaps = []*snapshots.Info{committed(chain[0], "", before), active("x", chain[0], since.Add(time.Second))}
	c := imageStoreClients{snapshots: f, content: storeContent{f: f}, images: storeImages{f: f}}
	report, err := c.discardUndurableImages(context.Background(), since)
	if err != nil {
		t.Fatal(err)
	}
	if !report.empty() || len(f.removed)+len(f.deleted)+len(f.imgGone) != 0 {
		t.Fatalf("a synced store lost %q %q %q", f.removed, f.deleted, f.imgGone)
	}
}

// Recovery runs only after an unclean stop of the boot that wrote the record:
// not after a clean one, not without a record, not twice in one boot.
func TestImageRecoveryRunsOnlyAfterAnUncleanStop(t *testing.T) {
	dir := t.TempDir()
	oldClean, oldBoot, oldPath := cleanStopPath, bootIDPath, imageSyncPath
	t.Cleanup(func() { cleanStopPath, bootIDPath, imageSyncPath = oldClean, oldBoot, oldPath })
	cleanStopPath, bootIDPath, imageSyncPath = filepath.Join(dir, "clean-stop"), filepath.Join(dir, "boot_id"), filepath.Join(dir, "image-sync")
	const previous, current = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
	if err := os.WriteFile(bootIDPath, []byte(current+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	since := time.Unix(1_800_000_000, 0)
	f := &storeFixture{blobs: map[string][]byte{}}
	_, chain := f.fixtureImage("docker.io/library/pulled:1", since.Add(time.Second), "layer")
	f.snaps = []*snapshots.Info{committed(chain[0], "", since.Add(time.Second))}
	n := node{snapStore: f, content: storeContent{f: f}, imageStore: storeImages{f: f}}
	run := func() {
		t.Helper()
		f.removed, f.imgGone = nil, nil
		if _, err := n.discardAfterUncleanStop(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	run() // no record
	if len(f.removed) != 0 {
		t.Fatal("recovery without a record removed snapshots")
	}
	for _, tc := range []struct {
		boot, clean string
		want        bool
	}{
		{previous, previous, false}, // a clean stop: everything was synced
		{current, "", false},        // this boot's own record
		{previous, "", true},        // an unclean stop
		{previous, "33333333-3333-3333-3333-333333333333\n", true},
	} {
		if err := writeImageSyncRecord(imageSyncRecord{Boot: tc.boot, DurableBefore: since.UnixNano()}); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(cleanStopPath, []byte(tc.clean), 0600); err != nil {
			t.Fatal(err)
		}
		run()
		if got := len(f.removed) > 0; got != tc.want {
			t.Fatalf("record of boot %s, clean stops %q: recovery ran %v, want %v", tc.boot, tc.clean, got, tc.want)
		}
	}
	if err := os.WriteFile(imageSyncPath, []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := n.discardAfterUncleanStop(context.Background()); err == nil {
		t.Fatal("a torn record was accepted")
	}
}

// An orderly engine stop syncs once more, so a stop guest init did not record
// as clean (no shared cache was ever attached, or the cache disk was missing)
// costs no healthy image: what nothing had synced since it was stored (CRI's
// sandbox image) is covered by the stop's own record.
func TestAnOrderlyEngineStopCoversWhatNothingHadSynced(t *testing.T) {
	dir := t.TempDir()
	oldClean, oldBoot, oldPath, oldNow, oldSync := cleanStopPath, bootIDPath, imageSyncPath, imageSyncNow, imageSync
	t.Cleanup(func() {
		cleanStopPath, bootIDPath, imageSyncPath, imageSyncNow, imageSync = oldClean, oldBoot, oldPath, oldNow, oldSync
	})
	cleanStopPath, bootIDPath, imageSyncPath = filepath.Join(dir, "clean-stop"), filepath.Join(dir, "boot_id"), filepath.Join(dir, "image-sync")
	imageSync = newImageSyncer(syncImageStore)
	const previous, current = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
	boot := func(id string) {
		t.Helper()
		if err := os.WriteFile(bootIDPath, []byte(id+"\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	// The previous boot: a pull's sync, then CRI pulls its sandbox image by
	// itself (no sync), then the engine stops in an orderly way.
	pulled := time.Unix(1_800_000_000, 0)
	boot(previous)
	imageSyncNow = func() time.Time { return pulled }
	if err := imageSync.Sync(); err != nil {
		t.Fatal(err)
	}
	f := &storeFixture{blobs: map[string][]byte{}}
	_, chain := f.fixtureImage("registry.k8s.io/pause:3.10.2", pulled.Add(time.Second), "pause")
	f.snaps = []*snapshots.Info{committed(chain[0], "", pulled.Add(time.Second))}
	n := node{snapStore: f, content: storeContent{f: f}, imageStore: storeImages{f: f}}
	imageSyncNow = func() time.Time { return pulled.Add(time.Minute) }
	syncImageStoreAtStop()
	// The next boot finds no clean-stop record at all.
	boot(current)
	if _, err := n.discardAfterUncleanStop(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(f.removed)+len(f.imgGone) != 0 {
		t.Fatalf("after an orderly engine stop recovery removed snapshots %q and images %q", f.removed, f.imgGone)
	}
	// Without the stop's sync the same store loses the image (the record
	// still says the pull's sync): the case the stop's sync is for.
	boot(previous)
	imageSyncNow = func() time.Time { return pulled }
	if err := imageSync.Sync(); err != nil {
		t.Fatal(err)
	}
	boot(current)
	if _, err := n.discardAfterUncleanStop(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(f.removed) != 1 || len(f.imgGone) != 1 {
		t.Fatalf("an unrecorded stop without the last sync kept what nothing had synced: removed %q %q", f.removed, f.imgGone)
	}
}

type pruneFixture struct {
	records []*control.UsageRecord
	filters []string
}

func (p *pruneFixture) DiskUsage(context.Context, *control.DiskUsageRequest, ...grpc.CallOption) (*control.DiskUsageResponse, error) {
	return &control.DiskUsageResponse{Record: p.records}, nil
}

func (p *pruneFixture) Prune(_ context.Context, req *control.PruneRequest, _ ...grpc.CallOption) (grpc.ServerStreamingClient[control.UsageRecord], error) {
	p.filters = req.GetFilter()
	return &usageStream{n: len(req.GetFilter())}, nil
}

type usageStream struct {
	grpc.ServerStreamingClient[control.UsageRecord]
	n int
}

func (s *usageStream) Recv() (*control.UsageRecord, error) {
	if s.n == 0 {
		return nil, io.EOF
	}
	s.n--
	return &control.UsageRecord{}, nil
}

// BuildKit prunes the records recovery named and every immutable record it
// made after the last sync, keeps cache mounts and older records, and the
// list goes only once it has.
func TestBuildKitPrunesTheRecordsMadeAfterTheLastSync(t *testing.T) {
	t.Cleanup(func() { os.Remove(buildkitPrunePath) })
	since := time.Unix(1_800_000_000, 0)
	p := &pruneFixture{records: []*control.UsageRecord{
		{ID: "made-after-the-sync-xxxxx", CreatedAt: timestamppb.New(since.Add(time.Second))},
		{ID: "older-record-xxxxxxxxxxxx", CreatedAt: timestamppb.New(since.Add(-time.Second))},
		{ID: "cache-mount-xxxxxxxxxxxxx", Mutable: true, CreatedAt: timestamppb.New(since.Add(time.Second))},
	}}
	oldDial := dialBuildKitControl
	t.Cleanup(func() { dialBuildKitControl = oldDial })
	failDial := errors.New("no buildkitd")
	dialBuildKitControl = func(context.Context) (buildkitPruner, func(), error) { return nil, nil, failDial }
	removedSnapshot := "abcdefghijklmnopqrstuvwxy"
	if err := addBuildKitPrune([]string{removedSnapshot}, since); err != nil {
		t.Fatal(err)
	}
	if err := pruneBuildKitRecords(context.Background()); !errors.Is(err, failDial) {
		t.Fatalf("prune without BuildKit: %v", err)
	}
	if l := readBuildKitPrune(); !slices.Equal(l.IDs, []string{removedSnapshot}) || l.Since != since.UnixNano() {
		t.Fatalf("the list did not survive a failed prune: %+v", l)
	}
	dialBuildKitControl = func(context.Context) (buildkitPruner, func(), error) { return p, func() {}, nil }
	if err := pruneBuildKitRecords(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []string{"id==" + removedSnapshot, "id==made-after-the-sync-xxxxx"}
	if !slices.Equal(p.filters, want) {
		t.Fatalf("pruned %q, want %q", p.filters, want)
	}
	if _, err := os.Stat(buildkitPrunePath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the list stayed after BuildKit pruned: %v", err)
	}
}

// An amd64 image pulled for emulation is unpacked like a native one, so after
// an unclean stop it is checked like one: a layer committed after the last
// sync takes the image with it, and a record written since that names a
// layer not there goes. An amd64 image from before the sync stays.
func TestDiscardUndurableImagesChecksEmulatedImagesToo(t *testing.T) {
	t.Cleanup(func() { os.Remove(buildkitPrunePath) })
	since := time.Unix(1_800_000_000, 0)
	before, after := since.Add(-time.Minute), since.Add(time.Second)
	f := &storeFixture{blobs: map[string][]byte{}}
	_, durableChain := f.fixtureImageFor("docker.io/library/old@sha256:"+strings.Repeat("1", 64), "amd64", before, "amd64 base")
	pulled, pulledChain := f.fixtureImageFor("docker.io/library/new@sha256:"+strings.Repeat("2", 64), "amd64", after, "amd64 base", "amd64 top")
	missing, _ := f.fixtureImageFor("docker.io/library/gone@sha256:"+strings.Repeat("3", 64), "amd64", after, "never unpacked amd64")
	f.snaps = []*snapshots.Info{
		committed(durableChain[0], "", before),
		committed(pulledChain[1], durableChain[0], after),
	}
	c := imageStoreClients{snapshots: f, content: storeContent{f: f}, images: storeImages{f: f}}
	if _, err := c.discardUndurableImages(context.Background(), since); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(f.removed, []string{pulledChain[1]}) {
		t.Fatalf("removed snapshots %q, want the amd64 layer committed after the sync", f.removed)
	}
	gone := slices.Clone(f.imgGone)
	slices.Sort(gone)
	want := []string{missing.GetName(), pulled.GetName()}
	slices.Sort(want)
	if !slices.Equal(gone, want) {
		t.Fatalf("removed images %q, want %q", gone, want)
	}
}
