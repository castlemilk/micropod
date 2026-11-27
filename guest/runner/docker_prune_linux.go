package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	leases "github.com/containerd/containerd/api/services/leases/v1"
	control "github.com/moby/buildkit/api/services/control"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// The prune routes `docker system prune` calls (containers, networks,
// volumes, images, then the build cache), each as Docker answers it, and each
// scoped to whose objects the caller may take:
//
//   - a delegated socket (a job's container): what that socket created;
//   - the machine's socket with a family (X-Micropod-Family): what the host
//     created with that family's label;
//   - the machine's socket without one: what the host created (CreatedBy ""),
//     never what a job's socket created, so a host prune never takes a
//     running job's container, volume or network between two of its steps.
//
// Images and the build cache are the machine's and carry no family: a
// family's prune of either removes nothing and says so (0 bytes); the
// machine's own socket prunes them machine-wide. Space reclaimed is what is
// gone afterwards, measured: an image's layers and blobs count only once the
// collector has removed them (a layer another image or the build cache still
// holds is not reclaimed), a container's writable layer and a volume's files
// as they were measured just before they went.

func init() {
	extraRoutes = append(extraRoutes, func(s *dockerEngine, w http.ResponseWriter, r *http.Request, method, path string) (bool, error) {
		if path != "build/prune" || method != http.MethodPost {
			return false, nil
		}
		return true, s.pruneBuildCache(w, r)
	})
}

// requestFamilyOf is the family a request on the machine's socket names
// (familyHeader); "" for none, and always on a delegated socket.
func requestFamilyOf(ctx context.Context) string {
	name, _ := ctx.Value(requestFamilyKey{}).(string)
	return name
}

// familyScoped reports whether the request acts for one job only: a
// delegated socket's, or the machine's socket naming a family.
func familyScoped(ctx context.Context) bool {
	return viewerOf(ctx) != "" || requestFamilyOf(ctx) != ""
}

// prunable reports whether a prune on ctx may take an object created by
// createdBy (a delegated socket's owner, "" for the host) with labels.
func prunable(ctx context.Context, createdBy string, labels map[string]string) bool {
	if viewer := viewerOf(ctx); viewer != "" {
		return createdBy == viewer
	}
	if createdBy != "" {
		return false
	}
	family := requestFamilyOf(ctx)
	return family == "" || labels[familyLabel] == family
}

// pruneFilters reads a prune's filters: label and label! (sets or arrays,
// every member a predicate) and until (a time or a duration before now).
type pruneFilters struct {
	values      map[string][]string
	labels, not []string
	until       time.Time
}

func parsePruneFilters(raw string, now time.Time, allowed ...string) (pruneFilters, error) {
	values, err := dockerFilterValues(raw, []string{"label", "label!"}, append([]string{"label", "label!", "until"}, allowed...))
	if err != nil {
		return pruneFilters{}, err
	}
	f := pruneFilters{values: values, labels: values["label"], not: values["label!"]}
	switch until := values["until"]; len(until) {
	case 0:
	case 1:
		if f.until, err = dockerFilterTime(until[0], now); err != nil {
			return f, fail(http.StatusBadRequest, err.Error())
		}
	default:
		return f, fail(http.StatusBadRequest, "the until filter takes one value")
	}
	return f, nil
}

// keeps reports whether labels and a creation time pass the filters.
func (f pruneFilters) keeps(labels map[string]string, created time.Time) bool {
	if !matchesLabels(labels, f.labels) {
		return false
	}
	for _, q := range f.not {
		k, v, has := strings.Cut(q, "=")
		if got, ok := labels[k]; ok && (!has || got == v) {
			return false
		}
	}
	return f.until.IsZero() || !created.IsZero() && created.Before(f.until)
}

// dockerFilterTime reads an until value as Docker does: a duration before
// now ("24h", "90m"), Unix seconds (with a fraction), or an RFC 3339 time,
// a date-time without a zone (UTC) or a date.
func dockerFilterTime(value string, now time.Time) (time.Time, error) {
	if d, err := time.ParseDuration(value); err == nil {
		return now.Add(-d), nil
	}
	if secs, err := strconv.ParseFloat(value, 64); err == nil && !math.IsInf(secs, 0) && !math.IsNaN(secs) {
		whole, frac := math.Modf(secs)
		return time.Unix(int64(whole), int64(frac*1e9)), nil
	}
	for _, layout := range []string{time.RFC3339Nano, "2006-01-02T15:04:05", "2006-01-02T15:04", "2006-01-02"} {
		if t, err := time.Parse(layout, value); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("invalid until filter %q: want a duration, a Unix time or an RFC 3339 time", value)
}

// pruneContainers serves POST /containers/prune: the stopped (created or
// exited) containers the caller may take that pass the filters.
func (s *dockerEngine) pruneContainers(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	f, err := parsePruneFilters(r.URL.Query().Get("filters"), time.Now())
	if err != nil {
		return err
	}
	s.mu.Lock()
	var candidates []*dockerContainer
	for _, c := range s.containers {
		if c.removed || c.busy() || c.Phase == "removing" || !prunable(ctx, c.CreatedBy, c.Config.Labels) {
			continue
		}
		if viewer := viewerOf(ctx); viewer != "" && c.ID == viewer {
			continue // the socket's own container is not its to remove
		}
		if f.keeps(c.Config.Labels, c.Created) {
			candidates = append(candidates, c)
		}
	}
	s.mu.Unlock()
	slices.SortFunc(candidates, func(a, b *dockerContainer) int { return strings.Compare(a.ID, b.ID) })
	layers := newLayerUsage(s.node)
	deleted := []string{}
	var reclaimed int64
	for _, c := range candidates {
		var size int64
		if c.RootFS != nil && c.RootFS.Ready {
			size, _ = layers.snapshot(ctx, dockerRootFSKey(c.ID))
		}
		release, err := s.lockContainerLifecycle(ctx, c)
		if err != nil {
			return err
		}
		err = s.remove(ctx, c, false)
		if release != nil {
			release()
		}
		var api apiError
		switch {
		case err == nil:
			deleted = append(deleted, c.ID)
			reclaimed += size
		case errors.As(err, &api) && (api.code == http.StatusNotFound || api.code == http.StatusConflict):
			// Gone meanwhile, or started again.
		default:
			return err
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ContainersDeleted": deleted, "SpaceReclaimed": reclaimed})
	return nil
}

// anonymousVolume is the shape of the names the engine gives a volume no one
// named (Docker's too): what a volume prune takes without all=true.
var anonymousVolume = regexp.MustCompile(`^[0-9a-f]{64}$`)

// pruneVolumes serves POST /volumes/prune: the unused volumes the caller may
// take that pass the filters; only anonymous ones unless the filter all is
// true (API 1.42 and later, as Docker).
func (s *dockerEngine) pruneVolumes(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	f, err := parsePruneFilters(r.URL.Query().Get("filters"), time.Now(), "all")
	if err != nil {
		return err
	}
	if !f.until.IsZero() {
		return fail(http.StatusBadRequest, "volume prune does not take an until filter")
	}
	all := false
	for _, v := range f.values["all"] {
		b, err := strconv.ParseBool(v)
		if err != nil {
			return fail(http.StatusBadRequest, "invalid all filter "+strconv.Quote(v))
		}
		all = b
	}
	entries, err := os.ReadDir(volumePath(""))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	deleted := []string{}
	var reclaimed int64
	for _, e := range entries {
		if !e.IsDir() || !all && !anonymousVolume.MatchString(e.Name()) {
			continue
		}
		s.mu.Lock()
		v, err := inspectVolume(e.Name())
		if err != nil || !prunable(ctx, v.createdBy, v.Labels) || !f.keeps(v.Labels, time.Time{}) || s.volumeInUse(v.Name) {
			s.mu.Unlock()
			continue
		}
		size := treeDiskBytes(v.Mountpoint)
		data, err := s.removeVolumeLocked(v.Name)
		if err == nil {
			err = syncVolumeNames()
		}
		s.mu.Unlock()
		if err := errors.Join(err, discardVolumeData(data)); err != nil {
			var api apiError
			if errors.As(err, &api) && api.code == http.StatusConflict {
				continue
			}
			return err
		}
		deleted = append(deleted, v.Name)
		reclaimed += size
	}
	writeJSON(w, http.StatusOK, map[string]any{"VolumesDeleted": deleted, "SpaceReclaimed": reclaimed})
	return nil
}

// pruneImages serves POST /images/prune: without dangling=false, the images
// no tag names; with it, every image; in both, only those no container uses
// (running or not) and that pass the label, label! and until filters (until
// by the image config's creation time). Tags go first, then the image with
// its digest references. SpaceReclaimed counts the blobs and layer snapshots
// that are gone after a synchronous collection: what another image or the
// build cache still holds is not reclaimed, and is not counted.
func (s *dockerEngine) pruneImages(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	f, err := parsePruneFilters(r.URL.Query().Get("filters"), time.Now(), "dangling")
	if err != nil {
		return err
	}
	dangling := true
	for _, v := range f.values["dangling"] {
		b, err := strconv.ParseBool(v)
		if err != nil {
			return fail(http.StatusBadRequest, "invalid dangling filter "+strconv.Quote(v))
		}
		dangling = b
	}
	if familyScoped(ctx) {
		writeJSON(w, http.StatusOK, map[string]any{"ImagesDeleted": []any{}, "SpaceReclaimed": 0})
		return nil
	}
	s.imageMu.Lock()
	defer s.imageMu.Unlock()
	listCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	listed, err := s.node.images.ListImages(listCtx, &cri.ListImagesRequest{})
	if err != nil {
		return err
	}
	rows, err := s.node.visibleDockerImageRows(listCtx, listed.GetImages())
	if err != nil {
		return err
	}
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.GetId())
	}
	configs := s.dockerImageConfigs(ctx, ids)
	var candidates []*cri.Image
	for _, row := range rows {
		if dangling && len(row.GetRepoTags()) != 0 {
			continue
		}
		var created time.Time
		if c := configs[row.GetId()].created; c > 0 {
			created = time.Unix(c, 0)
		}
		var labels map[string]string
		if len(f.labels)+len(f.not) != 0 {
			res, err := s.node.dockerImageListLabels(ctx, row.GetId())
			if err != nil || !res.present {
				continue
			}
			labels = res.labels
		}
		if !f.keeps(labels, created) {
			continue
		}
		if _, err := s.imageIDRemovalUsage(ctx, row.GetId(), false); err != nil {
			var api apiError
			if errors.As(err, &api) && api.code == http.StatusConflict {
				continue // a container uses it
			}
			return err
		}
		candidates = append(candidates, row)
	}
	if len(candidates) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"ImagesDeleted": []any{}, "SpaceReclaimed": 0})
		return nil
	}
	// What the candidates take, measured before they go.
	store := imageStoreClients{snapshots: s.node.snapStore, content: s.node.content}
	storeCtx := imageMetadataContext(ctx)
	blobsBefore, err := store.contentInfos(storeCtx)
	if err != nil {
		return err
	}
	layers := newLayerUsage(s.node)
	chains := map[string]int64{}
	for _, row := range candidates {
		for _, chain := range configs[row.GetId()].chains {
			if _, ok := chains[chain]; !ok {
				chains[chain], _ = layers.snapshot(ctx, chain)
			}
		}
	}
	deleted := []map[string]string{}
	for _, row := range candidates {
		ok := true
		for _, tag := range row.GetRepoTags() {
			untagged, err := s.removeImageTag(ctx, tag, false)
			if err != nil {
				log.Printf("image prune: keep %s: untag %s: %v", row.GetId(), tag, err)
				ok = false
				break
			}
			deleted = append(deleted, map[string]string{"Untagged": untagged})
		}
		if !ok {
			continue
		}
		if len(row.GetRepoTags()) != 0 {
			s.node.awaitCRIUntagged(ctx, row.GetId())
		}
		removed, err := s.removeUnusedImageID(ctx, row.GetId(), true)
		if err != nil {
			log.Printf("image prune: keep %s: %v", row.GetId(), err)
			continue
		}
		deleted = append(deleted, removed...)
	}
	if err := s.node.collectGarbage(ctx); err != nil {
		log.Printf("image prune: collect what the removed images held: %v", err)
	}
	blobsAfter, err := store.contentInfos(storeCtx)
	if err != nil {
		return err
	}
	snapsAfter, err := store.snapshotInfos(storeCtx)
	if err != nil {
		return err
	}
	var reclaimed int64
	kept := map[string]bool{}
	for _, b := range blobsAfter {
		kept[b.GetDigest()] = true
	}
	for _, b := range blobsBefore {
		if !kept[b.GetDigest()] {
			reclaimed += max(b.GetSize(), 0)
		}
	}
	present := map[string]bool{}
	for _, info := range snapsAfter {
		present[info.GetName()] = true
	}
	for chain, size := range chains {
		if !present[chain] {
			reclaimed += size
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ImagesDeleted": deleted, "SpaceReclaimed": reclaimed})
	return nil
}

// awaitCRIUntagged waits (briefly) until CRI, which learns of removed tags
// from containerd's events, lists none for the image, so its removal by ID
// does not take it for a tagged one.
func (n node) awaitCRIUntagged(ctx context.Context, id string) {
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		r, err := n.images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: id}})
		if err != nil || len(r.GetImage().GetRepoTags()) == 0 {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(20 * time.Millisecond):
		}
	}
}

// pruneGCLease is the empty lease whose synchronous delete runs containerd's
// collection after a prune.
const pruneGCLease = "micropod-prune-gc"

// collectGarbage runs containerd's garbage collection and returns once it is
// done: what no image, container, lease or snapshot holds any more is gone.
func (n node) collectGarbage(ctx context.Context) error {
	if n.storeLeases == nil {
		return errors.New("no leases client")
	}
	ctx = imageMetadataContext(ctx)
	if _, err := n.storeLeases.Create(ctx, &leases.CreateRequest{ID: pruneGCLease}); err != nil && status.Code(err) != codes.AlreadyExists {
		return err
	}
	_, err := n.storeLeases.Delete(ctx, &leases.DeleteRequest{ID: pruneGCLease, Sync: true})
	return err
}

// buildCacheFields are the build cache filters Docker passes on to BuildKit.
var buildCacheFields = []string{"id", "parent", "type", "description", "inuse", "shared", "private"}

// pruneBuildCache serves POST /build/prune as Docker's builder does: the
// filters (until, its old name unused-for, and the cache fields) and the
// space settings (all, keep-storage or reserved-space, max-used-space,
// min-free-space) go to BuildKit's prune, and the answer lists the records it
// removed with the space BuildKit counts for them. A family's prune removes
// nothing: BuildKit's records are the machine's.
func (s *dockerEngine) pruneBuildCache(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	values, err := dockerFilterValues(q.Get("filters"), nil, append([]string{"until", "unused-for"}, buildCacheFields...))
	if err != nil {
		return err
	}
	req := &control.PruneRequest{}
	if raw := q.Get("all"); raw != "" {
		if req.All, err = strconv.ParseBool(raw); err != nil {
			return fail(http.StatusBadRequest, "invalid all "+strconv.Quote(raw))
		}
	}
	for _, p := range []struct {
		name string
		into *int64
	}{{"keep-storage", &req.ReservedSpace}, {"reserved-space", &req.ReservedSpace}, {"max-used-space", &req.MaxUsedSpace}, {"min-free-space", &req.MinFreeSpace}} {
		if raw := q.Get(p.name); raw != "" {
			n, err := strconv.ParseInt(raw, 10, 64)
			if err != nil || n < 0 {
				return fail(http.StatusBadRequest, "invalid "+p.name+" "+strconv.Quote(raw))
			}
			*p.into = n
		}
	}
	until := append(values["until"], values["unused-for"]...)
	switch len(until) {
	case 0:
	case 1:
		d, err := time.ParseDuration(until[0])
		if err != nil {
			return fail(http.StatusBadRequest, "the until filter wants a duration, got "+strconv.Quote(until[0]))
		}
		req.KeepDuration = int64(d)
	default:
		return fail(http.StatusBadRequest, "the until filter takes one value")
	}
	var fields []string
	for _, field := range buildCacheFields {
		vals, ok := values[field]
		switch {
		case !ok:
		case len(vals) == 0:
			fields = append(fields, field)
		case len(vals) == 1 && field == "id":
			fields = append(fields, field+"~="+vals[0])
		case len(vals) == 1:
			fields = append(fields, field+"=="+vals[0])
		default:
			return fail(http.StatusBadRequest, "the "+field+" filter takes one value")
		}
	}
	if len(fields) != 0 {
		req.Filter = []string{strings.Join(fields, ",")}
	}
	if familyScoped(r.Context()) {
		writeJSON(w, http.StatusOK, map[string]any{"CachesDeleted": []string{}, "SpaceReclaimed": 0})
		return nil
	}
	if s.buildkitSocket == "" {
		return fail(http.StatusServiceUnavailable, "BuildKit is unavailable")
	}
	bk, done, err := dialBuildKitPrune(r.Context())
	if err != nil {
		return fmt.Errorf("reach BuildKit: %w", err)
	}
	defer done()
	stream, err := bk.Prune(r.Context(), req)
	if err != nil {
		return fmt.Errorf("prune the build cache: %w", err)
	}
	deleted := []string{}
	var reclaimed int64
	for {
		rec, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("prune the build cache: %w", err)
		}
		deleted = append(deleted, rec.GetID())
		reclaimed += max(rec.GetSize(), 0)
	}
	writeJSON(w, http.StatusOK, map[string]any{"CachesDeleted": deleted, "SpaceReclaimed": reclaimed})
	return nil
}

// dialBuildKitPrune returns BuildKit's control client for a prune; a
// variable so tests can stand in for BuildKit.
var dialBuildKitPrune = func(ctx context.Context) (interface {
	Prune(context.Context, *control.PruneRequest, ...grpc.CallOption) (grpc.ServerStreamingClient[control.UsageRecord], error)
}, func(), error) {
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
