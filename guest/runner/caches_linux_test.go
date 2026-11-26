package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

var dirFact = pathFact{Exists: true, Dir: true, ParentExists: true}

// testFacts is an image with root, node (1000) and app (1001) users.
func testFacts(env []string, paths map[string]pathFact, bins ...string) imageFacts {
	f := imageFacts{OK: true, Env: env,
		Passwd:   []passwdEntry{{"root", 0, 0, "/root"}, {"node", 1000, 1000, "/home/node"}, {"app", 1001, 1001, "/home/app"}},
		Group:    []groupEntry{{"root", 0}, {"node", 1000}, {"staff", 50}},
		Paths:    map[string]pathFact{"/root": dirFact, "/home": dirFact, "/home/node": dirFact, "/usr": dirFact, "/usr/local": dirFact},
		Binaries: map[string]bool{}}
	for k, v := range paths {
		f.Paths[k] = v
	}
	for _, b := range bins {
		f.Binaries[b] = true
	}
	return f
}

var golangEnv = []string{"PATH=/go/bin:/usr/local/go/bin:/usr/sbin:/usr/bin:/sbin:/bin", "GOLANG_VERSION=1.27.4", "GOTOOLCHAIN=local", "GOPATH=/go"}

func decide(t *testing.T, pol cachePolicy, spec dockerConfig, f imageFacts) cachePlan {
	t.Helper()
	if spec.Image == "" {
		spec.Image = "qa"
	}
	p, err := decideCaches(pol, spec, f)
	if err != nil {
		t.Fatalf("decideCaches: %v", err)
	}
	return p
}

func envOf(p cachePlan, key string) (string, bool) { return envLookup(p.Env, key, false) }

func reason(p cachePlan, tool string) string {
	st, ok := p.Tools[tool]
	if !ok {
		return "<absent>"
	}
	if st.Mode != "skipped" {
		return st.Mode
	}
	return st.Reason
}

func TestDecideCachesDefaultsGolang(t *testing.T) {
	p := decide(t, defaultCachePolicy(), dockerConfig{}, testFacts(golangEnv, nil))
	if p.Scope != "default" || p.UID != 0 || p.Home != "/root" || p.Reason != "" {
		t.Fatalf("plan identity %+v", p)
	}
	for key, want := range map[string]string{
		"GOMODCACHE": "/micropod/cache/gomod", "GOCACHE": "/micropod/cache/gobuild", "GOFLAGS": "-trimpath",
		"npm_config_cache": "/micropod/cache/npm", "pnpm_config_store_dir": "/micropod/cache/pnpm", "npm_config_store_dir": "/micropod/cache/pnpm",
		"PIP_CACHE_DIR": "/micropod/cache/pip/u0", "UV_CACHE_DIR": "/micropod/cache/uv", "UV_LINK_MODE": "copy", "COREPACK_HOME": "/micropod/cache/corepack",
	} {
		if got, _ := envOf(p, key); got != want {
			t.Errorf("%s=%q, want %q", key, got, want)
		}
	}
	if len(p.Mounts) != 1 || p.Mounts[0] != (cacheMount{Target: "/micropod/cache"}) {
		t.Fatalf("want exactly the scope bind, got %+v", p.Mounts)
	}
	for tool, want := range map[string]string{"gomod": "env", "gobuild": "env", "yarn": skipNotInstalled, "yarnberry": skipNotInstalled, "cargo": skipNotInstalled, "pip": "env", "uv": "env", "corepack": "env"} {
		if got := reason(p, tool); got != want {
			t.Errorf("%s: %s, want %s", tool, got, want)
		}
	}
	units := []string{}
	for _, s := range p.Stores {
		units = append(units, s.Unit)
	}
	if strings.Join(units, " ") != "gomod gobuild npm pnpm pip.u0 uv corepack" {
		t.Fatalf("stores %v", units)
	}
}

func TestDecideCachesSkipRules(t *testing.T) {
	node := []string{"PATH=/usr/local/bin:/usr/bin:/bin", "NODE_VERSION=22.23.5", "YARN_VERSION=1.22.22"}
	for _, tc := range []struct {
		name  string
		spec  dockerConfig
		facts imageFacts
		tool  string
		want  string
	}{
		{"request GOCACHE", dockerConfig{Env: []string{"GOCACHE=/tmp/x"}}, testFacts(golangEnv, nil), "gobuild", skipUserEnv},
		{"request GOMODCACHE", dockerConfig{Env: []string{"GOMODCACHE=/m"}}, testFacts(golangEnv, nil), "gomod", skipUserEnv},
		{"request npm key folded", dockerConfig{Env: []string{"NPM_CONFIG_CACHE=/n"}}, testFacts(node, nil), "npm", skipUserEnv},
		{"request legacy pnpm key", dockerConfig{Env: []string{"npm_config_store_dir=/s"}}, testFacts(node, nil), "pnpm", skipUserEnv},
		{"request pip disable", dockerConfig{Env: []string{"PIP_NO_CACHE_DIR=1"}}, testFacts(nil, nil), "pip", skipUserEnv},
		{"request YARN_CACHE_FOLDER", dockerConfig{Env: []string{"YARN_CACHE_FOLDER=/y"}}, testFacts(node, nil, "node"), "yarn", skipUserEnv},
		{"image pip disable", dockerConfig{}, testFacts([]string{"PIP_NO_CACHE_DIR=yes"}, nil), "pip", skipDisabledImage},
		{"image pip disable falsy", dockerConfig{}, testFacts([]string{"PIP_NO_CACHE_DIR=0"}, nil), "pip", "env"},
		{"image GOCACHE=off", dockerConfig{}, testFacts(append([]string{"GOCACHE=off"}, golangEnv...), nil), "gobuild", skipDisabledImage},
		{"image UV_NO_CACHE", dockerConfig{}, testFacts([]string{"UV_NO_CACHE=1"}, nil), "uv", skipDisabledImage},
		{"image berry global cache off", dockerConfig{}, testFacts(append([]string{"YARN_ENABLE_GLOBAL_CACHE=false"}, node...), nil, "node"), "yarnberry", skipDisabledImage},
		{"volume at go-build default", dockerConfig{HostConfig: dockerHost{Binds: []string{"mygo:/root/.cache/go-build"}}}, testFacts(golangEnv, nil), "gobuild", skipUserMount},
		{"volume at go-build keeps gomod", dockerConfig{HostConfig: dockerHost{Binds: []string{"mygo:/root/.cache/go-build"}}}, testFacts(golangEnv, nil), "gomod", "env"},
		{"home volume covers default", dockerConfig{HostConfig: dockerHost{Binds: []string{"home:/root"}}}, testFacts(golangEnv, nil), "gobuild", skipUserMount},
		{"mount below default", dockerConfig{HostConfig: dockerHost{Mounts: []dockerMount{{Type: "volume", Source: "dl", Target: "/go/pkg/mod/cache/download"}}}}, testFacts(golangEnv, nil), "gomod", skipUserMount},
		{"scoped alias volume counts", dockerConfig{HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-repo-gomod:/cache/gomod"}}}, testFacts(golangEnv, nil), "gomod", skipUserMount},
		{"baked module cache", dockerConfig{}, testFacts(golangEnv, map[string]pathFact{"/go/pkg/mod/cache/download": {Exists: true, Dir: true, NonEmpty: true}}), "gomod", skipPrewarmed},
		{"empty module cache dir is not warm", dockerConfig{}, testFacts(golangEnv, map[string]pathFact{"/go/pkg/mod/cache/download": {Exists: true, Dir: true}}), "gomod", "env"},
		{"baked build cache", dockerConfig{}, testFacts(golangEnv, map[string]pathFact{"/root/.cache/go-build/00": dirFact}), "gobuild", skipPrewarmed},
		{"baked npm cache", dockerConfig{}, testFacts(node, map[string]pathFact{"/root/.npm/_cacache": {Exists: true, Dir: true, NonEmpty: true}}), "npm", skipPrewarmed},
		{"prepared corepack", dockerConfig{}, testFacts(node, map[string]pathFact{"/root/.cache/node/corepack/v1": dirFact}), "corepack", skipPrewarmed},
		{"yarn needs node", dockerConfig{}, testFacts(nil, nil), "yarn", skipNotInstalled},
		{"yarn forced", dockerConfig{Labels: map[string]string{"io.micropod.cache": "+yarn"}}, testFacts(nil, nil), "yarn", "path"},
		{"yarn with node", dockerConfig{}, testFacts(node, nil, "node"), "yarn", "path"},
		{"berry with corepack only", dockerConfig{}, testFacts(node, nil, "corepack"), "yarnberry", "path"},
		{"cargo needs CARGO_HOME", dockerConfig{}, testFacts([]string{"CARGO_HOME=/usr/local/cargo"}, nil), "cargo", skipNotInstalled},
		{"cargo home exists", dockerConfig{}, testFacts([]string{"CARGO_HOME=/usr/local/cargo"}, map[string]pathFact{"/usr/local/cargo": dirFact}), "cargo", "path"},
		{"cargo config bind is not a cache overlap", dockerConfig{HostConfig: dockerHost{Binds: []string{"/w/config.toml:/usr/local/cargo/config.toml:ro"}}}, testFacts([]string{"CARGO_HOME=/usr/local/cargo"}, map[string]pathFact{"/usr/local/cargo": dirFact}), "cargo", "path"},
		{"cargo home volume", dockerConfig{HostConfig: dockerHost{Binds: []string{"ch:/usr/local/cargo"}}}, testFacts([]string{"CARGO_HOME=/usr/local/cargo"}, map[string]pathFact{"/usr/local/cargo": dirFact}), "cargo", skipUserMount},
		{"non-empty /micropod in image", dockerConfig{}, testFacts(golangEnv, map[string]pathFact{"/micropod": {Exists: true, Dir: true, NonEmpty: true}}), "gomod", skipReserved},
		{"user mount below /micropod/cache", dockerConfig{HostConfig: dockerHost{Binds: []string{"x:/micropod/cache/x"}}}, testFacts(golangEnv, nil), "gobuild", skipReserved},
		{"reserved path keeps path-mode", dockerConfig{}, testFacts(node, map[string]pathFact{"/micropod": {Exists: true, Dir: true, NonEmpty: true}}, "node"), "yarn", "path"},
		{"not selected", dockerConfig{Labels: map[string]string{"io.micropod.cache": "go"}}, testFacts(node, nil, "node"), "npm", skipNotSelected},
		{"minus removes", dockerConfig{Labels: map[string]string{"io.micropod.cache": "-pip"}}, testFacts(nil, nil), "pip", skipNotSelected},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := decide(t, defaultCachePolicy(), tc.spec, tc.facts)
			if got := reason(p, tc.tool); got != tc.want {
				t.Fatalf("%s: %s, want %s (%+v)", tc.tool, got, tc.want, p.Tools[tc.tool])
			}
			// A skipped tool never contributes variables or binds.
			if p.Tools[tc.tool].Mode == "skipped" {
				if len(p.ToolEnv[tc.tool]) > 0 {
					t.Fatalf("skipped tool set %v", p.ToolEnv[tc.tool])
				}
				for _, m := range p.Mounts {
					if m.Kind == tc.tool {
						t.Fatalf("skipped tool bound %+v", m)
					}
				}
			}
		})
	}
}

func TestDecideCachesOptOutsAndScope(t *testing.T) {
	g := testFacts(golangEnv, nil)
	off := defaultCachePolicy()
	off.Mode = "off"
	for _, tc := range []struct {
		name   string
		pol    cachePolicy
		spec   dockerConfig
		facts  imageFacts
		reason string
	}{
		{"policy off", off, dockerConfig{}, g, planPolicyOff},
		{"label off", defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": "off"}}, g, planLabelOff},
		{"alias label off", defaultCachePolicy(), dockerConfig{Labels: map[string]string{"com.micropod.cache": "OFF"}}, g, planLabelOff},
		{"shared=false", defaultCachePolicy(), dockerConfig{Labels: map[string]string{"micropod.cache.shared": "false"}}, g, planLabelOff},
		{"request env off", defaultCachePolicy(), dockerConfig{Env: []string{"MICROPOD_CACHE=off"}}, g, planEnvOff},
		{"image env off", defaultCachePolicy(), dockerConfig{}, testFacts(append([]string{"MICROPOD_CACHE=off"}, golangEnv...), nil), planImageOff},
		{"probe failed", defaultCachePolicy(), dockerConfig{}, imageFacts{}, skipProbeFailed},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := decide(t, tc.pol, tc.spec, tc.facts)
			if p.Reason != tc.reason || len(p.Mounts) != 0 || len(p.Env) != 0 || len(p.Stores) != 0 {
				t.Fatalf("plan %+v", p)
			}
		})
	}
	// The image may only disable: any other MICROPOD_CACHE value is ignored.
	if p := decide(t, defaultCachePolicy(), dockerConfig{}, testFacts(append([]string{"MICROPOD_CACHE=go"}, golangEnv...), nil)); reason(p, "npm") != "env" {
		t.Fatal("image MICROPOD_CACHE widened or narrowed the selection")
	}
	// probe-failed lists every selected tool.
	if p := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": "go"}}, imageFacts{}); len(p.Tools) != 2 || reason(p, "gomod") != skipProbeFailed {
		t.Fatalf("probe-failed tools %+v", p.Tools)
	}
	for _, tc := range []struct {
		spec  dockerConfig
		scope string
	}{
		{dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": "proja"}}, "proja"},
		{dockerConfig{Labels: map[string]string{"com.micropod.cache.scope": "projb"}}, "projb"},
		{dockerConfig{Env: []string{"MICROPOD_CACHE_SCOPE=projc"}}, "projc"},
		{dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": "proja"}, Env: []string{"MICROPOD_CACHE_SCOPE=projc"}}, "proja"},
	} {
		if p := decide(t, defaultCachePolicy(), tc.spec, g); p.Scope != tc.scope {
			t.Fatalf("scope %q, want %q", p.Scope, tc.scope)
		}
	}
	ci := defaultCachePolicy()
	ci.DefaultScope, ci.AllowedScopes = "", []string{"ci-*", "release"}
	if p := decide(t, ci, dockerConfig{}, g); p.Reason != planNoScope || p.attached() {
		t.Fatalf("empty default scope attached %+v", p)
	}
	for _, ok := range []string{"ci-1", "ci-", "release"} {
		if p := decide(t, ci, dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": ok}}, g); p.Scope != ok || !p.attached() {
			t.Fatalf("allowed scope %s: %+v", ok, p)
		}
	}
	for _, bad := range []dockerConfig{
		{Labels: map[string]string{"io.micropod.cache.scope": "other"}},
		{Labels: map[string]string{"io.micropod.cache.scope": "Bad/scope"}},
		{Env: []string{"MICROPOD_CACHE_SCOPE=../x"}},
		{Labels: map[string]string{"io.micropod.cache": "go,bogus"}},
	} {
		_, err := decideCaches(ci, bad, g)
		var api apiError
		if !errors.As(err, &api) || api.code != 400 {
			t.Fatalf("%+v: want HTTP 400, got %v", bad, err)
		}
	}
	if _, err := decideCaches(defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": "x"}}, g); err != nil {
		t.Fatal(err)
	}
}

func TestDecideCachesSelectionAndGoflags(t *testing.T) {
	g := testFacts(golangEnv, nil)
	p := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": "go"}}, g)
	if len(p.Stores) != 2 || reason(p, "gomod") != "env" || reason(p, "gobuild") != "env" || reason(p, "npm") != skipNotSelected {
		t.Fatalf("go group %+v", p.Tools)
	}
	if p := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": "go,+cargo"}}, g); reason(p, "cargo") != "path" || reason(p, "npm") != skipNotSelected {
		t.Fatalf("+cargo %+v", p.Tools)
	}
	if p := decide(t, defaultCachePolicy(), dockerConfig{Env: []string{"MICROPOD_CACHE=npm"}}, g); reason(p, "npm") != "env" || reason(p, "gomod") != skipNotSelected {
		t.Fatalf("env selection %+v", p.Tools)
	}
	narrow := defaultCachePolicy()
	narrow.Tools = []string{"gomod", "gobuild"}
	if p := decide(t, narrow, dockerConfig{}, g); reason(p, "npm") != skipNotSelected || reason(p, "gobuild") != "env" {
		t.Fatalf("policy tools %+v", p.Tools)
	}
	for _, tc := range []struct {
		name   string
		pol    func(*cachePolicy)
		spec   dockerConfig
		image  []string
		want   string
		absent bool
	}{
		{"default", nil, dockerConfig{}, nil, "-trimpath", false},
		{"request flags kept", nil, dockerConfig{Env: []string{"GOFLAGS=-mod=vendor"}}, nil, "-mod=vendor -trimpath", false},
		{"image flags kept", nil, dockerConfig{}, []string{"GOFLAGS=-mod=mod"}, "-mod=mod -trimpath", false},
		{"request wins over image", nil, dockerConfig{Env: []string{"GOFLAGS=-v"}}, []string{"GOFLAGS=-mod=mod"}, "-v -trimpath", false},
		{"explicit false wins", nil, dockerConfig{Env: []string{"GOFLAGS=-trimpath=false"}}, nil, "", true},
		{"already set", nil, dockerConfig{}, []string{"GOFLAGS=-mod=mod --trimpath"}, "", true},
		{"label opt-out", nil, dockerConfig{Labels: map[string]string{"io.micropod.cache.go-trimpath": "false"}}, nil, "", true},
		{"policy opt-out", func(p *cachePolicy) { p.GoTrimpath = false }, dockerConfig{}, nil, "", true},
		{"no merge without gobuild", nil, dockerConfig{Env: []string{"GOCACHE=/x"}}, nil, "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pol := defaultCachePolicy()
			if tc.pol != nil {
				tc.pol(&pol)
			}
			p := decide(t, pol, tc.spec, testFacts(append(append([]string{}, golangEnv...), tc.image...), nil))
			got, ok := envOf(p, "GOFLAGS")
			if tc.absent && ok || !tc.absent && got != tc.want {
				t.Fatalf("GOFLAGS=%q (set %v), want %q", got, ok, tc.want)
			}
			// The plan's GOFLAGS replaces the request's when the container starts.
			cfg := mergeEnv(tc.spec.Env, p.Env)
			if v, _ := envLookup(cfg, "GOFLAGS", false); !tc.absent && v != tc.want || strings.Count(strings.Join(cfg, "\n"), "GOFLAGS=") > 1 {
				t.Fatalf("merged env %v", cfg)
			}
		})
	}
	legacyOff := defaultCachePolicy()
	legacyOff.PnpmLegacyEnv = false
	if p := decide(t, legacyOff, dockerConfig{}, g); func() bool { _, ok := envOf(p, "npm_config_store_dir"); return ok }() {
		t.Fatal("legacy pnpm key set with pnpmLegacyEnv=false")
	}
}

func TestDecideCachesImageSetEnvAndPartitions(t *testing.T) {
	f := testFacts(append([]string{"GOMODCACHE=/opt/gomod", "PIP_CACHE_DIR=/var/cache/pip"}, golangEnv...), nil)
	p := decide(t, defaultCachePolicy(), dockerConfig{User: "1000:1000"}, f)
	if _, ok := envOf(p, "GOMODCACHE"); ok {
		t.Fatal("replaced an image-set GOMODCACHE")
	}
	if st := p.Tools["gomod"]; st.Mode != "path" || st.Path != "/opt/gomod" {
		t.Fatalf("gomod %+v", st)
	}
	want := map[string]cacheMount{
		"/opt/gomod":     {Kind: "gomod", Unit: "gomod", Target: "/opt/gomod"},
		"/var/cache/pip": {Kind: "pip", Unit: "pip.u1000", Target: "/var/cache/pip"},
	}
	for _, m := range p.Mounts {
		if w, ok := want[m.Target]; ok {
			if m != w {
				t.Fatalf("mount %+v, want %+v", m, w)
			}
			delete(want, m.Target)
		}
	}
	if len(want) != 0 {
		t.Fatalf("missing mounts %v in %+v", want, p.Mounts)
	}
	// Env-mode partition path for the configured uid; the scope bind comes first.
	p = decide(t, defaultCachePolicy(), dockerConfig{User: "1000:1000"}, testFacts(nil, nil))
	if v, _ := envOf(p, "PIP_CACHE_DIR"); v != "/micropod/cache/pip/u1000" || p.Mounts[0].Target != "/micropod/cache" {
		t.Fatalf("pip partition %q mounts %+v", v, p.Mounts)
	}
	var pip cacheStoreRef
	for _, s := range p.Stores {
		if s.Kind == "pip" {
			pip = s
		}
	}
	if pip.Unit != "pip.u1000" || pip.UID == nil || *pip.UID != 1000 {
		t.Fatalf("pip store %+v", pip)
	}
	// Disabling one tool at start removes exactly its variables (GOFLAGS rides with gobuild).
	env := p.env(map[string]string{"gobuild": skipStoreFailed})
	if _, ok := envLookup(env, "GOCACHE", false); ok {
		t.Fatal("skipped gobuild kept GOCACHE")
	}
	if _, ok := envLookup(env, "GOFLAGS", false); ok {
		t.Fatal("skipped gobuild kept GOFLAGS")
	}
	if _, ok := envLookup(env, "GOMODCACHE", false); !ok {
		t.Fatal("skipping gobuild dropped gomod")
	}
}

func TestDecideCachesUsersAndShims(t *testing.T) {
	node := []string{"PATH=/usr/local/bin:/usr/bin:/bin"}
	f := testFacts(node, map[string]pathFact{"/home/node/.cache": {}, "/home/node/.yarn": {}}, "node")
	p := decide(t, defaultCachePolicy(), dockerConfig{User: "node"}, f)
	if p.UID != 1000 || p.GID != 1000 || p.Home != "/home/node" {
		t.Fatalf("identity %+v", p)
	}
	if st := p.Tools["yarn"]; st.Path != "/home/node/.cache/yarn" {
		t.Fatalf("yarn %+v", st)
	}
	if st := p.Tools["yarnberry"]; st.Path != "/home/node/.yarn/berry" {
		t.Fatalf("berry %+v", st)
	}
	var shims []string
	for i, m := range p.Mounts {
		if m.Shim {
			shims = append(shims, m.Target)
			if i >= 2 {
				t.Fatal("shims must precede the binds below them")
			}
		}
	}
	if strings.Join(shims, " ") != "/home/node/.cache /home/node/.yarn" {
		t.Fatalf("shims %v", shims)
	}
	var yarn cacheStoreRef
	for _, s := range p.Stores {
		if s.Kind == "yarn" {
			yarn = s
		}
	}
	if yarn.Unit != "yarn.u1000" || !yarn.Exclusive {
		t.Fatalf("yarn store %+v", yarn)
	}
	// Root writes the yarn v1 root path and needs no shim.
	p = decide(t, defaultCachePolicy(), dockerConfig{}, f)
	if p.Tools["yarn"].Path != "/usr/local/share/.cache/yarn" || slices.ContainsFunc(p.Mounts, func(m cacheMount) bool { return m.Shim }) {
		t.Fatalf("root yarn %+v %+v", p.Tools["yarn"], p.Mounts)
	}
	// Unknown parents (not probed) never get a shim: it could hide image content.
	p = decide(t, defaultCachePolicy(), dockerConfig{User: "node"}, testFacts(node, nil, "node"))
	if slices.ContainsFunc(p.Mounts, func(m cacheMount) bool { return m.Shim }) {
		t.Fatal("shim for an unknown path")
	}
	// A missing HOME is shimmed at HOME itself.
	p = decide(t, defaultCachePolicy(), dockerConfig{User: "app"}, testFacts(node, map[string]pathFact{"/home/app": {}}, "node"))
	if !slices.ContainsFunc(p.Mounts, func(m cacheMount) bool { return m.Shim && m.Target == "/home/app" }) {
		t.Fatalf("missing home %+v", p.Mounts)
	}
	for _, tc := range []struct {
		user           string
		uid, gid       uint32
		home           string
		requestHome    string
		wantHomeInPlan string
	}{
		{"node:staff", 1000, 50, "/home/node", "", "/home/node"},
		{"1000", 1000, 1000, "/home/node", "", "/home/node"},
		{"1234", 1234, 0, "/", "", "/"},
		{"1234:7", 1234, 7, "/", "/work", "/work"},
		{"0", 0, 0, "/root", "", "/root"},
	} {
		spec := dockerConfig{User: tc.user}
		if tc.requestHome != "" {
			spec.Env = []string{"HOME=" + tc.requestHome}
		}
		p := decide(t, defaultCachePolicy(), spec, testFacts(nil, nil))
		if p.UID != tc.uid || p.GID != tc.gid || p.Home != tc.wantHomeInPlan {
			t.Fatalf("%s: %d:%d %s", tc.user, p.UID, p.GID, p.Home)
		}
	}
	// The image's USER applies when the request has none.
	if p := decide(t, defaultCachePolicy(), dockerConfig{}, func() imageFacts { f := testFacts(nil, nil); f.User = "node"; return f }()); p.UID != 1000 {
		t.Fatalf("image user %d", p.UID)
	}
	for _, bad := range []string{"nosuch", "node:nogroup"} {
		if _, err := decideCaches(defaultCachePolicy(), dockerConfig{User: bad}, testFacts(nil, nil)); err == nil {
			t.Fatalf("resolved %s", bad)
		}
	}
}

func TestDecideCachesCargo(t *testing.T) {
	f := testFacts([]string{"CARGO_HOME=/usr/local/cargo", "RUSTUP_HOME=/usr/local/rustup"}, map[string]pathFact{"/usr/local/cargo": dirFact}, "cargo")
	p := decide(t, defaultCachePolicy(), dockerConfig{}, f)
	var got []string
	for _, m := range p.Mounts {
		if m.Kind == "cargo" {
			got = append(got, m.Sub+"->"+m.Target+map[bool]string{true: " file", false: ""}[m.File])
		}
	}
	want := "registry->/usr/local/cargo/registry src/u0->/usr/local/cargo/registry/src git->/usr/local/cargo/git .package-cache->/usr/local/cargo/.package-cache file .package-cache-mutate->/usr/local/cargo/.package-cache-mutate file"
	if strings.Join(got, " ") != want {
		t.Fatalf("cargo binds\n got %s\nwant %s", strings.Join(got, " "), want)
	}
	if len(p.ToolEnv["cargo"]) != 0 {
		t.Fatal("cargo must not set variables")
	}
	// Extracted sources are per uid (crate tarballs keep modes such as 0640);
	// the store and its downloads stay shared. A missing registry/ under HOME
	// gets no shim: the shared registry bind is its mount point.
	nf := testFacts(nil, map[string]pathFact{"/home/node/.cargo": dirFact, "/home/node/.cargo/registry": {}}, "cargo")
	np := decide(t, defaultCachePolicy(), dockerConfig{User: "node"}, nf)
	var subs []string
	for _, m := range np.Mounts {
		if m.Shim {
			t.Fatalf("shim %s for a nested cargo bind", m.Target)
		}
		if m.Kind == "cargo" && !m.File {
			subs = append(subs, m.Unit+":"+m.Sub)
		}
	}
	if strings.Join(subs, " ") != "cargo:registry cargo:src/u1000 cargo:git" {
		t.Fatalf("uid 1000 cargo binds %v", subs)
	}
	// A baked registry is left alone.
	f.Paths["/usr/local/cargo/registry/cache"] = pathFact{Exists: true, Dir: true, NonEmpty: true}
	if p := decide(t, defaultCachePolicy(), dockerConfig{}, f); reason(p, "cargo") != skipPrewarmed {
		t.Fatal(reason(p, "cargo"))
	}
}

func TestDecideJobCaches(t *testing.T) {
	f := testFacts(append([]string{"GOFLAGS=-mod=mod"}, golangEnv...), nil, "node")
	p := decideJobCaches(defaultCachePolicy(), "repo-main", f)
	if p.Scope != "repo-main" || !p.attached() || len(p.Mounts) != 1 || p.Mounts[0].Target != "/micropod/cache" {
		t.Fatalf("job plan %+v", p)
	}
	if v, _ := envOf(p, "GOFLAGS"); v != "-mod=mod -trimpath" {
		t.Fatalf("job GOFLAGS %q", v)
	}
	for _, k := range []string{"yarn", "yarnberry", "cargo"} {
		if reason(p, k) != skipNotSelected {
			t.Fatalf("job attached path-mode %s", k)
		}
	}
	// Without facts a job still gets its caches, as uid 0.
	p = decideJobCaches(defaultCachePolicy(), "repo-main", imageFacts{})
	if v, _ := envOf(p, "PIP_CACHE_DIR"); v != "/micropod/cache/pip/u0" {
		t.Fatalf("job without facts %+v", p)
	}
	// A scheduler scope is not subject to the Docker allow-list or mode.
	ci := defaultCachePolicy()
	ci.Mode, ci.DefaultScope, ci.AllowedScopes = "off", "", []string{"none"}
	if p := decideJobCaches(ci, "repo-main", f); !p.attached() {
		t.Fatalf("job plan under CI policy %+v", p)
	}
}

func TestCachePolicyFile(t *testing.T) {
	p, err := parseCachePolicy([]byte(`{"version":1,"mode":"auto","defaultScope":"","allowedScopes":["ci-*"],"tools":["go","npm","bogus"],"goTrimpath":false,"pnpmLegacyEnv":false,"buildkit":{"registerBuildx":true},"future":1}`))
	if err != nil {
		t.Fatal(err)
	}
	if p.DefaultScope != "" || strings.Join(p.Tools, ",") != "gomod,gobuild,npm" || p.GoTrimpath || p.PnpmLegacyEnv || !p.allows("ci-7") || p.allows("other") {
		t.Fatalf("parsed %+v", p)
	}
	if p, err := parseCachePolicy([]byte(`{}`)); err != nil || p.Mode != "auto" || p.DefaultScope != "default" || len(p.Tools) != len(cacheTable) || !p.GoTrimpath || !p.PnpmLegacyEnv || !p.allows("anything") {
		t.Fatalf("defaults %+v %v", p, err)
	}
	for _, bad := range []string{`{"mode":"sometimes"}`, `{"defaultScope":"Nope!"}`, `not json`} {
		if p, err := parseCachePolicy([]byte(bad)); err == nil || p.Mode != "auto" {
			t.Fatalf("%s accepted: %+v", bad, p)
		}
	}
	dir := t.TempDir()
	file := filepath.Join(dir, "cache-policy.json")
	l := &policyLoader{path: file}
	if got := l.get(); got.Mode != "auto" || got.DefaultScope != "default" {
		t.Fatalf("missing file %+v", got)
	}
	write := func(s string) {
		tmp := file + ".tmp"
		if err := os.WriteFile(tmp, []byte(s), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(tmp, file); err != nil {
			t.Fatal(err)
		}
	}
	write(`{"mode":"off"}`)
	if got := l.get(); got.Mode != "auto" {
		t.Fatal("re-read before the 2 s interval")
	}
	l.checked = l.checked.Add(-3 * time.Second)
	if got := l.get(); got.Mode != "off" {
		t.Fatalf("renamed policy not seen: %+v", got)
	}
	write(`{"mode":"auto","tools":["pip"]}`)
	l.checked = time.Time{}
	if got := l.get(); got.Mode != "auto" || strings.Join(got.Tools, ",") != "pip" {
		t.Fatalf("second policy %+v", got)
	}
	write(`{broken`)
	l.checked = time.Time{}
	if got := l.get(); got.Mode != "auto" || len(got.Tools) != len(cacheTable) {
		t.Fatalf("invalid policy did not fall back to defaults: %+v", got)
	}
	if defaultCachePolicy().digest() == p.digest() {
		t.Fatal("policy digest ignores content")
	}
}

func TestCacheHelpers(t *testing.T) {
	for flags, want := range map[string]bool{"": false, "-mod=mod": false, "-trimpath": true, "--trimpath": true, "-trimpath=false": true, "-mod=mod -trimpath=true": true, "-trimpathx": false} {
		if hasTrimpath(flags) != want {
			t.Errorf("hasTrimpath(%q) = %v", flags, !want)
		}
	}
	for _, tc := range [][2]string{{"/a", "/a"}, {"/a", "/a/b"}, {"/a/b", "/a"}, {"/", "/x"}} {
		if !pathsOverlap(tc[0], tc[1]) {
			t.Errorf("%s %s should overlap", tc[0], tc[1])
		}
	}
	for _, tc := range [][2]string{{"/a", "/ab"}, {"/root/.cache/pip", "/root/.cache/go-build"}} {
		if pathsOverlap(tc[0], tc[1]) {
			t.Errorf("%s %s should not overlap", tc[0], tc[1])
		}
	}
	if got := mergeEnv([]string{"A=1", "GOFLAGS=-v", "B=2"}, []string{"GOFLAGS=-v -trimpath", "C=3"}); strings.Join(got, " ") != "A=1 B=2 GOFLAGS=-v -trimpath C=3" {
		t.Fatal(got)
	}
	if v, ok := envLookup([]string{"npm_config_cache=/a", "NPM_CONFIG_CACHE=/b"}, "npm_config_cache", true); !ok || v != "/b" {
		t.Fatal(v, ok)
	}
	pw := parsePasswd([]byte("root:x:0:0:root:/root:/bin/sh\n# comment\nbad line\nnode:x:1000:1000::/home/node:/bin/sh\n"))
	if len(pw) != 2 || pw[1] != (passwdEntry{"node", 1000, 1000, "/home/node"}) {
		t.Fatalf("passwd %+v", pw)
	}
	if gr := parseGroup([]byte("root:x:0:\nnode:x:1000:\n")); len(gr) != 2 || gr[1].GID != 1000 {
		t.Fatalf("group %+v", gr)
	}
	cands := factCandidates(golangEnv, pw, "")
	for _, want := range []string{"/micropod", "/go/pkg/mod/cache/download", "/root/.cache/go-build/00", "/usr/local/share/.cache/yarn/v6",
		"/home/node/.cache/yarn", "/home/node/.cache", "/home/node/.yarn/berry/cache", "/root/.cargo/registry/cache", "/root/.cache/pip/http-v2", "/home/node"} {
		if !slices.Contains(cands, want) {
			t.Errorf("probe would not stat %s", want)
		}
	}
	for _, tc := range []struct{ user, err string }{{"", ""}, {"node", ""}, {"1000:1000", ""}, {"a b", "invalid"}, {"x:", "invalid"}, {":1", "invalid"}} {
		err := validateDockerUser(tc.user)
		if (err == nil) != (tc.err == "") {
			t.Errorf("validateDockerUser(%q) = %v", tc.user, err)
		}
	}
	facts := testFacts(nil, nil)
	if uid, gid, err := dockerUser("node", &facts); err != nil || uid.Value != 1000 || gid.Value != 1000 {
		t.Fatalf("dockerUser(node) %v %v %v", uid, gid, err)
	}
	if _, _, err := dockerUser("node", nil); err == nil {
		t.Fatal("resolved a name without facts")
	}
	if uid, gid, err := dockerUser("5:6", nil); err != nil || uid.Value != 5 || gid.Value != 6 {
		t.Fatal(uid, gid, err)
	}
	if r, err := runAsFor("node", &imageFacts{}); err != nil || r.Username != "node" || r.UID != nil {
		t.Fatalf("name without facts %+v %v", r, err)
	}
	if _, err := runAsFor("1:staff", &imageFacts{}); err == nil {
		t.Fatal("group name without facts")
	}
	if r, err := runAsFor("node:staff", &facts); err != nil || *r.UID != 1000 || *r.GID != 50 {
		t.Fatalf("node:staff %+v %v", r, err)
	}
	if r, _ := runAsFor("7:8", &facts); r != nil {
		t.Fatal("numeric user needs no record")
	}
	// The record survives a JSON round trip (dockerRecord persistence).
	plan := decide(t, defaultCachePolicy(), dockerConfig{User: "node"}, testFacts(nil, map[string]pathFact{"/home/node/.cache": {}}, "node"))
	b, err := json.Marshal(dockerRecord{ID: "x", Cache: &plan, CacheSkipped: map[string]string{"yarn": skipBusyExclusive}})
	if err != nil {
		t.Fatal(err)
	}
	var back dockerRecord
	if err := json.Unmarshal(b, &back); err != nil || back.Cache == nil || len(back.Cache.Mounts) != len(plan.Mounts) || back.CacheSkipped["yarn"] != skipBusyExclusive {
		t.Fatalf("round trip %+v %v", back, err)
	}
	c := &dockerContainer{dockerRecord: back}
	c.Config.Env = []string{"A=1"}
	v := c.inspect()
	mc := v["MicropodCache"].(map[string]any)
	if mc["scope"] != "default" || mc["tools"].(map[string]cacheToolState)["yarn"].Reason != skipBusyExclusive || mc["tools"].(map[string]cacheToolState)["gomod"].Mode != "env" {
		t.Fatalf("inspect %+v", mc)
	}
	if env := v["Config"].(dockerConfig).Env; env[0] != "A=1" || !slices.Contains(env, "GOMODCACHE=/micropod/cache/gomod") {
		t.Fatalf("inspect env %v", env)
	}
	if mounts := v["Mounts"].([]map[string]any); !slices.ContainsFunc(mounts, func(m map[string]any) bool {
		return m["Destination"] == "/micropod/cache" && m["Name"] == "micropod-cache-default"
	}) {
		t.Fatalf("inspect mounts %v", mounts)
	}
}

// ---- root-only: real stores, ACL inheritance across uids ----

func needRoot(t *testing.T) {
	t.Helper()
	if os.Geteuid() != 0 {
		t.Skip("needs root (default-ACL xattrs, flock pins and a setresuid child)")
	}
}

// useCacheRoot points cacheRoot at a fresh world-traversable directory; it
// honours TMPDIR, so the test can run on a real ext4 volume.
func useCacheRoot(t *testing.T) string {
	t.Helper()
	base, err := os.MkdirTemp("", "mpcache")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(base, 0755); err != nil {
		t.Fatal(err)
	}
	old := cacheRoot
	cacheRoot = filepath.Join(base, "caches")
	t.Cleanup(func() { cacheRoot = old; os.RemoveAll(base) })
	return base
}

func modeOf(t *testing.T, p string) (uint32, uint32) {
	t.Helper()
	var st unix.Stat_t
	if err := unix.Lstat(p, &st); err != nil {
		t.Fatal(err)
	}
	return st.Mode & 07777, st.Uid
}

func defaultACL(p string) []byte {
	buf := make([]byte, 128)
	n, err := unix.Getxattr(p, aclDefaultXattr, buf)
	if err != nil {
		return nil
	}
	return buf[:n]
}

// The child half of TestCacheStoreACLAcrossUIDs runs as another uid with
// umask 077 and does what Go's cache does (MkdirAll 0777, OpenFile 0666).
// "fill" is the first user of a store; "use" also appends to, renames over
// and unlinks the other uid's entries.
func TestCacheACLChild(t *testing.T) {
	dir := os.Getenv("MP_CACHE_ACL_CHILD")
	if dir == "" {
		t.Skip("helper process")
	}
	syscall.Umask(077)
	tag, mode := os.Getenv("MP_CACHE_ACL_TAG"), os.Getenv("MP_CACHE_ACL_MODE")
	shared := filepath.Join(dir, "shared")
	steps := []func() error{
		func() error { return os.MkdirAll(filepath.Join(dir, tag, "lvl2"), 0777) },
		func() error { return os.WriteFile(filepath.Join(dir, tag, "lvl2", "entry"), []byte(tag), 0666) },
	}
	if mode == "fill" {
		steps = append(steps,
			func() error { return os.MkdirAll(shared, 0777) },
			func() error { return os.WriteFile(filepath.Join(shared, "entry"), []byte(tag), 0666) },
			func() error { return os.WriteFile(filepath.Join(shared, "victim"), []byte(tag), 0666) })
	} else {
		steps = append(steps,
			func() error { return os.Mkdir(filepath.Join(shared, tag), 0777) },
			func() error {
				f, err := os.OpenFile(filepath.Join(shared, "entry"), os.O_WRONLY|os.O_APPEND, 0)
				if err == nil {
					_, err = f.WriteString(tag)
					err = errors.Join(err, f.Close())
				}
				return err
			},
			func() error { return os.WriteFile(filepath.Join(shared, "tmp-"+tag), []byte(tag), 0666) },
			func() error { return os.Rename(filepath.Join(shared, "tmp-"+tag), filepath.Join(shared, "entry")) },
			func() error { return os.Remove(filepath.Join(shared, "victim")) })
	}
	for i, step := range steps {
		if err := step(); err != nil {
			t.Fatalf("%s step %d as uid %d: %v", mode, i, os.Getuid(), err)
		}
	}
}

func runACLChild(t *testing.T, dir, mode string, uid uint32) (string, error) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	// The go test binary may live in an owner-only directory; copy it
	// somewhere the other uid can execute it.
	bin := filepath.Join(filepath.Dir(cacheRoot), "child.test")
	if _, err := os.Stat(bin); err != nil {
		src, err := os.Open(exe)
		if err != nil {
			t.Fatal(err)
		}
		dst, err := os.OpenFile(bin, os.O_CREATE|os.O_WRONLY, 0755)
		if err != nil {
			t.Fatal(err)
		}
		_, err = io.Copy(dst, src)
		src.Close()
		if err = errors.Join(err, dst.Close()); err != nil {
			t.Fatal(err)
		}
	}
	tag := "u" + strconv.FormatUint(uint64(uid), 10)
	cmd := exec.Command(bin, "-test.run=^TestCacheACLChild$", "-test.count=1", "-test.v")
	cmd.Env = append(os.Environ(), "MP_CACHE_ACL_CHILD="+dir, "MP_CACHE_ACL_TAG="+tag, "MP_CACHE_ACL_MODE="+mode)
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uid, Gid: uid}}
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err = cmd.Run()
	return out.String(), err
}

// seedShared does a "fill" as root under umask 077, in-process.
func seedShared(t *testing.T, dir string) {
	t.Helper()
	old := syscall.Umask(077)
	defer syscall.Umask(old)
	if err := os.MkdirAll(filepath.Join(dir, "shared"), 0777); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"entry", "victim"} {
		if err := os.WriteFile(filepath.Join(dir, "shared", name), []byte("root"), 0666); err != nil {
			t.Fatal(err)
		}
	}
}

// assertShareable walks a store: every directory below it is 0777 with the
// default ACL and every file 0666, whoever created it under whatever umask.
func assertShareable(t *testing.T, store string) (dirs, files int) {
	t.Helper()
	err := filepath.Walk(store, func(p string, info os.FileInfo, err error) error {
		if err != nil || p == store {
			return err
		}
		mode, _ := modeOf(t, p)
		if info.IsDir() {
			dirs++
			if mode != 0777 || !bytes.Equal(defaultACL(p), cacheACL) {
				t.Errorf("dir %s mode %o acl %x", p, mode, defaultACL(p))
			}
		} else {
			files++
			if mode != 0666 {
				t.Errorf("file %s mode %o", p, mode)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return dirs, files
}

func TestCacheStoreACLAcrossUIDs(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	store, err := ensureStore("qual", "gobuild", nil)
	if err != nil {
		t.Fatal(err)
	}
	if store != filepath.Join(cacheRoot, "scopes", "qual", "gobuild") {
		t.Fatal(store)
	}
	for p, want := range map[string]uint32{cacheRoot: 0711, filepath.Join(cacheRoot, "scopes"): 0711, filepath.Join(cacheRoot, "scopes", "qual"): 0755, store: 0777,
		filepath.Join(cacheRoot, ".meta"): 0700, filepath.Join(cacheRoot, ".meta", "qual"): 0700, filepath.Join(cacheRoot, ".trash"): 0700} {
		if mode, owner := modeOf(t, p); mode != want || owner != 0 {
			t.Fatalf("%s mode %o owner %d, want %o root", p, mode, owner, want)
		}
	}
	if !bytes.Equal(defaultACL(store), cacheACL) {
		t.Fatalf("store default ACL %x", defaultACL(store))
	}
	if b, err := os.ReadFile(filepath.Join(cacheRoot, ".meta", "layout.json")); err != nil || strings.TrimSpace(string(b)) != `{"version":1}` {
		t.Fatalf("layout %q %v", b, err)
	}
	// Order A: root fills, then uid 1000 and a third uid use it.
	seedShared(t, store)
	for _, uid := range []uint32{1000, 2000} {
		if out, err := runACLChild(t, store, "use", uid); err != nil {
			t.Fatalf("uid %d in a root-filled store: %v\n%s", uid, err, out)
		}
		seedShared(t, store) // a fresh root-owned victim for the next uid
	}
	if _, owner := modeOf(t, filepath.Join(store, "u1000", "lvl2")); owner != 1000 {
		t.Fatalf("lvl2 owner %d", owner)
	}
	if dirs, files := assertShareable(t, store); dirs != 7 || files != 4 {
		t.Fatalf("walked %d dirs %d files", dirs, files)
	}
	// Order B on a fresh store: uid 1000 fills, then uid 2000 uses it.
	store2, err := ensureStore("qual", "gomod", nil)
	if err != nil {
		t.Fatal(err)
	}
	if out, err := runACLChild(t, store2, "fill", 1000); err != nil {
		t.Fatalf("uid 1000 fill: %v\n%s", err, out)
	}
	if out, err := runACLChild(t, store2, "use", 2000); err != nil {
		t.Fatalf("uid 2000 after uid 1000: %v\n%s", err, out)
	}
	assertShareable(t, store2)
	// Negative control: the previous layout (1777, no ACL) under umask 077
	// gives owner-only entries the other uid cannot write.
	plain := filepath.Join(filepath.Dir(cacheRoot), "plain")
	if err := os.Mkdir(plain, 0777); err != nil {
		t.Fatal(err)
	}
	os.Chmod(plain, 0777|os.ModeSticky)
	seedShared(t, plain)
	if mode, _ := modeOf(t, filepath.Join(plain, "shared")); mode != 0700 {
		t.Fatalf("control dir %o", mode)
	}
	if out, err := runACLChild(t, plain, "use", 1000); err == nil || !strings.Contains(out, "permission denied") {
		t.Fatalf("control without ACL did not fail: %v\n%s", err, out)
	}
}

func TestEnsureStoreRepairsDrift(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	store, err := ensureStore("qual", "npm", nil)
	if err != nil {
		t.Fatal(err)
	}
	// The old layout's sticky bit, a lost ACL and a foreign owner are all repaired.
	os.Chmod(store, 0777|os.ModeSticky)
	unix.Removexattr(store, aclDefaultXattr)
	os.Chown(store, 1000, 1000)
	if _, err := ensureStore("qual", "npm", nil); err != nil {
		t.Fatal(err)
	}
	if mode, owner := modeOf(t, store); mode != 0777 || owner != 0 || !bytes.Equal(defaultACL(store), cacheACL) {
		t.Fatalf("not repaired: %o %d %x", mode, owner, defaultACL(store))
	}
	// A container replaced its store with a symlink: it is moved to .trash,
	// never followed, and a fresh store takes its place.
	victim := filepath.Join(filepath.Dir(cacheRoot), "victim")
	os.Mkdir(victim, 0700)
	os.RemoveAll(store)
	if err := os.Symlink(victim, store); err != nil {
		t.Fatal(err)
	}
	if _, err := ensureStore("qual", "npm", nil); err != nil {
		t.Fatal(err)
	}
	if mode, _ := modeOf(t, victim); mode != 0700 || defaultACL(victim) != nil {
		t.Fatal("followed a planted symlink")
	}
	if st, err := os.Lstat(store); err != nil || !st.IsDir() {
		t.Fatal("store not recreated", err)
	}
	trash, _ := os.ReadDir(filepath.Join(cacheRoot, ".trash"))
	if len(trash) != 1 || !strings.HasPrefix(trash[0].Name(), "npm.") {
		t.Fatalf("trash %v", trash)
	}
	// Partitioned kinds get the same treatment on both levels.
	uid := uint32(1000)
	p, err := ensureStore("qual", "pip", &uid)
	if err != nil || p != filepath.Join(cacheRoot, "scopes", "qual", "pip", "u1000") {
		t.Fatal(p, err)
	}
	for _, d := range []string{p, filepath.Dir(p)} {
		if mode, owner := modeOf(t, d); mode != 0777 || owner != 0 || !bytes.Equal(defaultACL(d), cacheACL) {
			t.Fatalf("%s %o %d", d, mode, owner)
		}
	}
	// pnpm: an empty 0666 index.db exists, and a 0664 one is widened.
	pn, err := ensureStore("qual", "pnpm", nil)
	if err != nil {
		t.Fatal(err)
	}
	if mode, _ := modeOf(t, filepath.Join(pn, "v11", "index.db")); mode != 0666 {
		t.Fatalf("index.db %o", mode)
	}
	os.Mkdir(filepath.Join(pn, "v12"), 0777)
	os.WriteFile(filepath.Join(pn, "v12", "index.db-wal"), nil, 0644)
	os.Chmod(filepath.Join(pn, "v12", "index.db-wal"), 0664)
	os.Chmod(filepath.Join(pn, "v11", "index.db"), 0664)
	if _, err := ensureStore("qual", "pnpm", nil); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"v11/index.db", "v12/index.db-wal"} {
		if mode, _ := modeOf(t, filepath.Join(pn, f)); mode != 0666 {
			t.Fatalf("%s %o", f, mode)
		}
	}
	// cargo: shared registry/git and the two lock files cargo flocks.
	cg, err := ensureStore("qual", "cargo", nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"registry", "registry/src", "git", "src"} {
		if mode, _ := modeOf(t, filepath.Join(cg, f)); mode != 0777 || !bytes.Equal(defaultACL(filepath.Join(cg, f)), cacheACL) {
			t.Fatalf("%s %o", f, mode)
		}
	}
	for _, f := range []string{".package-cache", ".package-cache-mutate"} {
		st, err := os.Lstat(filepath.Join(cg, f))
		if err != nil || !st.Mode().IsRegular() || st.Mode().Perm() != 0666 {
			t.Fatalf("%s %v %v", f, st, err)
		}
	}
}

func TestOpenCacheMountsReplaysPlan(t *testing.T) {
	needRoot(t)
	base := useCacheRoot(t)
	node := []string{"PATH=/usr/local/bin:/usr/bin:/bin", "CARGO_HOME=/usr/local/cargo"}
	f := testFacts(node, map[string]pathFact{"/home/node/.cache": {}, "/home/node/.yarn": {}, "/usr/local/cargo": dirFact}, "node")
	plan := decide(t, defaultCachePolicy(), dockerConfig{User: "node"}, f)
	shimRoot := filepath.Join(base, "container", "shim")
	a := openCacheMounts(&plan, shimRoot)
	defer closeMounts(a.files)
	if len(a.skipped) != 0 {
		t.Fatalf("skipped %v", a.skipped)
	}
	targets := map[string]string{}
	for _, m := range a.mounts {
		src, err := os.Readlink(m.HostPath)
		if err != nil {
			t.Fatalf("%s: %v", m.HostPath, err)
		}
		targets[m.ContainerPath] = src
	}
	for target, src := range map[string]string{
		"/micropod/cache":                        filepath.Join(cacheRoot, "scopes/default"),
		"/home/node/.cache/yarn":                 filepath.Join(cacheRoot, "scopes/default/yarn/u1000"),
		"/home/node/.yarn/berry":                 filepath.Join(cacheRoot, "scopes/default/yarnberry"),
		"/usr/local/cargo/registry":              filepath.Join(cacheRoot, "scopes/default/cargo/registry"),
		"/usr/local/cargo/registry/src":          filepath.Join(cacheRoot, "scopes/default/cargo/src/u1000"),
		"/usr/local/cargo/.package-cache":        filepath.Join(cacheRoot, "scopes/default/cargo/.package-cache"),
		"/usr/local/cargo/.package-cache-mutate": filepath.Join(cacheRoot, "scopes/default/cargo/.package-cache-mutate"),
		"/home/node/.cache":                      filepath.Join(shimRoot, "0"),
		"/home/node/.yarn":                       filepath.Join(shimRoot, "1"),
	} {
		if targets[target] != src {
			t.Errorf("%s bound from %q, want %q", target, targets[target], src)
		}
	}
	// The scope is bound read-only; only the env-mode units this start locked
	// and marked are writable, each through its own bind over it.
	for _, m := range a.mounts {
		if want := m.ContainerPath == "/micropod/cache"; m.Readonly != want {
			t.Errorf("%s readonly=%v", m.ContainerPath, m.Readonly)
		}
	}
	for _, sub := range []string{"gomod", "gobuild", "npm", "pnpm", "pip/u1000", "uv", "corepack"} {
		if got, want := targets["/micropod/cache/"+sub], filepath.Join(cacheRoot, "scopes/default", sub); got != want {
			t.Errorf("/micropod/cache/%s bound from %q, want %q", sub, got, want)
		}
	}
	for _, sub := range []string{"yarn/u1000", "yarnberry", "cargo", "pip", "pip/u0"} {
		if _, bound := targets["/micropod/cache/"+sub]; bound {
			t.Errorf("/micropod/cache/%s is writable although no env-mode tool of this start marked it", sub)
		}
	}
	if _, owner := modeOf(t, filepath.Join(shimRoot, "0")); owner != 1000 {
		t.Fatalf("shim owner %d", owner)
	}
	if v, _ := envLookup(a.env, "PIP_CACHE_DIR", false); v != "/micropod/cache/pip/u1000" {
		t.Fatalf("env %v", a.env)
	}
	for _, u := range []string{"gomod", "yarn.u1000", "cargo"} {
		if _, err := os.Stat(filepath.Join(cacheRoot, ".meta", "default", u+".used")); err != nil {
			t.Fatalf("no last-used stamp for %s: %v", u, err)
		}
	}
	// A second concurrent start: yarn v1 is exclusive, everything else shared.
	b := openCacheMounts(&plan, filepath.Join(base, "container2", "shim"))
	defer closeMounts(b.files)
	if len(b.skipped) != 1 || b.skipped["yarn"] != skipBusyExclusive {
		t.Fatalf("second start skipped %v", b.skipped)
	}
	for _, m := range b.mounts {
		if m.ContainerPath == "/home/node/.cache/yarn" {
			t.Fatal("second start bound the exclusive yarn store")
		}
	}
	if !slices.ContainsFunc(b.mounts, func(m *cri.Mount) bool { return m.ContainerPath == "/micropod/cache" }) {
		t.Fatal("second start lost the shared scope bind")
	}
	// The janitor's eviction lock cannot be taken while containers pin a unit.
	if l, err := unitLock("default", "gomod", true); err == nil {
		l.Close()
		t.Fatal("exclusive lock taken while pinned")
	}
	closeMounts(a.files)
	a.files = nil
	c := openCacheMounts(&plan, filepath.Join(base, "container3", "shim"))
	defer closeMounts(c.files)
	if _, busy := c.skipped["yarn"]; busy {
		t.Fatal("yarn lease not released when the first container exited")
	}
}

func TestCacheDebugHook(t *testing.T) {
	g := testFacts(golangEnv, nil)
	p := decide(t, defaultCachePolicy(), dockerConfig{User: "1000", Labels: map[string]string{"io.micropod.cache.scope": "qual-pip", "io.micropod.cache.debug-shared": "pip"}}, g)
	if v, _ := envOf(p, "PIP_CACHE_DIR"); v != "/micropod/cache/pip" {
		t.Fatalf("forced shared pip %q", v)
	}
	for _, spec := range []dockerConfig{
		{Labels: map[string]string{"io.micropod.cache.debug-shared": "pip"}},
		{Labels: map[string]string{"io.micropod.cache.scope": "qual-x", "io.micropod.cache.debug-shared": "nope"}},
	} {
		if _, err := decideCaches(defaultCachePolicy(), spec, g); err == nil {
			t.Fatalf("accepted %+v", spec.Labels)
		}
	}
	s := &dockerEngine{}
	w := httptest.NewRecorder()
	if handled, err := cacheRoutes(s, w, httptest.NewRequest("GET", "/micropod/caches", nil), "GET", "micropod/caches"); !handled || err != nil || !strings.Contains(w.Body.String(), `"policyDigest"`) {
		t.Fatalf("GET caches %v %v %s", handled, err, w.Body.String())
	}
	w = httptest.NewRecorder()
	if handled, err := cacheRoutes(s, w, httptest.NewRequest("POST", "/micropod/caches/debug", strings.NewReader(`{"scope":"qual-x","kind":"bogus"}`)), "POST", "micropod/caches/debug"); !handled || err == nil {
		t.Fatal("accepted an unknown kind", handled, err)
	}
	if handled, _ := cacheRoutes(s, httptest.NewRecorder(), httptest.NewRequest("GET", "/containers/json", nil), "GET", "containers/json"); handled {
		t.Fatal("claimed an unrelated route")
	}
	if !slices.ContainsFunc(extraRoutes, func(f func(*dockerEngine, http.ResponseWriter, *http.Request, string, string) (bool, error)) bool {
		return f != nil
	}) {
		t.Fatal("cache routes not registered")
	}
}

func TestCacheDebugStripACL(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	if _, err := setStoreACL("default", "gobuild", nil, false); err == nil {
		t.Fatal("stripped a non-qualification scope")
	}
	store, err := setStoreACL("qual-neg", "gobuild", nil, false)
	if err != nil {
		t.Fatal(err)
	}
	check := func(wantMode uint32, wantACL bool) {
		t.Helper()
		if mode, _ := modeOf(t, store); mode != wantMode || (defaultACL(store) != nil) != wantACL {
			t.Fatalf("mode %o acl %x", mode, defaultACL(store))
		}
	}
	check(01777, false)
	// Starts keep the stripped layout while the marker exists.
	if _, err := ensureStore("qual-neg", "gobuild", nil); err != nil {
		t.Fatal(err)
	}
	check(01777, false)
	if _, err := setStoreACL("qual-neg", "gobuild", nil, true); err != nil {
		t.Fatal(err)
	}
	check(0777, true)
}
