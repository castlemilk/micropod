package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	images "github.com/containerd/containerd/api/services/images/v1"
	control "github.com/moby/buildkit/api/services/control"
	"google.golang.org/grpc"
)

func TestDockerFilterTime(t *testing.T) {
	now := time.Date(2026, 11, 28, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		in   string
		want time.Time
	}{
		{"24h", now.Add(-24 * time.Hour)},
		{"90m", now.Add(-90 * time.Minute)},
		{"1795800000", time.Unix(1795800000, 0)},
		{"1795800000.5", time.Unix(1795800000, 5e8)},
		{"2026-11-27T10:00:00Z", time.Date(2026, 11, 27, 10, 0, 0, 0, time.UTC)},
		{"2026-11-27T10:00:00", time.Date(2026, 11, 27, 10, 0, 0, 0, time.UTC)},
		{"2026-11-27", time.Date(2026, 11, 27, 0, 0, 0, 0, time.UTC)},
	} {
		got, err := dockerFilterTime(tc.in, now)
		if err != nil || !got.Equal(tc.want) {
			t.Errorf("until %q = %v, %v; want %v", tc.in, got, err, tc.want)
		}
	}
	if _, err := dockerFilterTime("yesterday", now); err == nil {
		t.Error("until yesterday was accepted")
	}
}

func TestPruneFiltersKeep(t *testing.T) {
	now := time.Now()
	f, err := parsePruneFilters(`{"label":{"team=ci":true},"label!":["keep"],"until":["1h"]}`, now)
	if err != nil {
		t.Fatal(err)
	}
	old, recent := now.Add(-2*time.Hour), now.Add(-time.Minute)
	for _, tc := range []struct {
		labels  map[string]string
		created time.Time
		want    bool
	}{
		{map[string]string{"team": "ci"}, old, true},
		{map[string]string{"team": "ci"}, recent, false},
		{map[string]string{"team": "ci", "keep": ""}, old, false},
		{map[string]string{"team": "release"}, old, false},
		{map[string]string{"team": "ci"}, time.Time{}, false}, // no creation time: not older than until
	} {
		if got := f.keeps(tc.labels, tc.created); got != tc.want {
			t.Errorf("labels %v created %v: kept %v, want %v", tc.labels, tc.created, got, tc.want)
		}
	}
	if _, err := parsePruneFilters(`{"until":["1h","2h"]}`, now); err == nil {
		t.Error("two until values were accepted")
	}
	if _, err := parsePruneFilters(`{"dangling":["true"]}`, now); err == nil {
		t.Error("a container prune took a dangling filter")
	}
}

// A prune takes only the caller's own: a delegated socket what it created, a
// request naming a family what the host created with that family's label,
// the machine's socket what the host created, never a job socket's.
func TestPrunableScopes(t *testing.T) {
	host := context.Background()
	job := withViewer(host, "owner")
	family := withRequestFamily(host, "gha-1")
	labelled := map[string]string{familyLabel: "gha-1"}
	for _, tc := range []struct {
		name      string
		ctx       context.Context
		createdBy string
		labels    map[string]string
		want      bool
	}{
		{"host, the host's", host, "", nil, true},
		{"host, a family's labelled one", host, "", labelled, true},
		{"host, a job socket's", host, "owner", nil, false},
		{"job, its own", job, "owner", nil, true},
		{"job, another's", job, "other", nil, false},
		{"job, the host's", job, "", nil, false},
		{"family, its labelled one", family, "", labelled, true},
		{"family, unlabelled", family, "", nil, false},
		{"family, another family's", family, "", map[string]string{familyLabel: "gha-2"}, false},
		{"family, a job socket's", family, "owner", labelled, false},
	} {
		if got := prunable(tc.ctx, tc.createdBy, tc.labels); got != tc.want {
			t.Errorf("%s: prunable %v, want %v", tc.name, got, tc.want)
		}
	}
}

// docker network prune is scoped as the other prunes are: a job's socket
// takes what it created, the machine's socket the host's, and a request on
// the machine's socket that names a family only that family's networks: not
// another job's, and not one the host made with no family.
func TestNetworkPruneScopes(t *testing.T) {
	host := context.Background()
	job := withViewer(host, "owner")
	family := withRequestFamily(host, "gha-1")
	plain := &workerNetwork{Name: "host-net"}
	mine := &workerNetwork{Name: "gha-1-net", Labels: map[string]string{familyLabel: "gha-1", "job": "a"}}
	theirs := &workerNetwork{Name: "gha-2-net", Labels: map[string]string{familyLabel: "gha-2"}}
	jobs := &workerNetwork{Name: "job-net", CreatedBy: "owner", Labels: map[string]string{familyLabel: "gha-1"}}
	others := &workerNetwork{Name: "other-job-net", CreatedBy: "other"}
	for _, tc := range []struct {
		name   string
		ctx    context.Context
		n      *workerNetwork
		labels []string
		want   bool
	}{
		{"the host takes its own", host, plain, nil, true},
		{"the host takes a family's it made", host, mine, nil, true},
		{"the host never takes a job's", host, jobs, nil, false},
		{"a family takes its own", family, mine, nil, true},
		{"a family takes its own that matches the filter", family, mine, []string{"job=a"}, true},
		{"a family keeps its own that fails the filter", family, mine, []string{"job=b"}, false},
		{"a family never takes another family's", family, theirs, nil, false},
		{"a family never takes the host's own", family, plain, nil, false},
		{"a family never takes a job socket's", family, jobs, nil, false},
		{"a job takes what its socket made", job, jobs, nil, true},
		{"a job never takes another job's", job, others, nil, false},
		{"a job never takes the host's", job, plain, nil, false},
		{"a job never takes a family's the host made", job, mine, nil, false},
	} {
		if got := networkPrunable(tc.ctx, tc.n, tc.labels); got != tc.want {
			t.Errorf("%s: prunable %v, want %v", tc.name, got, tc.want)
		}
	}
}

// docker container prune and docker volume prune on a job's socket remove
// what that socket created and nothing of another job's or the host's; on
// the machine's socket they remove the host's own, never a job's children.
func TestContainerAndVolumePruneTakeOnlyTheCallersOwn(t *testing.T) {
	s, owner, child, other, otherChild := familyFixture(t)
	if err := ensureVolumeBy(strings.Repeat("e", 64), nil, owner.ID); err != nil {
		t.Fatal(err)
	}
	prune := func(ctx context.Context, path string, query string) map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("POST", path+"?"+query, nil).WithContext(ctx)
		var err error
		switch path {
		case "/containers/prune":
			err = s.pruneContainers(rec, req)
		default:
			err = s.volumes(rec, req, "/prune")
		}
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	job := withViewer(context.Background(), owner.ID)
	got := prune(job, "/containers/prune", "")
	if ids := got["ContainersDeleted"].([]any); len(ids) != 1 || ids[0] != child.ID {
		t.Fatalf("a job's container prune removed %v, want only its child", ids)
	}
	// Without all, only the anonymous volume; with it, every one of its own.
	got = prune(job, "/volumes/prune", "")
	if v := got["VolumesDeleted"].([]any); len(v) != 1 || v[0] != strings.Repeat("e", 64) {
		t.Fatalf("a job's volume prune removed %v, want its anonymous volume", v)
	}
	got = prune(job, "/volumes/prune", `filters={"all":["true"]}`)
	if v := got["VolumesDeleted"].([]any); len(v) != 1 || v[0] != "app_pgdata" || !hasVolume("b_data") || !hasVolume("host_data") {
		t.Fatalf("a job's volume prune with all removed %v", v)
	}
	s.mu.Lock()
	_, otherChildLeft := s.containers[otherChild.ID]
	s.mu.Unlock()
	if !otherChildLeft {
		t.Fatal("a job's prune removed another job's child")
	}
	// The machine's socket: the host's own stopped containers, with a label
	// filter, not a job's child.
	got = prune(context.Background(), "/containers/prune", `filters={"label":["job=job-b"]}`)
	if ids := got["ContainersDeleted"].([]any); len(ids) != 1 || ids[0] != other.ID {
		t.Fatalf("the host's container prune removed %v, want only job-b", ids)
	}
	got = prune(context.Background(), "/volumes/prune", `filters={"all":["1"]}`)
	if v := got["VolumesDeleted"].([]any); !slices.Equal(v, []any{"host_data"}) {
		t.Fatalf("the host's volume prune removed %v, want only the host's volume", v)
	}
}

type fakeBuildKitPrune struct {
	req     *control.PruneRequest
	records []*control.UsageRecord
}

func (f *fakeBuildKitPrune) Prune(_ context.Context, req *control.PruneRequest, _ ...grpc.CallOption) (grpc.ServerStreamingClient[control.UsageRecord], error) {
	f.req = req
	return &usageRecords{items: f.records}, nil
}

type usageRecords struct {
	grpc.ServerStreamingClient[control.UsageRecord]
	items []*control.UsageRecord
}

func (u *usageRecords) Recv() (*control.UsageRecord, error) {
	if len(u.items) == 0 {
		return nil, io.EOF
	}
	r := u.items[0]
	u.items = u.items[1:]
	return r, nil
}

// docker builder prune's filters and space settings reach BuildKit as
// Docker's builder passes them, the answer counts what BuildKit removed, and
// a job's socket removes nothing of the machine's build cache.
func TestBuildCachePrune(t *testing.T) {
	f := &fakeBuildKitPrune{records: []*control.UsageRecord{{ID: "a", Size: 100}, {ID: "b", Size: 23}}}
	old := dialBuildKitPrune
	t.Cleanup(func() { dialBuildKitPrune = old })
	dialBuildKitPrune = func(context.Context) (interface {
		Prune(context.Context, *control.PruneRequest, ...grpc.CallOption) (grpc.ServerStreamingClient[control.UsageRecord], error)
	}, func(), error) {
		return f, func() {}, nil
	}
	s := &dockerEngine{buildkitSocket: "/run/buildkit.sock"}
	rec := httptest.NewRecorder()
	q := `all=1&keep-storage=1000&filters={"until":["24h"],"type":["exec.cachemount"],"id":["abc"]}`
	if err := s.pruneBuildCache(rec, httptest.NewRequest("POST", "/build/prune?"+q, nil)); err != nil {
		t.Fatal(err)
	}
	if !f.req.GetAll() || f.req.GetReservedSpace() != 1000 || f.req.GetKeepDuration() != int64(24*time.Hour) ||
		!slices.Equal(f.req.GetFilter(), []string{"id~=abc,type==exec.cachemount"}) {
		t.Fatalf("BuildKit asked to prune %v", f.req)
	}
	var out struct {
		CachesDeleted  []string
		SpaceReclaimed int64
	}
	if json.Unmarshal(rec.Body.Bytes(), &out) != nil || !slices.Equal(out.CachesDeleted, []string{"a", "b"}) || out.SpaceReclaimed != 123 {
		t.Fatalf("answer %s", rec.Body)
	}
	f.req = nil
	rec = httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/build/prune?all=1", nil).WithContext(withViewer(context.Background(), "owner"))
	if err := s.pruneBuildCache(rec, req); err != nil || f.req != nil || !strings.Contains(rec.Body.String(), `"SpaceReclaimed":0`) {
		t.Fatalf("a job's builder prune reached BuildKit (%v) or answered %s, %v", f.req, rec.Body, err)
	}
	if !delegatedRoute("POST", "/v1.47/build/prune") || delegatedRoute("GET", "/build/prune") {
		t.Fatal("a job's socket does not serve POST /build/prune alone")
	}
}

// An image prune on a job's socket removes none of the machine's images.
func TestImagePruneOnAJobsSocketRemovesNothing(t *testing.T) {
	engine, runtime := imageListLabelFixture(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/images/prune?filters="+`{"dangling":["false"]}`, nil).WithContext(withViewer(context.Background(), "owner"))
	if err := engine.pruneImages(rec, req); err != nil {
		t.Fatal(err)
	}
	if runtime.lists != 0 || !strings.Contains(rec.Body.String(), `"ImagesDeleted":[]`) {
		t.Fatalf("a job's image prune listed the machine's images (%d) or answered %s", runtime.lists, rec.Body)
	}
	rec = httptest.NewRecorder()
	if err := engine.pruneImages(rec, httptest.NewRequest("POST", "/images/prune?filters="+`{"dangling":["maybe"]}`, nil)); err == nil {
		t.Fatal("dangling=maybe was accepted")
	}
}

// GET /images/json filters on dangling, reference, before and since.
func TestDockerImageListDanglingReferenceBeforeSince(t *testing.T) {
	engine, runtime := imageListLabelFixture(t)
	// ci:unlabeled loses its tag: a dangling image with its config record.
	untagged := runtime.list[3]
	untagged.RepoTags = nil
	delete(runtime.catalog.rows, "ci:unlabeled")
	for i, image := range runtime.list {
		created := time.Date(2026, 11, 1+i, 0, 0, 0, 0, time.UTC).Format(time.RFC3339)
		runtime.status[image.GetId()].Info["info"] = `{"imageSpec":{"created":"` + created + `","config":{"Labels":null}}}`
	}
	ids := func(filter string) []string {
		t.Helper()
		w := listImagesV147(engine, filter)
		var rows []struct {
			ID string `json:"Id"`
		}
		if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &rows) != nil {
			t.Fatalf("%s: %d %s", filter, w.Code, w.Body)
		}
		var out []string
		for _, r := range rows {
			out = append(out, r.ID[len(r.ID)-1:])
		}
		return out
	}
	for _, tc := range []struct {
		filter string
		want   []string
	}{
		{`{"dangling":["true"]}`, []string{"d"}},
		{`{"dangling":{"false":true}}`, []string{"a", "b", "c"}},
		{`{"reference":["ci:al*"]}`, []string{"a"}},
		{`{"reference":["ci"]}`, []string{"a", "b", "c"}},
		{`{"reference":["docker.io/library/ci:beta"]}`, nil},
		{`{"before":["ci:gamma"]}`, []string{"a", "b"}},
		{`{"since":["ci:alpha"]}`, []string{"b", "c", "d"}},
		{`{"since":["ci:alpha"],"before":["` + runtime.list[3].GetId() + `"]}`, []string{"b", "c"}},
	} {
		if got := ids(tc.filter); !slices.Equal(got, tc.want) {
			t.Errorf("%s: images %v, want %v", tc.filter, got, tc.want)
		}
	}
	if w := listImagesV147(engine, `{"before":["nosuch:image"]}`); w.Code != http.StatusNotFound {
		t.Errorf("before an image that is not there: %d", w.Code)
	}
	if w := listImagesV147(engine, `{"dangling":["maybe"]}`); w.Code != http.StatusBadRequest {
		t.Errorf("dangling=maybe: %d", w.Code)
	}
}

// A pull by repo:tag@digest is stored by CRI as repo@digest; the tag it named
// is kept on that record and listed beside it (MicropodPulledAs), and the
// tag itself is not moved.
func TestATagAndDigestPullKeepsItsName(t *testing.T) {
	engine, runtime := imageListLabelFixture(t)
	image := runtime.list[0]
	target := runtime.catalog.rows[image.GetId()].GetTarget()
	byDigest := "docker.io/library/ci@" + target.GetDigest()
	runtime.catalog.rows[byDigest] = &images.Image{Name: byDigest, Target: target}
	image.RepoDigests = []string{byDigest}
	store := &recordingImageStore{imageListTestCatalog: runtime.catalog}
	engine.node.imageStore = store
	if err := engine.node.rememberPulledTag(context.Background(), "ci:0.1.15@"+target.GetDigest()); err != nil {
		t.Fatal(err)
	}
	if err := engine.node.rememberPulledTag(context.Background(), "ci:0.1.15"); err != nil || store.updates != 1 {
		t.Fatalf("a tag-only pull labelled a record (%d updates, %v)", store.updates, err)
	}
	if _, moved := runtime.catalog.rows["docker.io/library/ci:0.1.15"]; moved {
		t.Fatal("the pulled tag was made a tag of the image")
	}
	w := listImagesV147(engine, "")
	var rows []struct {
		ID               string `json:"Id"`
		MicropodPulledAs []string
	}
	if json.Unmarshal(w.Body.Bytes(), &rows) != nil || rows[0].ID != image.GetId() {
		t.Fatalf("list %s", w.Body)
	}
	if want := []string{"docker.io/library/ci:0.1.15@" + target.GetDigest()}; !slices.Equal(rows[0].MicropodPulledAs, want) {
		t.Fatalf("pulled as %v, want %v", rows[0].MicropodPulledAs, want)
	}
	if len(rows[1].MicropodPulledAs) != 0 {
		t.Fatalf("another image listed %v", rows[1].MicropodPulledAs)
	}
	// Without its tag it is still named: not dangling, kept by a prune of
	// dangling images, and found by a reference filter on its pulled name.
	image.RepoTags = nil
	delete(runtime.catalog.rows, "ci:alpha")
	for filter, want := range map[string]bool{`{"dangling":["true"]}`: false, `{"reference":["ci:0.1.15"]}`: true} {
		w := listImagesV147(engine, filter)
		if got := strings.Contains(w.Body.String(), image.GetId()); got != want {
			t.Errorf("%s: listed %v, want %v (%s)", filter, got, want, w.Body)
		}
	}
}

type recordingImageStore struct {
	*imageListTestCatalog
	updates int
}

func (s *recordingImageStore) Get(_ context.Context, req *images.GetImageRequest, _ ...grpc.CallOption) (*images.GetImageResponse, error) {
	img, ok := s.rows[req.GetName()]
	if !ok {
		return nil, errNoImage
	}
	return &images.GetImageResponse{Image: &images.Image{Name: img.GetName(), Target: img.GetTarget(), Labels: img.GetLabels()}}, nil
}

func (s *recordingImageStore) Update(_ context.Context, req *images.UpdateImageRequest, _ ...grpc.CallOption) (*images.UpdateImageResponse, error) {
	s.updates++
	s.rows[req.GetImage().GetName()].Labels = req.GetImage().GetLabels()
	return &images.UpdateImageResponse{Image: req.GetImage()}, nil
}

var errNoImage = fail(http.StatusNotFound, "no such image")

func TestDockerListStatus(t *testing.T) {
	now := time.Date(2026, 11, 28, 12, 0, 0, 0, time.UTC)
	c := func(phase string, started, finished time.Duration, exit int32, health string) *dockerContainer {
		d := &dockerContainer{dockerRecord: dockerRecord{Phase: phase, Exit: exit}}
		if started != 0 {
			d.Started = now.Add(-started)
		}
		if finished != 0 {
			d.Finished = now.Add(-finished)
		}
		if health != "" {
			d.Health = &dockerHealthState{Status: health}
		}
		return d
	}
	for _, tc := range []struct {
		c    *dockerContainer
		want string
	}{
		{c("running", 3*time.Second, 0, 0, ""), "Up 3 seconds"},
		{c("running", 500*time.Millisecond, 0, 0, ""), "Up Less than a second"},
		{c("running", 70*time.Second, 0, 0, dockerHealthHealthy), "Up About a minute (healthy)"},
		{c("running", 5*time.Minute, 0, 0, dockerHealthStarting), "Up 5 minutes (health: starting)"},
		{c("running", 3*time.Hour, 0, 0, ""), "Up 3 hours"},
		{c("exited", time.Hour, 2*time.Minute, 0, ""), "Exited (0) 2 minutes ago"},
		{c("exited", time.Hour, 50*time.Hour, 137, ""), "Exited (137) 2 days ago"},
		{c("created", 0, 0, 0, ""), "Created"},
		{c("dead", 0, 0, -1, ""), "Dead"},
	} {
		if got := tc.c.dockerListStatus(now); got != tc.want {
			t.Errorf("%s: %q, want %q", tc.c.Phase, got, tc.want)
		}
		if tc.c.dockerStatus() != tc.c.Phase {
			t.Errorf("%s: State changed to %q", tc.c.Phase, tc.c.dockerStatus())
		}
	}
}

func TestDockerUlimitsAndPIDMode(t *testing.T) {
	ok := `{"Image":"a","HostConfig":{"Ulimits":[{"Name":"nofile","Soft":1024,"Hard":4096},{"Name":"nproc","Soft":-1,"Hard":-1}],"PidMode":""}}`
	spec, err := parseDockerConfig([]byte(ok))
	if err != nil {
		t.Fatal(err)
	}
	if len(spec.HostConfig.Ulimits) != 2 || spec.HostConfig.Ulimits[0] != (dockerUlimit{"nofile", 1024, 4096}) {
		t.Fatalf("ulimits %v", spec.HostConfig.Ulimits)
	}
	for _, body := range []string{
		`{"Image":"a","HostConfig":{"Ulimits":[{"Name":"bogus","Soft":1,"Hard":1}]}}`,
		`{"Image":"a","HostConfig":{"Ulimits":[{"Name":"nofile","Soft":10,"Hard":5}]}}`,
		`{"Image":"a","HostConfig":{"Ulimits":[{"Name":"nofile","Soft":-1,"Hard":-1}]}}`,
		`{"Image":"a","HostConfig":{"Ulimits":[{"Name":"nproc","Soft":1,"Hard":1},{"Name":"nproc","Soft":2,"Hard":2}]}}`,
		`{"Image":"a","HostConfig":{"Ulimits":[{"Name":"nproc","Soft":1,"Hard":1,"Other":1}]}}`,
		`{"Image":"a","HostConfig":{"PidMode":"container:x"}}`,
	} {
		if _, err := parseDockerConfig([]byte(body)); err == nil {
			t.Errorf("accepted %s", body)
		}
	}
	if _, err := parseDockerConfig([]byte(`{"Image":"a","HostConfig":{"PidMode":"host"}}`)); err == nil || !strings.Contains(err.Error(), "--pid=host is not available") {
		t.Errorf("--pid=host: %v", err)
	}
	original := []byte(`{"process":{"args":["sh"],"rlimits":[{"type":"RLIMIT_NOFILE","hard":1048576,"soft":1048576},{"type":"RLIMIT_CORE","hard":0,"soft":0}]},"mounts":[]}`)
	out, err := spec.specWithUlimits(original)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Process struct {
			Args    []string
			Rlimits []struct {
				Type       string
				Hard, Soft uint64
			}
		}
	}
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatal(err)
	}
	limits := map[string][2]uint64{}
	for _, r := range got.Process.Rlimits {
		limits[r.Type] = [2]uint64{r.Soft, r.Hard}
	}
	if limits["RLIMIT_NOFILE"] != [2]uint64{1024, 4096} || limits["RLIMIT_NPROC"] != [2]uint64{^uint64(0), ^uint64(0)} ||
		limits["RLIMIT_CORE"] != [2]uint64{0, 0} || len(got.Process.Rlimits) != 3 || !slices.Equal(got.Process.Args, []string{"sh"}) {
		t.Fatalf("rlimits %v (%s)", got.Process.Rlimits, out)
	}
}
