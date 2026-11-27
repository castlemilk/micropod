package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// The delegated engine socket: who may be given one at create, and what a
// request on it is.

func engineForPolicy(t *testing.T, policy string) *dockerEngine {
	t.Helper()
	path := filepath.Join(t.TempDir(), "absent.json")
	if policy != "" {
		path = filepath.Join(t.TempDir(), "cache-policy.json")
		if err := os.WriteFile(path, []byte(policy), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return &dockerEngine{containers: map[string]*dockerContainer{}, cachePolicy: policyLoader{path: path}}
}

func ryukSpec() dockerConfig {
	return dockerConfig{
		Image: "testcontainers/ryuk:0.11.0",
		Labels: map[string]string{
			"org.testcontainers.ryuk": "true", "org.testcontainers.reaper": "true",
			tcSession: "0123456789abcdef0123",
		},
		HostConfig: dockerHost{Binds: []string{"/var/run/docker.sock:/var/run/docker.sock"}},
	}
}

func TestEngineSocketGrant(t *testing.T) {
	host := withCacheOrigin(context.Background(), cacheOrigin{hostFacing: true})
	nested := withCacheOrigin(context.Background(), cacheOrigin{creator: "attempt"})
	sock := func(labels map[string]string, bind string) dockerConfig {
		return dockerConfig{Image: "golang:1", Labels: labels, HostConfig: dockerHost{Binds: []string{bind}}}
	}
	trusted := map[string]string{"io.micropod.cache.trust": "trusted"}
	for _, tc := range []struct {
		name   string
		policy string
		ctx    context.Context
		spec   dockerConfig
		grant  bool
		denied string // substring of the 403, "" for no error
	}{
		{"no docker.sock bind", "", host, dockerConfig{Image: "golang:1"}, false, ""},
		{"shipped default, unlabeled, host", "", host, sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), true, ""},
		{"/run/docker.sock source", "", host, sock(nil, "/run/docker.sock:/var/run/docker.sock"), true, ""},
		{"untrusted default, labelled trusted, host", `{"defaultTrust":"untrusted"}`, host,
			sock(trusted, "/var/run/docker.sock:/var/run/docker.sock"), true, ""},
		{"untrusted default, unlabeled", `{"defaultTrust":"untrusted"}`, host,
			sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), false, "only a trusted container"},
		{"untrusted default, trusted only in env", `{"defaultTrust":"untrusted"}`, host,
			dockerConfig{Image: "golang:1", Env: []string{"MICROPOD_CACHE_TRUST=trusted"},
				HostConfig: dockerHost{Binds: []string{"/var/run/docker.sock:/var/run/docker.sock"}}}, false, "only a trusted container"},
		{"labelled untrusted", "", host, sock(map[string]string{"io.micropod.cache.trust": "untrusted"}, "/var/run/docker.sock:/var/run/docker.sock"),
			false, "only a trusted container"},
		{"read-only", "", host, sock(map[string]string{"io.micropod.cache.readonly": "1"}, "/var/run/docker.sock:/var/run/docker.sock"),
			false, "only a trusted container"},
		{"from inside a container", "", nested, sock(trusted, "/var/run/docker.sock:/var/run/docker.sock"), false, "cannot be given a Docker socket"},
		{"no origin mark is a container's", "", context.Background(), sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), false, "cannot be given"},
		{"the reaper keeps its cleanup socket", `{"defaultTrust":"untrusted"}`, nested, ryukSpec(), false, ""},
		// dockerSocket: the host may hand a container of any tier a socket.
		{"dockerSocket trusted is the default", `{"defaultTrust":"untrusted","dockerSocket":"trusted"}`, host,
			sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), false, "only a trusted container"},
		{"any: untrusted default, unlabeled", `{"defaultTrust":"untrusted","dockerSocket":"any"}`, host,
			sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), true, ""},
		{"any: labelled untrusted", `{"dockerSocket":"any"}`, host,
			sock(map[string]string{"io.micropod.cache.trust": "untrusted"}, "/var/run/docker.sock:/var/run/docker.sock"), true, ""},
		{"any: read-only", `{"dockerSocket":"any"}`, host,
			sock(map[string]string{"io.micropod.cache.readonly": "1"}, "/run/docker.sock:/var/run/docker.sock"), true, ""},
		{"any: trusted", `{"defaultTrust":"untrusted","dockerSocket":"any"}`, host,
			sock(trusted, "/var/run/docker.sock:/var/run/docker.sock"), true, ""},
		{"any: no bind, no socket", `{"dockerSocket":"any"}`, host, dockerConfig{Image: "golang:1"}, false, ""},
		{"any: still only the host delegates", `{"dockerSocket":"any"}`, nested,
			sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), false, "cannot be given a Docker socket"},
		{"any: no origin mark is a container's", `{"dockerSocket":"any"}`, context.Background(),
			sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), false, "cannot be given"},
		{"any: the reaper keeps its cleanup socket", `{"defaultTrust":"untrusted","dockerSocket":"any"}`, nested, ryukSpec(), false, ""},
		{"any: an unknown trust value still fails", `{"dockerSocket":"any"}`, host,
			sock(map[string]string{"io.micropod.cache.trust": "bogus"}, "/var/run/docker.sock:/var/run/docker.sock"), false, "!400"},
		// A policy that cannot be read as written grants nothing more.
		{"unknown dockerSocket value fails closed", `{"dockerSocket":"everyone"}`, host,
			sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), false, "only a trusted container"},
		{"any beside an invalid key fails closed", `{"dockerSocket":"any","mode":"sometimes"}`, host,
			sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), false, "only a trusted container"},
		{"malformed policy fails closed", `{"dockerSocket":"any"`, host,
			sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), false, "only a trusted container"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := engineForPolicy(t, tc.policy)
			grant, err := s.engineSocketGrant(tc.ctx, tc.spec)
			if grant != tc.grant {
				t.Fatalf("grant = %v, want %v (err %v)", grant, tc.grant, err)
			}
			switch {
			case tc.denied == "" && err != nil:
				t.Fatalf("unexpected error %v", err)
			case tc.denied == "!400":
				var api apiError
				if !errors.As(err, &api) || api.code != 400 {
					t.Fatalf("err %v, want 400", err)
				}
			case tc.denied != "":
				var api apiError
				if !errors.As(err, &api) || api.code != 403 || !strings.Contains(api.message, tc.denied) {
					t.Fatalf("err %v, want 403 containing %q", err, tc.denied)
				}
			}
		})
	}
}

// A start mounts the delegated socket at the bind's target and the reaper's
// cleanup socket at its own; a create validates neither as a workspace bind.
func TestOpenMountsDelegatedEngineSocket(t *testing.T) {
	s := engineForPolicy(t, "")
	spec := dockerConfig{Image: "golang:1", HostConfig: dockerHost{Binds: []string{"/var/run/docker.sock:/var/run/docker.sock"}}}
	rules := cacheVolumeRules{}
	if files, mounts, _, err := s.openMountsWith(spec, rules, true, mountSockets{}, ""); err != nil || len(files) != 0 || len(mounts) != 0 {
		t.Fatalf("create: files %d mounts %d err %v", len(files), len(mounts), err)
	}
	if _, _, _, err := s.openMountsWith(spec, rules, false, mountSockets{}, ""); err == nil || !strings.Contains(err.Error(), "not granted") {
		t.Fatalf("start without a granted socket: %v", err)
	}
	_, mounts, _, err := s.openMountsWith(spec, rules, false, mountSockets{engine: "/run/micropod-oci/engine-1/docker.sock"}, "")
	if err != nil || len(mounts) != 1 || mounts[0].HostPath != "/run/micropod-oci/engine-1/docker.sock" || mounts[0].ContainerPath != "/var/run/docker.sock" {
		t.Fatalf("start: %+v %v", mounts, err)
	}
	_, mounts, _, err = s.openMountsWith(ryukSpec(), rules, false, mountSockets{cleanup: "/run/micropod-oci/reaper-1/api.sock", engine: "/elsewhere"}, "")
	if err != nil || len(mounts) != 1 || mounts[0].HostPath != "/run/micropod-oci/reaper-1/api.sock" || !mounts[0].Readonly {
		t.Fatalf("reaper: %+v %v", mounts, err)
	}
}

// Every request on a container's socket is that container's, never the
// host's, so what it creates is capped at its tier; closing removes it.
func TestServeContainerEngineMarksTheContainersOrigin(t *testing.T) {
	got := make(chan cacheOrigin, 1)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got <- cacheOriginOf(r.Context())
		w.WriteHeader(200)
	})
	path, closeFn, err := serveContainerEngine(handler, t.TempDir(), "c0ffee")
	if err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode()&os.ModeSocket == 0 || st.Mode().Perm() != 0o666 {
		t.Fatalf("socket %s: %v %v", path, st.Mode(), err)
	}
	if dir, _ := os.Stat(filepath.Dir(path)); dir.Mode().Perm() != 0o700 {
		t.Fatalf("socket directory mode %v, want 0700", dir.Mode().Perm())
	}
	client := http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", path)
		}}}
	resp, err := client.Get("http://docker/_ping")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if o := <-got; o.hostFacing || o.creator != "c0ffee" {
		t.Fatalf("origin %+v, want the container's", o)
	}
	closeFn()
	if _, err := os.Stat(filepath.Dir(path)); !os.IsNotExist(err) {
		t.Fatalf("socket directory survives close: %v", err)
	}
}

// A published port is reachable at the network gateway on its Mac port, as
// Docker's are from inside a container; closing the port releases it.
func TestOpenGatewayRelayReachesTheTarget(t *testing.T) {
	target, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	go func() {
		for {
			c, err := target.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				buf := make([]byte, 5)
				n, _ := c.Read(buf)
				c.Write(append([]byte("echo:"), buf[:n]...))
			}()
		}
	}()
	probe, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := uint16(probe.Addr().(*net.TCPAddr).Port)
	probe.Close()
	p, err := openGatewayRelay(context.Background(), "127.0.0.1", port, target.Addr().String(), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	c, err := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(int(port))), 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	c.SetDeadline(time.Now().Add(5 * time.Second))
	c.Write([]byte("hello"))
	got, _ := io.ReadAll(c)
	c.Close()
	if string(got) != "echo:hello" {
		t.Fatalf("relayed %q", got)
	}
	if err := p.close(); err != nil {
		t.Fatal(err)
	}
	if c, err := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(int(port))), time.Second); err == nil {
		c.Close()
		t.Fatal("gateway port still accepts after close")
	}
}

// Every container gets Docker's empty, read-only /.dockerenv unless it mounts
// something there itself.
func TestDockerEnvMount(t *testing.T) {
	old := dockerEnvPath
	dockerEnvPath = filepath.Join(t.TempDir(), "dockerenv")
	dockerEnvOnce = sync.Once{}
	t.Cleanup(func() { dockerEnvPath, dockerEnvOnce = old, sync.Once{} })
	m := dockerEnvMount(dockerConfig{Image: "alpine"})
	if m == nil || m.ContainerPath != "/.dockerenv" || !m.Readonly || m.HostPath != dockerEnvPath {
		t.Fatalf("mount %+v", m)
	}
	if st, err := os.Stat(dockerEnvPath); err != nil || st.Size() != 0 {
		t.Fatalf("dockerenv %v %v", st, err)
	}
	own := dockerConfig{Image: "alpine", HostConfig: dockerHost{Binds: []string{"/Users/me/env:/.dockerenv:ro"}}}
	if m := dockerEnvMount(own); m != nil {
		t.Fatalf("a container's own /.dockerenv mount is replaced: %+v", m)
	}
}

// dockerSocket is host-owned and parsed strictly: an unknown value, or a
// policy file that cannot be parsed, grants no untrusted container a socket,
// and the shipped default's digest does not change.
func TestCachePolicyDockerSocket(t *testing.T) {
	pol, err := parseCachePolicy([]byte(`{"dockerSocket":"any","defaultTrust":"untrusted"}`))
	if err != nil || !pol.socketForAnyTier() || !pol.untrustedByDefault() {
		t.Fatalf("%+v %v", pol, err)
	}
	for _, body := range []string{`{}`, `{"dockerSocket":"trusted"}`, `{"dockerSocket":""}`} {
		if pol, err = parseCachePolicy([]byte(body)); err != nil || pol.socketForAnyTier() || pol.digest() != defaultCachePolicy().digest() {
			t.Fatalf("%s: %+v %v", body, pol, err)
		}
	}
	for _, body := range []string{`{"dockerSocket":"ANY"}`, `{"dockerSocket":"untrusted"}`, `{"dockerSocket":true}`, `{"dockerSocket":"any","defaultTrust":"semi"}`} {
		if pol, err = parseCachePolicy([]byte(body)); err == nil {
			t.Fatalf("%s parsed: %+v", body, pol)
		}
	}
	if failClosedCachePolicy().socketForAnyTier() || defaultCachePolicy().socketForAnyTier() {
		t.Fatal("a default policy hands untrusted containers a socket")
	}
	file := filepath.Join(t.TempDir(), "cache-policy.json")
	write := func(body string) *policyLoader {
		t.Helper()
		if err := os.WriteFile(file, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return &policyLoader{path: file, share: hostConfigMounted}
	}
	if !write(`{"dockerSocket":"any"}`).get().socketForAnyTier() {
		t.Fatal("the policy as written was not read")
	}
	for _, body := range []string{`{"dockerSocket":"any","mode":"sometimes"}`, `{"dockerSocket":"any"`, `{"dockerSocket":"some"}`, `{"dockerSocket":"any","maxAgeDays":-1}`} {
		if pol := write(body).get(); pol.socketForAnyTier() || !pol.untrustedByDefault() {
			t.Fatalf("%s: %+v, want the fail-closed policy", body, pol)
		}
	}
	// The share the host asked for did not mount, or its file is gone.
	if pol := (&policyLoader{path: file, share: hostConfigUnavailable}).get(); pol.socketForAnyTier() {
		t.Fatalf("an unavailable share: %+v", pol)
	}
	if pol := (&policyLoader{path: filepath.Join(t.TempDir(), "absent.json"), share: hostConfigMounted}).get(); pol.socketForAnyTier() {
		t.Fatalf("a missing file on a mounted share: %+v", pol)
	}
}

// Under dockerSocket: any, an untrusted container the host gave a socket
// creates only containers of its own tier: a child it labels trusted is
// untrusted (it reads the shared stores, never writes them), is in the
// owner's cache scope, gets at most the family's own socket (never a family
// of its own), and the socket shows it its own family and nothing of another
// job's.
func TestAnUntrustedSocketOwnersFamily(t *testing.T) {
	s, owner, child, other, otherChild := delegatedFixture(t)
	policy := filepath.Join(t.TempDir(), "cache-policy.json")
	if err := os.WriteFile(policy, []byte(`{"defaultTrust":"untrusted","dockerSocket":"any"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	s.cachePolicy = policyLoader{path: policy}
	host := withCacheOrigin(context.Background(), cacheOrigin{hostFacing: true})
	bind := dockerHost{Binds: []string{"/var/run/docker.sock:/var/run/docker.sock"}}
	ownerSpec := dockerConfig{Image: "golang:1", Labels: map[string]string{"io.micropod.cache": "off", "io.micropod.cache.scope": "proj-a"}, HostConfig: bind}
	if grant, err := s.engineSocketGrant(host, ownerSpec); err != nil || !grant {
		t.Fatalf("the untrusted owner's socket: %v %v", grant, err)
	}
	plan, _, err := s.cacheDecision(host, ownerSpec, "sha256:x")
	if err != nil || plan.tier() != trustUntrusted || !plan.ReadOnly {
		t.Fatalf("the owner's plan: %+v %v", plan, err)
	}
	owner.Config, owner.Cache, owner.EngineSocket = ownerSpec, plan, true

	// What the owner's socket marks every request with (serveContainerEngine).
	own := withViewer(withCacheOrigin(context.Background(), cacheOrigin{creator: owner.ID}), owner.ID)
	for name, labels := range map[string]map[string]string{
		"unlabelled":       {"io.micropod.cache": "off"},
		"claiming trusted": {"io.micropod.cache": "off", "io.micropod.cache.trust": "trusted"},
	} {
		childPlan, _, err := s.cacheDecision(own, dockerConfig{Image: "postgres:16", Labels: labels}, "sha256:x")
		if err != nil || childPlan.tier() != trustUntrusted || !childPlan.ReadOnly || childPlan.Scope != "proj-a" {
			t.Errorf("%s child: %+v %v, want an untrusted reader in the owner's scope", name, childPlan, err)
		}
		rules := containerVolumeRules(s.cachePolicy.get(), dockerConfig{Labels: labels}, childPlan, owner.ID)
		if !rules.readOnly || !rules.confined {
			t.Errorf("%s child's volume rules: %+v, want read-only and confined to the owner's scope", name, rules)
		}
	}
	// A child cannot name another scope.
	if _, _, err := s.cacheDecision(own, dockerConfig{Image: "postgres:16", Labels: map[string]string{"io.micropod.cache": "off", "io.micropod.cache.scope": "proj-b"}}, "sha256:x"); err == nil {
		t.Error("a child named another cache scope")
	}
	// A child that binds docker.sock (a runner's `container:` job) shares
	// the family's socket: no family of its own. What it creates there is
	// still an untrusted reader in the owner's scope, whatever it claims.
	jobSpec := dockerConfig{Image: "docker:cli", Labels: map[string]string{"io.micropod.cache": "off", "io.micropod.cache.trust": "trusted"}, HostConfig: bind}
	if grant, err := s.engineSocketGrant(own, jobSpec); err != nil || !grant {
		t.Fatalf("a child sharing its family's socket: %v %v", grant, err)
	}
	jobPlan, _, err := s.cacheDecision(own, jobSpec, "sha256:x")
	if err != nil || jobPlan.tier() != trustUntrusted {
		t.Fatalf("the job container's plan: %+v %v", jobPlan, err)
	}
	child.Config, child.Cache, child.EngineSocket = jobSpec, jobPlan, true
	if child.ownsFamily() {
		t.Fatal("a child with a socket owns a family")
	}
	// What the child's socket marks a request with (openEngineSocket).
	shared := withViewer(withCacheOrigin(context.Background(), cacheOrigin{creator: child.ID}), owner.ID)
	grandchild, _, err := s.cacheDecision(shared, dockerConfig{Image: "postgres:16", Labels: map[string]string{"io.micropod.cache": "off", "io.micropod.cache.trust": "trusted"}}, "sha256:x")
	if err != nil || grandchild.tier() != trustUntrusted || !grandchild.ReadOnly || grandchild.Scope != "proj-a" {
		t.Errorf("a container made on the child's socket: %+v %v, want an untrusted reader in the owner's scope", grandchild, err)
	}
	sharedPath, closeShared, err := serveFamilyEngine(delegatedAPI{s}, t.TempDir(), owner.ID, child.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer closeShared()
	sharedClient := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", sharedPath)
		}}}
	for c, want := range map[*dockerContainer]int{owner: 200, child: 200, other: 404, otherChild: 404} {
		if code := getJSON(t, sharedClient, "/containers/"+c.ID+"/json", nil); code != want {
			t.Errorf("inspect %s on the child's socket: %d, want %d", c.Name, code, want)
		}
	}
	if code := getJSON(t, sharedClient, "/micropod/capacity", nil); code != 403 {
		t.Errorf("/micropod/capacity on the child's socket: %d, want 403", code)
	}
	// Only a family's owner shares: a socket whose container is gone, or is
	// itself a child, hands nothing on; nor does any socket while the policy
	// keeps sockets to trusted containers.
	var api apiError
	for name, ctx := range map[string]context.Context{
		"a socket whose owner is gone": withViewer(withCacheOrigin(context.Background(), cacheOrigin{creator: "gone"}), "gone"),
		"a child taken for an owner":   withViewer(withCacheOrigin(context.Background(), cacheOrigin{creator: child.ID}), child.ID),
		"no family at all":             withCacheOrigin(context.Background(), cacheOrigin{creator: owner.ID}),
	} {
		if grant, err := s.engineSocketGrant(ctx, jobSpec); grant || !errors.As(err, &api) || api.code != 403 {
			t.Errorf("%s: %v %v, want 403", name, grant, err)
		}
	}
	if err := os.WriteFile(policy, []byte(`{"defaultTrust":"trusted"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	s.cachePolicy = policyLoader{path: policy}
	if grant, err := s.engineSocketGrant(own, jobSpec); grant || !errors.As(err, &api) || api.code != 403 {
		t.Errorf("a child's socket under dockerSocket trusted: %v %v, want 403", grant, err)
	}
	if err := os.WriteFile(policy, []byte(`{"defaultTrust":"untrusted","dockerSocket":"any"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	s.cachePolicy = policyLoader{path: policy}

	client := delegatedClient(t, s, owner.ID)
	var list []dockerContainerListRow
	if code := getJSON(t, client, "/v1.47/containers/json?all=1", &list); code != 200 || len(list) != 2 {
		t.Fatalf("the family's list: %d %+v", code, list)
	}
	for c, want := range map[*dockerContainer]int{owner: 200, child: 200, other: 404, otherChild: 404} {
		if code := getJSON(t, client, "/containers/"+c.ID+"/json", nil); code != want {
			t.Errorf("inspect %s: %d, want %d", c.Name, code, want)
		}
	}
	for _, path := range []string{"/micropod/caches", "/micropod/metrics", "/v1.47/micropod/containers/summary"} {
		if code := getJSON(t, client, path, nil); code != 403 {
			t.Errorf("%s on the socket: %d, want 403", path, code)
		}
	}
}
