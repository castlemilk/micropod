package main

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"syscall"
	"time"

	contentapi "github.com/containerd/containerd/api/services/content/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"github.com/containerd/containerd/api/types"
	"github.com/containerd/platforms"
	control "github.com/moby/buildkit/api/services/control"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// GET /system/df: Docker's disk usage report in the shape API 1.44-1.51
// clients decode (`docker system df [-v]`, the SDKs' DiskUsage): LayersSize
// and the Images, Containers, Volumes and BuildCache lists. Each list is
// computed only when the `type` query names it (`container`, `image`,
// `volume`, `build-cache`; all four when it names none); an unrequested one
// is null, as Docker sends it. Sizes are measured as Docker's containerd
// image store measures them:
//
//   - an image is its present content blobs (index, manifest, config,
//     compressed layers) plus its unpacked layer snapshots; SharedSize is the
//     part other images also hold, Containers the containers made from it;
//     LayersSize counts each blob and snapshot once.
//   - a container is its writable layer (SizeRw) and that plus its image's
//     unpacked layers (SizeRootFs).
//   - a volume is the disk its files take (hard links counted once), with the
//     number of containers that mount it.
//   - the build cache is BuildKit's own records. BuildKit is asked only when
//     it runs or has state on the disk: a machine that never built does not
//     start it to report an empty cache.
//
// The report reads the stores without the engine lock except for the moments
// it lists containers and volumes, so a slow walk of a large volume never
// holds up other requests.
func init() {
	extraRoutes = append(extraRoutes, func(s *dockerEngine, w http.ResponseWriter, r *http.Request, method, path string) (bool, error) {
		if path != "system/df" || method != http.MethodGet {
			return false, nil
		}
		return true, s.systemDiskUsage(w, r)
	})
}

type dockerDiskUsage struct {
	LayersSize int64
	Images     []dockerDiskUsageImage
	Containers []dockerDiskUsageContainer
	Volumes    []dockerDiskUsageVolume
	BuildCache []dockerBuildCacheRecord
}

type dockerDiskUsageImage struct {
	ID          string `json:"Id"`
	ParentID    string `json:"ParentId"`
	RepoTags    []string
	RepoDigests []string
	Created     int64
	Size        int64
	SharedSize  int64
	Labels      map[string]string
	Containers  int64
}

type dockerDiskUsageContainer struct {
	dockerContainerListRow
	SizeRw     int64
	SizeRootFs int64
}

type dockerDiskUsageVolume struct {
	volumeInfo
	UsageData dockerVolumeUsage
}

type dockerVolumeUsage struct {
	Size     int64
	RefCount int64
}

type dockerBuildCacheRecord struct {
	ID          string
	Parents     []string `json:",omitempty"`
	Type        string
	Description string
	InUse       bool
	Shared      bool
	Size        int64
	CreatedAt   time.Time
	LastUsedAt  *time.Time
	UsageCount  int64
}

// diskUsageTypes are the `type` values Docker defines for /system/df.
var diskUsageTypes = []string{"container", "image", "volume", "build-cache"}

func (s *dockerEngine) systemDiskUsage(w http.ResponseWriter, r *http.Request) error {
	want := map[string]bool{}
	for _, t := range r.URL.Query()["type"] {
		known := false
		for _, k := range diskUsageTypes {
			known = known || t == k
		}
		if !known {
			return fail(http.StatusBadRequest, "unknown object type: "+t)
		}
		want[t] = true
	}
	if len(want) == 0 {
		for _, k := range diskUsageTypes {
			want[k] = true
		}
	}
	ctx := r.Context()
	viewer := viewerOf(ctx)
	report := dockerDiskUsage{}
	layers := newLayerUsage(s.node)
	if want["image"] || want["container"] {
		images, total, err := s.imageDiskUsage(ctx, viewer, layers)
		if err != nil {
			return err
		}
		if want["image"] {
			report.Images, report.LayersSize = images, total
		}
	}
	if want["container"] {
		report.Containers = s.containerDiskUsage(ctx, viewer, layers)
	}
	if want["volume"] {
		report.Volumes = s.volumeDiskUsage(viewer)
	}
	if want["build-cache"] {
		records, err := s.buildCacheDiskUsage(ctx)
		if err != nil {
			return err
		}
		report.BuildCache = records
	}
	writeJSON(w, http.StatusOK, report)
	return nil
}

// layerUsage measures layer snapshots and content blobs, each once per
// report, and remembers each image's unpacked size for SizeRootFs.
type layerUsage struct {
	node      node
	snapshots map[string]int64
	blobs     map[string]int64
	unpacked  map[string]int64
}

func newLayerUsage(n node) *layerUsage {
	return &layerUsage{node: n, snapshots: map[string]int64{}, blobs: map[string]int64{}, unpacked: map[string]int64{}}
}

// snapshot is the disk a layer snapshot (or a container's writable layer)
// takes; 0 when there is none (a layer not unpacked here).
func (u *layerUsage) snapshot(ctx context.Context, key string) (int64, error) {
	if size, ok := u.snapshots[key]; ok {
		return size, nil
	}
	usage, err := u.node.imageUsage.Usage(dockerRootFSContext(ctx), &snapshots.UsageRequest{Snapshotter: dockerRootFSSnapshotter, Key: key})
	if status.Code(err) == codes.NotFound {
		usage, err = &snapshots.UsageResponse{}, nil
	}
	if err != nil {
		return 0, err
	}
	size := max(usage.GetSize(), 0)
	u.snapshots[key] = size
	return size, nil
}

// blob is the size of a content blob the store holds; -1 when it holds none.
func (u *layerUsage) blob(ctx context.Context, digest string) (int64, error) {
	if size, ok := u.blobs[digest]; ok {
		return size, nil
	}
	info, err := u.node.content.Info(imageMetadataContext(ctx), &contentapi.InfoRequest{Digest: digest})
	size := int64(-1)
	switch {
	case status.Code(err) == codes.NotFound:
	case err != nil:
		return 0, err
	default:
		size = max(info.GetInfo().GetSize(), 0)
	}
	u.blobs[digest] = size
	return size, nil
}

// imageBlobs lists the content an image's record reaches for linux/arm64:
// the record's target (an index or a manifest), the arm64 manifest an index
// names, that manifest's config and layers. A blob that cannot be read ends
// the walk there: what was reached is still counted.
func (n node) imageBlobs(ctx context.Context, target *types.Descriptor) []string {
	if target == nil {
		return nil
	}
	ctx = imageMetadataContext(ctx)
	digests := []string{target.GetDigest()}
	manifest := target
	if isIndexMediaType(target.GetMediaType()) {
		raw, err := n.readVerifiedImageBlob(ctx, target, "image index")
		if err != nil {
			return digests
		}
		var index ocispec.Index
		if json.Unmarshal(raw, &index) != nil {
			return digests
		}
		match := platforms.Only(platforms.MustParse(enginePlatform))
		var pick *ocispec.Descriptor
		for i := range index.Manifests {
			m := &index.Manifests[i]
			if m.Platform != nil && match.Match(*m.Platform) && (pick == nil || match.Less(*m.Platform, *pick.Platform)) {
				pick = m
			}
		}
		if pick == nil {
			return digests
		}
		manifest = &types.Descriptor{MediaType: pick.MediaType, Digest: pick.Digest.String(), Size: pick.Size}
		digests = append(digests, manifest.GetDigest())
	}
	raw, err := n.readVerifiedImageBlob(ctx, manifest, "image manifest")
	if err != nil {
		return digests
	}
	var parsed ocispec.Manifest
	if json.Unmarshal(raw, &parsed) != nil {
		return digests
	}
	if parsed.Config.Digest != "" {
		digests = append(digests, parsed.Config.Digest.String())
	}
	for _, layer := range parsed.Layers {
		digests = append(digests, layer.Digest.String())
	}
	return digests
}

// diskImage is one image of the report before its shared part is known.
type diskImage struct {
	row     dockerDiskUsageImage
	chains  []string
	digests []string
}

// imageDiskUsage lists every image (images are the machine's, whoever asks)
// with its sizes; Containers counts only the containers viewer sees, so a
// delegated socket does not learn how many containers other jobs run.
func (s *dockerEngine) imageDiskUsage(ctx context.Context, viewer string, layers *layerUsage) ([]dockerDiskUsageImage, int64, error) {
	listCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	listed, err := s.node.images.ListImages(listCtx, &cri.ListImagesRequest{})
	if err != nil {
		return nil, 0, err
	}
	rows, err := s.node.visibleDockerImageRows(listCtx, listed.GetImages())
	if err != nil {
		return nil, 0, err
	}
	// Each image's own ID record names its target (CRI writes one per
	// image); the tags and digests are aliases of it.
	catalog, err := s.node.imageStore.List(imageMetadataContext(listCtx), &images.ListImagesRequest{})
	if err != nil {
		return nil, 0, fail(http.StatusServiceUnavailable, "containerd image inventory could not be verified")
	}
	targets := map[string]*types.Descriptor{}
	for _, record := range catalog.GetImages() {
		if t := record.GetTarget(); fullDockerImageID(record.GetName()) && t != nil {
			targets[record.GetName()] = t
		}
	}
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.GetId())
	}
	configs := s.dockerImageConfigs(listCtx, ids)

	s.mu.Lock()
	using := map[string]int64{}
	for _, c := range s.containers {
		if !c.removed && seesContainer(viewer, c) {
			using[c.ImageID]++
		}
	}
	s.mu.Unlock()

	measured := make([]diskImage, 0, len(rows))
	for _, row := range rows {
		id := row.GetId()
		config := configs[id]
		image := diskImage{
			row: dockerDiskUsageImage{ID: id, RepoTags: row.GetRepoTags(), RepoDigests: row.GetRepoDigests(),
				Created: config.created, Containers: using[id]},
			chains:  config.chains,
			digests: s.node.imageBlobs(ctx, targets[id]),
		}
		if image.row.RepoTags == nil {
			image.row.RepoTags = []string{}
		}
		if image.row.RepoDigests == nil {
			image.row.RepoDigests = []string{}
		}
		measured = append(measured, image)
	}
	total, err := sizeImages(ctx, measured, layers)
	if err != nil {
		return nil, 0, err
	}
	out := make([]dockerDiskUsageImage, 0, len(measured))
	for _, image := range measured {
		out = append(out, image.row)
	}
	return out, total, nil
}

// sizeImages fills each image's Size and SharedSize and returns LayersSize:
// every distinct blob and layer snapshot of the images, once.
func sizeImages(ctx context.Context, images []diskImage, layers *layerUsage) (int64, error) {
	chainHolders, blobHolders := map[string]int{}, map[string]int{}
	for _, image := range images {
		for _, chain := range distinct(image.chains) {
			chainHolders[chain]++
		}
		for _, d := range distinct(image.digests) {
			blobHolders[d]++
		}
	}
	var total int64
	for chain := range chainHolders {
		size, err := layers.snapshot(ctx, chain)
		if err != nil {
			return 0, err
		}
		total += size
	}
	for d := range blobHolders {
		size, err := layers.blob(ctx, d)
		if err != nil {
			return 0, err
		}
		total += max(size, 0)
	}
	for i := range images {
		image := &images[i]
		var size, shared, unpacked int64
		for _, chain := range distinct(image.chains) {
			n := layers.snapshots[chain]
			size, unpacked = size+n, unpacked+n
			if chainHolders[chain] > 1 {
				shared += n
			}
		}
		for _, d := range distinct(image.digests) {
			n := max(layers.blobs[d], 0)
			size += n
			if blobHolders[d] > 1 {
				shared += n
			}
		}
		image.row.Size, image.row.SharedSize = size, shared
		layers.unpacked[image.row.ID] = unpacked
	}
	return total, nil
}

func distinct(values []string) []string {
	seen := make(map[string]bool, len(values))
	out := make([]string, 0, len(values))
	for _, v := range values {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}

// containerDiskUsage lists the containers viewer sees with their writable
// layer: the retained rootfs snapshot of a container that keeps one, else
// the runtime's own snapshot while it runs (an --rm or read-only container),
// else nothing.
func (s *dockerEngine) containerDiskUsage(ctx context.Context, viewer string, layers *layerUsage) []dockerDiskUsageContainer {
	type pending struct {
		row          dockerDiskUsageContainer
		layer, image string
	}
	s.mu.Lock()
	var rows []pending
	for _, c := range s.containers {
		if c.removed || !seesContainer(viewer, c) {
			continue
		}
		row := s.containerListRowLocked(c)
		mounts := c.mountList()
		row.Mounts = make([]any, 0, len(mounts))
		for _, m := range mounts {
			row.Mounts = append(row.Mounts, m)
		}
		p := pending{row: dockerDiskUsageContainer{dockerContainerListRow: row}, image: c.ImageID}
		switch {
		case c.RootFS != nil && c.RootFS.Ready:
			p.layer = dockerRootFSKey(c.ID)
		case c.busy() && c.RuntimeID != "":
			p.layer = c.RuntimeID
		}
		rows = append(rows, p)
	}
	s.mu.Unlock()
	out := make([]dockerDiskUsageContainer, 0, len(rows))
	for _, p := range rows {
		if p.layer != "" {
			// A layer that went away since the listing measures 0.
			p.row.SizeRw, _ = layers.snapshot(ctx, p.layer)
		}
		p.row.SizeRootFs = p.row.SizeRw + layers.unpacked[p.image]
		out = append(out, p.row)
	}
	slices.SortFunc(out, func(a, b dockerDiskUsageContainer) int {
		if order := b.created.Compare(a.created); order != 0 {
			return order
		}
		return cmp.Compare(a.ID, b.ID)
	})
	return out
}

// volumeDiskUsage lists the volumes viewer sees with the disk their files
// take and how many of the containers viewer sees mount each.
func (s *dockerEngine) volumeDiskUsage(viewer string) []dockerDiskUsageVolume {
	entries, _ := os.ReadDir(filepath.Join(volumeStore, "volumes"))
	s.mu.Lock()
	var rows []dockerDiskUsageVolume
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		v, err := inspectVolume(e.Name())
		if err != nil || !s.seesVolumeLocked(viewer, v) {
			continue
		}
		var refs int64
		for _, c := range s.containers {
			if !c.removed && seesContainer(viewer, c) && c.mountsVolume(v.Name) {
				refs++
			}
		}
		rows = append(rows, dockerDiskUsageVolume{volumeInfo: v, UsageData: dockerVolumeUsage{RefCount: refs}})
	}
	s.mu.Unlock()
	out := make([]dockerDiskUsageVolume, 0, len(rows))
	for _, row := range rows {
		row.UsageData.Size = treeDiskBytes(row.Mountpoint)
		out = append(out, row)
	}
	return out
}

// mountsVolume reports whether c's configuration mounts the named volume.
func (c *dockerContainer) mountsVolume(name string) bool {
	mounts, _ := c.Config.mounts()
	for _, m := range mounts {
		if m.Type == "volume" && m.Source == name {
			return true
		}
	}
	return false
}

// treeDiskBytes is the disk the files below dir take, as du counts it: the
// blocks each file holds, a file with several links once. Unreadable entries
// are skipped.
func treeDiskBytes(dir string) int64 {
	type inode struct{ dev, ino uint64 }
	seen := map[inode]bool{}
	var total int64
	_ = filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			total += max(info.Size(), 0)
			return nil
		}
		if st.Nlink > 1 {
			key := inode{uint64(st.Dev), st.Ino}
			if seen[key] {
				return nil
			}
			seen[key] = true
		}
		total += st.Blocks * 512
		return nil
	})
	return total
}

// buildCacheDiskUsage is BuildKit's record list. A bundle without BuildKit
// has no build cache. BuildKit that is not running is started for the
// report only when its root holds state (it has built before); a machine
// that never built reports an empty cache without starting it.
func (s *dockerEngine) buildCacheDiskUsage(ctx context.Context) ([]dockerBuildCacheRecord, error) {
	records := []dockerBuildCacheRecord{}
	if s.buildkitSocket == "" {
		return records, nil
	}
	if !sharedBuildkit.running() {
		entries, err := os.ReadDir(buildkitRoot)
		if errors.Is(err, os.ErrNotExist) || err == nil && len(entries) == 0 {
			return records, nil
		}
	}
	du, err := buildkitDiskUsage(ctx)
	if err != nil {
		return nil, fail(http.StatusServiceUnavailable, "BuildKit cache usage is unavailable: "+err.Error())
	}
	for _, r := range du {
		record := dockerBuildCacheRecord{ID: r.GetID(), Parents: r.GetParents(), Type: r.GetRecordType(),
			Description: r.GetDescription(), InUse: r.GetInUse(), Shared: r.GetShared(), Size: r.GetSize(),
			UsageCount: r.GetUsageCount()}
		if record.Parents == nil && r.GetParent() != "" {
			record.Parents = []string{r.GetParent()}
		}
		if t := r.GetCreatedAt(); t != nil {
			record.CreatedAt = t.AsTime()
		}
		if t := r.GetLastUsedAt(); t != nil {
			used := t.AsTime()
			record.LastUsedAt = &used
		}
		records = append(records, record)
	}
	return records, nil
}

// buildkitDiskUsage asks buildkitd (started if it is not running) for its
// cache records; a variable so tests can stand in for BuildKit.
var buildkitDiskUsage = func(ctx context.Context) ([]*control.UsageRecord, error) {
	conn, err := sharedBuildkit.dial(ctx)
	if err != nil {
		return nil, err
	}
	conn.Close()
	cc, err := grpc.NewClient("unix://"+buildkitSocket, grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(buildkitMaxMessage)))
	if err != nil {
		return nil, err
	}
	defer cc.Close()
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	du, err := control.NewControlClient(cc).DiskUsage(ctx, &control.DiskUsageRequest{})
	if err != nil {
		return nil, err
	}
	return du.GetRecord(), nil
}
