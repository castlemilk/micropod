package main

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"net/http"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	"github.com/distribution/reference"
	"github.com/opencontainers/go-digest"
	specs "github.com/opencontainers/image-spec/specs-go"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// emulatedStore is containerd's image store as these tests need it: records
// by name, the label and target filters the engine sends, and updates by
// field mask. A record CRI would index gets CRI's managed label (index).
type emulatedStore struct {
	mu   sync.Mutex
	refs map[string]*images.Image
}

func (s *emulatedStore) Get(_ context.Context, req *images.GetImageRequest, _ ...grpc.CallOption) (*images.GetImageResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if img := s.refs[req.GetName()]; img != nil {
		return &images.GetImageResponse{Image: cloneImage(img)}, nil
	}
	return nil, status.Error(codes.NotFound, "image not found")
}

func cloneImage(img *images.Image) *images.Image {
	out := &images.Image{Name: img.GetName(), Labels: maps.Clone(img.GetLabels())}
	if t := img.GetTarget(); t != nil {
		out.Target = &types.Descriptor{MediaType: t.GetMediaType(), Digest: t.GetDigest(), Size: t.GetSize()}
	}
	return out
}

func (s *emulatedStore) List(_ context.Context, req *images.ListImagesRequest, _ ...grpc.CallOption) (*images.ListImagesResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := &images.ListImagesResponse{}
	for _, img := range s.refs {
		if len(req.GetFilters()) == 0 || matchesStoreFilter(img, req.GetFilters()[0]) {
			out.Images = append(out.Images, cloneImage(img))
		}
	}
	slices.SortFunc(out.Images, func(a, b *images.Image) int { return strings.Compare(a.GetName(), b.GetName()) })
	return out, nil
}

func matchesStoreFilter(img *images.Image, filter string) bool {
	if raw, ok := strings.CutPrefix(filter, "target.digest=="); ok {
		d, _ := strconv.Unquote(raw)
		return img.GetTarget().GetDigest() == d
	}
	raw, ok := strings.CutPrefix(filter, "labels.")
	if !ok {
		panic("unexpected filter " + filter)
	}
	key, value, hasValue := strings.Cut(raw, "==")
	key, _ = strconv.Unquote(key)
	got, present := img.GetLabels()[key]
	if !hasValue {
		return present
	}
	want, _ := strconv.Unquote(value)
	return present && got == want
}

func (s *emulatedStore) Create(_ context.Context, req *images.CreateImageRequest, _ ...grpc.CallOption) (*images.CreateImageResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.refs[req.GetImage().GetName()] != nil {
		return nil, status.Error(codes.AlreadyExists, "exists")
	}
	img := cloneImage(req.GetImage())
	s.refs[img.GetName()] = img
	return &images.CreateImageResponse{Image: cloneImage(img)}, nil
}

func (s *emulatedStore) Update(_ context.Context, req *images.UpdateImageRequest, _ ...grpc.CallOption) (*images.UpdateImageResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	img := s.refs[req.GetImage().GetName()]
	if img == nil {
		return nil, status.Error(codes.NotFound, "image not found")
	}
	for _, path := range req.GetUpdateMask().GetPaths() {
		switch {
		case path == "target":
			img.Target = cloneImage(req.GetImage()).GetTarget()
		case strings.HasPrefix(path, "labels."):
			key := strings.TrimPrefix(path, "labels.")
			if value, ok := req.GetImage().GetLabels()[key]; ok {
				if img.Labels == nil {
					img.Labels = map[string]string{}
				}
				img.Labels[key] = value
			} else {
				delete(img.Labels, key)
			}
		default:
			panic("unexpected update path " + path)
		}
	}
	return &images.UpdateImageResponse{Image: cloneImage(img)}, nil
}

func (s *emulatedStore) Delete(_ context.Context, req *images.DeleteImageRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.refs, req.GetName())
	return &emptypb.Empty{}, nil
}

// emulatedCRI answers ImageStatus for every record of the store: the config
// ID and platform of the manifest it names (an index resolves to its
// linux/arm64 entry, as CRI's does).
type emulatedCRI struct {
	cri.ImageServiceClient
	store   *emulatedStore
	configs map[string]ocispec.Platform // manifest digest -> config platform
	ids     map[string]string           // manifest digest -> config ID
	indexes map[string]string           // index digest -> its arm64 manifest
}

func (c *emulatedCRI) ImageStatus(ctx context.Context, req *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	name := req.GetImage().GetImage()
	if named, err := reference.ParseNormalizedNamed(name); err == nil && !strings.HasPrefix(name, "sha256:") {
		name = named.String()
	}
	got, err := c.store.Get(ctx, &images.GetImageRequest{Name: name})
	if err != nil {
		return &cri.ImageStatusResponse{}, nil
	}
	target := got.GetImage().GetTarget().GetDigest()
	if native, ok := c.indexes[target]; ok {
		target = native
	}
	p, ok := c.configs[target]
	if !ok {
		return &cri.ImageStatusResponse{}, nil
	}
	info, _ := json.Marshal(map[string]any{"imageSpec": map[string]any{"os": p.OS, "architecture": p.Architecture}})
	image := &cri.Image{Id: c.ids[target]}
	if !strings.Contains(name, "@") && !strings.HasPrefix(name, "sha256:") {
		image.RepoTags = []string{name}
	}
	return &cri.ImageStatusResponse{Image: image, Info: map[string]string{"info": string(info)}}, nil
}

type fakeRegistry struct {
	roots map[string]ocispec.Descriptor // reference -> root
	blobs map[string][]byte
}

func (r *fakeRegistry) resolve(_ context.Context, ref string, _ *cri.AuthConfig) (ocispec.Descriptor, registryFetch, error) {
	root, ok := r.roots[ref]
	if !ok {
		return ocispec.Descriptor{}, nil, status.Error(codes.NotFound, ref+": not found")
	}
	return root, func(_ context.Context, d ocispec.Descriptor) ([]byte, error) {
		if b, ok := r.blobs[d.Digest.String()]; ok {
			return b, nil
		}
		return nil, errors.New("no blob " + d.Digest.String())
	}, nil
}

func (r *fakeRegistry) put(t *testing.T, mediaType string, v any) ocispec.Descriptor {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	d := ocispec.Descriptor{MediaType: mediaType, Digest: digest.FromBytes(b), Size: int64(len(b))}
	r.blobs[d.Digest.String()] = b
	return d
}

// fakePuller stores the pulled record as the transfer service would, and CRI
// then labels it managed as its image event does.
type fakePuller struct {
	store  *emulatedStore
	pulls  []string
	target map[string]ocispec.Descriptor // name -> manifest it resolves to
	err    error
}

func (p *fakePuller) pullPlatform(_ context.Context, name string, platform ocispec.Platform, _ *cri.AuthConfig, labels map[string]string) error {
	p.pulls = append(p.pulls, name+" "+platform.OS+"/"+platform.Architecture)
	if p.err != nil {
		return p.err
	}
	d := p.target[name]
	p.store.mu.Lock()
	defer p.store.mu.Unlock()
	stored := maps.Clone(labels)
	stored[criManagedImage] = "managed"
	p.store.refs[name] = &images.Image{Name: name, Labels: stored,
		Target: &types.Descriptor{MediaType: d.MediaType, Digest: d.Digest.String(), Size: d.Size}}
	return nil
}

type emulatedPullFixture struct {
	s        *dockerEngine
	store    *emulatedStore
	registry *fakeRegistry
	puller   *fakePuller
	cri      *emulatedCRI
	index    ocispec.Descriptor
	amd64    ocispec.Descriptor
	arm64    ocispec.Descriptor
	single   ocispec.Descriptor // an arm64-only single manifest
}

func newEmulatedPullFixture(t *testing.T) *emulatedPullFixture {
	t.Helper()
	withEmulation(t, qemuEmulation)
	r := &fakeRegistry{roots: map[string]ocispec.Descriptor{}, blobs: map[string][]byte{}}
	manifest := func(arch string) ocispec.Descriptor {
		config := r.put(t, ocispec.MediaTypeImageConfig, ocispec.Image{Platform: ocispec.Platform{OS: "linux", Architecture: arch},
			RootFS: ocispec.RootFS{Type: "layers", DiffIDs: []digest.Digest{digest.FromString(arch + " layer")}}})
		return r.put(t, ocispec.MediaTypeImageManifest, ocispec.Manifest{Versioned: specs.Versioned{SchemaVersion: 2},
			MediaType: ocispec.MediaTypeImageManifest, Config: config,
			Layers: []ocispec.Descriptor{{MediaType: ocispec.MediaTypeImageLayerGzip, Digest: digest.FromString(arch + " blob"), Size: 10}}})
	}
	f := &emulatedPullFixture{registry: r, amd64: manifest("amd64"), arm64: manifest("arm64")}
	amd, arm := f.amd64, f.arm64
	amd.Platform = &ocispec.Platform{OS: "linux", Architecture: "amd64"}
	arm.Platform = &ocispec.Platform{OS: "linux", Architecture: "arm64"}
	attestation := ocispec.Descriptor{MediaType: ocispec.MediaTypeImageManifest, Digest: digest.FromString("attestation"), Size: 5,
		Platform: &attestationEntry}
	f.index = r.put(t, ocispec.MediaTypeImageIndex, ocispec.Index{Versioned: specs.Versioned{SchemaVersion: 2},
		MediaType: ocispec.MediaTypeImageIndex, Manifests: []ocispec.Descriptor{arm, attestation, amd}})
	f.single = f.arm64
	r.roots["docker.io/library/alpine:3.20"] = f.index
	r.roots["docker.io/library/alpine@"+f.index.Digest.String()] = f.index
	r.roots["docker.io/library/armonly:1"] = f.single
	f.store = &emulatedStore{refs: map[string]*images.Image{}}
	f.puller = &fakePuller{store: f.store, target: map[string]ocispec.Descriptor{
		"docker.io/library/alpine@" + f.amd64.Digest.String(): f.amd64,
	}}
	f.cri = &emulatedCRI{store: f.store,
		configs: map[string]ocispec.Platform{f.amd64.Digest.String(): amd64Platform, f.arm64.Digest.String(): nativePlatform},
		ids:     map[string]string{f.amd64.Digest.String(): "sha256:" + strings.Repeat("a", 64), f.arm64.Digest.String(): "sha256:" + strings.Repeat("b", 64)},
		indexes: map[string]string{f.index.Digest.String(): f.arm64.Digest.String()},
	}
	content := &buildxDeleteContent{blobs: r.blobs}
	f.s = &dockerEngine{node: node{images: f.cri, imageStore: f.store, registry: r, platformPull: f.puller, content: content}}
	return f
}

func (f *emulatedPullFixture) pull(t *testing.T, query string) (*httptest.ResponseRecorder, error) {
	t.Helper()
	w := httptest.NewRecorder()
	err := f.s.images(w, httptest.NewRequest(http.MethodPost, "/v1.47/images/create?"+query, nil), "create")
	return w, err
}

// A pull for linux/amd64 by tag picks the index's amd64 entry, pulls it by
// digest into its own record (labelled with the index, the platform and the
// tag), names it by the tag when the tag names nothing yet, and answers only
// after the image store sync.
func TestEmulatedPullByTagStoresTheAmd64ImageUnderItsDigest(t *testing.T) {
	var steps []string
	observeImageSync(t, &steps, nil)
	f := newEmulatedPullFixture(t)
	w, err := f.pull(t, "fromImage=alpine&tag=3.20&platform=linux%2Famd64")
	if err != nil || w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "linux/amd64") {
		t.Fatalf("pull = %v %d %s", err, w.Code, w.Body)
	}
	pinned := "docker.io/library/alpine@" + f.amd64.Digest.String()
	if !slices.Equal(f.puller.pulls, []string{pinned + " linux/amd64"}) || !slices.Equal(steps, []string{"sync"}) {
		t.Fatalf("pulled %v, synced %v", f.puller.pulls, steps)
	}
	record := f.store.refs[pinned]
	tag := "docker.io/library/alpine:3.20"
	if record.Labels[emulatedIndexLabel] != f.index.Digest.String() || record.Labels[emulatedPlatformLabel] != "linux/amd64" ||
		record.Labels[emulatedTagLabel(tag)] != tag {
		t.Fatalf("pinned labels %v", record.Labels)
	}
	if got := f.store.refs[tag]; got == nil || got.Target.Digest != f.amd64.Digest.String() {
		t.Fatalf("the tag names %v, want the amd64 manifest", got)
	}
}

// A tag that already names the native image keeps it: a pull or create with
// no platform still gets linux/arm64, and --platform linux/amd64 finds the
// amd64 image through the tag's label.
func TestEmulatedPullLeavesANativeTagAlone(t *testing.T) {
	observeImageSync(t, new([]string), nil)
	f := newEmulatedPullFixture(t)
	tag := "docker.io/library/alpine:3.20"
	f.store.refs[tag] = &images.Image{Name: tag, Labels: map[string]string{criManagedImage: "managed"},
		Target: &types.Descriptor{MediaType: f.index.MediaType, Digest: f.index.Digest.String(), Size: f.index.Size}}
	if _, err := f.pull(t, "fromImage=alpine&tag=3.20&platform=amd64"); err != nil {
		t.Fatal(err)
	}
	if got := f.store.refs[tag].Target.Digest; got != f.index.Digest.String() {
		t.Fatalf("the native tag was moved to %s", got)
	}
	ctx := context.Background()
	native, err := f.s.node.dockerPlatformImageStatus(ctx, "alpine:3.20", nil)
	if err != nil || native.GetImage().GetId() != f.cri.ids[f.arm64.Digest.String()] {
		t.Fatalf("no platform = %v %v, want the arm64 image", native, err)
	}
	want := amd64Platform
	emulated, err := f.s.node.dockerPlatformImageStatus(ctx, "alpine:3.20", &want)
	if err != nil || emulated.GetImage().GetId() != f.cri.ids[f.amd64.Digest.String()] {
		t.Fatalf("linux/amd64 = %v %v, want the amd64 image", emulated, err)
	}
	arm := nativePlatform
	if again, err := f.s.node.dockerPlatformImageStatus(ctx, "alpine:3.20", &arm); err != nil || again.GetImage().GetId() != f.cri.ids[f.arm64.Digest.String()] {
		t.Fatalf("linux/arm64 = %v %v", again, err)
	}
}

// A tag that names only the amd64 image is not linux/arm64: a create for
// linux/arm64 is Docker's not-found, so the CLI pulls the native image.
func TestCreateForTheNativePlatformDoesNotTakeTheEmulatedTag(t *testing.T) {
	observeImageSync(t, new([]string), nil)
	f := newEmulatedPullFixture(t)
	if _, err := f.pull(t, "fromImage=alpine&tag=3.20&platform=linux/amd64"); err != nil {
		t.Fatal(err)
	}
	arm := nativePlatform
	_, err := f.s.node.dockerPlatformImageStatus(context.Background(), "alpine:3.20", &arm)
	var problem apiError
	if !errors.As(err, &problem) || problem.code != http.StatusNotFound ||
		!strings.Contains(problem.message, "does not match the specified platform: wanted linux/arm64, actual: linux/amd64") {
		t.Fatalf("linux/arm64 of an amd64-only tag = %v", err)
	}
}

// A pull by the index digest finds the amd64 image again by that digest, and
// names no tag.
func TestEmulatedPullByIndexDigest(t *testing.T) {
	observeImageSync(t, new([]string), nil)
	f := newEmulatedPullFixture(t)
	if _, err := f.pull(t, "fromImage=alpine&tag="+f.index.Digest.String()+"&platform=linux/amd64"); err != nil {
		t.Fatal(err)
	}
	if _, tagged := f.store.refs["docker.io/library/alpine:3.20"]; tagged {
		t.Fatal("a pull by digest named a tag")
	}
	want := amd64Platform
	got, err := f.s.node.emulatedAlternative(context.Background(), "alpine@"+f.index.Digest.String(), want)
	if err != nil || got != "docker.io/library/alpine@"+f.amd64.Digest.String() {
		t.Fatalf("alternative = %q %v", got, err)
	}
}

// What an image lacks is Docker's 404: an index with no amd64 entry, and a
// single manifest of another platform; neither is pulled.
func TestEmulatedPullOfAnImageWithoutThePlatform(t *testing.T) {
	observeImageSync(t, new([]string), nil)
	f := newEmulatedPullFixture(t)
	for query, message := range map[string]string{
		"fromImage=armonly&tag=1&platform=linux/amd64": "image with reference armonly:1 was found but does not match the specified platform: wanted linux/amd64, actual: linux/arm64",
		"fromImage=nope&tag=1&platform=linux/amd64":    "pull access denied for nope:1",
	} {
		_, err := f.pull(t, query)
		var problem apiError
		if !errors.As(err, &problem) || problem.code != http.StatusNotFound || !strings.HasPrefix(problem.message, message) {
			t.Errorf("%s: %v", query, err)
		}
	}
	withoutAmd64 := f.registry.put(t, ocispec.MediaTypeImageIndex, ocispec.Index{Versioned: specs.Versioned{SchemaVersion: 2},
		Manifests: []ocispec.Descriptor{{MediaType: ocispec.MediaTypeImageManifest, Digest: f.arm64.Digest, Size: f.arm64.Size,
			Platform: &ocispec.Platform{OS: "linux", Architecture: "arm64"}}}})
	_, err := selectPlatformManifest(context.Background(), "x:1", withoutAmd64, amd64Platform, func(_ context.Context, d ocispec.Descriptor) ([]byte, error) {
		return f.registry.blobs[d.Digest.String()], nil
	})
	var problem apiError
	if !errors.As(err, &problem) || problem.code != http.StatusNotFound ||
		problem.message != "no matching manifest for linux/amd64 in the manifest list entries: x:1 has no linux/amd64 image" {
		t.Fatalf("index without amd64: %v", err)
	}
	if len(f.puller.pulls) != 0 {
		t.Fatalf("pulled %v", f.puller.pulls)
	}
}

// Without emulation a pull for linux/amd64 never reaches the registry.
func TestEmulatedPullRefusedWithoutEmulation(t *testing.T) {
	observeImageSync(t, new([]string), nil)
	f := newEmulatedPullFixture(t)
	withEmulation(t, &amd64Emulation{Reason: "x86-64 emulation is off: the machine sets micropod.amd64=off"})
	_, err := f.pull(t, "fromImage=alpine&tag=3.20&platform=linux/amd64")
	var problem apiError
	if !errors.As(err, &problem) || problem.code != http.StatusBadRequest || !strings.Contains(problem.message, "micropod.amd64=off") || len(f.puller.pulls) != 0 {
		t.Fatalf("pull without emulation = %v, pulls %v", err, f.puller.pulls)
	}
}

// A second tag pulled to the same amd64 image keeps the first tag's label;
// a newer pull of a tag takes the tag's label from the older image.
func TestEmulatedTagLabelsFollowTheLastPull(t *testing.T) {
	observeImageSync(t, new([]string), nil)
	f := newEmulatedPullFixture(t)
	f.registry.roots["docker.io/library/alpine:latest"] = f.index
	for _, tag := range []string{"3.20", "latest"} {
		if _, err := f.pull(t, "fromImage=alpine&tag="+tag+"&platform=linux/amd64"); err != nil {
			t.Fatal(err)
		}
	}
	pinned := f.store.refs["docker.io/library/alpine@"+f.amd64.Digest.String()]
	for _, tag := range []string{"docker.io/library/alpine:3.20", "docker.io/library/alpine:latest"} {
		if pinned.Labels[emulatedTagLabel(tag)] != tag {
			t.Fatalf("labels %v lack %s", pinned.Labels, tag)
		}
	}
	older := "docker.io/library/alpine@" + digest.FromString("older amd64").String()
	f.store.refs[older] = &images.Image{Name: older, Labels: map[string]string{emulatedTagLabel("docker.io/library/alpine:3.20"): "docker.io/library/alpine:3.20"}}
	if err := f.s.node.moveEmulatedTagLabel(context.Background(), "docker.io/library/alpine:3.20", pinned.Name); err != nil {
		t.Fatal(err)
	}
	if _, still := f.store.refs[older].Labels[emulatedTagLabel("docker.io/library/alpine:3.20")]; still {
		t.Fatal("the older image kept the tag's label")
	}
}

// A create for an image of a platform the engine cannot run is refused at
// create, naming why, rather than failing at start with an exec format error.
func TestRunsHere(t *testing.T) {
	withEmulation(t, qemuEmulation)
	for p, want := range map[string]bool{"linux/arm64": true, "linux/arm64/v8": true, "linux/amd64": true, "linux/arm/v7": false, "linux/s390x": false} {
		parsed, _ := requestedPlatformForTest(p)
		if runs, why := runsHere(parsed); runs != want {
			t.Errorf("%s runs = %v (%s)", p, runs, why)
		}
	}
}

func requestedPlatformForTest(raw string) (ocispec.Platform, error) {
	parts := strings.Split(raw, "/")
	p := ocispec.Platform{OS: parts[0], Architecture: parts[1]}
	if len(parts) > 2 {
		p.Variant = parts[2]
	}
	return p, nil
}

// A build is native only when it names linux/arm64 alone.
func TestBuildIsNative(t *testing.T) {
	for raw, want := range map[string]bool{"": true, "linux/arm64": true, "linux/arm64/v8": true, "linux/amd64": false,
		"linux/amd64,linux/arm64": false, "linux/arm64,linux/amd64": false} {
		if got := buildIsNative(raw); got != want {
			t.Errorf("%q native = %v", raw, got)
		}
	}
}
