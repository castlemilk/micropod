package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The trust tier and the guarded dependency proxies.

func untrustedPolicy() cachePolicy {
	pol := defaultCachePolicy()
	pol.DefaultTrust = trustUntrusted
	return pol
}

func decideFor(t *testing.T, pol cachePolicy, spec dockerConfig, f imageFacts, req cacheRequest) cachePlan {
	t.Helper()
	if spec.Image == "" {
		spec.Image = "qa"
	}
	p, err := decideCachesFor(pol, spec, f, req)
	if err != nil {
		t.Fatalf("decideCachesFor: %v", err)
	}
	return p
}

// containerRequest is a create through a socket bound into a container whose
// own tier is creatorTier.
func containerRequest(creatorTier string) cacheRequest {
	return cacheRequest{origin: cacheOrigin{creator: "c0ffee", creatorTier: creatorTier}}
}

func requireReader(t *testing.T, p cachePlan, tier, from string) {
	t.Helper()
	if !p.ReadOnly || p.tier() != tier || p.TrustFrom != from {
		t.Fatalf("plan trust %q from %q readOnly %v, want %s from %s", p.Trust, p.TrustFrom, p.ReadOnly, tier, from)
	}
	for _, st := range p.Stores {
		if st.Exclusive {
			t.Fatalf("a reader plan asks for %s's writer slot", st.Kind)
		}
	}
}

func requireWriter(t *testing.T, p cachePlan, from string) {
	t.Helper()
	if p.ReadOnly || p.Trust != "" || p.TrustFrom != from {
		t.Fatalf("plan trust %q from %q readOnly %v, want trusted from %s", p.Trust, p.TrustFrom, p.ReadOnly, from)
	}
}

// An unlabeled container gets the policy's defaultTrust: trusted as shipped
// (a developer's docker run warms the caches), a reader of every store under
// defaultTrust=untrusted.
func TestCacheTrustUnlabeledGetsThePolicyDefault(t *testing.T) {
	facts := testFacts(golangEnv, nil)
	requireWriter(t, decide(t, defaultCachePolicy(), dockerConfig{}, facts), trustFromPolicy)
	p := decide(t, untrustedPolicy(), dockerConfig{}, facts)
	requireReader(t, p, trustUntrusted, trustFromPolicy)
	if !p.attached() || len(p.Stores) == 0 {
		t.Fatalf("an untrusted container still reads the stores warm: %+v", p)
	}
	// The yarn v1 row is exclusive; a reader never asks for its slot.
	y := decide(t, untrustedPolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": "yarn"}},
		testFacts([]string{"HOME=/root"}, nil, "node"))
	requireReader(t, y, trustUntrusted, trustFromPolicy)
}

// A container may always lower its tier; it may claim trusted only where the
// policy default is trusted or on the host-facing socket. Unknown values fail.
func TestCacheTrustClaimsAndLowering(t *testing.T) {
	facts := testFacts(golangEnv, nil)
	trusted := dockerConfig{Labels: map[string]string{"io.micropod.cache.trust": "trusted"}}
	requireWriter(t, decide(t, untrustedPolicy(), trusted, facts), trustFromLabel)
	requireReader(t, decideFor(t, untrustedPolicy(), trusted, facts, cacheRequest{}), trustUntrusted, trustFromRefused)
	envClaim := dockerConfig{Env: []string{"MICROPOD_CACHE_TRUST=trusted"}}
	requireReader(t, decideFor(t, untrustedPolicy(), envClaim, facts, cacheRequest{}), trustUntrusted, trustFromRefused)

	requireReader(t, decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache.trust": "untrusted"}}, facts),
		trustUntrusted, trustFromLabel)
	requireReader(t, decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache.readonly": "1"}}, facts),
		trustReadOnly, trustFromLabel)
	// readonly never raises an untrusted default.
	requireReader(t, decide(t, untrustedPolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache.readonly": "1"}}, facts),
		trustUntrusted, trustFromPolicy)

	for _, bad := range []string{"bogus", "TRUSTED-ish", "1"} {
		_, err := decideCaches(defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache.trust": bad}}, facts)
		var api apiError
		if !errors.As(err, &api) || api.code != 400 {
			t.Fatalf("trust %q: %v, want HTTP 400", bad, err)
		}
	}
	// The tier is decided (and an unknown one refused) even when nothing
	// attaches, because alias volumes and docker cp follow it.
	off := dockerConfig{Labels: map[string]string{"io.micropod.cache": "off"}}
	requireReader(t, decide(t, untrustedPolicy(), off, facts), trustUntrusted, trustFromPolicy)
	off.Labels["io.micropod.cache.trust"] = "bogus"
	if _, err := decideCaches(defaultCachePolicy(), off, facts); err == nil {
		t.Fatal("an unknown trust value passed with caches off")
	}
}

// A create from inside a container (a socket bound into it) is never more
// trusted than that container, and an unknown creator counts as untrusted.
func TestCacheTrustCreatorCeiling(t *testing.T) {
	facts := testFacts(golangEnv, nil)
	trusted := dockerConfig{Labels: map[string]string{"io.micropod.cache.trust": "trusted"}}
	requireReader(t, decideFor(t, defaultCachePolicy(), dockerConfig{}, facts, containerRequest(trustUntrusted)), trustUntrusted, trustFromCreator)
	requireReader(t, decideFor(t, defaultCachePolicy(), trusted, facts, containerRequest(trustUntrusted)), trustUntrusted, trustFromCreator)
	requireReader(t, decideFor(t, defaultCachePolicy(), dockerConfig{}, facts, containerRequest(trustReadOnly)), trustReadOnly, trustFromCreator)
	requireReader(t, decideFor(t, defaultCachePolicy(), dockerConfig{}, facts, cacheRequest{}), trustUntrusted, trustFromCreator)
	requireWriter(t, decideFor(t, defaultCachePolicy(), dockerConfig{}, facts, containerRequest(trustTrusted)), trustFromPolicy)
	// A trusted creator does not lift an untrusted policy default.
	requireReader(t, decideFor(t, untrustedPolicy(), trusted, facts, containerRequest(trustTrusted)), trustUntrusted, trustFromRefused)
}

// The engine reads a create's origin from its context: the host-facing
// socket's mark, or the creator a container's socket names, whose plan caps
// the new container. Without a mark the request is a container's.
func TestCacheDecisionTakesTheCreatorsTier(t *testing.T) {
	s := &dockerEngine{containers: map[string]*dockerContainer{}, cachePolicy: policyLoader{path: filepath.Join(t.TempDir(), "absent.json")}}
	untrusted := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache.trust": "untrusted"}}, testFacts(golangEnv, nil))
	trusted := decide(t, defaultCachePolicy(), dockerConfig{}, testFacts(golangEnv, nil))
	s.containers["u"] = &dockerContainer{dockerRecord: dockerRecord{ID: "u", Cache: &untrusted}}
	s.containers["t"] = &dockerContainer{dockerRecord: dockerRecord{ID: "t", Cache: &trusted}}
	// A legacy plan (an older engine's, trusted by its labels) under an
	// untrusted default caps what it creates at untrusted.
	legacy := cachePlan{Scope: "default"}
	s.containers["l"] = &dockerContainer{dockerRecord: dockerRecord{ID: "l", Cache: &legacy}}
	spec := dockerConfig{Image: "qa", Labels: map[string]string{"io.micropod.cache": "off", "io.micropod.cache.trust": "trusted"}}
	for _, tc := range []struct {
		ctx  context.Context
		tier string
	}{
		{withCacheOrigin(context.Background(), cacheOrigin{hostFacing: true}), trustTrusted},
		{withCacheOrigin(context.Background(), cacheOrigin{creator: "t"}), trustTrusted},
		{withCacheOrigin(context.Background(), cacheOrigin{creator: "u"}), trustUntrusted},
		{withCacheOrigin(context.Background(), cacheOrigin{creator: "gone"}), trustUntrusted},
		{withCacheOrigin(context.Background(), cacheOrigin{creator: "l"}), trustTrusted},
		{context.Background(), trustUntrusted},
	} {
		plan, _, err := s.cacheDecision(tc.ctx, spec, "sha256:x")
		if err != nil || plan.tier() != tc.tier {
			t.Fatalf("origin %+v: tier %q (%v), want %s", cacheOriginOf(tc.ctx), plan.tier(), err, tc.tier)
		}
	}
	policyFile := filepath.Join(t.TempDir(), "cache-policy.json")
	if err := os.WriteFile(policyFile, []byte(`{"defaultTrust":"trusted"}`), 0644); err != nil {
		t.Fatal(err)
	}
	s.cachePolicy = policyLoader{path: policyFile}
	if plan, _, err := s.cacheDecision(withCacheOrigin(context.Background(), cacheOrigin{creator: "l"}), dockerConfig{Image: "qa", Labels: map[string]string{"io.micropod.cache": "off"}}, "sha256:x"); err != nil || plan.tier() != trustTrusted {
		t.Fatalf("a legacy trusted creator under the shipped default: %q %v", plan.tier(), err)
	}
	if err := os.WriteFile(policyFile, []byte(`{"defaultTrust":"untrusted","mode":"auto"}`), 0644); err != nil {
		t.Fatal(err)
	}
	s.cachePolicy = policyLoader{path: policyFile}
	// Under the untrusted default the claim is refused anyway; the creator
	// ceiling (untrusted for the legacy plan) holds for an unlabeled child too.
	plan, _, err := s.cacheDecision(withCacheOrigin(context.Background(), cacheOrigin{creator: "l"}), dockerConfig{Image: "qa", Labels: map[string]string{"io.micropod.cache": "off"}}, "sha256:x")
	if err != nil || plan.tier() != trustUntrusted {
		t.Fatalf("a legacy creator under an untrusted default: %q %v", plan.tier(), err)
	}
}

// The policy key is host-owned and parsed strictly; a policy file that exists
// but cannot be parsed fails closed (untrusted by default), a missing one is
// the shipped default.
func TestCachePolicyDefaultTrust(t *testing.T) {
	pol, err := parseCachePolicy([]byte(`{"defaultTrust":"untrusted","proxyUntrusted":true}`))
	if err != nil || !pol.untrustedByDefault() || !pol.ProxyUntrusted {
		t.Fatalf("%+v %v", pol, err)
	}
	if pol, err = parseCachePolicy([]byte(`{"defaultTrust":"trusted"}`)); err != nil || pol.untrustedByDefault() || pol.digest() != defaultCachePolicy().digest() {
		t.Fatalf("trusted: %+v %v", pol, err)
	}
	if pol, err = parseCachePolicy([]byte(`{"defaultTrust":"maybe"}`)); err == nil || !pol.untrustedByDefault() {
		t.Fatalf("an unknown defaultTrust parsed: %+v %v", pol, err)
	}
	dir := t.TempDir()
	file := filepath.Join(dir, "cache-policy.json")
	l := &policyLoader{path: file}
	if l.get().untrustedByDefault() {
		t.Fatal("a missing policy file is not the shipped default")
	}
	for _, body := range []string{`{"mode":"sometimes"}`, `{not json`, `{"defaultTrust":"semi"}`} {
		if err := os.WriteFile(file, []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
		l = &policyLoader{path: file}
		if !l.get().untrustedByDefault() {
			t.Fatalf("invalid policy %s trusts unlabeled containers", body)
		}
	}
}

// allowedScopes holds for a named scope (400), for the policy's own default
// (nothing attaches), and for legacy alias volumes at create and start.
func TestCacheScopeAllowListCoversDefaultsAndAliasVolumes(t *testing.T) {
	pol := defaultCachePolicy()
	pol.AllowedScopes = []string{"team-*"}
	facts := testFacts(golangEnv, nil)
	if _, err := decideCaches(pol, dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": "other"}}, facts); err == nil {
		t.Fatal("a scope outside the allow-list was accepted")
	}
	if p := decide(t, pol, dockerConfig{}, facts); p.attached() || p.Reason != planScopeNotAllowed {
		t.Fatalf("a default scope outside the allow-list attached: %+v", p)
	}
	eng := &dockerEngine{workspace: t.TempDir()}
	plan := decide(t, pol, dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": "team-a"}}, facts)
	for _, bind := range []string{"micropod-ci-scoped-other-gomod:/go/pkg/mod", "micropod-ci-scoped-other-gomod:/go/pkg/mod:ro"} {
		spec := dockerConfig{HostConfig: dockerHost{Binds: []string{bind}}}
		for _, create := range []bool{true, false} {
			_, _, _, err := eng.openMounts(spec, volumeRules(pol, &plan), create, "", t.TempDir())
			var api apiError
			if !errors.As(err, &api) || api.code != 400 || !strings.Contains(err.Error(), "does not allow") {
				t.Fatalf("%s (create %v): %v", bind, create, err)
			}
		}
	}
}

// Under defaultTrust=untrusted an unlabeled container is a reader for legacy
// alias volumes and docker cp as well: no read-write alias, no archive write.
func TestCacheUntrustedByDefaultAliasAndArchive(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	useBoot(t, "boot-a")
	old := cacheDirty
	cacheDirty = newCacheDirtyTracker()
	t.Cleanup(func() { cacheDirty = old })
	policyFile := filepath.Join(t.TempDir(), "cache-policy.json")
	if err := os.WriteFile(policyFile, []byte(`{"defaultTrust":"untrusted"}`), 0644); err != nil {
		t.Fatal(err)
	}
	s := &dockerEngine{workspace: t.TempDir(), cachePolicy: policyLoader{path: policyFile}}
	spec := dockerConfig{HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-default-gomod:/go/pkg/mod"}}}
	plan := decide(t, untrustedPolicy(), spec, imageFacts{})
	if _, _, _, err := s.openMounts(spec, volumeRules(untrustedPolicy(), &plan), true, "", ""); err == nil || !strings.Contains(err.Error(), "read-write") {
		t.Fatalf("an unlabeled container under defaultTrust=untrusted mounted an alias read-write: %v", err)
	}
	if _, err := ensureStore("default", "gomod", nil); err != nil {
		t.Fatal(err)
	}
	c := &dockerContainer{dockerRecord: dockerRecord{Phase: "exited", Config: spec, Cache: &plan}}
	if _, _, err := s.openArchive(t.Context(), c, "/go/pkg/mod/cache", true); err == nil || !strings.Contains(err.Error(), "may only read") {
		t.Fatalf("docker cp into the shared store: %v", err)
	}
	if marked("default", "gomod") {
		t.Fatal("the refused write marked the store")
	}
}

// A plan an older engine made (no TrustFrom) and a record without a plan are
// never trusted under an untrusted default; under the shipped default they
// keep what their labels said.
func TestCacheLegacyRecordsFollowAnUntrustedDefault(t *testing.T) {
	legacy := cachePlan{Scope: "default", Stores: []cacheStoreRef{{Kind: "yarn", Unit: "yarn.u0", Exclusive: true}}}
	c := &dockerContainer{dockerRecord: dockerRecord{Cache: &legacy}}
	if c.cacheReadOnly(defaultCachePolicy()) {
		t.Fatal("a legacy trusted plan lost its tier under the shipped default")
	}
	if !c.cacheReadOnly(untrustedPolicy()) {
		t.Fatal("a legacy plan stays trusted under defaultTrust=untrusted")
	}
	if !legacy.Stores[0].Exclusive {
		t.Fatal("reading the tier changed the container's own plan")
	}
	legacy.legacyTrust(untrustedPolicy())
	if !legacy.ReadOnly || legacy.TrustFrom != trustFromLegacy || legacy.Stores[0].Exclusive {
		t.Fatalf("upgraded plan %+v", legacy)
	}
	bare := &dockerContainer{}
	if bare.cacheReadOnly(defaultCachePolicy()) || !bare.cacheReadOnly(untrustedPolicy()) {
		t.Fatal("a record without a plan")
	}
	bare.Config.Labels = map[string]string{"io.micropod.cache.trust": "untrusted"}
	if !bare.cacheReadOnly(defaultCachePolicy()) {
		t.Fatal("a labelled untrusted record without a plan writes")
	}
}

// The scheduler's job path carries the job's own tier: a job not classified
// trusted reads; a trusted job writes even under an untrusted default.
func TestDecideJobCachesCarriesTheJobsTier(t *testing.T) {
	f := testFacts(golangEnv, nil)
	requireReader(t, decideJobCaches(defaultCachePolicy(), "repo-main", "untrusted", f, nil), trustUntrusted, trustFromLabel)
	requireReader(t, decideJobCaches(defaultCachePolicy(), "repo-main", "", f, nil), trustUntrusted, trustFromLabel)
	requireWriter(t, decideJobCaches(untrustedPolicy(), "repo-main", "trusted", f, nil), trustFromLabel)
}

func proxyPolicy() cachePolicy {
	pol := defaultCachePolicy()
	pol.GoProxy = "http://10.42.0.1:7677/go"
	pol.NpmRegistry = "http://10.42.0.1:7677/npm"
	return pol
}

func nodeGoFacts() imageFacts {
	return testFacts(append([]string{"HOME=/root"}, golangEnv...), nil, "node")
}

// The proxies are injected only while they answer, never over a setting of
// the request, the image or the project, never into a reader tier unless the
// policy asks, and Go always keeps a direct fallback.
func TestCacheProxyInjectionIsGuarded(t *testing.T) {
	up := func(string) bool { return true }
	down := func(string) bool { return false }
	spec := dockerConfig{}
	p := decideFor(t, proxyPolicy(), spec, nodeGoFacts(), cacheRequest{origin: cacheOrigin{hostFacing: true}, proxyUp: up})
	if v, _ := envOf(p, "GOPROXY"); v != "http://10.42.0.1:7677/go|direct" {
		t.Fatalf("GOPROXY %q", v)
	}
	if v, _ := envOf(p, "npm_config_registry"); v != "http://10.42.0.1:7677/npm" || p.Proxy["npm"] != proxyInjected || p.Proxy["pnpm"] != proxyInjected {
		t.Fatalf("npm registry %q %v", v, p.Proxy)
	}
	p = decideFor(t, proxyPolicy(), spec, nodeGoFacts(), cacheRequest{origin: cacheOrigin{hostFacing: true}, proxyUp: down})
	if _, set := envOf(p, "GOPROXY"); set || p.Proxy["gomod"] != proxySkipUnreachable {
		t.Fatalf("GOPROXY injected with the proxy down: %v", p.Proxy)
	}
	if _, set := envOf(p, "npm_config_registry"); set || p.Proxy["npm"] != proxySkipUnreachable {
		t.Fatalf("npm registry injected with the proxy down: %v", p.Proxy)
	}
	// An untrusted container gets no proxy unless the policy says so.
	untrusted := dockerConfig{Labels: map[string]string{"io.micropod.cache.trust": "untrusted"}}
	p = decideFor(t, proxyPolicy(), untrusted, nodeGoFacts(), cacheRequest{origin: cacheOrigin{hostFacing: true}, proxyUp: up})
	if _, set := envOf(p, "GOPROXY"); set || p.Proxy["gomod"] != proxySkipReader || p.Proxy["npm"] != proxySkipReader {
		t.Fatalf("a reader tier got a proxy: %v", p.Proxy)
	}
	pol := proxyPolicy()
	pol.ProxyUntrusted = true
	p = decideFor(t, pol, untrusted, nodeGoFacts(), cacheRequest{origin: cacheOrigin{hostFacing: true}, proxyUp: up})
	if _, set := envOf(p, "GOPROXY"); !set {
		t.Fatalf("proxyUntrusted: %v", p.Proxy)
	}
	// Request and image settings win; an empty value is a setting.
	p = decide(t, proxyPolicy(), dockerConfig{Env: []string{"GOPROXY=", "npm_config_registry=https://npm.corp"}}, nodeGoFacts())
	if p.Proxy["gomod"] != proxySkipRequest || p.Proxy["npm"] != proxySkipRequest {
		t.Fatalf("request settings: %v", p.Proxy)
	}
	img := nodeGoFacts()
	img.Env = append(img.Env, "NPM_CONFIG_REGISTRY=https://npm.corp")
	if p = decide(t, proxyPolicy(), spec, img); p.Proxy["npm"] != proxySkipRequest {
		t.Fatalf("image setting: %v", p.Proxy)
	}
	// A project or image .npmrc that sets the registry wins too.
	p = decideFor(t, proxyPolicy(), spec, nodeGoFacts(), cacheRequest{origin: cacheOrigin{hostFacing: true}, projectNpmRegistry: true})
	if _, set := envOf(p, "npm_config_registry"); set || p.Proxy["npm"] != proxySkipNpmrc || p.Proxy["gomod"] != proxyInjected {
		t.Fatalf("project npmrc: %v", p.Proxy)
	}
	img = nodeGoFacts()
	img.NpmRegistry = map[string]bool{"/root/.npmrc": true}
	if p = decide(t, proxyPolicy(), spec, img); p.Proxy["npm"] != proxySkipNpmrc {
		t.Fatalf("image ~/.npmrc: %v", p.Proxy)
	}
	img.NpmRegistry = map[string]bool{"/app/.npmrc": true}
	img.WorkingDir = "/app/sub"
	if p = decide(t, proxyPolicy(), spec, img); p.Proxy["npm"] != proxySkipNpmrc {
		t.Fatalf("image project .npmrc: %v", p.Proxy)
	}
	if p = decide(t, proxyPolicy(), dockerConfig{WorkingDir: "/elsewhere"}, img); p.Proxy["npm"] != proxyInjected {
		t.Fatalf("an image .npmrc outside the working directory: %v", p.Proxy)
	}
}

func TestGoProxyAlwaysKeepsADirectFallback(t *testing.T) {
	for in, want := range map[string]string{
		"http://p/go":                 "http://p/go|direct",
		"http://p/go,direct":          "http://p/go,direct",
		"http://p/go|direct":          "http://p/go|direct",
		"http://p/go,off":             "http://p/go|direct",
		"http://a/go,http://b/go":     "http://a/go,http://b/go|direct",
		"http://a/go|off|http://b/go": "http://a/go|http://b/go|direct",
		"off":                         "direct",
		" http://p/go , direct ":      "http://p/go,direct",
	} {
		if got := goProxyWithDirect(in); got != want {
			t.Errorf("goProxyWithDirect(%q) = %q, want %q", in, got, want)
		}
	}
	if firstProxyURL("direct,http://a/go|https://b") != "http://a/go" || firstProxyURL("direct") != "" {
		t.Fatal("firstProxyURL")
	}
}

func TestNpmrcSetsRegistry(t *testing.T) {
	for body, want := range map[string]bool{
		"registry=https://npm.corp/\n":                   true,
		"  Registry = https://npm.corp/":                 true,
		"@corp:registry=https://npm.corp/\n":             false,
		"# registry=https://x\n; registry=https://y\n":   false,
		"always-auth=true\n//npm.corp/:_authToken=abc\n": false,
		"strict-ssl=false\nregistry=http://localhost/\n": true,
	} {
		if got := npmrcSetsRegistry([]byte(body)); got != want {
			t.Errorf("%q: %v", body, got)
		}
	}
}

// The engine finds a project .npmrc through the workspace bind that covers
// the working directory, and never follows a symlink out of the workspace.
func TestProjectNpmRegistryThroughTheWorkspaceBind(t *testing.T) {
	ws := t.TempDir()
	project := filepath.Join(ws, "src", "app")
	if err := os.MkdirAll(filepath.Join(project, "pkg"), 0755); err != nil {
		t.Fatal(err)
	}
	s := &dockerEngine{workspace: ws}
	spec := dockerConfig{WorkingDir: "/work/pkg", HostConfig: dockerHost{Binds: []string{project + ":/work"}}}
	if s.projectNpmRegistry(spec, "") {
		t.Fatal("no .npmrc yet")
	}
	if err := os.WriteFile(filepath.Join(project, ".npmrc"), []byte("@corp:registry=https://npm.corp/\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if s.projectNpmRegistry(spec, "") {
		t.Fatal("a scoped registry counted")
	}
	if err := os.WriteFile(filepath.Join(project, ".npmrc"), []byte("registry=https://npm.corp/\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if !s.projectNpmRegistry(spec, "") || !s.projectNpmRegistry(dockerConfig{HostConfig: spec.HostConfig}, "/work") {
		t.Fatal("the project's registry was not found")
	}
	if s.projectNpmRegistry(dockerConfig{WorkingDir: "/other", HostConfig: spec.HostConfig}, "") {
		t.Fatal("a working directory outside the bind")
	}
	outside := filepath.Join(t.TempDir(), "npmrc")
	if err := os.WriteFile(outside, []byte("registry=https://evil/\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(project, ".npmrc")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(project, "pkg", ".npmrc")); err != nil {
		t.Fatal(err)
	}
	if s.projectNpmRegistry(spec, "") {
		t.Fatal("followed a symlink out of the workspace")
	}
}

// One health check per URL per TTL; the check itself is one bounded GET in
// which any answer below 500 counts as up.
func TestProxyHealthCheck(t *testing.T) {
	now := time.Unix(1000, 0)
	probes := 0
	h := &proxyHealth{probe: func(string) bool { probes++; return probes%2 == 1 }, now: func() time.Time { return now }}
	if !h.up("http://p") || !h.up("http://p") || probes != 1 {
		t.Fatalf("probes %d", probes)
	}
	now = now.Add(proxyProbeTTL)
	if h.up("http://p") || probes != 2 {
		t.Fatalf("after the TTL: probes %d", probes)
	}
	for status, want := range map[int]bool{200: true, 404: true, 302: true, 503: false} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if status == 302 {
				http.Redirect(w, r, "http://192.0.2.1/elsewhere", http.StatusFound)
				return
			}
			w.WriteHeader(status)
		}))
		if got := probeProxy(srv.URL + "/go"); got != want {
			t.Errorf("status %d: up=%v", status, got)
		}
		srv.Close()
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	if probeProxy("http://" + addr + "/go") {
		t.Fatal("a closed port counted as up")
	}
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second)
	}))
	defer slow.Close()
	start := time.Now()
	if probeProxy(slow.URL) || time.Since(start) > time.Second {
		t.Fatalf("a proxy that does not answer took %v", time.Since(start))
	}
}

// Facts cached before the probe read npmrc files (version 2) are probed
// again, so an image's own registry setting is never missed.
func TestImageFactsWithoutNpmrcRegistriesAreProbedAgain(t *testing.T) {
	old := imageFactsDir
	imageFactsDir = t.TempDir()
	t.Cleanup(func() { imageFactsDir = old })
	id := "sha256:" + strings.Repeat("cd", 32)
	if err := writeCachedFacts(imageFacts{Version: 2, ImageID: id, OK: true}); err != nil {
		t.Fatal(err)
	}
	if _, ok := readCachedFacts(id); ok || factsVersion < 3 {
		t.Fatal("facts cached without npmrc registries are used")
	}
}
