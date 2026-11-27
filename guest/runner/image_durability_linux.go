package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	contentapi "github.com/containerd/containerd/api/services/content/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"github.com/containerd/containerd/api/types"
	"github.com/containerd/platforms"
	control "github.com/moby/buildkit/api/services/control"
	"github.com/opencontainers/go-digest"
	"github.com/opencontainers/image-spec/identity"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// Image durability.
//
// containerd unpacks a layer by writing its files into a new snapshot's
// directory and then committing the snapshot in its bolt metadata, which bolt
// fsyncs; nothing syncs the files. They sit in the guest's page cache until
// writeback (ext4's delayed allocation and the 30 s dirty expiry: up to about
// 35 s), so a crash in that window left a committed snapshot whose files were
// empty or missing. The image was listed, every container from it failed
// ("exec format error", "no such file or directory"), and pulling it again did
// not repair it: the unpacker skips a layer whose snapshot exists. A content
// blob's rename into the store is not synced either, so the store could name a
// blob whose file was gone, which a pull would not fetch again.
//
// Two halves keep an image whole or gone:
//
//   - Before a pull, a load or a build through the Docker socket answers, and
//     after a scheduler job's pull, imageSync.Sync syncs the filesystem that
//     holds containerd's root (syncfs: every dirty page written, a journal
//     commit, the device flushed) and then records, durably, the time that
//     sync began (imageSyncRecord): everything containerd committed before
//     it is on the disk. One syncfs serves every caller waiting when it
//     begins; it covers whatever wrote the store (CRI's transfer service,
//     ctr import, BuildKit), not one pull path.
//
//   - The engine's start after an unclean stop of the boot that wrote the
//     record (guest init's clean-stop record does not name it) removes what
//     containerd committed after the recorded time: those snapshots and every
//     snapshot above them, the blobs committed since whose file is missing,
//     the image records that name any of it or that were written since and
//     name a snapshot or blob that is not there, and BuildKit's cache records
//     made since. An image is then whole or not there, and a pull fetches and
//     unpacks it again. Snapshots and blobs committed before the recorded time
//     are never touched.
//
// containerd stamps a committed snapshot and a committed blob with the guest's
// realtime clock when it commits them, after their data was written, and that
// clock does not go back within a boot: guest init steps it forward to the
// host's (at boot, every minute and after the host slept) and slews a backward
// correction (vmm/guest-init backwardSlew). So "committed at or after the sync
// began" is exactly "maybe not on the disk". The one exception is a host whose
// own clock was set back by half a second or more, which the guest follows
// with a step: a layer committed just after it can carry a time before the
// last sync's, and a crash before the next sync then keeps it unchecked.

const imageStoreSnapshotter = "overlayfs"

var (
	// imageStoreRoot is a directory on the filesystem that holds containerd's
	// root (its content store, snapshots and metadata). BuildKit's root and
	// the engine's records are on the same OS disk.
	imageStoreRoot = "/var/lib/containerd"
	// imageSyncPath is the record of the last sync (on the OS disk too).
	imageSyncPath = filepath.Join(engineRoot, "image-sync")
	// buildkitPrunePath lists BuildKit cache records recovery removed or found
	// suspect and BuildKit has not yet pruned.
	buildkitPrunePath = filepath.Join(engineRoot, "buildkit-prune")
	imageSyncNow      = time.Now
	syncFilesystem    = func(f *os.File) error { return unix.Syncfs(int(f.Fd())) }
	// imageSyncs, imageSyncUS and imageSyncFSUS count the syncs, their time
	// and the part of it the syncfs took (the rest is the record's commit),
	// for the engine's metrics.
	imageSyncs, imageSyncUS, imageSyncFSUS atomic.Int64
)

// imageSyncRecord is what imageSyncPath holds.
type imageSyncRecord struct {
	// Boot is the boot whose engine wrote the record.
	Boot string `json:"boot"`
	// DurableBefore is the guest realtime clock (Unix nanoseconds) when the
	// last sync of that boot began: everything containerd committed earlier
	// is on the disk.
	DurableBefore int64 `json:"durableBefore"`
}

// imageSyncer serialises the syncs and lets one serve every caller that
// arrived before it began.
type imageSyncer struct {
	mu      sync.Mutex
	cond    *sync.Cond
	running bool
	begun   uint64 // syncs begun
	ended   uint64 // syncs ended
	last    error  // the result of sync number ended
	run     func() error
}

func newImageSyncer(run func() error) *imageSyncer {
	s := &imageSyncer{run: run}
	s.cond = sync.NewCond(&s.mu)
	return s
}

var imageSync = newImageSyncer(syncImageStore)

// Sync returns when a sync that began after the call has ended, with its
// error: on success everything containerd committed before the call is on the
// disk and the record says so. A sync that began before the call cannot vouch
// for what was committed after it began, so a caller that finds one running
// waits for it and runs (or joins) the next one.
func (s *imageSyncer) Sync() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	need := s.begun + 1
	for s.ended < need {
		if s.running {
			s.cond.Wait()
			continue
		}
		s.running = true
		s.begun++
		n := s.begun
		s.mu.Unlock()
		err := s.run()
		s.mu.Lock()
		s.running = false
		s.ended = n
		s.last = err
		s.cond.Broadcast()
	}
	return s.last
}

// syncImageStore syncs the image store's filesystem, then records when that
// began. The record is written after the sync, with its own journal commit:
// written before, a commit that the sync started early could carry it ahead
// of the block allocations its later writeback made, and claim data that a
// crash then lost.
func syncImageStore() error {
	begin := imageSyncNow()
	f, err := os.Open(imageStoreRoot)
	if err != nil {
		return fmt.Errorf("sync the image store: %w", err)
	}
	err = syncFilesystem(f)
	f.Close()
	if err != nil {
		return fmt.Errorf("sync the image store: %w", err)
	}
	imageSyncFSUS.Add(time.Since(begin).Microseconds())
	if err := writeImageSyncRecord(imageSyncRecord{Boot: currentBootID(), DurableBefore: begin.UnixNano()}); err != nil {
		return fmt.Errorf("record the image store sync: %w", err)
	}
	imageSyncs.Add(1)
	imageSyncUS.Add(time.Since(begin).Microseconds())
	return nil
}

// syncImageStoreAtStop is the engine's last sync, as it stops in an orderly
// way: the record then covers everything containerd committed in this boot.
// Guest init does not record every clean stop (its record lives with the
// shared caches: a machine that never attached one has no directory for it,
// and a boot without its cache disk records none), and recovery treats a stop
// it did not record as unclean. Without this sync that removed healthy images
// nothing had synced since they were stored: CRI's own pull of its sandbox
// image, an image a raw BuildKit client exported.
func syncImageStoreAtStop() {
	if err := imageSync.Sync(); err != nil {
		log.Printf("sync the image store as the engine stops: %v", err)
	}
}

func writeImageSyncRecord(r imageSyncRecord) error {
	b, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return writeDurable(imageSyncPath, b)
}

// writeDurable replaces path with data: written out, renamed, the directory
// synced (one journal commit on the OS disk).
func writeDurable(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := writeFileOut(tmp, data, 0600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	return syncDir(filepath.Dir(path))
}

func readImageSyncRecord() (imageSyncRecord, error) {
	var r imageSyncRecord
	b, err := os.ReadFile(imageSyncPath)
	if err != nil {
		return r, err
	}
	if err := json.Unmarshal(b, &r); err != nil || r.DurableBefore <= 0 {
		return r, fmt.Errorf("%s is not an image sync record", imageSyncPath)
	}
	return r, nil
}

// imageStoreClients are the containerd services image recovery uses, in the
// engine's namespace.
type imageStoreClients struct {
	snapshots snapshotStore
	content   interface {
		List(context.Context, *contentapi.ListContentRequest, ...grpc.CallOption) (contentapi.Content_ListClient, error)
		Read(context.Context, *contentapi.ReadContentRequest, ...grpc.CallOption) (contentapi.Content_ReadClient, error)
		Delete(context.Context, *contentapi.DeleteContentRequest, ...grpc.CallOption) (*emptypb.Empty, error)
	}
	images imageMetadataClient
	cri    cri.ImageServiceClient
}

// snapshotStore is the part of containerd's snapshots client image recovery
// needs.
type snapshotStore interface {
	List(context.Context, *snapshots.ListSnapshotsRequest, ...grpc.CallOption) (snapshots.Snapshots_ListClient, error)
	Remove(context.Context, *snapshots.RemoveSnapshotRequest, ...grpc.CallOption) (*emptypb.Empty, error)
}

// imageRecoveryReport is what one recovery pass removed.
type imageRecoveryReport struct {
	Since     time.Time
	Blobs     []string // blob records whose file was missing
	Snapshots []string // removed snapshots, children first
	Images    []string // removed image records
	// Pinned are the tags of removed images CRI pins (its sandbox image),
	// which CRI pulls again by itself, without a sync, at the next pod.
	Pinned   []string
	BuildKit []string // BuildKit cache records left for BuildKit to prune
}

func (r imageRecoveryReport) empty() bool {
	return len(r.Blobs)+len(r.Snapshots)+len(r.Images)+len(r.BuildKit) == 0
}

// criPinnedLabel marks the images CRI pins (its sandbox image).
const criPinnedLabel = "io.cri-containerd.pinned"

// buildkitRecordID is the shape of BuildKit's cache record IDs, which name
// its snapshots (identity.NewID: 25 characters of base 36).
var buildkitRecordID = regexp.MustCompile(`^[a-z0-9]{25}$`)

// recoverImageStore runs before the Docker socket opens: after an unclean
// stop of the boot that last recorded a sync it removes what may not have
// reached the disk (discardUndurableImages); then it syncs, so what it
// removed stays removed and this boot's record starts from a synced store.
//
// It returns the pinned images it removed (CRI's sandbox image): CRI would
// pull one again by itself at the next pod, with no sync, so the caller pulls
// them again and syncs once the socket is open (repullPinnedImages). When
// BuildKit could not prune what recovery listed, buildkitOK is false: the
// list stays for the next start, and BuildKit must not serve this boot.
func (n node) recoverImageStore(ctx context.Context) (pinned []string, buildkitOK bool, err error) {
	pinned, err = n.discardAfterUncleanStop(ctx)
	if err != nil {
		return nil, false, err
	}
	if err := imageSync.Sync(); err != nil {
		return nil, false, err
	}
	if err := pruneBuildKitRecords(ctx); err != nil {
		log.Printf("BuildKit is off this boot: %v", err)
		return pinned, false, nil
	}
	return pinned, true, nil
}

func (n node) discardAfterUncleanStop(ctx context.Context) ([]string, error) {
	rec, err := readImageSyncRecord()
	switch {
	case errors.Is(err, os.ErrNotExist):
		// A new disk, or one an engine without this record used last.
		return nil, nil
	case err != nil:
		return nil, err
	case rec.Boot == "" || rec.Boot == currentBootID() || readCleanStop()[rec.Boot]:
		return nil, nil
	}
	since := time.Unix(0, rec.DurableBefore)
	c := imageStoreClients{snapshots: n.snapStore, content: n.content, images: n.imageStore, cri: n.images}
	report, err := c.discardUndurableImages(ctx, since)
	if err != nil {
		return nil, fmt.Errorf("check the image store after an unclean stop: %w", err)
	}
	logImageRecovery(report)
	// BuildKit's own records made since (a RUN step's result is a record
	// over a snapshot it never commits) are only known to BuildKit.
	if _, err := os.Stat(buildkitRoot); err == nil {
		if err := addBuildKitPrune(nil, since); err != nil {
			return nil, err
		}
	}
	return report.Pinned, nil
}

// repullPinnedImages pulls the pinned images recovery removed and syncs, in
// the background after the socket opens (a pull needs the network, which the
// engine's start must not wait for). If it fails, CRI pulls one when a pod
// needs it, and the next recovery judges that pull as any other.
func (n node) repullPinnedImages(ctx context.Context, names []string) {
	for _, name := range names {
		if _, err := n.images.PullImage(ctx, &cri.PullImageRequest{Image: &cri.ImageSpec{Image: name}}); err != nil {
			log.Printf("pull %s again after recovery removed it: %v", name, err)
			continue
		}
		if err := imageSync.Sync(); err != nil {
			log.Printf("pull %s again after recovery removed it: %v", name, err)
		}
	}
}

func logImageRecovery(r imageRecoveryReport) {
	if r.empty() {
		log.Printf("image store after an unclean stop: everything committed before %s was synced, nothing since", r.Since.UTC().Format(time.RFC3339Nano))
		return
	}
	log.Printf("image store after an unclean stop: removed what was committed after the last sync (%s): %d image records %v, %d snapshots, %d missing blobs; %d BuildKit cache records to prune",
		r.Since.UTC().Format(time.RFC3339Nano), len(r.Images), r.Images, len(r.Snapshots), len(r.Blobs), len(r.BuildKit))
}

// discardUndurableImages removes what containerd committed at or after since
// and may have lost, and every image record that names it.
func (c imageStoreClients) discardUndurableImages(ctx context.Context, since time.Time) (imageRecoveryReport, error) {
	ctx = imageMetadataContext(ctx)
	report := imageRecoveryReport{Since: since}
	after := func(t interface{ AsTime() time.Time }) bool { return t != nil && !t.AsTime().Before(since) }

	// Blobs: the data was synced before the rename, the rename was not.
	gone := map[string]bool{}
	blobs, err := c.contentInfos(ctx)
	if err != nil {
		return report, err
	}
	for _, info := range blobs {
		if info.GetCreatedAt() == nil || !after(info.GetCreatedAt()) {
			continue
		}
		ok, err := c.blobReadable(ctx, info.GetDigest(), info.GetSize())
		if err != nil {
			return report, err
		}
		if ok {
			continue
		}
		if _, err := c.content.Delete(ctx, &contentapi.DeleteContentRequest{Digest: info.GetDigest()}); err != nil && status.Code(err) != codes.NotFound {
			return report, fmt.Errorf("remove the record of missing blob %s: %w", info.GetDigest(), err)
		}
		gone[info.GetDigest()] = true
		report.Blobs = append(report.Blobs, info.GetDigest())
	}

	// Snapshots committed since, and everything above them.
	infos, err := c.snapshotInfos(ctx)
	if err != nil {
		return report, err
	}
	byName := map[string]*snapshots.Info{}
	children := map[string][]string{}
	for _, info := range infos {
		byName[info.GetName()] = info
		if p := info.GetParent(); p != "" {
			children[p] = append(children[p], info.GetName())
		}
	}
	removed := map[string]bool{}
	var order []string // children before their parent
	var visit func(name string)
	visit = func(name string) {
		if removed[name] {
			return
		}
		removed[name] = true
		kids := children[name]
		slices.Sort(kids)
		for _, kid := range kids {
			visit(kid)
		}
		order = append(order, name)
	}
	var roots []string
	for _, info := range infos {
		if info.GetKind() == snapshots.Kind_COMMITTED && after(info.GetCreatedAt()) {
			roots = append(roots, info.GetName())
		}
	}
	slices.Sort(roots)
	for _, name := range roots {
		visit(name)
	}
	for _, name := range order {
		if buildkitRecordID.MatchString(name) {
			report.BuildKit = append(report.BuildKit, name)
		}
	}
	// BuildKit learns of its records only once it runs: name them durably
	// before their snapshots go, so a crash in between still prunes them.
	if err := addBuildKitPrune(report.BuildKit, time.Time{}); err != nil {
		return report, err
	}
	for _, name := range order {
		if _, err := c.snapshots.Remove(ctx, &snapshots.RemoveSnapshotRequest{Snapshotter: imageStoreSnapshotter, Key: name}); err != nil && status.Code(err) != codes.NotFound {
			return report, fmt.Errorf("remove snapshot %s: %w", name, err)
		}
		report.Snapshots = append(report.Snapshots, name)
	}
	present := map[string]bool{}
	for name := range byName {
		if !removed[name] {
			present[name] = true
		}
	}

	// Image records.
	records, err := c.images.List(ctx, &images.ListImagesRequest{})
	if err != nil {
		return report, fmt.Errorf("list images: %w", err)
	}
	for _, img := range records.GetImages() {
		recent := after(img.GetUpdatedAt()) || after(img.GetCreatedAt())
		if len(gone)+len(removed) == 0 && !recent {
			continue
		}
		why, err := c.imageUndurable(ctx, img, gone, removed, present, recent)
		if err != nil {
			return report, err
		}
		if why == "" {
			continue
		}
		if _, err := c.images.Delete(ctx, &images.DeleteImageRequest{Name: img.GetName()}); err != nil && status.Code(err) != codes.NotFound {
			return report, fmt.Errorf("remove image %s (%s): %w", img.GetName(), why, err)
		}
		log.Printf("image store after an unclean stop: removed image %s: %s", img.GetName(), why)
		report.Images = append(report.Images, img.GetName())
		if img.GetLabels()[criPinnedLabel] == "pinned" && !strings.Contains(img.GetName(), "@") && !strings.HasPrefix(img.GetName(), "sha256:") {
			report.Pinned = append(report.Pinned, img.GetName())
		}
	}
	if err := c.awaitCRIForgets(ctx, report.Images); err != nil {
		return report, err
	}
	return report, nil
}

// imageUndurable says why img cannot be kept, "" when it can: it names a blob
// recovery found missing or a snapshot it removed, or it was written since the
// last sync and names a blob that cannot be read or a layer snapshot that is
// not there. An image with no linux/arm64 manifest has no snapshots here and
// is judged by its blobs alone.
func (c imageStoreClients) imageUndurable(ctx context.Context, img *images.Image, gone, removed, present map[string]bool, recent bool) (string, error) {
	target := img.GetTarget()
	if gone[target.GetDigest()] {
		return "its manifest's blob was lost", nil
	}
	missing := func(kind, d string, err error) (string, error) {
		if status.Code(err) == codes.NotFound || errors.Is(err, errBlobUnreadable) {
			if gone[d] || recent {
				return kind + " " + d + " is missing", nil
			}
			return "", nil
		}
		return "", err
	}
	manifestDesc := target
	if isIndexMediaType(target.GetMediaType()) {
		raw, err := c.readBlob(ctx, target)
		if err != nil {
			return missing("index", target.GetDigest(), err)
		}
		var index ocispec.Index
		if err := json.Unmarshal(raw, &index); err != nil {
			return "", nil
		}
		match := platforms.Only(platforms.MustParse("linux/arm64"))
		var pick *ocispec.Descriptor
		for i := range index.Manifests {
			m := &index.Manifests[i]
			if m.Platform != nil && match.Match(*m.Platform) && (pick == nil || match.Less(*m.Platform, *pick.Platform)) {
				pick = m
			}
		}
		if pick == nil {
			return "", nil
		}
		manifestDesc = &types.Descriptor{MediaType: pick.MediaType, Digest: pick.Digest.String(), Size: pick.Size}
		if gone[manifestDesc.Digest] {
			return "its linux/arm64 manifest's blob was lost", nil
		}
	}
	raw, err := c.readBlob(ctx, manifestDesc)
	if err != nil {
		return missing("manifest", manifestDesc.GetDigest(), err)
	}
	var manifest ocispec.Manifest
	if err := json.Unmarshal(raw, &manifest); err != nil || manifest.Config.Digest == "" {
		return "", nil
	}
	if gone[manifest.Config.Digest.String()] {
		return "its config's blob was lost", nil
	}
	for _, l := range manifest.Layers {
		if gone[l.Digest.String()] {
			return "layer blob " + l.Digest.String() + " was lost", nil
		}
	}
	raw, err = c.readBlob(ctx, &types.Descriptor{MediaType: manifest.Config.MediaType, Digest: manifest.Config.Digest.String(), Size: manifest.Config.Size})
	if err != nil {
		return missing("config", manifest.Config.Digest.String(), err)
	}
	var config ocispec.Image
	if err := json.Unmarshal(raw, &config); err != nil {
		return "", nil
	}
	// containerd's transfer service unpacks an image of any linux
	// architecture (an amd64 one pulled for emulation, or a single-platform
	// image pulled with no platform), so every linux image's layers are
	// checked; only another OS's are never unpacked here.
	if config.OS != "" && config.OS != "linux" {
		return "", nil // never unpacked here
	}
	for _, chain := range identity.ChainIDs(slices.Clone(config.RootFS.DiffIDs)) {
		name := chain.String()
		if removed[name] {
			return "layer snapshot " + name + " was committed after the last sync", nil
		}
		if recent && !present[name] {
			return "layer snapshot " + name + " is not there", nil
		}
	}
	return "", nil
}

func isIndexMediaType(t string) bool {
	return t == ocispec.MediaTypeImageIndex || t == "application/vnd.docker.distribution.manifest.list.v2+json"
}

var errBlobUnreadable = errors.New("blob unreadable")

// readBlob reads a small image blob (an index, a manifest, a config) whole and
// checks its digest.
func (c imageStoreClients) readBlob(ctx context.Context, d *types.Descriptor) ([]byte, error) {
	if d.GetSize() <= 0 || d.GetSize() > verifiedImageBlobLimit {
		return nil, errBlobUnreadable
	}
	stream, err := c.content.Read(ctx, &contentapi.ReadContentRequest{Digest: d.GetDigest()})
	if err != nil {
		return nil, err
	}
	var data []byte
	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		data = append(data, chunk.GetData()...)
		if int64(len(data)) > d.GetSize() {
			return nil, errBlobUnreadable
		}
	}
	if int64(len(data)) != d.GetSize() || digest.FromBytes(data).String() != d.GetDigest() {
		return nil, errBlobUnreadable
	}
	return data, nil
}

// blobReadable reports whether the store can read a blob's last byte: its
// file is in place, at least as long as recorded.
func (c imageStoreClients) blobReadable(ctx context.Context, d string, size int64) (bool, error) {
	req := &contentapi.ReadContentRequest{Digest: d}
	if size > 0 {
		req.Offset, req.Size = size-1, 1
	}
	stream, err := c.content.Read(ctx, req)
	if status.Code(err) == codes.NotFound {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("read blob %s: %w", d, err)
	}
	var n int
	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return n == int(min(size, 1)), nil
		}
		if status.Code(err) == codes.NotFound || status.Code(err) == codes.OutOfRange || status.Code(err) == codes.InvalidArgument {
			return false, nil
		}
		if err != nil {
			return false, fmt.Errorf("read blob %s: %w", d, err)
		}
		n += len(chunk.GetData())
	}
}

func (c imageStoreClients) contentInfos(ctx context.Context) ([]*contentapi.Info, error) {
	stream, err := c.content.List(ctx, &contentapi.ListContentRequest{})
	if err != nil {
		return nil, fmt.Errorf("list blobs: %w", err)
	}
	var out []*contentapi.Info
	for {
		r, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return out, nil
		}
		if err != nil {
			return nil, fmt.Errorf("list blobs: %w", err)
		}
		out = append(out, r.GetInfo()...)
	}
}

func (c imageStoreClients) snapshotInfos(ctx context.Context) ([]*snapshots.Info, error) {
	stream, err := c.snapshots.List(ctx, &snapshots.ListSnapshotsRequest{Snapshotter: imageStoreSnapshotter})
	if err != nil {
		return nil, fmt.Errorf("list snapshots: %w", err)
	}
	var out []*snapshots.Info
	for {
		r, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return out, nil
		}
		if err != nil {
			return nil, fmt.Errorf("list snapshots: %w", err)
		}
		out = append(out, r.GetInfo()...)
	}
}

// awaitCRIForgets waits (briefly) until CRI, which learns of image changes
// from containerd's events, no longer resolves a removed image's name, so the
// first request after the socket opens does not see it.
func (c imageStoreClients) awaitCRIForgets(ctx context.Context, names []string) error {
	if c.cri == nil {
		return nil
	}
	deadline := time.Now().Add(5 * time.Second)
	for _, name := range names {
		for {
			r, err := c.cri.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: name}})
			if err == nil && r.GetImage() == nil {
				break
			}
			if time.Now().After(deadline) {
				log.Printf("image store after an unclean stop: CRI still resolves removed image %s", name)
				return nil
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(20 * time.Millisecond):
			}
		}
	}
	return nil
}

// buildkitPruneList is what buildkitPrunePath holds: BuildKit cache records
// to prune, and the time after which every immutable record BuildKit made is
// to be pruned as well (zero: none).
type buildkitPruneList struct {
	IDs   []string `json:"ids,omitempty"`
	Since int64    `json:"since,omitempty"`
}

// addBuildKitPrune adds ids, and records made at or after since, to the
// durable list of BuildKit cache records to prune.
func addBuildKitPrune(ids []string, since time.Time) error {
	if len(ids) == 0 && since.IsZero() {
		return nil
	}
	l := readBuildKitPrune()
	for _, id := range ids {
		if !slices.Contains(l.IDs, id) {
			l.IDs = append(l.IDs, id)
		}
	}
	if !since.IsZero() && (l.Since == 0 || since.UnixNano() < l.Since) {
		l.Since = since.UnixNano()
	}
	b, err := json.Marshal(l)
	if err != nil {
		return err
	}
	return writeDurable(buildkitPrunePath, b)
}

func readBuildKitPrune() buildkitPruneList {
	var l buildkitPruneList
	b, err := os.ReadFile(buildkitPrunePath)
	if err != nil || json.Unmarshal(b, &l) != nil {
		return buildkitPruneList{}
	}
	l.IDs = slices.DeleteFunc(l.IDs, func(id string) bool { return !buildkitRecordID.MatchString(id) })
	return l
}

// buildkitPruner is what pruneBuildKitRecords needs of BuildKit's control API.
type buildkitPruner interface {
	DiskUsage(context.Context, *control.DiskUsageRequest, ...grpc.CallOption) (*control.DiskUsageResponse, error)
	Prune(context.Context, *control.PruneRequest, ...grpc.CallOption) (grpc.ServerStreamingClient[control.UsageRecord], error)
}

// buildkitRoot is buildkitd's root (buildkitd.toml).
var buildkitRoot = "/var/lib/micropod/buildkit"

// dialBuildKitControl starts buildkitd if it is not running and returns its
// control client; nil when the bundle has no BuildKit.
var dialBuildKitControl = func(ctx context.Context) (buildkitPruner, func(), error) {
	if _, err := os.Stat(buildkitBinary); errors.Is(err, os.ErrNotExist) {
		return nil, nil, nil
	}
	sharedBuildkit.setLifetime(ctx)
	conn, err := sharedBuildkit.dial(ctx)
	if err != nil {
		return nil, nil, err
	}
	conn.Close()
	cc, err := grpc.NewClient("unix://"+buildkitSocket, grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(buildkitMaxMessage)))
	if err != nil {
		return nil, nil, err
	}
	return control.NewControlClient(cc), func() { cc.Close() }, nil
}

// pruneBuildKitRecords has BuildKit drop the cache records recovery listed
// before anything can build on them: records whose snapshots recovery
// removed, and every immutable record made after the last sync of an unclean
// boot, whose files may never have reached the disk. BuildKit does not check
// an immutable record's snapshot when it loads it, and a build that reused
// one would mount a missing or broken snapshot, or compute a layer from it.
// Mutable records (cache mounts) are kept. The list goes once BuildKit has
// pruned (or when the bundle has no BuildKit), so a crash before then prunes
// at the next start.
func pruneBuildKitRecords(ctx context.Context) error {
	l := readBuildKitPrune()
	if len(l.IDs) == 0 && l.Since == 0 {
		if err := os.Remove(buildkitPrunePath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	bk, done, err := dialBuildKitControl(ctx)
	if err != nil {
		return fmt.Errorf("start BuildKit to prune the cache records recovery found: %w", err)
	}
	if bk != nil {
		defer done()
		ids := slices.Clone(l.IDs)
		if l.Since != 0 {
			du, err := bk.DiskUsage(ctx, &control.DiskUsageRequest{})
			if err != nil {
				return fmt.Errorf("list BuildKit cache records: %w", err)
			}
			since := time.Unix(0, l.Since)
			for _, r := range du.GetRecord() {
				if !r.GetMutable() && r.GetCreatedAt() != nil && !r.GetCreatedAt().AsTime().Before(since) && !slices.Contains(ids, r.GetID()) {
					ids = append(ids, r.GetID())
				}
			}
		}
		pruned := 0
		if len(ids) > 0 {
			filters := make([]string, 0, len(ids))
			for _, id := range ids {
				filters = append(filters, "id=="+id)
			}
			stream, err := bk.Prune(ctx, &control.PruneRequest{Filter: filters, All: true})
			if err != nil {
				return fmt.Errorf("prune BuildKit cache records: %w", err)
			}
			for {
				_, err := stream.Recv()
				if errors.Is(err, io.EOF) {
					break
				}
				if err != nil {
					return fmt.Errorf("prune BuildKit cache records: %w", err)
				}
				pruned++
			}
		}
		log.Printf("image store after an unclean stop: BuildKit pruned %d of %d cache records made after the last sync or over removed snapshots", pruned, len(ids))
	}
	if err := os.Remove(buildkitPrunePath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return syncDir(filepath.Dir(buildkitPrunePath))
}
