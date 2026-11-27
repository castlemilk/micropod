package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"maps"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	images "github.com/containerd/containerd/api/services/images/v1"
	streaming "github.com/containerd/containerd/api/services/streaming/v1"
	transferapi "github.com/containerd/containerd/api/services/transfer/v1"
	"github.com/containerd/containerd/api/types"
	transfer "github.com/containerd/containerd/api/types/transfer"
	"github.com/containerd/containerd/errdefs"
	"github.com/containerd/containerd/remotes"
	"github.com/containerd/containerd/remotes/docker"
	dockerconfig "github.com/containerd/containerd/remotes/docker/config"
	"github.com/containerd/platforms"
	"github.com/distribution/reference"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/fieldmaskpb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// Images for linux/amd64, beside the native ones.
//
// CRI pulls, resolves and creates for linux/arm64 only (containerd 2.4's CRI
// image store selects with platforms.Default(), and an index record whose
// arm64 image is not present fails every CRI lookup and image event). One
// shape works for any platform: an image record whose target is a single
// manifest. CRI resolves such a record without a platform check, and
// containerd's transfer service unpacks any linux image. So a pull for
// linux/amd64 stores the amd64 image under its own digest name and leaves the
// tag's native image alone:
//
//  1. The engine resolves the reference at the registry (one manifest GET of
//     the index, or of the manifest and its config for a single-platform
//     image) and picks the linux/amd64 manifest, as Docker does.
//  2. The transfer service pulls <repository>@<that manifest's digest>,
//     unpacked for linux/amd64, into a record of that name. The record is
//     labelled with the index it came from (emulatedIndexLabel) and the tag
//     it was pulled by (emulatedTagLabel), so a create by the index digest or
//     the tag finds it. CRI indexes it from containerd's image event and adds
//     its config-ID record, as for any image it did not pull itself.
//  3. A pull by tag points the tag at the amd64 image only when the tag names
//     nothing yet, or names an earlier amd64 image. A tag that names a
//     native image keeps it, so a create or pull with no platform still gets
//     linux/arm64; `--platform linux/amd64` gets the amd64 image.
//  4. imageSync.Sync makes what the pull stored durable before it answers,
//     as for a native pull (image_durability_linux.go).
//
// Both platforms of a multi-platform image then live side by side: the tag
// (and the index digest, once pulled natively) is the native image, and the
// amd64 image has its own config ID, its own digest name and its own layers.
const (
	emulatedIndexLabel     = "io.micropod.platform.index"
	emulatedPlatformLabel  = "io.micropod.platform"
	emulatedTagLabelPrefix = "io.micropod.platform.tag."
	// What a registry index or manifest may be; Docker's own limit is 4 MiB.
	registryManifestLimit = 4 << 20
)

// emulatedTagLabel is the label key that names a tag on the amd64 image last
// pulled by it. A key per tag lets one image carry several tags and a lookup
// filter by key; the value is the tag itself.
func emulatedTagLabel(tag string) string {
	sum := sha256.Sum256([]byte(tag))
	return emulatedTagLabelPrefix + hex.EncodeToString(sum[:12])
}

// registryResolver resolves a reference at its registry and fetches blobs of
// its repository.
type registryResolver interface {
	resolve(ctx context.Context, ref string, auth *cri.AuthConfig) (ocispec.Descriptor, registryFetch, error)
}

type registryFetch func(context.Context, ocispec.Descriptor) ([]byte, error)

// platformPuller pulls one manifest by digest into a named record, unpacked
// for a platform.
type platformPuller interface {
	pullPlatform(ctx context.Context, name string, platform ocispec.Platform, auth *cri.AuthConfig, labels map[string]string) error
}

// registryHostDir is where CRI reads registry host configuration
// (hosts.toml, certificates) by default; the emulated pull reads the same.
func registryHostDir() string {
	for _, dir := range []string{"/etc/containerd/certs.d", "/etc/docker/certs.d"} {
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			return dir
		}
	}
	return ""
}

// dockerRegistryResolver is containerd's own registry client, configured as
// CRI configures its pulls: the same hosts directory, Docker Hub's host
// mapping and the request's credentials for the reference's registry only.
type dockerRegistryResolver struct{}

func (dockerRegistryResolver) resolve(ctx context.Context, ref string, auth *cri.AuthConfig) (ocispec.Descriptor, registryFetch, error) {
	named, err := reference.ParseNormalizedNamed(ref)
	if err != nil {
		return ocispec.Descriptor{}, nil, err
	}
	registry := pushRegistryHost(reference.Domain(named))
	options := dockerconfig.HostOptions{
		Credentials: func(host string) (string, string, error) {
			if auth == nil || pushRegistryHost(host) != registry {
				return "", "", nil
			}
			if auth.GetIdentityToken() != "" {
				return "", auth.GetIdentityToken(), nil
			}
			return auth.GetUsername(), auth.GetPassword(), nil
		},
	}
	if dir := registryHostDir(); dir != "" {
		options.HostDir = dockerconfig.HostDirFromRoot(dir)
	}
	resolver := docker.NewResolver(docker.ResolverOptions{Hosts: dockerconfig.ConfigureHosts(ctx, options)})
	name, root, err := resolver.Resolve(ctx, named.String())
	if err != nil {
		return ocispec.Descriptor{}, nil, err
	}
	fetcher, err := resolver.Fetcher(ctx, name)
	if err != nil {
		return ocispec.Descriptor{}, nil, err
	}
	return root, func(ctx context.Context, desc ocispec.Descriptor) ([]byte, error) {
		return fetchRegistryBlob(ctx, fetcher, desc)
	}, nil
}

func fetchRegistryBlob(ctx context.Context, fetcher remotes.Fetcher, desc ocispec.Descriptor) ([]byte, error) {
	if desc.Size <= 0 || desc.Size > registryManifestLimit {
		return nil, fmt.Errorf("%s is %d bytes, more than an image manifest may be", desc.Digest, desc.Size)
	}
	rc, err := fetcher.Fetch(ctx, desc)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	data, err := io.ReadAll(io.LimitReader(rc, desc.Size+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != desc.Size || desc.Digest.Algorithm().FromBytes(data) != desc.Digest {
		return nil, fmt.Errorf("%s does not match the registry's descriptor", desc.Digest)
	}
	return data, nil
}

func isIndexDescriptor(mediaType string) bool {
	return mediaType == ocispec.MediaTypeImageIndex || mediaType == "application/vnd.docker.distribution.manifest.list.v2+json"
}

func isManifestDescriptor(mediaType string) bool {
	return mediaType == ocispec.MediaTypeImageManifest || mediaType == "application/vnd.docker.distribution.manifest.v2+json"
}

// selectPlatformManifest picks the manifest for want from what the reference
// resolved to: the best match of an index's entries (attestations, which name
// unknown/unknown, never match), or the single manifest itself when its
// config names that platform. The answers for an image without that platform
// are Docker's.
func selectPlatformManifest(ctx context.Context, ref string, root ocispec.Descriptor, want ocispec.Platform, fetch registryFetch) (ocispec.Descriptor, error) {
	matcher := platforms.Only(want)
	switch {
	case isIndexDescriptor(root.MediaType):
		raw, err := fetch(ctx, root)
		if err != nil {
			return ocispec.Descriptor{}, fmt.Errorf("fetch the image index of %s: %w", ref, err)
		}
		var index ocispec.Index
		if err := json.Unmarshal(raw, &index); err != nil {
			return ocispec.Descriptor{}, fail(http.StatusConflict, "the image index of "+ref+" could not be read: "+err.Error())
		}
		var pick *ocispec.Descriptor
		for i := range index.Manifests {
			m := &index.Manifests[i]
			if m.Platform == nil || !isManifestDescriptor(m.MediaType) || !matcher.Match(platforms.Normalize(*m.Platform)) {
				continue
			}
			if pick == nil || matcher.Less(platforms.Normalize(*m.Platform), platforms.Normalize(*pick.Platform)) {
				pick = m
			}
		}
		if pick == nil {
			return ocispec.Descriptor{}, fail(http.StatusNotFound, "no matching manifest for "+platforms.Format(want)+
				" in the manifest list entries: "+ref+" has no "+platforms.Format(want)+" image")
		}
		return *pick, nil
	case isManifestDescriptor(root.MediaType):
		raw, err := fetch(ctx, root)
		if err != nil {
			return ocispec.Descriptor{}, fmt.Errorf("fetch the image manifest of %s: %w", ref, err)
		}
		var manifest ocispec.Manifest
		if err := json.Unmarshal(raw, &manifest); err != nil || manifest.Config.Digest == "" {
			return ocispec.Descriptor{}, fail(http.StatusConflict, "the image manifest of "+ref+" could not be read")
		}
		raw, err = fetch(ctx, manifest.Config)
		if err != nil {
			return ocispec.Descriptor{}, fmt.Errorf("fetch the image config of %s: %w", ref, err)
		}
		var config ocispec.Image
		if err := json.Unmarshal(raw, &config); err != nil {
			return ocispec.Descriptor{}, fail(http.StatusConflict, "the image config of "+ref+" could not be read")
		}
		have := platforms.Normalize(ocispec.Platform{OS: config.OS, Architecture: config.Architecture, Variant: config.Variant})
		if !matcher.Match(have) {
			return ocispec.Descriptor{}, fail(http.StatusNotFound, "image with reference "+ref+
				" was found but does not match the specified platform: wanted "+platforms.Format(want)+", actual: "+platforms.Format(have))
		}
		desc := root
		desc.Platform = &have
		return desc, nil
	default:
		return ocispec.Descriptor{}, fail(http.StatusConflict, ref+" is a "+root.MediaType+", not an image")
	}
}

// registryPullError says what a failed resolution means, as Docker does.
func registryPullError(ref string, err error) error {
	var problem apiError
	switch {
	case errors.As(err, &problem):
		return err
	case errdefs.IsNotFound(err) || status.Code(err) == codes.NotFound:
		return fail(http.StatusNotFound, "pull access denied for "+ref+", repository does not exist or may require 'docker login': "+err.Error())
	case strings.Contains(err.Error(), "401 Unauthorized") || strings.Contains(err.Error(), "403 Forbidden"):
		return fail(http.StatusForbidden, "pull access denied for "+ref+": "+err.Error())
	default:
		return err
	}
}

// pullEmulatedImage serves `docker pull --platform linux/amd64` (and any other
// platform requestedPlatform accepts that is not the engine's own).
func (s *dockerEngine) pullEmulatedImage(w http.ResponseWriter, r *http.Request, ref string, want ocispec.Platform, auth *cri.AuthConfig) error {
	if s.node.registry == nil || s.node.platformPull == nil {
		return fail(http.StatusServiceUnavailable, "the engine cannot pull "+platforms.Format(want)+" images: containerd's transfer service is unavailable")
	}
	parsed, err := reference.ParseNormalizedNamed(ref)
	if err != nil {
		return fail(http.StatusBadRequest, "invalid pull reference")
	}
	named := reference.TagNameOnly(parsed)
	ctx := r.Context()
	root, fetch, err := s.node.registry.resolve(ctx, named.String(), auth)
	if err != nil {
		return registryPullError(ref, err)
	}
	manifest, err := selectPlatformManifest(ctx, ref, root, want, fetch)
	if err != nil {
		return err
	}
	pinned := named.Name() + "@" + manifest.Digest.String()
	labels := map[string]string{emulatedPlatformLabel: platforms.Format(platforms.Normalize(*manifestPlatform(manifest, want)))}
	if isIndexDescriptor(root.MediaType) {
		labels[emulatedIndexLabel] = root.Digest.String()
	}
	tag, byTag := named.(reference.NamedTagged)
	if _, digested := named.(reference.Canonical); digested {
		byTag = false
	}
	if byTag {
		labels[emulatedTagLabel(tag.String())] = tag.String()
	}
	// The same lock a native pull holds: a pull may store while other pulls
	// store, never while a tag or an ID is being removed.
	s.imageMu.RLock()
	defer s.imageMu.RUnlock()
	// The transfer replaces a record that exists: keep its labels (CRI's,
	// and the tags other pulls left on this image).
	stored := maps.Clone(labels)
	if existing, err := s.node.imageStore.Get(imageMetadataContext(ctx), &images.GetImageRequest{Name: pinned}); err == nil {
		for key, value := range existing.GetImage().GetLabels() {
			if _, ok := stored[key]; !ok {
				stored[key] = value
			}
		}
	} else if status.Code(err) != codes.NotFound {
		return fmt.Errorf("read the image record %s: %w", pinned, err)
	}
	if err := s.node.platformPull.pullPlatform(ctx, pinned, *manifestPlatform(manifest, want), auth, stored); err != nil {
		return registryPullError(ref, err)
	}
	// A record from an earlier pull keeps its labels: merge this pull's in.
	if err := s.node.labelEmulatedImage(ctx, pinned, labels); err != nil {
		return err
	}
	if byTag {
		if err := s.node.moveEmulatedTagLabel(ctx, tag.String(), pinned); err != nil {
			return err
		}
		if err := s.node.pointTagAtEmulated(ctx, tag.String(), root, manifest); err != nil {
			return err
		}
	}
	if err := s.node.awaitEmulatedImage(ctx, pinned); err != nil {
		return err
	}
	// The unpacked files are on the disk before the pull answers
	// (image_durability_linux.go).
	if err := imageSync.Sync(); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "Downloaded " + ref + " (" + platforms.Format(want) + ", " + manifest.Digest.String() + ")"})
	return nil
}

func manifestPlatform(manifest ocispec.Descriptor, want ocispec.Platform) *ocispec.Platform {
	if manifest.Platform != nil {
		p := platforms.Normalize(*manifest.Platform)
		return &p
	}
	return &want
}

func (n node) labelEmulatedImage(ctx context.Context, name string, labels map[string]string) error {
	storeCtx := imageMetadataContext(ctx)
	current, err := n.imageStore.Get(storeCtx, &images.GetImageRequest{Name: name})
	if err != nil {
		return fmt.Errorf("read the pulled image record %s: %w", name, err)
	}
	record := current.GetImage()
	var paths []string
	for key, value := range labels {
		if record.GetLabels()[key] != value {
			paths = append(paths, "labels."+key)
		}
	}
	if len(paths) == 0 {
		return nil
	}
	_, err = n.imageStore.Update(storeCtx, &images.UpdateImageRequest{
		Image:      &images.Image{Name: name, Labels: labels},
		UpdateMask: &fieldmaskpb.FieldMask{Paths: paths},
	})
	if err != nil {
		return fmt.Errorf("label the pulled image record %s: %w", name, err)
	}
	return nil
}

// moveEmulatedTagLabel leaves the tag's label on the image just pulled only:
// the tag means the image it was last pulled as.
func (n node) moveEmulatedTagLabel(ctx context.Context, tag, pinned string) error {
	storeCtx := imageMetadataContext(ctx)
	key := emulatedTagLabel(tag)
	rows, err := n.imageStore.List(storeCtx, &images.ListImagesRequest{Filters: []string{"labels." + strconv.Quote(key)}})
	if err != nil {
		return fmt.Errorf("list the images pulled as %s: %w", tag, err)
	}
	for _, row := range rows.GetImages() {
		if row.GetName() == pinned {
			continue
		}
		_, err := n.imageStore.Update(storeCtx, &images.UpdateImageRequest{
			Image:      &images.Image{Name: row.GetName()},
			UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"labels." + key}},
		})
		if err != nil && status.Code(err) != codes.NotFound {
			return fmt.Errorf("move %s from %s: %w", tag, row.GetName(), err)
		}
	}
	return nil
}

// pointTagAtEmulated names the pulled image by its tag when the tag names
// nothing else that runs natively: no record yet, or an earlier image of
// another platform. A tag naming a native image (a multi-platform index
// pulled with no platform, or an arm64 manifest) keeps it.
func (n node) pointTagAtEmulated(ctx context.Context, tag string, root, manifest ocispec.Descriptor) error {
	storeCtx := imageMetadataContext(ctx)
	target := &types.Descriptor{MediaType: manifest.MediaType, Digest: manifest.Digest.String(), Size: manifest.Size}
	current, err := n.imageStore.Get(storeCtx, &images.GetImageRequest{Name: tag})
	if status.Code(err) == codes.NotFound {
		_, err = n.imageStore.Create(storeCtx, &images.CreateImageRequest{Image: &images.Image{Name: tag, Target: target}})
		if status.Code(err) == codes.AlreadyExists {
			return nil // a concurrent pull named it first
		}
		if err != nil {
			return fmt.Errorf("tag %s: %w", tag, err)
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("read tag %s: %w", tag, err)
	}
	have := current.GetImage().GetTarget()
	if have.GetDigest() == manifest.Digest.String() || have.GetDigest() == root.Digest.String() {
		return nil
	}
	if isIndexDescriptor(have.GetMediaType()) {
		return nil // CRI resolved this index for linux/arm64: the tag is native
	}
	native, err := n.recordRunsNatively(ctx, have)
	if err != nil || native {
		return err
	}
	_, err = n.imageStore.Update(storeCtx, &images.UpdateImageRequest{
		Image:      &images.Image{Name: tag, Target: target},
		UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"target"}},
	})
	if err != nil {
		return fmt.Errorf("move tag %s: %w", tag, err)
	}
	return nil
}

// recordRunsNatively reads a single-manifest record's config platform.
func (n node) recordRunsNatively(ctx context.Context, target *types.Descriptor) (bool, error) {
	ctx = imageMetadataContext(ctx)
	raw, err := n.readVerifiedImageBlob(ctx, target, "image manifest")
	if err != nil {
		return false, err
	}
	var manifest ocispec.Manifest
	if err := json.Unmarshal(raw, &manifest); err != nil || manifest.Config.Digest == "" {
		return false, fail(http.StatusConflict, "image manifest could not be read")
	}
	raw, err = n.readVerifiedImageBlob(ctx, &types.Descriptor{MediaType: manifest.Config.MediaType, Digest: manifest.Config.Digest.String(), Size: manifest.Config.Size}, "image config")
	if err != nil {
		return false, err
	}
	var config ocispec.Image
	if err := json.Unmarshal(raw, &config); err != nil {
		return false, fail(http.StatusConflict, "image config could not be read")
	}
	return platforms.OnlyStrict(nativePlatform).Match(platforms.Normalize(config.Platform)), nil
}

// awaitEmulatedImage waits for CRI to index the pulled record from
// containerd's image event (it then adds the config-ID record and its
// managed label), so the next request finds the image.
func (n node) awaitEmulatedImage(ctx context.Context, name string) error {
	return waitForDockerImageIndex(ctx, func(visible context.Context) (bool, error) {
		record, err := n.imageStore.Get(imageMetadataContext(visible), &images.GetImageRequest{Name: name})
		if err != nil {
			return false, err
		}
		if record.GetImage().GetLabels()[criManagedImage] != "managed" {
			return false, nil
		}
		lookup, err := n.images.ImageStatus(visible, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: name}})
		return lookup.GetImage().GetId() != "", err
	})
}

// pullPlatform is a transfer-service pull of one manifest, by digest, into a
// record of that name, unpacked for its platform. Credentials, when the
// request carries them, go to the reference's registry only.
func (p dockerRegistryPusher) pullPlatform(ctx context.Context, name string, platform ocispec.Platform, auth *cri.AuthConfig, labels map[string]string) error {
	if p.transfer == nil || p.streams == nil {
		return status.Error(codes.Unavailable, "containerd image transfer is unavailable")
	}
	named, err := reference.ParseNormalizedNamed(name)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(imageMetadataContext(ctx))
	defer cancel()
	resolver := &transfer.RegistryResolver{HostDir: registryHostDir()}
	credentials := registryPushCredentials{kind: transfer.AuthType_NONE}
	if auth != nil {
		switch {
		case auth.GetIdentityToken() != "":
			credentials = registryPushCredentials{kind: transfer.AuthType_REFRESH, secret: auth.GetIdentityToken()}
		case auth.GetUsername() != "" || auth.GetPassword() != "":
			credentials = registryPushCredentials{kind: transfer.AuthType_CREDENTIALS, username: auth.GetUsername(), secret: auth.GetPassword()}
		}
	}
	authDone := make(chan error, 1)
	if credentials.kind != transfer.AuthType_NONE {
		resolver.AuthStream = "docker-pull-auth-" + rand.Text()
		stream, err := p.openStream(ctx, resolver.AuthStream)
		if err != nil {
			return err
		}
		registry := pushRegistryHost(reference.Domain(named))
		go func() {
			err := serveRegistryCredentials(stream, registry, credentials)
			if errors.Is(err, io.EOF) || ctx.Err() != nil {
				err = nil
			}
			authDone <- err
		}()
	} else {
		authDone <- nil
	}
	source, err := registryPushAny(&transfer.OCIRegistry{Reference: name, Resolver: resolver})
	if err != nil {
		return err
	}
	pl := &types.Platform{OS: platform.OS, Architecture: platform.Architecture, Variant: platform.Variant}
	destination, err := registryPushAny(&transfer.ImageStore{
		Name: name, Labels: labels, Platforms: []*types.Platform{pl},
		Unpacks: []*transfer.UnpackConfiguration{{Platform: pl, Snapshotter: dockerRootFSSnapshotter}},
	})
	if err != nil {
		return err
	}
	started := time.Now()
	_, err = p.transfer.Transfer(ctx, &transferapi.TransferRequest{Source: source, Destination: destination})
	cancel()
	if authErr := <-authDone; err == nil && authErr != nil {
		err = authErr
	}
	if err == nil {
		log.Printf("pulled %s for %s in %s", name, platforms.Format(platform), time.Since(started).Round(time.Millisecond))
	}
	return err
}

// serveRegistryCredentials answers containerd's credential requests during a
// transfer with the request's credentials, for their registry only.
func serveRegistryCredentials(stream streaming.Streaming_StreamClient, registry string, credentials registryPushCredentials) error {
	for {
		message, err := stream.Recv()
		if err != nil {
			return err
		}
		var request transfer.AuthRequest
		if err := unmarshalRegistryPushAny(message, &request); err != nil {
			return err
		}
		response := &transfer.AuthResponse{}
		if pushRegistryHost(request.GetHost()) == registry {
			response.AuthType = credentials.kind
			response.Username = credentials.username
			response.Secret = credentials.secret
		}
		message, err = registryPushAny(response)
		if err != nil {
			return err
		}
		if err := stream.Send(message); err != nil {
			return err
		}
	}
}

// dockerPlatformImageStatus resolves a create's image for the platform it
// names (nil: none, and the reference resolves as it always has). An image of
// another platform under the same reference is looked up by what an emulated
// pull recorded (emulatedAlternative). A reference that names only an image of
// another platform is Docker's not-found, so `docker run --platform` pulls
// the right one and tries again.
func (n node) dockerPlatformImageStatus(ctx context.Context, ref string, want *ocispec.Platform) (*cri.ImageStatusResponse, error) {
	img, err := n.dockerImageStatus(ctx, ref, true)
	if err != nil || want == nil {
		return img, err
	}
	var found *ocispec.Platform
	if img.GetImage().GetId() != "" {
		have, ok := imagePlatform(img)
		if !ok || platformMatches(*want, have) {
			return img, nil
		}
		found = &have
	}
	alternative, err := n.emulatedAlternative(ctx, ref, *want)
	if err != nil {
		return nil, err
	}
	if alternative != "" {
		other, err := n.dockerImageStatus(ctx, alternative, true)
		if err != nil {
			return nil, err
		}
		if other.GetImage().GetId() != "" {
			if have, ok := imagePlatform(other); !ok || platformMatches(*want, have) {
				return other, nil
			}
		}
	}
	if found != nil {
		return nil, fail(http.StatusNotFound, "image with reference "+ref+" was found but does not match the specified platform: wanted "+
			platforms.Format(*want)+", actual: "+platforms.Format(*found))
	}
	return &cri.ImageStatusResponse{}, nil
}

// emulatedAlternative names the local image of platform want that ref means,
// "" when there is none: for a tag, the image last pulled by that tag for
// want, else want's entry of the index the tag names; for a digest, the image
// pulled for want from that index, else want's entry of that index when it
// is local. An image ID names one image and has no alternative.
func (n node) emulatedAlternative(ctx context.Context, ref string, want ocispec.Platform) (string, error) {
	if possibleImageID.MatchString(ref) || bareHexImageTag(ref) != nil {
		return "", nil
	}
	parsed, err := reference.ParseNormalizedNamed(ref)
	if err != nil {
		return "", nil
	}
	named := reference.TagNameOnly(parsed)
	storeCtx := imageMetadataContext(ctx)
	var filter string
	if digested, ok := named.(reference.Canonical); ok {
		filter = "labels." + strconv.Quote(emulatedIndexLabel) + "==" + strconv.Quote(digested.Digest().String())
	} else if tagged, ok := named.(reference.NamedTagged); ok {
		filter = "labels." + strconv.Quote(emulatedTagLabel(tagged.String()))
	}
	if filter != "" {
		rows, err := n.imageStore.List(storeCtx, &images.ListImagesRequest{Filters: []string{filter}})
		if err != nil {
			return "", fmt.Errorf("look up the %s image of %s: %w", platforms.Format(want), ref, err)
		}
		for _, row := range rows.GetImages() {
			p, err := platforms.Parse(row.GetLabels()[emulatedPlatformLabel])
			if err != nil || !platformMatches(want, p) {
				continue
			}
			if candidate, err := reference.ParseNormalizedNamed(row.GetName()); err == nil && candidate.Name() == named.Name() {
				return row.GetName(), nil
			}
		}
	}
	// The index the reference names, when it is local, lists want's manifest.
	record, err := n.imageStore.Get(storeCtx, &images.GetImageRequest{Name: named.String()})
	if status.Code(err) == codes.NotFound {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("read the image record %s: %w", named, err)
	}
	target := record.GetImage().GetTarget()
	if !isIndexDescriptor(target.GetMediaType()) {
		return "", nil
	}
	raw, err := n.readVerifiedImageBlob(storeCtx, target, "image index")
	if err != nil {
		var problem apiError
		if errors.As(err, &problem) {
			return "", nil
		}
		return "", err
	}
	var index ocispec.Index
	if json.Unmarshal(raw, &index) != nil {
		return "", nil
	}
	matcher := platforms.Only(want)
	var pick *ocispec.Descriptor
	for i := range index.Manifests {
		m := &index.Manifests[i]
		if m.Platform != nil && isManifestDescriptor(m.MediaType) && matcher.Match(platforms.Normalize(*m.Platform)) &&
			(pick == nil || matcher.Less(platforms.Normalize(*m.Platform), platforms.Normalize(*pick.Platform))) {
			pick = m
		}
	}
	if pick == nil {
		return "", nil
	}
	name := named.Name() + "@" + pick.Digest.String()
	if _, err := n.imageStore.Get(storeCtx, &images.GetImageRequest{Name: name}); err != nil {
		if status.Code(err) == codes.NotFound {
			return "", nil
		}
		return "", fmt.Errorf("read the image record %s: %w", name, err)
	}
	return name, nil
}
