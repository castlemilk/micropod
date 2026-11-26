package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// A delegated Docker socket is its owner's alone: it sees the owner and what
// the owner created there, never another job's containers, networks or
// volumes, and it refuses the engine's own routes.

func delegatedFixture(t *testing.T) (s *dockerEngine, owner, child, other, otherChild *dockerContainer) {
	t.Helper()
	id := func(c byte) string { return strings.Repeat(string(c), 64) }
	mk := func(id, name, createdBy, ip string) *dockerContainer {
		return &dockerContainer{IP: ip, dockerRecord: dockerRecord{ID: id, Name: name, Phase: "running", CreatedBy: createdBy,
			Config: dockerConfig{Image: "alpine", Labels: map[string]string{"job": name}}}, changed: make(chan struct{})}
	}
	owner = mk(id('a'), "job-a", "", "10.88.0.10")
	child = mk(id('b'), "job-a-postgres", owner.ID, "10.88.0.11")
	other = mk(id('c'), "job-b", "", "10.88.0.12")
	otherChild = mk(id('d'), "job-b-postgres", other.ID, "10.88.0.13")
	s = engineForPolicy(t, "")
	for _, c := range []*dockerContainer{owner, child, other, otherChild} {
		s.containers[c.ID] = c
	}
	s.execs = map[string]*dockerExec{"exec-of-b": {container: other, cmd: []string{"sh"}}}
	s.namedNetworks = map[string]*workerNetwork{}
	return s, owner, child, other, otherChild
}

func delegatedClient(t *testing.T, s *dockerEngine, owner string) *http.Client {
	t.Helper()
	path, closeFn, err := serveContainerEngine(delegatedAPI{s}, t.TempDir(), owner)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(closeFn)
	return &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", path)
		}}}
}

func getJSON(t *testing.T, client *http.Client, path string, v any) int {
	t.Helper()
	resp, err := client.Get("http://docker" + path)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if v != nil && resp.StatusCode == 200 {
		if err := json.Unmarshal(body, v); err != nil {
			t.Fatalf("%s: %v: %s", path, err, body)
		}
	}
	return resp.StatusCode
}

func TestDelegatedSocketSeesOnlyItsFamily(t *testing.T) {
	s, owner, child, other, otherChild := delegatedFixture(t)
	own := &workerNetwork{Name: "tc-net", ID: strings.Repeat("1", 64), Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.1.0/24"), CreatedBy: owner.ID}
	job := &workerNetwork{Name: "job-net", ID: strings.Repeat("2", 64), Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.2.0/24")}
	foreign := &workerNetwork{Name: "b-net", ID: strings.Repeat("3", 64), Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.3.0/24"), CreatedBy: other.ID}
	for _, n := range []*workerNetwork{own, job, foreign} {
		s.namedNetworks[n.ID] = n
	}
	owner.SecondaryNetworks = []dockerSecondaryEndpoint{{ID: strings.Repeat("e", 64), NetworkID: job.ID, IP: "10.90.2.5"}}
	client := delegatedClient(t, s, owner.ID)

	var list []dockerContainerListRow
	if code := getJSON(t, client, "/v1.47/containers/json?all=1", &list); code != 200 {
		t.Fatalf("list: %d", code)
	}
	var ids []string
	for _, row := range list {
		ids = append(ids, row.ID)
	}
	slices.Sort(ids)
	if !slices.Equal(ids, []string{owner.ID, child.ID}) {
		t.Fatalf("listed %v, want only the owner and its child", ids)
	}
	for c, want := range map[*dockerContainer]int{owner: 200, child: 200, other: 404, otherChild: 404} {
		if code := getJSON(t, client, "/containers/"+c.ID+"/json", nil); code != want {
			t.Errorf("inspect %s: %d, want %d", c.Name, code, want)
		}
		if code := getJSON(t, client, "/containers/"+c.Name+"/json", nil); code != want {
			t.Errorf("inspect by name %s: %d, want %d", c.Name, code, want)
		}
	}
	// A short ID prefix never resolves to, or collides with, another job's.
	if code := getJSON(t, client, "/containers/cccc/json", nil); code != 404 {
		t.Errorf("another job's container by prefix: %d", code)
	}
	if code := getJSON(t, client, "/exec/exec-of-b/json", nil); code != 404 {
		t.Errorf("another job's exec: %d", code)
	}
	var nets []map[string]any
	if code := getJSON(t, client, "/networks", &nets); code != 200 {
		t.Fatalf("networks: %d", code)
	}
	var names []string
	for _, n := range nets {
		names = append(names, n["Name"].(string))
	}
	if !slices.Equal(names, []string{"bridge", "job-net", "none", "tc-net"}) {
		t.Fatalf("networks %v, want the built-ins, the owner's own and the one it is on", names)
	}
	if code := getJSON(t, client, "/networks/"+foreign.ID, nil); code != 404 {
		t.Errorf("another job's network: %d", code)
	}
	var bridge struct{ Containers map[string]any }
	if code := getJSON(t, client, "/networks/bridge", &bridge); code != 200 {
		t.Fatalf("bridge: %d", code)
	}
	for id := range bridge.Containers {
		if id != owner.ID && id != child.ID {
			t.Errorf("the bridge's members show another job's container %.12s", id)
		}
	}
	for _, path := range []string{"/micropod/caches", "/micropod/containers/summary", "/micropod/metrics", "/micropod/traces", "/v1.47/micropod/storage"} {
		if code := getJSON(t, client, path, nil); code != 403 {
			t.Errorf("%s: %d, want 403", path, code)
		}
	}
	if code := getJSON(t, client, "/_ping", nil); code != 200 {
		t.Errorf("_ping: %d", code)
	}
	// A route it does not serve answers as an unimplemented one does on the
	// host's socket, so a client's probe (docker inspect walks plugins) skips it.
	if code := getJSON(t, client, "/v1.47/plugins/x/json", nil); code != 501 {
		t.Errorf("plugins: %d, want 501", code)
	}

	// Events: only the owner's family's.
	s.mu.Lock()
	s.containerEvent(child, "start", nil)
	s.containerEvent(otherChild, "start", nil)
	s.mu.Unlock()
	resp, err := client.Get("http://docker/events?since=1&until=" + strconv.FormatInt(time.Now().Add(time.Second).Unix(), 10))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(body), child.ID) || strings.Contains(string(body), otherChild.ID) {
		t.Fatalf("events %s: want the owner's child's only", body)
	}

	// Removing: only a network the owner created; a container by its own lookup.
	ctx := withViewer(context.Background(), owner.ID)
	for _, n := range []*workerNetwork{job, foreign} {
		rec := httptest.NewRecorder()
		err := s.networks(rec, httptest.NewRequest("DELETE", "/networks/"+n.ID, nil).WithContext(ctx), "/"+n.ID)
		var api apiError
		if !errors.As(err, &api) || api.code != 404 || s.namedNetworks[n.ID] == nil {
			t.Errorf("remove %s through the owner's socket: %v", n.Name, err)
		}
	}
	if _, err := s.lookupFor(ctx, other.Name); err == nil {
		t.Error("another job's container resolved for stop, kill or rm")
	}
	if c, err := s.lookupFor(context.Background(), other.Name); err != nil || c != other {
		t.Errorf("the host's socket lost sight of a container: %v", err)
	}
}

// The routes a delegated socket serves: the ones a CI step's Docker client
// uses, never the engine's own.
func TestDelegatedRoute(t *testing.T) {
	for _, tc := range []struct {
		method, path string
		ok           bool
	}{
		{"GET", "/_ping", true}, {"HEAD", "/v1.47/_ping", true}, {"GET", "/version", true}, {"GET", "/info", true},
		{"GET", "/events", true}, {"POST", "/auth", true}, {"POST", "/v1.47/session", true}, {"POST", "/grpc", true},
		{"POST", "/containers/create", true}, {"GET", "/containers/json", true}, {"POST", "/containers/x/start", true},
		{"PUT", "/containers/x/archive", true}, {"POST", "/exec/x/start", true}, {"POST", "/images/create", true},
		{"POST", "/networks/create", true}, {"GET", "/networks", true}, {"DELETE", "/volumes/x", true}, {"GET", "/volumes", true},
		{"GET", "/micropod/buildkit", true},
		{"GET", "/micropod/caches", false}, {"POST", "/micropod/caches/prune", false}, {"DELETE", "/v1.47/micropod/caches", false},
		{"POST", "/micropod/caches/debug", false}, {"GET", "/micropod/containers/summary", false}, {"POST", "/micropod/traces/clear", false},
		{"GET", "/micropod/metrics", false}, {"GET", "/micropod/storage", false}, {"POST", "/commit", false}, {"POST", "/build", false},
		{"POST", "/_ping", false}, {"DELETE", "/events", false}, {"GET", "/plugins", false}, {"POST", "/swarm/init", false},
	} {
		if got := delegatedRoute(tc.method, tc.path); got != tc.ok {
			t.Errorf("%s %s: served %v, want %v", tc.method, tc.path, got, tc.ok)
		}
	}
}

// A volume or network created on a delegated socket is its owner's; the
// socket sees a volume it created or its owner mounts, never another job's.
func TestDelegatedVolumeVisibility(t *testing.T) {
	s, owner, _, other, _ := delegatedFixture(t)
	owner.Config.HostConfig.Binds = []string{"job-a-workspace:/w"}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, tc := range []struct {
		v    volumeInfo
		want bool
	}{
		{volumeInfo{Name: "tc-data", createdBy: owner.ID}, true},
		{volumeInfo{Name: "job-a-workspace"}, true},
		{volumeInfo{Name: "job-b-workspace"}, false},
		{volumeInfo{Name: "b-data", createdBy: other.ID}, false},
		{volumeInfo{Name: "micropod-ci-scoped-x-gomod"}, false},
		{volumeInfo{Name: "child-made", createdBy: "child"}, false},
	} {
		v, want := tc.v, tc.want
		if got := s.seesVolumeLocked(owner.ID, v); got != want {
			t.Errorf("%s: sees %v, want %v", v.Name, got, want)
		}
		if !s.seesVolumeLocked("", v) {
			t.Errorf("%s: the host's socket lost sight of it", v.Name)
		}
	}
}

// A reaper created on a delegated socket reaps only its creator's family,
// even for a container carrying its session's labels.
func TestDelegatedReaperReapsOnlyItsFamily(t *testing.T) {
	const session = "0123456789abcdef0123"
	owner := strings.Repeat("a", 64)
	self := strings.Repeat("1", 64)
	mk := func(id, createdBy string) *dockerContainer {
		return &dockerContainer{dockerRecord: dockerRecord{ID: id, Name: "c-" + id[:4], Phase: "running", CreatedBy: createdBy,
			Config: dockerConfig{Labels: map[string]string{tcSession: session, tcReap: "true"}}}}
	}
	foreign := mk(strings.Repeat("2", 64), strings.Repeat("b", 64))
	s := &dockerEngine{containers: map[string]*dockerContainer{foreign.ID: foreign}}
	api := &cleanupAPI{engine: s, session: session, owner: self, family: owner}
	rec := httptest.NewRecorder()
	api.ServeHTTP(rec, httptest.NewRequest("DELETE", "/containers/"+foreign.ID+"?force=1", nil))
	if rec.Code != 404 || s.containers[foreign.ID] == nil {
		t.Fatalf("reaped another family's container: %d %s", rec.Code, rec.Body)
	}
	rec = httptest.NewRecorder()
	api.ServeHTTP(rec, httptest.NewRequest("GET", "/containers/json?all=1", nil))
	if strings.Contains(rec.Body.String(), foreign.ID) {
		t.Fatalf("listed another family's container: %s", rec.Body)
	}
}

// useVolumeStore points the engine's volumes at a temporary directory.
func useVolumeStore(t *testing.T) {
	t.Helper()
	old := volumeStore
	volumeStore = t.TempDir()
	t.Cleanup(func() { volumeStore = old })
	for _, d := range []string{"volumes", "volume-meta"} {
		if err := os.Mkdir(filepath.Join(volumeStore, d), 0755); err != nil {
			t.Fatal(err)
		}
	}
}

// A child of a delegated socket mounts a volume the host gave its owner
// read-only read-only too; one the owner mounts writable, or created there,
// stays writable.
func TestDelegatedChildKeepsTheOwnersReadOnlyVolume(t *testing.T) {
	useVolumeStore(t)
	s, owner, _, _, _ := delegatedFixture(t)
	owner.Config.HostConfig.Binds = []string{"shared-fixtures:/fixtures:ro", "job-cache:/cache", "twice:/a:ro", "twice:/b"}
	for _, v := range []string{"shared-fixtures", "job-cache", "twice"} {
		if err := ensureVolume(v, nil); err != nil {
			t.Fatal(err)
		}
	}
	if err := ensureVolumeBy("tc-data", nil, owner.ID); err != nil {
		t.Fatal(err)
	}
	spec := dockerConfig{Image: "alpine", HostConfig: dockerHost{
		Binds:  []string{"shared-fixtures:/data", "job-cache:/c", "twice:/t", "tc-data:/d", "fresh:/f", "shared-fixtures:/r:ro"},
		Mounts: []dockerMount{{Type: "volume", Source: "shared-fixtures", Target: "/m"}},
	}}
	s.mu.Lock()
	_, err := s.delegatedCreateLocked(owner.ID, &spec)
	s.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"shared-fixtures:/data:ro", "job-cache:/c", "twice:/t", "tc-data:/d", "fresh:/f", "shared-fixtures:/r:ro"}
	if !slices.Equal(spec.HostConfig.Binds, want) || !spec.HostConfig.Mounts[0].ReadOnly {
		t.Fatalf("binds %v mounts %+v: a volume the owner has read-only must be read-only in its child", spec.HostConfig.Binds, spec.HostConfig.Mounts)
	}
	if v, err := inspectVolume("fresh"); err != nil || v.createdBy != owner.ID {
		t.Fatalf("a volume a child creates is its owner's: %+v %v", v, err)
	}
}

// A network or volume a container's socket created is its job's: a container
// the host's socket creates (another job's compose project, which names its
// objects predictably) neither joins nor mounts it, and the host's socket
// does not create a volume over it. The owner's own family still may.
func TestHostSocketDoesNotAdoptADelegatedSocketsObjects(t *testing.T) {
	useVolumeStore(t)
	s, owner, child, _, _ := delegatedFixture(t)
	imageID := healthConfigDigest([]byte("{}"))
	s.node = node{images: dockerHealthTestImages{id: imageID}, imageStore: dockerHealthTestImageStore{}}
	s.healthImages = dockerImageHealthCache{byID: map[string]dockerImageHealth{imageID: {}}}
	squat := &workerNetwork{Name: "app_default", ID: strings.Repeat("1", 64), Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.1.0/24"), CreatedBy: owner.ID,
		Labels: map[string]string{"com.docker.compose.project": "app", "com.docker.compose.network": "default"}}
	hostNet := &workerNetwork{Name: "host-net", ID: strings.Repeat("2", 64), Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.2.0/24")}
	s.namedNetworks[squat.ID], s.namedNetworks[hostNet.ID] = squat, hostNet
	if err := ensureVolumeBy("app_pgdata", nil, owner.ID); err != nil {
		t.Fatal(err)
	}
	host := withCacheOrigin(context.Background(), cacheOrigin{hostFacing: true})
	for _, spec := range []dockerConfig{
		{Image: "postgres", HostConfig: dockerHost{NetworkMode: "app_default"}},
		{Image: "postgres", HostConfig: dockerHost{NetworkMode: "host-net"}, Endpoints: map[string]dockerEndpointOptions{"app_default": {}}},
		{Image: "postgres", HostConfig: dockerHost{Binds: []string{"app_pgdata:/var/lib/postgresql/data"}}},
		{Image: "postgres", HostConfig: dockerHost{Mounts: []dockerMount{{Type: "volume", Source: "app_pgdata", Target: "/data", ReadOnly: true}}}},
	} {
		spec.Labels = map[string]string{"io.micropod.cache": "off"}
		_, err := s.create(host, spec, "")
		var api apiError
		if !errors.As(err, &api) || api.code != http.StatusConflict || !strings.Contains(api.message, "container's Docker socket") {
			t.Errorf("host create %v %v: %v, want 409", spec.HostConfig, spec.Endpoints, err)
		}
	}
	rec := httptest.NewRecorder()
	err := s.volumes(rec, httptest.NewRequest("POST", "/volumes/create", strings.NewReader(`{"Name":"app_pgdata"}`)).WithContext(host), "/create")
	var api apiError
	if !errors.As(err, &api) || api.code != http.StatusConflict {
		t.Errorf("host volume create over a delegated volume: %v %d", err, rec.Code)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.hostJoinLocked(child.family(), []string{squat.ID}, nil); err != nil {
		t.Errorf("the owner's own child may join its network: %v", err)
	}
	if err := s.hostJoinLocked(owner.family(), []string{squat.ID, hostNet.ID}, &dockerConfig{HostConfig: dockerHost{Binds: []string{"app_pgdata:/d", "other:/o"}}}); err != nil {
		t.Errorf("the owner may join and mount what it created: %v", err)
	}
	if err := s.hostJoinLocked(strings.Repeat("9", 64), []string{squat.ID}, nil); err == nil {
		t.Error("another family joined the owner's network on the host's socket")
	}
}

// On a delegated socket another job's network is not there by any key, and
// it answers exactly as a network that does not exist does, so a create's
// answer does not tell a job that another job's network has some name.
func TestDelegatedCreateDoesNotTellAnotherJobsNetworkExists(t *testing.T) {
	useVolumeStore(t)
	s, owner, _, other, _ := delegatedFixture(t)
	imageID := healthConfigDigest([]byte("{}"))
	s.node = node{images: dockerHealthTestImages{id: imageID}, imageStore: dockerHealthTestImageStore{}}
	s.healthImages = dockerImageHealthCache{byID: map[string]dockerImageHealth{imageID: {}}}
	foreign := &workerNetwork{Name: "repo_default", ID: strings.Repeat("3", 64), Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.3.0/24"), CreatedBy: other.ID}
	mine := &workerNetwork{Name: "mine", ID: strings.Repeat("4", 64), Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.4.0/24"), CreatedBy: owner.ID}
	s.namedNetworks[foreign.ID], s.namedNetworks[mine.ID] = foreign, mine
	ctx := withViewer(withCacheOrigin(context.Background(), cacheOrigin{creator: owner.ID}), owner.ID)
	answer := func(spec dockerConfig) string {
		spec.Image, spec.Labels = "alpine", map[string]string{"io.micropod.cache": "off"}
		_, err := s.create(ctx, spec, "")
		var api apiError
		if !errors.As(err, &api) {
			t.Fatalf("create %+v: %v", spec.HostConfig, err)
		}
		return strconv.Itoa(api.code) + " " + api.message
	}
	for _, key := range []string{"repo_default", foreign.ID, foreign.ID[:12]} {
		got := answer(dockerConfig{HostConfig: dockerHost{NetworkMode: key}})
		if want := answer(dockerConfig{HostConfig: dockerHost{NetworkMode: "absent" + key[:4]}}); got != strings.Replace(want, "absent"+key[:4], key, 1) {
			t.Errorf("primary %q: %q, a missing network: %q", key, got, want)
		}
		got = answer(dockerConfig{HostConfig: dockerHost{NetworkMode: "mine"}, Endpoints: map[string]dockerEndpointOptions{key: {}}})
		if want := "404 no such network: " + key; got != want {
			t.Errorf("endpoint %q: %q, want %q", key, got, want)
		}
	}
}
