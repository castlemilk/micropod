package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	content "github.com/containerd/containerd/api/services/content/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	control "github.com/moby/buildkit/api/services/control"
	digest "github.com/opencontainers/go-digest"
	"github.com/opencontainers/image-spec/identity"
	"github.com/opencontainers/image-spec/specs-go"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// dfContent is a content store: small blobs it can read, and layer blobs it
// only knows the size of.
type dfContent struct {
	buildxDeleteContent
	layers map[string]int64
	infos  []string
}

func (c *dfContent) Info(_ context.Context, req *content.InfoRequest, _ ...grpc.CallOption) (*content.InfoResponse, error) {
	c.infos = append(c.infos, req.GetDigest())
	if size, ok := c.layers[req.GetDigest()]; ok {
		return &content.InfoResponse{Info: &content.Info{Digest: req.GetDigest(), Size: size}}, nil
	}
	if data, ok := c.blobs[req.GetDigest()]; ok {
		return &content.InfoResponse{Info: &content.Info{Digest: req.GetDigest(), Size: int64(len(data))}}, nil
	}
	return nil, status.Error(codes.NotFound, "blob not found")
}

type dfSnapshots struct {
	sizes map[string]int64
	calls []string
}

func (u *dfSnapshots) Usage(_ context.Context, req *snapshots.UsageRequest, _ ...grpc.CallOption) (*snapshots.UsageResponse, error) {
	u.calls = append(u.calls, req.GetKey())
	if req.GetSnapshotter() != dockerRootFSSnapshotter {
		return nil, status.Error(codes.InvalidArgument, "wrong snapshotter")
	}
	if size, ok := u.sizes[req.GetKey()]; ok {
		return &snapshots.UsageResponse{Size: size}, nil
	}
	return nil, status.Error(codes.NotFound, "snapshot not found")
}

type dfCRI struct {
	cri.ImageServiceClient
	list   []*cri.Image
	status map[string]*cri.ImageStatusResponse
}

func (f *dfCRI) ListImages(context.Context, *cri.ListImagesRequest, ...grpc.CallOption) (*cri.ListImagesResponse, error) {
	return &cri.ListImagesResponse{Images: f.list}, nil
}

func (f *dfCRI) ImageStatus(_ context.Context, req *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	if st, ok := f.status[req.GetImage().GetImage()]; ok {
		return st, nil
	}
	return &cri.ImageStatusResponse{}, nil
}

type dfFixture struct {
	engine      *dockerEngine
	store       *dfContent
	usage       *dfSnapshots
	base, app   string // image IDs
	baseIdx     ocispec.Descriptor
	appManifest ocispec.Descriptor
}

// Two images: base (an index whose arm64 entry has one layer, L1) and app (a
// manifest with L1 and L2, built on base). They share the L1 blob and the
// base layer's snapshot.
func newDFFixture(t *testing.T) dfFixture {
	t.Helper()
	store := &dfContent{buildxDeleteContent: buildxDeleteContent{blobs: map[string][]byte{}}, layers: map[string]int64{}}
	l1, l2 := digest.FromString("layer one"), digest.FromString("layer two")
	store.layers[l1.String()], store.layers[l2.String()] = 1000, 2000
	diff1, diff2 := digest.FromString("diff one"), digest.FromString("diff two")
	created := time.Date(2026, 11, 20, 1, 2, 3, 0, time.UTC)
	config := func(diffs ...digest.Digest) ocispec.Descriptor {
		return store.json(t, ocispec.MediaTypeImageConfig, ocispec.Image{
			Created:  &created,
			Platform: ocispec.Platform{OS: "linux", Architecture: "arm64"},
			RootFS:   ocispec.RootFS{Type: "layers", DiffIDs: diffs},
		})
	}
	manifest := func(cfg ocispec.Descriptor, layers ...ocispec.Descriptor) ocispec.Descriptor {
		return store.json(t, ocispec.MediaTypeImageManifest, ocispec.Manifest{
			Versioned: specs.Versioned{SchemaVersion: 2}, MediaType: ocispec.MediaTypeImageManifest, Config: cfg, Layers: layers,
		})
	}
	layer := func(d digest.Digest, size int64) ocispec.Descriptor {
		return ocispec.Descriptor{MediaType: ocispec.MediaTypeImageLayerGzip, Digest: d, Size: size}
	}
	baseConfig := config(diff1)
	baseManifest := manifest(baseConfig, layer(l1, 1000))
	baseManifest.Platform = &ocispec.Platform{OS: "linux", Architecture: "arm64", Variant: "v8"}
	// The amd64 entry was never pulled: none of its blobs are in the store.
	otherManifest := ocispec.Descriptor{MediaType: ocispec.MediaTypeImageManifest, Digest: digest.FromString("amd64 manifest"),
		Size: 500, Platform: &ocispec.Platform{OS: "linux", Architecture: "amd64"}}
	baseIndex := store.json(t, ocispec.MediaTypeImageIndex, ocispec.Index{
		Versioned: specs.Versioned{SchemaVersion: 2}, MediaType: ocispec.MediaTypeImageIndex,
		Manifests: []ocispec.Descriptor{otherManifest, baseManifest},
	})
	appConfig := config(diff1, diff2)
	appManifest := manifest(appConfig, layer(l1, 1000), layer(l2, 2000))

	chains := identity.ChainIDs([]digest.Digest{diff1, diff2})
	usage := &dfSnapshots{sizes: map[string]int64{chains[0].String(): 10_000, chains[1].String(): 20_000}}

	base, app := baseConfig.Digest.String(), appConfig.Digest.String()
	runtime := &dfCRI{status: map[string]*cri.ImageStatusResponse{}}
	catalog := &imageListTestCatalog{t: t, rows: map[string]*images.Image{}}
	for _, image := range []struct {
		id, tag string
		config  ocispec.Descriptor
		target  ocispec.Descriptor
	}{{base, "docker.io/library/base:1", baseConfig, baseIndex}, {app, "docker.io/library/app:1", appConfig, appManifest}} {
		row := &cri.Image{Id: image.id, RepoTags: []string{image.tag}, Size: 123}
		runtime.list = append(runtime.list, row)
		runtime.status[image.id] = &cri.ImageStatusResponse{Image: row,
			Info: map[string]string{"info": `{"imageSpec":` + string(store.blobs[image.config.Digest.String()]) + `}`}}
		target := imageBlobDescriptor(image.target)
		catalog.rows[image.id] = &images.Image{Name: image.id, Target: target, Labels: map[string]string{criManagedImage: "managed"}}
		catalog.rows[image.tag] = &images.Image{Name: image.tag, Target: target}
	}
	engine := &dockerEngine{
		node:       node{images: runtime, imageStore: catalog, content: store, imageUsage: usage},
		containers: map[string]*dockerContainer{},
	}
	return dfFixture{engine: engine, store: store, usage: usage, base: base, app: app, baseIdx: baseIndex, appManifest: appManifest}
}

func (f dfFixture) df(t *testing.T, query string) (*httptest.ResponseRecorder, map[string]json.RawMessage) {
	t.Helper()
	w := httptest.NewRecorder()
	f.engine.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/system/df"+query, nil))
	var body map[string]json.RawMessage
	if w.Code == http.StatusOK {
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatalf("df body %s: %v", w.Body, err)
		}
	}
	return w, body
}

type dfImageRow struct {
	ID          string `json:"Id"`
	RepoTags    []string
	RepoDigests []string
	Created     int64
	Size        int64
	SharedSize  int64
	Containers  int64
}

// Images are measured as Docker's containerd store measures them: present
// blobs (the arm64 path through an index only) plus unpacked layers; what
// two images share is SharedSize for both and counted once in LayersSize.
func TestSystemDFImages(t *testing.T) {
	f := newDFFixture(t)
	f.engine.containers["c1"] = &dockerContainer{dockerRecord: dockerRecord{ID: "c1", Name: "one", ImageID: f.app, Phase: "exited"}}
	f.engine.containers["c2"] = &dockerContainer{dockerRecord: dockerRecord{ID: "c2", Name: "two", ImageID: f.app, Phase: "running"}}
	w, body := f.df(t, "?type=image")
	if w.Code != http.StatusOK {
		t.Fatalf("df = %d %s", w.Code, w.Body)
	}
	for _, unrequested := range []string{"Containers", "Volumes", "BuildCache"} {
		if string(body[unrequested]) != "null" {
			t.Fatalf("%s = %s, want null when the type was not asked for", unrequested, body[unrequested])
		}
	}
	var rows []dfImageRow
	var layers int64
	if json.Unmarshal(body["Images"], &rows) != nil || json.Unmarshal(body["LayersSize"], &layers) != nil || len(rows) != 2 {
		t.Fatalf("df images = %s", w.Body)
	}
	blob := func(d ocispec.Descriptor) int64 { return int64(len(f.store.blobs[d.Digest.String()])) }
	var baseManifest, baseConfig, appConfig ocispec.Descriptor
	var index ocispec.Index
	_ = json.Unmarshal(f.store.blobs[f.baseIdx.Digest.String()], &index)
	baseManifest = index.Manifests[1]
	var m ocispec.Manifest
	_ = json.Unmarshal(f.store.blobs[baseManifest.Digest.String()], &m)
	baseConfig = m.Config
	_ = json.Unmarshal(f.store.blobs[f.appManifest.Digest.String()], &m)
	appConfig = m.Config
	baseSize := blob(f.baseIdx) + blob(baseManifest) + blob(baseConfig) + 1000 + 10_000
	appSize := blob(f.appManifest) + blob(appConfig) + 1000 + 2000 + 10_000 + 20_000
	shared := int64(1000 + 10_000)
	created := time.Date(2026, 11, 20, 1, 2, 3, 0, time.UTC).Unix()
	byID := map[string]dfImageRow{}
	for _, row := range rows {
		byID[row.ID] = row
	}
	if got := byID[f.base]; got.Size != baseSize || got.SharedSize != shared || got.Containers != 0 || got.Created != created ||
		!slices.Equal(got.RepoTags, []string{"docker.io/library/base:1"}) {
		t.Fatalf("base = %+v, want size %d shared %d created %d", got, baseSize, shared, created)
	}
	if got := byID[f.app]; got.Size != appSize || got.SharedSize != shared || got.Containers != 2 || got.Created != created {
		t.Fatalf("app = %+v, want size %d shared %d, 2 containers", got, appSize, shared)
	}
	if want := baseSize + appSize - shared; layers != want {
		t.Fatalf("LayersSize = %d, want %d (each blob and snapshot once)", layers, want)
	}
	for _, d := range f.store.infos {
		if d == digest.FromString("amd64 manifest").String() {
			t.Fatal("the report measured the index's amd64 entry")
		}
	}
}

// Containers carry their writable layer and that plus their image's layers;
// volumes the disk their files take (a hard link once) and the containers
// that mount them; a delegated socket sees only its own family's.
func TestSystemDFContainersAndVolumes(t *testing.T) {
	f := newDFFixture(t)
	useVolumeStore(t)
	for _, name := range []string{"cache", "idle"} {
		if err := ensureVolume(name, map[string]string{"k": name}); err != nil {
			t.Fatal(err)
		}
	}
	data := filepath.Join(volumePath("cache"), "data")
	if err := os.WriteFile(data, make([]byte, 64<<10), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(data, filepath.Join(volumePath("cache"), "link")); err != nil {
		t.Fatal(err)
	}
	retained := strings.Repeat("a", 64)
	running := strings.Repeat("b", 64)
	f.usage.sizes[dockerRootFSKey(retained)] = 4096
	f.usage.sizes["cri-container"] = 512
	f.engine.containers[retained] = &dockerContainer{dockerRecord: dockerRecord{ID: retained, Name: "kept", ImageID: f.app,
		Phase: "exited", RootFS: &dockerRootFS{Ready: true}, Created: time.Unix(100, 0),
		Config: dockerConfig{Image: "app:1", HostConfig: dockerHost{Binds: []string{"cache:/cache"}}}}}
	f.engine.containers[running] = &dockerContainer{dockerRecord: dockerRecord{ID: running, Name: "rm", ImageID: f.base,
		Phase: "running", RuntimeID: "cri-container", Created: time.Unix(200, 0), CreatedBy: retained,
		Config: dockerConfig{Image: "base:1", HostConfig: dockerHost{AutoRemove: true}}}}
	w, body := f.df(t, "?type=container&type=volume")
	if w.Code != http.StatusOK || string(body["Images"]) != "null" {
		t.Fatalf("df = %d %s", w.Code, w.Body)
	}
	var containers []struct {
		ID         string `json:"Id"`
		State      string
		SizeRw     int64
		SizeRootFs int64
		Mounts     []map[string]any
	}
	if err := json.Unmarshal(body["Containers"], &containers); err != nil || len(containers) != 2 {
		t.Fatalf("containers = %s (%v)", body["Containers"], err)
	}
	if c := containers[0]; c.ID != running || c.SizeRw != 512 || c.SizeRootFs != 512+10_000 || c.State != "running" {
		t.Fatalf("running --rm container = %+v", c)
	}
	if c := containers[1]; c.ID != retained || c.SizeRw != 4096 || c.SizeRootFs != 4096+30_000 ||
		len(c.Mounts) != 1 || c.Mounts[0]["Name"] != "cache" || c.Mounts[0]["Driver"] != "local" {
		t.Fatalf("retained container = %+v", c)
	}
	var volumes []struct {
		Name      string
		Labels    map[string]string
		UsageData struct{ Size, RefCount int64 }
	}
	if err := json.Unmarshal(body["Volumes"], &volumes); err != nil || len(volumes) != 2 {
		t.Fatalf("volumes = %s (%v)", body["Volumes"], err)
	}
	slices.SortFunc(volumes, func(a, b struct {
		Name      string
		Labels    map[string]string
		UsageData struct{ Size, RefCount int64 }
	}) int {
		return strings.Compare(a.Name, b.Name)
	})
	if v := volumes[0]; v.Name != "cache" || v.UsageData.RefCount != 1 || v.UsageData.Size < 64<<10 || v.UsageData.Size >= 128<<10 ||
		v.Labels["k"] != "cache" {
		t.Fatalf("cache volume = %+v, want one reference and the 64 KiB file counted once", v)
	}
	if v := volumes[1]; v.Name != "idle" || v.UsageData.RefCount != 0 || v.UsageData.Size != 0 {
		t.Fatalf("idle volume = %+v", v)
	}

	// The retained container's delegated socket sees its family: itself and
	// the container it created.
	r := httptest.NewRequest(http.MethodGet, "/v1.47/system/df?type=container", nil)
	r = r.WithContext(context.WithValue(r.Context(), apiViewerKey{}, retained))
	w = httptest.NewRecorder()
	f.engine.ServeHTTP(w, r)
	if w.Code != http.StatusOK || strings.Count(w.Body.String(), `"SizeRw"`) != 2 {
		t.Fatalf("family view = %d %s", w.Code, w.Body)
	}
	r = r.WithContext(context.WithValue(r.Context(), apiViewerKey{}, strings.Repeat("c", 64)))
	w = httptest.NewRecorder()
	f.engine.ServeHTTP(w, r)
	if w.Code != http.StatusOK || strings.Contains(w.Body.String(), `"SizeRw"`) {
		t.Fatalf("another job's view = %d %s", w.Code, w.Body)
	}
}

// Another job's delegated socket learns nothing of this job's containers or
// volumes from the report: no container row, no volume row, and no count of
// them on the images (which are the machine's and stay listed) or on a
// volume both jobs can see.
func TestSystemDFDelegatedSocketCountsOnlyItsFamily(t *testing.T) {
	f := newDFFixture(t)
	useVolumeStore(t)
	owner := strings.Repeat("a", 64)
	child := strings.Repeat("b", 64)
	other := strings.Repeat("c", 64)
	for name, createdBy := range map[string]string{"mine": owner, "theirs": other, "shared": ""} {
		if err := ensureVolumeBy(name, nil, createdBy); err != nil {
			t.Fatal(err)
		}
	}
	container := func(id, name, image, createdBy string, binds ...string) {
		f.engine.containers[id] = &dockerContainer{dockerRecord: dockerRecord{ID: id, Name: name, ImageID: image,
			Phase: "running", RuntimeID: "cri-" + name, Created: time.Unix(100, 0), CreatedBy: createdBy,
			Config: dockerConfig{Image: name, HostConfig: dockerHost{Binds: binds}}}}
	}
	container(owner, "owner", f.app, "", "shared:/shared")
	container(child, "child", f.app, owner, "mine:/mine")
	container(other, "other", f.app, "", "shared:/shared", "theirs:/theirs")

	view := func(viewer string) (images map[string]int64, containers []string, volumes map[string]int64) {
		t.Helper()
		r := httptest.NewRequest(http.MethodGet, "/v1.47/system/df?type=image&type=container&type=volume", nil)
		if viewer != "" {
			r = r.WithContext(context.WithValue(r.Context(), apiViewerKey{}, viewer))
		}
		w := httptest.NewRecorder()
		f.engine.ServeHTTP(w, r)
		var body struct {
			Images []struct {
				ID         string `json:"Id"`
				Containers int64
			}
			Containers []struct {
				ID string `json:"Id"`
			}
			Volumes []struct {
				Name      string
				UsageData struct{ RefCount int64 }
			}
		}
		if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &body) != nil {
			t.Fatalf("df as %q = %d %s", viewer, w.Code, w.Body)
		}
		images, volumes = map[string]int64{}, map[string]int64{}
		for _, i := range body.Images {
			images[i.ID] = i.Containers
		}
		for _, c := range body.Containers {
			containers = append(containers, c.ID)
		}
		slices.Sort(containers)
		for _, v := range body.Volumes {
			volumes[v.Name] = v.UsageData.RefCount
		}
		return images, containers, volumes
	}

	images, containers, volumes := view("")
	if images[f.app] != 3 || len(containers) != 3 || len(volumes) != 3 || volumes["shared"] != 2 {
		t.Fatalf("the host's view = images %v containers %v volumes %v, want everything", images, containers, volumes)
	}
	images, containers, volumes = view(owner)
	if len(images) != 2 || images[f.app] != 2 || !slices.Equal(containers, []string{owner, child}) {
		t.Fatalf("the owner's view = images %v containers %v, want both images and its 2 containers", images, containers)
	}
	if _, leaked := volumes["theirs"]; leaked || len(volumes) != 2 || volumes["mine"] != 1 || volumes["shared"] != 1 {
		t.Fatalf("the owner's volumes = %v, want its own and the one it mounts, counting only its containers", volumes)
	}
	images, containers, volumes = view(other)
	if len(images) != 2 || images[f.app] != 1 || !slices.Equal(containers, []string{other}) {
		t.Fatalf("the other job's view = images %v containers %v, want both images and 1 container", images, containers)
	}
	if _, leaked := volumes["mine"]; leaked || len(volumes) != 2 || volumes["theirs"] != 1 || volumes["shared"] != 1 {
		t.Fatalf("the other job's volumes = %v", volumes)
	}
}

// The build cache is BuildKit's record list, asked for only when BuildKit
// runs or has state; a bundle without BuildKit reports none.
func TestSystemDFBuildCache(t *testing.T) {
	f := newDFFixture(t)
	oldRoot, oldDU := buildkitRoot, buildkitDiskUsage
	t.Cleanup(func() { buildkitRoot, buildkitDiskUsage = oldRoot, oldDU })
	asked := 0
	used := time.Date(2026, 11, 27, 9, 0, 0, 0, time.UTC)
	buildkitDiskUsage = func(context.Context) ([]*control.UsageRecord, error) {
		asked++
		return []*control.UsageRecord{
			{ID: "r1", Size: 700, InUse: true, RecordType: "regular", Description: "mount / from exec", UsageCount: 3,
				CreatedAt: timestamppb.New(used.Add(-time.Hour)), LastUsedAt: timestamppb.New(used), Parent: "r0"},
			{ID: "r2", Size: 300, Shared: true, RecordType: "exec.cachemount", Parents: []string{"r1"}},
		}, nil
	}
	buildkitRoot = filepath.Join(t.TempDir(), "buildkit")
	w, body := f.df(t, "?type=build-cache")
	if w.Code != http.StatusOK || string(body["BuildCache"]) != "[]" || asked != 0 {
		t.Fatalf("no BuildKit in the bundle = %d %s (asked %d)", w.Code, w.Body, asked)
	}
	f.engine.buildkitSocket = "/run/test-buildkit.sock"
	w, body = f.df(t, "?type=build-cache")
	if w.Code != http.StatusOK || string(body["BuildCache"]) != "[]" || asked != 0 {
		t.Fatalf("BuildKit never started = %d %s (asked %d)", w.Code, w.Body, asked)
	}
	if err := os.MkdirAll(filepath.Join(buildkitRoot, "runc-overlayfs"), 0700); err != nil {
		t.Fatal(err)
	}
	w, body = f.df(t, "?type=build-cache")
	var records []dockerBuildCacheRecord
	if w.Code != http.StatusOK || json.Unmarshal(body["BuildCache"], &records) != nil || asked != 1 || len(records) != 2 {
		t.Fatalf("BuildKit with state = %d %s (asked %d)", w.Code, w.Body, asked)
	}
	if r := records[0]; r.ID != "r1" || r.Size != 700 || !r.InUse || r.Type != "regular" || r.UsageCount != 3 ||
		!slices.Equal(r.Parents, []string{"r0"}) || r.LastUsedAt == nil || !r.LastUsedAt.Equal(used) || !r.CreatedAt.Equal(used.Add(-time.Hour)) {
		t.Fatalf("record = %+v", r)
	}
	if r := records[1]; !r.Shared || r.LastUsedAt != nil || !slices.Equal(r.Parents, []string{"r1"}) {
		t.Fatalf("shared record = %+v", r)
	}
}

// No type means all four; an unknown one is refused; only GET is served.
func TestSystemDFTypes(t *testing.T) {
	f := newDFFixture(t)
	useVolumeStore(t)
	w, body := f.df(t, "")
	if w.Code != http.StatusOK {
		t.Fatalf("df = %d %s", w.Code, w.Body)
	}
	for _, key := range []string{"Images", "Containers", "Volumes", "BuildCache"} {
		if raw := string(body[key]); raw == "null" || raw == "" {
			t.Fatalf("%s = %q with no type given", key, raw)
		}
	}
	if w, _ := f.df(t, "?type=image&type=networks"); w.Code != http.StatusBadRequest ||
		!strings.Contains(w.Body.String(), "unknown object type: networks") {
		t.Fatalf("unknown type = %d %s", w.Code, w.Body)
	}
}
