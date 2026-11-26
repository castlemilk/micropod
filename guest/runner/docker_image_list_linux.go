package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	images "github.com/containerd/containerd/api/services/images/v1"
	"github.com/containerd/containerd/api/types"
	"github.com/distribution/reference"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func dockerImageLabelFilters(raw string) ([]string, error) {
	if raw == "" {
		return nil, nil
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(raw), &fields) != nil {
		return nil, fail(http.StatusBadRequest, "invalid image list filters")
	}
	for key := range fields {
		if key != "label" {
			return nil, fail(http.StatusBadRequest, "unsupported image list filter: "+key)
		}
	}
	wire, exists := fields["label"]
	if !exists {
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
}

func (n node) dockerImageListLabels(ctx context.Context, id string) (dockerImageLabelResult, error) {
	if !fullDockerImageID(id) {
		return dockerImageLabelResult{}, fail(http.StatusConflict, "image label lookup requires a full config ID")
	}
	status, err := n.dockerConfigImageStatus(ctx, id, true)
	if err != nil || status.GetImage() == nil {
		return dockerImageLabelResult{}, err
	}
	var details struct {
		ImageSpec *struct {
			Config *struct{ Labels map[string]string }
		}
	}
	if json.Unmarshal([]byte(status.GetInfo()["info"]), &details) != nil ||
		details.ImageSpec == nil {
		return dockerImageLabelResult{}, fail(http.StatusServiceUnavailable, "runtime image labels could not be verified")
	}
	if details.ImageSpec.Config == nil {
		return dockerImageLabelResult{present: true}, nil
	}
	return dockerImageLabelResult{labels: details.ImageSpec.Config.Labels, present: true}, nil
}

func (s *dockerEngine) listDockerImages(w http.ResponseWriter, r *http.Request, summary func(*cri.Image) map[string]any) error {
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return fail(http.StatusBadRequest, "invalid image list query")
	}
	predicates, err := dockerImageLabelFilters(query.Get("filters"))
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	listed, err := s.node.images.ListImages(ctx, &cri.ListImagesRequest{})
	if err != nil {
		return err
	}
	rows, err := s.node.visibleDockerImageRows(ctx, listed.GetImages())
	if err != nil {
		return err
	}
	list := make([]map[string]any, 0, len(rows))
	if len(predicates) == 0 {
		for _, image := range rows {
			list = append(list, summary(image))
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
		}
		if result.present && matchesLabels(result.labels, predicates) {
			row := summary(image)
			row["Labels"] = result.labels
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

// CRI uses an asynchronous inventory for readiness, size and labels. Join it
// with the live containerd catalog so a deleted alias cannot keep a row visible.
func (n node) visibleDockerImageRows(ctx context.Context, rows []*cri.Image) ([]*cri.Image, error) {
	if len(rows) == 0 {
		return nil, nil
	}
	ctx = imageMetadataContext(ctx)
	catalogRows, err := n.imageStore.List(ctx, &images.ListImagesRequest{})
	if err != nil || catalogRows == nil {
		return nil, fail(http.StatusServiceUnavailable, "containerd image inventory could not be verified")
	}
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
						return nil, fail(http.StatusServiceUnavailable, "containerd image alias could not be verified")
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
	return visible, nil
}
