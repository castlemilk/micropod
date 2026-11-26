package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"

	content "github.com/containerd/containerd/api/services/content/v1"
	"golang.org/x/sys/unix"
)

type dockerImageHealth struct {
	Healthcheck *dockerHealthConfig
	Shell       []string
}

func (s *dockerEngine) configureDockerHealth(ctx context.Context, config *dockerConfig, imageID string) error {
	image, err := s.imageHealth(ctx, imageID)
	if err != nil {
		return err
	}
	config.Healthcheck = mergeDockerHealth(config.Healthcheck, image.Healthcheck)
	if err := config.Healthcheck.validate(); err != nil {
		return fail(http.StatusBadRequest, err.Error())
	}
	if len(config.Healthcheck.command(config.Shell)) > 0 && (s.node.execTasks == nil || s.node.containers == nil) {
		return fail(http.StatusServiceUnavailable, "containerd health check execution is unavailable")
	}
	return nil
}

func (s *dockerEngine) inspectDockerImageConfig(ctx context.Context, id string, spec json.RawMessage) (any, error) {
	image, err := s.imageHealth(ctx, id)
	if err != nil {
		return nil, err
	}
	if image.Healthcheck == nil && len(image.Shell) == 0 {
		return spec, nil
	}
	var config map[string]json.RawMessage
	if len(spec) != 0 && json.Unmarshal(spec, &config) != nil {
		return nil, fail(http.StatusConflict, "image Config has invalid metadata")
	}
	if config == nil {
		config = make(map[string]json.RawMessage)
	}
	if image.Healthcheck != nil {
		config["Healthcheck"], err = json.Marshal(image.Healthcheck)
		if err != nil {
			return nil, err
		}
	}
	if len(image.Shell) != 0 {
		config["Shell"], err = json.Marshal(image.Shell)
		if err != nil {
			return nil, err
		}
	}
	return config, nil
}

const (
	dockerHealthImageEntries   = 128
	dockerHealthImageEntrySize = 16 << 10
)

type dockerImageHealthLookup struct {
	done      chan struct{}
	image     dockerImageHealth
	err       error
	abandoned bool
}

type dockerImageHealthCache struct {
	mu      sync.Mutex
	byID    map[string]dockerImageHealth
	pending map[string]*dockerImageHealthLookup
	order   [dockerHealthImageEntries]string
	next    int
}

// ImageStatus decodes into the OCI image config, which omits Healthcheck and Shell.
// Read those fields from the selected config digest, independent of the current tag.
func (s *dockerEngine) imageHealth(ctx context.Context, id string) (dockerImageHealth, error) {
	cache := &s.healthImages
	for {
		cache.mu.Lock()
		if image, found := cache.byID[id]; found {
			cache.mu.Unlock()
			return image, nil
		}
		if pending := cache.pending[id]; pending != nil {
			cache.mu.Unlock()
			select {
			case <-pending.done:
				if pending.abandoned && ctx.Err() == nil {
					continue
				}
				return pending.image, pending.err
			case <-ctx.Done():
				return dockerImageHealth{}, ctx.Err()
			}
		}
		if cache.pending == nil {
			cache.pending = make(map[string]*dockerImageHealthLookup)
		}
		pending := &dockerImageHealthLookup{done: make(chan struct{})}
		cache.pending[id] = pending
		cache.mu.Unlock()

		image, err := s.node.readImageHealth(ctx, id, engineRoot)
		cache.mu.Lock()
		if err == nil && image.cacheable() {
			if cache.byID == nil {
				cache.byID = make(map[string]dockerImageHealth)
			}
			delete(cache.byID, cache.order[cache.next])
			cache.order[cache.next] = id
			cache.next = (cache.next + 1) % len(cache.order)
			cache.byID[id] = image
		}
		pending.image, pending.err, pending.abandoned = image, err, ctx.Err() != nil
		delete(cache.pending, id)
		close(pending.done)
		cache.mu.Unlock()
		return image, err
	}
}

func (image dockerImageHealth) cacheable() bool {
	cost := dockerHealthArgBytes(image.Shell)
	if image.Healthcheck != nil {
		cost += dockerHealthArgBytes(image.Healthcheck.Test)
	}
	return cost <= dockerHealthImageEntrySize
}

func dockerHealthArgBytes(args []string) int {
	cost := 16 * len(args)
	for _, arg := range args {
		cost += len(arg)
	}
	return cost
}

func (n node) readImageHealth(ctx context.Context, id string, scratch string) (dockerImageHealth, error) {
	if n.content == nil || !fullDockerImageID(id) {
		return dockerImageHealth{}, fail(http.StatusServiceUnavailable, "image health configuration is unavailable")
	}
	ctx, cancel := context.WithTimeout(imageMetadataContext(ctx), 5*time.Second)
	defer cancel()
	stream, err := n.content.Read(ctx, &content.ReadContentRequest{Digest: id})
	if err != nil {
		return dockerImageHealth{}, imageBlobReadError("image config", err)
	}
	return decodeImageHealth(id, stream.Recv, scratch)
}

func decodeImageHealth(id string, next func() (*content.ReadContentResponse, error), scratch string) (dockerImageHealth, error) {
	var image struct {
		Config dockerImageHealth `json:"config"`
	}
	var data []byte
	var spill *os.File
	var size int64
	digest := sha256.New()
	for {
		chunk, err := next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return image.Config, imageBlobReadError("image config", err)
		}
		part := chunk.GetData()
		if chunk.GetOffset() != size || len(part) == 0 {
			return image.Config, fail(http.StatusConflict, "image config stream could not be verified")
		}
		size += int64(len(part))
		_, _ = digest.Write(part)
		if spill == nil && size <= verifiedImageBlobLimit {
			data = append(data, part...)
			continue
		}
		if spill == nil {
			// Preserve previously valid large configs and let the standard
			// decoder skip unrelated fields without allocating them on the heap.
			spill, err = os.CreateTemp(scratch, ".health-config-")
			if err != nil {
				return image.Config, fmt.Errorf("stage large image config: %w", err)
			}
			defer spill.Close()
			if err := os.Remove(spill.Name()); err != nil {
				return image.Config, fmt.Errorf("unlink staged image config: %w", err)
			}
			if _, err := spill.Write(data); err != nil {
				return image.Config, fmt.Errorf("stage large image config: %w", err)
			}
			data = nil
		}
		if _, err := spill.Write(part); err != nil {
			return image.Config, fmt.Errorf("stage large image config: %w", err)
		}
	}
	if fmt.Sprintf("sha256:%x", digest.Sum(nil)) != id {
		return image.Config, fail(http.StatusConflict, "image config digest could not be verified")
	}
	if spill != nil {
		if size <= 0 || int64(int(size)) != size {
			return image.Config, fail(http.StatusConflict, "image config cannot be mapped on this worker")
		}
		mapped, err := unix.Mmap(int(spill.Fd()), 0, int(size), unix.PROT_READ, unix.MAP_PRIVATE)
		if err != nil {
			return image.Config, fmt.Errorf("map large image config: %w", err)
		}
		defer unix.Munmap(mapped)
		data = mapped
	}
	data = bytes.TrimSpace(data)
	if len(data) == 0 || data[0] != '{' || json.Unmarshal(data, &image) != nil {
		return dockerImageHealth{}, fail(http.StatusConflict, "image config has invalid JSON")
	}
	return image.Config, nil
}
