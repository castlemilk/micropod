package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The dependency proxies: which GOPROXY lists the guest accepts, the check
// at every start, and the config files that win over the policy's proxy.

// The guest accepts every goProxy list the host does (',' and '|' both
// separate entries), so a host-accepted value never fails the policy closed.
func TestGuestAcceptsTheHostsGoProxyLists(t *testing.T) {
	for _, v := range []string{"direct|https://proxy.example", "off|http://x", "http://10.42.0.1:7677/go|direct", "https://a,https://b|direct"} {
		if !validProxySetting(v) {
			t.Fatalf("%q refused", v)
		}
		pol, err := parseCachePolicy([]byte(`{"goProxy":"` + v + `"}`))
		if err != nil || pol.untrustedByDefault() || pol.GoProxy != v {
			t.Fatalf("%q: %+v %v", v, pol, err)
		}
	}
	for _, v := range []string{"file:///p", "http://x|file:///p", "ftp://x,direct"} {
		if validProxySetting(v) {
			t.Fatalf("%q accepted", v)
		}
	}
}

// A start rechecks the proxies its create injected: one that does not answer
// now is left out of that start (its variable and inspect say so), the
// others stay.
func TestCacheProxiesAreRecheckedAtStart(t *testing.T) {
	up := func(string) bool { return true }
	p := decideFor(t, proxyPolicy(), dockerConfig{}, nodeGoFacts(), cacheRequest{origin: cacheOrigin{hostFacing: true}, proxyUp: up})
	if down := p.unreachableProxies(up); len(down) != 0 {
		t.Fatalf("all up: %v", down)
	}
	npmDown := func(u string) bool { return !strings.Contains(u, "/npm") }
	down := p.unreachableProxies(npmDown)
	if down["npm"] != proxySkipUnreachable || down["pnpm"] != proxySkipUnreachable || down["gomod"] != "" {
		t.Fatalf("down %v", down)
	}
	env := withoutProxies(p.env(nil), down)
	if _, set := envLookup(env, "npm_config_registry", false); set {
		t.Fatalf("npm_config_registry kept with the registry down: %v", env)
	}
	if v, _ := envLookup(env, "GOPROXY", false); v != "http://10.42.0.1:7677/go|direct" {
		t.Fatalf("GOPROXY %q", v)
	}
	if _, set := envLookup(env, "npm_config_cache", false); !set {
		t.Fatal("the npm store's own variable went with the registry")
	}
	if got := (&cachePlan{}).unreachableProxies(func(string) bool { return false }); got != nil {
		t.Fatalf("a plan without proxies: %v", got)
	}
	c := &dockerContainer{dockerRecord: dockerRecord{Cache: &p, CacheProxy: down}}
	mc := c.inspect()["MicropodCache"].(map[string]any)
	if proxy := mc["proxy"].(map[string]string); proxy["npm"] != proxySkipUnreachable || proxy["gomod"] != proxyInjected {
		t.Fatalf("inspect proxy %v", proxy)
	}
}

// The proxy guard reads the config files a request mounts and the go env
// files of the image, and a request that names its own config files keeps
// them.
func TestCacheProxyGuardReadsMountedAndImageConfigFiles(t *testing.T) {
	ws := t.TempDir()
	s := &dockerEngine{workspace: ws}
	npmrc := filepath.Join(ws, "npmrc")
	goenv := filepath.Join(ws, "goenv")
	if err := os.WriteFile(npmrc, []byte("registry=https://npm.corp/\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(goenv, []byte("GOPROXY=off\n"), 0644); err != nil {
		t.Fatal(err)
	}
	facts := nodeGoFacts()
	env := append(append([]string{}, facts.Env...), "HOME=/root")
	spec := dockerConfig{HostConfig: dockerHost{Binds: []string{npmrc + ":/root/.npmrc:ro", goenv + ":/root/.config/go/env:ro"}}}
	if !s.mountedConfigSets(spec, npmrcCandidates(env, facts.Passwd, "", ""), npmrcSetsRegistry) {
		t.Fatal("a bind-mounted ~/.npmrc was not read")
	}
	if !s.mountedConfigSets(spec, goEnvCandidates(env, facts.Passwd, ""), goEnvSetsProxy) {
		t.Fatal("a bind-mounted go env file was not read")
	}
	if s.mountedConfigSets(dockerConfig{}, npmrcCandidates(env, facts.Passwd, "", ""), npmrcSetsRegistry) {
		t.Fatal("nothing mounted")
	}
	// A deeper tmpfs hides a bind's file.
	if err := os.WriteFile(filepath.Join(ws, ".npmrc"), []byte("registry=https://npm.corp/\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if s.mountedConfigSets(dockerConfig{HostConfig: dockerHost{Binds: []string{ws + ":/root:ro"}, Tmpfs: map[string]string{"/root": ""}}}, []string{"/root/.npmrc"}, npmrcSetsRegistry) {
		t.Fatal("a tmpfs over the bind")
	}
	if !s.mountedConfigSets(dockerConfig{HostConfig: dockerHost{Binds: []string{ws + ":/root:ro"}}}, []string{"/root/.npmrc"}, npmrcSetsRegistry) {
		t.Fatal("a bind of the home directory")
	}

	up := cacheRequest{origin: cacheOrigin{hostFacing: true}, proxyUp: func(string) bool { return true }}
	withGo := up
	withGo.projectGoProxy = true
	if p := decideFor(t, proxyPolicy(), dockerConfig{}, nodeGoFacts(), withGo); p.Proxy["gomod"] != proxySkipGoEnv {
		t.Fatalf("mounted go env: %v", p.Proxy)
	}
	img := nodeGoFacts()
	img.GoEnvProxy = map[string]bool{"/root/.config/go/env": true}
	if p := decideFor(t, proxyPolicy(), dockerConfig{}, img, up); p.Proxy["gomod"] != proxySkipGoEnv {
		t.Fatalf("image go env: %v", p.Proxy)
	}
	if p := decideFor(t, proxyPolicy(), dockerConfig{Env: []string{"XDG_CONFIG_HOME=/cfg"}}, img, up); p.Proxy["gomod"] != proxyInjected {
		t.Fatalf("another go env file: %v", p.Proxy)
	}
	for _, e := range []string{"NPM_CONFIG_USERCONFIG=/w/.npmrc", "npm_config_globalconfig=/w/npmrc"} {
		if p := decideFor(t, proxyPolicy(), dockerConfig{Env: []string{e}}, nodeGoFacts(), up); p.Proxy["npm"] != proxySkipRequest || p.Proxy["gomod"] != proxyInjected {
			t.Fatalf("%s: %v", e, p.Proxy)
		}
	}
	if p := decideFor(t, proxyPolicy(), dockerConfig{Env: []string{"GOENV=/w/goenv"}}, nodeGoFacts(), up); p.Proxy["gomod"] != proxySkipRequest {
		t.Fatalf("GOENV: %v", p.Proxy)
	}
	if p := decideFor(t, proxyPolicy(), dockerConfig{Env: []string{"GOENV=off"}}, nodeGoFacts(), up); p.Proxy["gomod"] != proxyInjected {
		t.Fatalf("GOENV=off: %v", p.Proxy)
	}
	for body, want := range map[string]bool{"GOPROXY=off\n": true, "GOFLAGS=-mod=mod\nGOPROXY=https://corp\n": true, "GOPRIVATE=x\n": false, "# GOPROXY=x\n": false} {
		if goEnvSetsProxy([]byte(body)) != want {
			t.Errorf("goEnvSetsProxy(%q)", body)
		}
	}
	if got := goEnvCandidates([]string{"GOENV=/etc/goenv"}, nil, ""); len(got) != 1 || got[0] != "/etc/goenv" {
		t.Fatalf("GOENV candidates %v", got)
	}
	if got := goEnvCandidates([]string{"GOENV=off"}, nil, ""); len(got) != 0 {
		t.Fatalf("GOENV=off candidates %v", got)
	}
}
