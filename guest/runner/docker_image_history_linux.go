package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"

	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	"github.com/distribution/reference"
	"github.com/opencontainers/image-spec/identity"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"google.golang.org/grpc"
)

type imageLayerUsageClient interface {
	Usage(context.Context, *snapshots.UsageRequest, ...grpc.CallOption) (*snapshots.UsageResponse, error)
}

type dockerImageHistoryEntry struct {
	ID        string `json:"Id"`
	Created   int64
	CreatedBy string
	Tags      []string
	Size      int64
	Comment   string
}

func (s *dockerEngine) imageHistory(w http.ResponseWriter, r *http.Request, ref string) error {
	status, err := s.node.dockerImageStatus(r.Context(), ref, true)
	if err != nil {
		return err
	}
	image := status.GetImage()
	if image == nil {
		return fail(http.StatusNotFound, "No such image")
	}

	var details struct {
		Spec *struct {
			RootFS  ocispec.RootFS    `json:"rootfs"`
			History []ocispec.History `json:"history"`
		} `json:"imageSpec"`
	}
	if err := json.Unmarshal([]byte(status.GetInfo()["info"]), &details); err != nil {
		return fmt.Errorf("decode image history metadata: %w", err)
	}
	if details.Spec == nil {
		return errors.New("image history metadata is unavailable")
	}

	history := details.Spec.History
	entries := make([]dockerImageHistoryEntry, len(history))
	if len(history) == 0 {
		writeJSON(w, http.StatusOK, entries)
		return nil
	}
	var layers int
	for _, entry := range history {
		if !entry.EmptyLayer {
			layers++
		}
	}
	if diffIDs := len(details.Spec.RootFS.DiffIDs); layers > diffIDs {
		return fmt.Errorf("image history describes %d filesystem entries for %d layers", layers, diffIDs)
	}

	// The committed overlay snapshot's usage measures each filesystem change.
	// Chain IDs identify snapshots, including when a diff appears under different parents.
	chains := identity.ChainIDs(details.Spec.RootFS.DiffIDs[:layers])
	ctx := dockerRootFSContext(r.Context())
	for i, entry := range history {
		item := &entries[len(entries)-1-i]
		item.ID = "<missing>"
		item.CreatedBy = entry.CreatedBy
		item.Comment = entry.Comment
		if entry.Created != nil {
			item.Created = entry.Created.Unix()
		}
		if entry.EmptyLayer {
			continue
		}
		key := chains[0].String()
		usage, err := s.node.imageUsage.Usage(ctx, &snapshots.UsageRequest{Snapshotter: dockerRootFSSnapshotter, Key: key})
		if err != nil {
			return fmt.Errorf("read image layer %s snapshot usage: %w", key, err)
		}
		if usage == nil || usage.Size < 0 {
			return fmt.Errorf("invalid image layer %s snapshot usage", key)
		}
		item.Size = usage.Size
		chains = chains[1:]
	}

	// CRI identifies the inspected image. OCI history does not identify its ancestors.
	entries[0].ID = image.GetId()
	for _, raw := range image.GetRepoTags() {
		if tag, err := reference.ParseNormalizedNamed(raw); err == nil {
			if _, tagged := tag.(reference.NamedTagged); tagged {
				entries[0].Tags = append(entries[0].Tags, reference.FamiliarString(tag))
			}
		}
	}
	slices.Sort(entries[0].Tags)
	entries[0].Tags = slices.Compact(entries[0].Tags)
	writeJSON(w, http.StatusOK, entries)
	return nil
}
