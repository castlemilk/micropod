package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"math"
	"net/http"
	"net/url"
	"path"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	"github.com/containerd/platforms"
	"github.com/distribution/reference"
	"github.com/opencontainers/image-spec/identity"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/protobuf/types/known/fieldmaskpb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// dockerImageListFilters is what GET /images/json filters on, as Docker:
// label predicates, dangling (no tag names the image), reference patterns
// (matched against the image's familiar tags and digests), and before and
// since (images created before or after the one named).
type dockerImageListFilters struct {
	labels        []string
	dangling      *bool
	references    []string
	before, since []string
}

func parseDockerImageListFilters(raw string) (dockerImageListFilters, error) {
	var f dockerImageListFilters
	if raw == "" {
		return f, nil
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(raw), &fields) != nil {
		return f, fail(http.StatusBadRequest, "invalid image list filters")
	}
	other := map[string]json.RawMessage{}
	for key, value := range fields {
		switch key {
		case "label":
		case "dangling", "reference", "before", "since":
			other[key] = value
		default:
			return f, fail(http.StatusBadRequest, "unsupported image list filter: "+key)
		}
	}
	labels, err := dockerImageLabelFilters(fields["label"])
	if err != nil {
		return f, err
	}
	f.labels = labels
	if len(other) == 0 {
		return f, nil
	}
	b, _ := json.Marshal(other)
	values, err := dockerFilterValues(string(b), nil, []string{"dangling", "reference", "before", "since"})
	if err != nil {
		return f, fail(http.StatusBadRequest, "invalid image list filter values")
	}
	for _, v := range values["dangling"] {
		d, err := strconv.ParseBool(v)
		if err != nil {
			return f, fail(http.StatusBadRequest, "invalid dangling filter "+strconv.Quote(v))
		}
		f.dangling = &d
	}
	for _, pattern := range values["reference"] {
		if _, err := path.Match(pattern, ""); err != nil {
			return f, fail(http.StatusBadRequest, "invalid reference filter "+strconv.Quote(pattern))
		}
	}
	f.references, f.before, f.since = values["reference"], values["before"], values["since"]
	return f, nil
}

// danglingImage reports whether no name was given to an image: no tag names
// it, and no pull named it by repo:tag@digest (pulledAs). Docker counts a
// digest-only image as dangling; one a client pulled by tag and digest (a
// pinned warm image) it named, and a prune of dangling images keeps it.
func danglingImage(image *cri.Image, pulledAs []string) bool {
	return len(image.GetRepoTags()) == 0 && len(pulledAs) == 0
}

// keepsRow reports whether an image passes dangling and reference.
func (f dockerImageListFilters) keepsRow(image *cri.Image, pulledAs []string) bool {
	if f.dangling != nil && *f.dangling != danglingImage(image, pulledAs) {
		return false
	}
	if len(f.references) == 0 {
		return true
	}
	for _, name := range append(append(slices.Clone(image.GetRepoTags()), pulledAs...), image.GetRepoDigests()...) {
		ref, err := reference.ParseNormalizedNamed(name)
		if err != nil {
			continue
		}
		refs := []reference.Named{ref}
		if tagged, ok := ref.(reference.NamedTagged); ok {
			if _, digested := ref.(reference.Digested); digested {
				// A repo:tag@digest it was pulled as matches as repo:tag too.
				if bare, err := reference.WithTag(reference.TrimNamed(ref), tagged.Tag()); err == nil {
					refs = append(refs, bare)
				}
			}
		}
		for _, pattern := range f.references {
			for _, r := range refs {
				if ok, _ := reference.FamiliarMatch(pattern, r); ok {
					return true
				}
			}
		}
	}
	return false
}

// createdBounds resolves before and since to creation times (Unix seconds)
// by the images they name in rows: an ID, an ID prefix of 12 or more, or a
// tag.
func (f dockerImageListFilters) createdBounds(rows []*cri.Image, configs map[string]dockerImageConfig) (before, since int64, err error) {
	find := func(name string) (int64, error) {
		tag, _ := namedImageTag(name)
		short := strings.TrimPrefix(name, "sha256:")
		for _, row := range rows {
			id := strings.TrimPrefix(row.GetId(), "sha256:")
			if id == short || len(short) >= 12 && strings.HasPrefix(id, short) || tag != nil && slices.ContainsFunc(row.GetRepoTags(), func(t string) bool {
				listed, err := namedImageTag(t)
				return err == nil && listed.String() == tag.String()
			}) {
				return configs[row.GetId()].created, nil
			}
		}
		return 0, fail(http.StatusNotFound, "No such image: "+name)
	}
	before, since = math.MaxInt64, math.MinInt64
	for _, name := range f.before {
		t, err := find(name)
		if err != nil {
			return 0, 0, err
		}
		before = min(before, t)
	}
	for _, name := range f.since {
		t, err := find(name)
		if err != nil {
			return 0, 0, err
		}
		since = max(since, t)
	}
	return before, since, nil
}

func dockerImageLabelFilters(wire json.RawMessage) ([]string, error) {
	if wire == nil {
		return nil, nil
	}
	var predicates []string
	var array []*string
	if json.Unmarshal(wire, &array) == nil {
		for _, value := range array {
			if value == nil {
				return nil, fail(http.StatusBadRequest, "invalid image label filter values")
			}
			predicates = append(predicates, *value)
		}
	} else {
		var set map[string]*bool
		if json.Unmarshal(wire, &set) != nil {
			return nil, fail(http.StatusBadRequest, "invalid image label filter values")
		}
		for value, enabled := range set {
			if enabled == nil {
				return nil, fail(http.StatusBadRequest, "invalid image label filter values")
			}
			// Docker's label filter treats all keys in this object as predicates.
			predicates = append(predicates, value)
		}
	}
	for _, predicate := range predicates {
		key, value, _ := strings.Cut(predicate, "=")
		if strings.HasSuffix(key, "!") {
			return nil, fail(http.StatusBadRequest, "negative image label filters are unsupported")
		}
		// Containerd limits the combined key and value to 4 KiB.
		if len(key)+len(value) > 4096 {
			return nil, fail(http.StatusBadRequest, "image label key and value exceed 4096 bytes")
		}
	}
	return predicates, nil
}

type dockerImageLabelResult struct {
	labels  map[string]string
	present bool
	// config is what the same read says of the image's creation and layers.
	config dockerImageConfig
}

// dockerImageConfigSpec is the part of CRI's verbose image status (the
// image's OCI config, as `docker image inspect` decodes it) that listings use.
type dockerImageConfigSpec struct {
	ImageSpec *struct {
		Created      *time.Time `json:"created"`
		Config       *struct{ Labels map[string]string }
		RootFS       ocispec.RootFS `json:"rootfs"`
		OS           string         `json:"os"`
		Architecture string         `json:"architecture"`
		Variant      string         `json:"variant"`
	} `json:"imageSpec"`
}

func (spec dockerImageConfigSpec) config() dockerImageConfig {
	var c dockerImageConfig
	if spec.ImageSpec == nil {
		return c
	}
	if created := spec.ImageSpec.Created; created != nil && !created.IsZero() && created.Unix() > 0 {
		c.created = created.Unix()
	}
	for _, chain := range identity.ChainIDs(slices.Clone(spec.ImageSpec.RootFS.DiffIDs)) {
		c.chains = append(c.chains, chain.String())
	}
	if spec.ImageSpec.Architecture != "" {
		os := spec.ImageSpec.OS
		if os == "" {
			os = "linux"
		}
		c.platform = platforms.Normalize(ocispec.Platform{OS: os, Architecture: spec.ImageSpec.Architecture, Variant: spec.ImageSpec.Variant})
	}
	return c
}

func (n node) dockerImageListLabels(ctx context.Context, id string) (dockerImageLabelResult, error) {
	if !fullDockerImageID(id) {
		return dockerImageLabelResult{}, fail(http.StatusConflict, "image label lookup requires a full config ID")
	}
	status, err := n.dockerConfigImageStatus(ctx, id, true)
	if err != nil || status.GetImage() == nil {
		return dockerImageLabelResult{}, err
	}
	var details dockerImageConfigSpec
	if json.Unmarshal([]byte(status.GetInfo()["info"]), &details) != nil ||
		details.ImageSpec == nil {
		return dockerImageLabelResult{}, fail(http.StatusServiceUnavailable, "runtime image labels could not be verified")
	}
	result := dockerImageLabelResult{present: true, config: details.config()}
	if details.ImageSpec.Config != nil {
		result.labels = details.ImageSpec.Config.Labels
	}
	return result, nil
}

// dockerImageConfig is what an image's config says of its creation time and
// layers. An image ID is the digest of that config, so neither ever changes
// for an ID.
type dockerImageConfig struct {
	created int64    // Unix seconds; 0 when the config records no time
	chains  []string // the layers' chain IDs (their snapshot keys), base first
	// platform is the config's; zero when it names none.
	platform ocispec.Platform
}

// setPlatform reports the config's platform in a listing row, as `docker
// image inspect` does; a row whose config was not read keeps linux/arm64.
func (c dockerImageConfig) setPlatform(row map[string]any) {
	if c.platform.Architecture == "" {
		return
	}
	row["Os"], row["Architecture"] = c.platform.OS, c.platform.Architecture
	if c.platform.Variant != "" {
		row["Variant"] = c.platform.Variant
	}
}

// dockerImageConfigCache keeps dockerImageConfig per image ID, so a listing
// reads only the configs of images it has not seen before (one verbose CRI
// status each) and the steady state costs no runtime call per image.
type dockerImageConfigCache struct {
	mu      sync.Mutex
	configs map[string]dockerImageConfig
}

func (c *dockerImageConfigCache) store(id string, config dockerImageConfig) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.configs == nil {
		c.configs = make(map[string]dockerImageConfig)
	}
	c.configs[id] = config
}

// dockerImageConfigs returns the config facts of every image in ids, reading
// the ones not yet known, and forgets IDs no longer listed (ids is a whole
// listing). An image whose config cannot be read now is left out, not
// remembered: the next listing tries again.
func (s *dockerEngine) dockerImageConfigs(ctx context.Context, ids []string) map[string]dockerImageConfig {
	out := make(map[string]dockerImageConfig, len(ids))
	listed := make(map[string]bool, len(ids))
	var missing []string
	s.imageConfigs.mu.Lock()
	for _, id := range ids {
		if listed[id] {
			continue
		}
		listed[id] = true
		if config, ok := s.imageConfigs.configs[id]; ok {
			out[id] = config
		} else {
			missing = append(missing, id)
		}
	}
	for id := range s.imageConfigs.configs {
		if !listed[id] {
			delete(s.imageConfigs.configs, id)
		}
	}
	s.imageConfigs.mu.Unlock()
	for _, id := range missing {
		if !fullDockerImageID(id) {
			continue
		}
		status, err := s.node.dockerConfigImageStatus(ctx, id, true)
		if err != nil || status.GetImage() == nil {
			continue
		}
		var details dockerImageConfigSpec
		if json.Unmarshal([]byte(status.GetInfo()["info"]), &details) != nil || details.ImageSpec == nil {
			continue
		}
		out[id] = details.config()
		s.imageConfigs.store(id, out[id])
	}
	return out
}

func (s *dockerEngine) listDockerImages(w http.ResponseWriter, r *http.Request, summary func(*cri.Image) map[string]any) error {
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return fail(http.StatusBadRequest, "invalid image list query")
	}
	filters, err := parseDockerImageListFilters(query.Get("filters"))
	if err != nil {
		return err
	}
	predicates := filters.labels

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	listed, err := s.node.images.ListImages(ctx, &cri.ListImagesRequest{})
	if err != nil {
		return err
	}
	all, pulled, err := s.node.visibleDockerImageNames(ctx, listed.GetImages())
	if err != nil {
		return err
	}
	// MicropodPulledAs (not Docker's) names the repo:tag@digest references
	// the image was pulled as (pulledTagLabel); Docker clients ignore it.
	withPulled := func(image *cri.Image, row map[string]any) map[string]any {
		if names := pulled[image.GetId()]; len(names) != 0 {
			row["MicropodPulledAs"] = names
		}
		return row
	}
	rows := make([]*cri.Image, 0, len(all))
	for _, image := range all {
		if filters.keepsRow(image, pulled[image.GetId()]) {
			rows = append(rows, image)
		}
	}
	created := func(int64) bool { return true }
	if len(filters.before)+len(filters.since) != 0 {
		ids := make([]string, 0, len(all))
		for _, image := range all {
			ids = append(ids, image.GetId())
		}
		before, since, err := filters.createdBounds(all, s.dockerImageConfigs(ctx, ids))
		if err != nil {
			return err
		}
		created = func(t int64) bool { return t < before && t > since }
	}
	list := make([]map[string]any, 0, len(rows))
	if len(predicates) == 0 {
		// Created is the config's time, as Docker reports it: what an
		// age-based groom (`docker image prune --filter until=…`, a
		// runner's own sweep) sorts by. 0 when the config records none.
		ids := make([]string, 0, len(rows))
		for _, image := range rows {
			ids = append(ids, image.GetId())
		}
		configs := s.dockerImageConfigs(ctx, ids)
		for _, image := range rows {
			if !created(configs[image.GetId()].created) {
				continue
			}
			row := withPulled(image, summary(image))
			row["Created"] = configs[image.GetId()].created
			configs[image.GetId()].setPlatform(row)
			list = append(list, row)
		}
		writeJSON(w, http.StatusOK, list)
		return nil
	}

	// CRI summaries omit image config labels. Read each distinct config once
	// for a filtered request and keep tag/size fields from the same inventory.
	checked := make(map[string]dockerImageLabelResult)
	for _, image := range rows {
		id := image.GetId()
		result, ok := checked[id]
		if !ok {
			result, err = s.node.dockerImageListLabels(ctx, id)
			if err != nil {
				return err
			}
			checked[id] = result
			s.imageConfigs.store(id, result.config)
		}
		if result.present && matchesLabels(result.labels, predicates) && created(result.config.created) {
			row := withPulled(image, summary(image))
			row["Labels"] = result.labels
			row["Created"] = result.config.created
			result.config.setPlatform(row)
			list = append(list, row)
		}
	}
	writeJSON(w, http.StatusOK, list)
	return nil
}

type dockerImageCatalog struct {
	exact      map[string]*types.Descriptor
	normalized map[string]*types.Descriptor
	targetIDs  map[string]string
	repoTarget map[[2]string]bool
	managedIDs map[string]bool
}

func dockerImageCatalogReference(name string) string {
	ref, err := reference.ParseNormalizedNamed(name)
	if err != nil {
		return ""
	}
	return reference.TagNameOnly(ref).String()
}

func (catalog dockerImageCatalog) target(ref string) *types.Descriptor {
	if target, ok := catalog.exact[ref]; ok {
		return target
	}
	return catalog.normalized[dockerImageCatalogReference(ref)]
}

// pulledTagLabel prefixes the labels that keep, on a digest reference's
// record (repo@digest), each tag a pull named with it (repo:tag@digest). CRI
// stores such a pull under repo@digest only, as Docker does, so the listing
// lost the name the client pulled by and a client that checks for its image
// by that name (Cuttlefish's warmer) pulled it again at every start. The tag
// is not made a tag of the image: a pinned pull of an older digest must not
// move the tag a newer pull set. The label goes with the record.
const pulledTagLabel = "io.micropod.pulled-tag."

// rememberPulledTag labels the record a pull of raw made when raw names a tag
// and a digest; any other reference needs nothing.
func (n node) rememberPulledTag(ctx context.Context, raw string) error {
	named, err := reference.ParseNormalizedNamed(raw)
	if err != nil {
		return nil
	}
	tagged, isTagged := named.(reference.NamedTagged)
	canonical, isCanonical := named.(reference.Canonical)
	if !isTagged || !isCanonical || n.imageStore == nil {
		return nil
	}
	ctx = imageMetadataContext(ctx)
	name := named.Name() + "@" + canonical.Digest().String()
	got, err := n.imageStore.Get(ctx, &images.GetImageRequest{Name: name})
	if err != nil {
		return fmt.Errorf("read %s: %w", name, err)
	}
	img := got.GetImage()
	key := pulledTagLabel + tagged.Tag()
	if img.GetLabels()[key] != "" {
		return nil
	}
	img.Labels = maps.Clone(img.GetLabels())
	if img.Labels == nil {
		img.Labels = map[string]string{}
	}
	img.Labels[key] = "1"
	_, err = n.imageStore.Update(ctx, &images.UpdateImageRequest{Image: img, UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"labels." + key}}})
	return err
}

// pulledAs is every repo:tag@digest a record's pulled-tag labels name.
func pulledAs(record *images.Image) []string {
	var out []string
	named, err := reference.ParseNormalizedNamed(record.GetName())
	canonical, ok := named.(reference.Canonical)
	if err != nil || !ok {
		return nil
	}
	if _, tagged := named.(reference.Tagged); tagged {
		return nil
	}
	for key := range record.GetLabels() {
		tag, ok := strings.CutPrefix(key, pulledTagLabel)
		if !ok {
			continue
		}
		withTag, err := reference.WithTag(reference.TrimNamed(named), tag)
		if err != nil {
			continue
		}
		if full, err := reference.WithDigest(withTag, canonical.Digest()); err == nil {
			out = append(out, full.String())
		}
	}
	slices.Sort(out)
	return out
}

// CRI uses an asynchronous inventory for readiness, size and labels. Join it
// with the live containerd catalog so a deleted alias cannot keep a row visible.
func (n node) visibleDockerImageRows(ctx context.Context, rows []*cri.Image) ([]*cri.Image, error) {
	visible, _, err := n.visibleDockerImageNames(ctx, rows)
	return visible, err
}

// visibleDockerImageNames is visibleDockerImageRows with, per image ID, the
// repo:tag@digest names its digest references were pulled as (pulledAs).
func (n node) visibleDockerImageNames(ctx context.Context, rows []*cri.Image) ([]*cri.Image, map[string][]string, error) {
	if len(rows) == 0 {
		return nil, nil, nil
	}
	ctx = imageMetadataContext(ctx)
	catalogRows, err := n.imageStore.List(ctx, &images.ListImagesRequest{})
	if err != nil || catalogRows == nil {
		return nil, nil, fail(http.StatusServiceUnavailable, "containerd image inventory could not be verified")
	}
	pulled := map[string][]string{}
	for _, record := range catalogRows.GetImages() {
		if names := pulledAs(record); len(names) != 0 {
			pulled[record.GetName()] = names
		}
	}
	extra := map[string][]string{}
	catalog := dockerImageCatalog{
		exact:      make(map[string]*types.Descriptor, len(catalogRows.GetImages())),
		normalized: make(map[string]*types.Descriptor),
		targetIDs:  make(map[string]string),
		repoTarget: make(map[[2]string]bool),
		managedIDs: make(map[string]bool),
	}
	for _, record := range catalogRows.GetImages() {
		name, target := record.GetName(), record.GetTarget()
		digest := target.GetDigest()
		if name == "" || !fullDockerImageID(digest) || target.GetSize() <= 0 || target.GetMediaType() == "" {
			continue
		}
		catalog.exact[name] = target
		if fullDockerImageID(name) {
			catalog.managedIDs[name] = record.GetLabels()[criManagedImage] == "managed"
			if prior, known := catalog.targetIDs[digest]; known && prior != name {
				catalog.targetIDs[digest] = ""
			} else {
				catalog.targetIDs[digest] = name
			}
			continue
		}
		ref, err := reference.ParseNormalizedNamed(name)
		if err != nil {
			continue
		}
		if digested, ok := ref.(reference.Digested); !ok || digested.Digest().String() == digest {
			catalog.repoTarget[[2]string{ref.Name(), digest}] = true
		}
		normalized := reference.TagNameOnly(ref).String()
		if prior, exists := catalog.normalized[normalized]; exists &&
			(prior.GetDigest() != digest || prior.GetSize() != target.GetSize() || prior.GetMediaType() != target.GetMediaType()) {
			catalog.normalized[normalized] = nil
		} else {
			catalog.normalized[normalized] = target
		}
	}

	visible := make([]*cri.Image, 0, len(rows))
	aliasConfigs := make(map[string]string)
	for _, row := range rows {
		id := row.GetId()
		if !fullDockerImageID(id) {
			continue
		}
		image := &cri.Image{Id: id, Size: row.GetSize()}
		config := catalog.exact[id]
		matchingTargets := make(map[string]bool)
		if config != nil {
			matchingTargets[config.GetDigest()] = true
		}
		for _, name := range row.GetRepoDigests() {
			parsed, err := reference.ParseNormalizedNamed(name)
			ref, canonical := parsed.(reference.Canonical)
			if err != nil || !canonical {
				continue
			}
			digest := ref.Digest().String()
			if targetID, known := catalog.targetIDs[digest]; known && targetID != id && !matchingTargets[digest] {
				continue
			}
			if catalog.repoTarget[[2]string{ref.Name(), digest}] {
				matchingTargets[digest] = true
				image.RepoDigests = append(image.RepoDigests, name)
				extra[id] = append(extra[id], pulled[name]...)
			}
		}
		for _, name := range row.GetRepoTags() {
			target := catalog.target(name)
			if target == nil {
				continue
			}
			digest := target.GetDigest()
			if matchingTargets[digest] || catalog.targetIDs[digest] == id {
				image.RepoTags = append(image.RepoTags, name)
				if catalog.targetIDs[digest] == id && catalog.managedIDs[id] {
					image.RepoDigests = appendDockerTagDigest(image.RepoDigests, dockerTagReference(name), digest)
				}
				continue
			}
			if config != nil {
				continue
			}
			if _, known := catalog.targetIDs[digest]; known {
				continue
			}
			// A legacy tag-only import may lack a generated config record.
			// The current manifest supplies the binding before using that tag.
			switch target.GetMediaType() {
			case ocispec.MediaTypeImageManifest, "application/vnd.docker.distribution.manifest.v2+json":
				configID, known := aliasConfigs[digest]
				if !known {
					configID, err = n.manifestConfigID(ctx, target)
					var problem apiError
					if err != nil && (!errors.As(err, &problem) || problem.code != http.StatusConflict) {
						return nil, nil, fail(http.StatusServiceUnavailable, "containerd image alias could not be verified")
					}
					aliasConfigs[digest] = configID
				}
				if configID == id {
					image.RepoTags = append(image.RepoTags, name)
				}
			}
		}
		if config != nil || len(image.RepoTags) != 0 || len(image.RepoDigests) != 0 {
			visible = append(visible, image)
		}
	}
	return visible, extra, nil
}
