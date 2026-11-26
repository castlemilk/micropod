package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Every container started through the Docker socket gets the machine's tool
// caches unless something below says otherwise. The decision is made once at
// create from the request, the image facts and the machine policy, persisted
// with the container and replayed on every start.

const cacheMountRoot = "/micropod/cache"
const cachePolicyFile = "/run/micropod/host-config/cache-policy.json"

// Skip reasons, as shown in docker inspect MicropodCache.tools.<tool>.reason
// and counted in the cache_skip metric.
const (
	skipUserEnv       = "user-env"
	skipDisabledImage = "disabled-by-image"
	skipUserMount     = "user-mount"
	skipPrewarmed     = "image-prewarmed"
	skipNotInstalled  = "not-installed"
	skipReserved      = "reserved-path"
	skipProbeFailed   = "probe-failed"
	skipNotSelected   = "not-selected"
	skipBusyExclusive = "busy-exclusive"
	skipStoreFailed   = "store-failed"
)

// Plan-level reasons for attaching nothing.
const (
	planPolicyOff = "policy-off"
	planLabelOff  = "label-off"
	planEnvOff    = "env-off"
	planImageOff  = "image-off"
	planRootless  = "rootless"
	planNoScope   = "no-scope"
)

type cacheToolState struct {
	Mode   string `json:"mode"` // env, path or skipped
	Path   string `json:"path,omitempty"`
	Reason string `json:"reason,omitempty"`
}

// cacheStoreRef names one store a plan uses: it is created/verified, locked and
// stamped on every start.
type cacheStoreRef struct {
	Kind      string  `json:"kind"`
	Unit      string  `json:"unit"`
	UID       *uint32 `json:"uid,omitempty"`
	Exclusive bool    `json:"exclusive,omitempty"`
}

// cacheMount is one bind of a plan. Kind "" with Shim false is the scope bind
// at /micropod/cache; Sub is relative to the store directory of Unit.
type cacheMount struct {
	Kind   string `json:"kind,omitempty"`
	Unit   string `json:"unit,omitempty"`
	Sub    string `json:"sub,omitempty"`
	Target string `json:"target"`
	File   bool   `json:"file,omitempty"`
	Shim   bool   `json:"shim,omitempty"`
}

type cachePlan struct {
	Scope        string                    `json:"scope"`
	UID          uint32                    `json:"uid"`
	GID          uint32                    `json:"gid"`
	Home         string                    `json:"home,omitempty"`
	Env          []string                  `json:"env,omitempty"`
	ToolEnv      map[string][]string       `json:"toolEnv,omitempty"`
	Stores       []cacheStoreRef           `json:"stores,omitempty"`
	Mounts       []cacheMount              `json:"mounts,omitempty"`
	Tools        map[string]cacheToolState `json:"tools"`
	PolicyDigest string                    `json:"policyDigest,omitempty"`
	Reason       string                    `json:"reason,omitempty"`
}

// attached reports whether the plan binds anything at all.
func (p *cachePlan) attached() bool { return p != nil && len(p.Mounts) > 0 }

// env returns the plan's variables with the tools skipped at start removed.
func (p *cachePlan) env(skipped map[string]string) []string {
	if p == nil {
		return nil
	}
	if len(skipped) == 0 {
		return p.Env
	}
	var out []string
	for _, t := range cacheTable {
		if _, gone := skipped[t.Kind]; !gone {
			out = append(out, p.ToolEnv[t.Kind]...)
		}
	}
	return out
}

// toolCtx is what a table row's path functions see: the effective environment
// (image then request), HOME and uid of the process the container starts.
type toolCtx struct {
	env  []string
	home string
	uid  uint32
}

func (x toolCtx) get(key string) string { v, _ := envLookup(x.env, key, false); return v }
func (x toolCtx) cacheHome() string {
	if v := x.get("XDG_CACHE_HOME"); path.IsAbs(v) {
		return v
	}
	return path.Join(x.home, ".cache")
}
func (x toolCtx) dataHome() string {
	if v := x.get("XDG_DATA_HOME"); path.IsAbs(v) {
		return v
	}
	return path.Join(x.home, ".local/share")
}

// cacheMarker is a pre-warm check: the image already has content at Path.
type cacheMarker struct {
	Path     string
	NonEmpty bool // otherwise existence is enough
}

type cacheTarget struct {
	Sub    string // below the store, "" for the store itself
	Target string
	File   bool
}

type cacheTool struct {
	Kind, Group string
	Mode        string   // "env": a variable points into /micropod/cache; "path": bind at a fixed path
	EnvKey      string   // env mode: the variable the engine sets
	AltKeys     []string // other variables that select the same location
	Fold        bool     // npm-style keys are compared case-insensitively
	DisableKeys []string // truthy -> the tool's cache is disabled
	OffValues   map[string]string
	Partition   bool // per-uid store <kind>/u<uid>
	Exclusive   bool // one running container per store (LOCK_EX|LOCK_NB at start)
	Extra       func(pol cachePolicy, value string) [][2]string
	DefaultPath func(x toolCtx) string
	Targets     func(x toolCtx) []cacheTarget // path mode
	Markers     func(p string) []cacheMarker
	Presence    func(x toolCtx, f *imageFacts) bool // path mode
}

// userKeys are the variables whose presence in the request means the user
// chose the location (or disabled the cache) themselves.
func (t *cacheTool) userKeys() []string {
	keys := append([]string(nil), t.AltKeys...)
	if t.EnvKey != "" {
		keys = append([]string{t.EnvKey}, keys...)
	}
	keys = append(keys, t.DisableKeys...)
	for k := range t.OffValues {
		if !slices.Contains(keys, k) {
			keys = append(keys, k)
		}
	}
	return keys
}

func (t *cacheTool) disabledBy(env []string) bool {
	for _, k := range t.DisableKeys {
		if v, ok := envLookup(env, k, t.Fold); ok && truthy(v) {
			return true
		}
	}
	for k, off := range t.OffValues {
		if v, ok := envLookup(env, k, t.Fold); ok && strings.EqualFold(strings.TrimSpace(v), off) {
			return true
		}
	}
	return false
}

// imagePath returns the location the image itself configured for an env-mode
// tool; the engine then binds the store there and leaves the variable alone.
func (t *cacheTool) imagePath(img []string) (string, bool) {
	for _, k := range append([]string{t.EnvKey}, t.AltKeys...) {
		if k == "" {
			continue
		}
		if v, ok := envLookup(img, k, t.Fold); ok {
			if off, isOff := t.OffValues[k]; isOff && strings.EqualFold(v, off) {
				continue
			}
			return v, true
		}
	}
	return "", false
}

func firstEnv(x toolCtx, fold bool, keys ...string) string {
	for _, k := range keys {
		if v, ok := envLookup(x.env, k, fold); ok && path.IsAbs(v) {
			return path.Clean(v)
		}
	}
	return ""
}

func nodeOnPath(_ toolCtx, f *imageFacts) bool {
	return f.Binaries["node"] || f.Binaries["yarn"] || f.Binaries["corepack"]
}

func cargoHome(x toolCtx) string {
	if v := firstEnv(x, false, "CARGO_HOME"); v != "" {
		return v
	}
	return path.Join(x.home, ".cargo")
}

// cargoSrcSub is the per-uid directory, below the shared cargo store, bound
// at $CARGO_HOME/registry/src.
func cargoSrcSub(uid uint32) string { return "src/u" + strconv.FormatUint(uint64(uid), 10) }

// cacheTable is the single source of truth for what is cached, where, and for
// whom. Order is the attach and env order. Partition flags are the measured
// S2 matrix: pip < 25 writes 0600 HTTP-cache files (silent miss for the other
// uid) and yarn v1 creates 0755 dirs (0777 & ~umask) that defeat the ACL.
var cacheTable = []*cacheTool{
	{Kind: "gomod", Group: "go", Mode: "env", EnvKey: "GOMODCACHE",
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "GOMODCACHE"); v != "" {
				return v
			}
			if gp := x.get("GOPATH"); gp != "" {
				if first, _, _ := strings.Cut(gp, ":"); path.IsAbs(first) {
					return path.Join(first, "pkg/mod")
				}
			}
			return path.Join(x.home, "go/pkg/mod")
		},
		Markers: func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "cache/download"), true}} }},
	{Kind: "gobuild", Group: "go", Mode: "env", EnvKey: "GOCACHE", OffValues: map[string]string{"GOCACHE": "off"},
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "GOCACHE"); v != "" {
				return v
			}
			return path.Join(x.cacheHome(), "go-build")
		},
		// Go creates all 256 two-hex shard directories when it opens a cache.
		Markers: func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "00"), false}} }},
	{Kind: "npm", Mode: "env", EnvKey: "npm_config_cache", Fold: true,
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, true, "npm_config_cache"); v != "" {
				return v
			}
			return path.Join(x.home, ".npm")
		},
		Markers: func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "_cacache"), true}} }},
	// pnpm 9 and 10 read only npm_config_store_dir, pnpm 11 and 12 only
	// pnpm_config_store_dir (measured), so both are set. npm 11 prints
	// `npm warn Unknown env config "store-dir"` for the legacy key (npm 10 is
	// silent); revisit when npm 12 ships.
	{Kind: "pnpm", Mode: "env", EnvKey: "pnpm_config_store_dir", AltKeys: []string{"npm_config_store_dir"}, Fold: true,
		Extra: func(pol cachePolicy, value string) [][2]string {
			if pol.PnpmLegacyEnv {
				return [][2]string{{"npm_config_store_dir", value}}
			}
			return nil
		},
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, true, "pnpm_config_store_dir", "npm_config_store_dir"); v != "" {
				return v
			}
			return path.Join(x.dataHome(), "pnpm/store")
		},
		Markers: func(p string) []cacheMarker { return []cacheMarker{{p, true}} }},
	// Yarn classic: no YARN_* variable is ever set (Berry reads the same
	// names). Shared cold installs corrupt each other (measured 4/4 and 8/8
	// failures), so one container per store at a time.
	{Kind: "yarn", Mode: "path", AltKeys: []string{"YARN_CACHE_FOLDER"}, Fold: true, Partition: true, Exclusive: true,
		DefaultPath: func(x toolCtx) string {
			if v := x.get("XDG_CACHE_HOME"); path.IsAbs(v) {
				return path.Join(v, "yarn")
			}
			if x.uid == 0 {
				return "/usr/local/share/.cache/yarn"
			}
			return path.Join(x.home, ".cache/yarn")
		},
		Markers:  func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "v6"), false}} },
		Presence: nodeOnPath},
	{Kind: "yarnberry", Mode: "path", AltKeys: []string{"YARN_GLOBAL_FOLDER", "YARN_CACHE_FOLDER", "YARN_ENABLE_GLOBAL_CACHE"}, Fold: true,
		OffValues: map[string]string{"YARN_ENABLE_GLOBAL_CACHE": "false"},
		DefaultPath: func(x toolCtx) string {
			if v := x.get("XDG_DATA_HOME"); path.IsAbs(v) {
				return path.Join(v, "yarn/berry")
			}
			return path.Join(x.home, ".yarn/berry")
		},
		Markers:  func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "cache"), true}} },
		Presence: nodeOnPath},
	{Kind: "pip", Mode: "env", EnvKey: "PIP_CACHE_DIR", DisableKeys: []string{"PIP_NO_CACHE_DIR"}, Partition: true,
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "PIP_CACHE_DIR"); v != "" {
				return v
			}
			return path.Join(x.cacheHome(), "pip")
		},
		Markers: func(p string) []cacheMarker {
			return []cacheMarker{{path.Join(p, "http-v2"), false}, {path.Join(p, "http"), false}, {path.Join(p, "wheels"), false}}
		}},
	{Kind: "uv", Mode: "env", EnvKey: "UV_CACHE_DIR", DisableKeys: []string{"UV_NO_CACHE"},
		// The project's venv is never on the cache mount; hardlinks would fail.
		Extra: func(cachePolicy, string) [][2]string { return [][2]string{{"UV_LINK_MODE", "copy"}} },
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "UV_CACHE_DIR"); v != "" {
				return v
			}
			return path.Join(x.cacheHome(), "uv")
		},
		Markers: func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "archive-v0"), false}} }},
	// registry/ and git/ plus cargo's two lock files; never bin/, config.toml,
	// credentials.toml or the per-container .global-cache SQLite files.
	// registry/src is per uid: cargo extracts each crate with its tarball's
	// own modes (fnv 1.0.7 ships 0640 files), which no default ACL can widen,
	// so another uid could not read sources root extracted (measured rc=101).
	// The downloads (registry/index and registry/cache) stay shared.
	{Kind: "cargo", Mode: "path",
		DefaultPath: cargoHome,
		Targets: func(x toolCtx) []cacheTarget {
			h := cargoHome(x)
			return []cacheTarget{{"registry", path.Join(h, "registry"), false},
				{cargoSrcSub(x.uid), path.Join(h, "registry/src"), false},
				{"git", path.Join(h, "git"), false},
				{".package-cache", path.Join(h, ".package-cache"), true}, {".package-cache-mutate", path.Join(h, ".package-cache-mutate"), true}}
		},
		Markers: func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "registry/cache"), true}} },
		Presence: func(x toolCtx, f *imageFacts) bool {
			p, ok := f.Paths[cargoHome(x)]
			return ok && p.Dir
		}},
	{Kind: "corepack", Mode: "env", EnvKey: "COREPACK_HOME",
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "COREPACK_HOME"); v != "" {
				return v
			}
			return path.Join(x.cacheHome(), "node/corepack")
		},
		Markers: func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "v1"), false}} }},
}

func cacheToolByKind(kind string) *cacheTool {
	for _, t := range cacheTable {
		if t.Kind == kind {
			return t
		}
	}
	return nil
}

func (t *cacheTool) targets(x toolCtx) []cacheTarget {
	if t.Targets != nil {
		if ts := t.Targets(x); len(ts) > 0 {
			return ts
		}
	}
	return []cacheTarget{{"", t.DefaultPath(x), false}}
}

// ---- machine policy ----

type cachePolicy struct {
	Mode          string   `json:"mode"`
	DefaultScope  string   `json:"defaultScope"`
	AllowedScopes []string `json:"allowedScopes"`
	Tools         []string `json:"tools"`
	GoTrimpath    bool     `json:"goTrimpath"`
	PnpmLegacyEnv bool     `json:"pnpmLegacyEnv"`
}

func allCacheKinds() []string {
	var kinds []string
	for _, t := range cacheTable {
		kinds = append(kinds, t.Kind)
	}
	return kinds
}

func defaultCachePolicy() cachePolicy {
	return cachePolicy{Mode: "auto", DefaultScope: "default", AllowedScopes: []string{"*"}, Tools: allCacheKinds(), GoTrimpath: true, PnpmLegacyEnv: true}
}

// parseCachePolicy reads the host-rendered policy. Absent keys keep their
// defaults; unknown keys (buildkit, version, future fields) are ignored.
func parseCachePolicy(b []byte) (cachePolicy, error) {
	pol := defaultCachePolicy()
	var wire struct {
		Mode          *string   `json:"mode"`
		DefaultScope  *string   `json:"defaultScope"`
		AllowedScopes *[]string `json:"allowedScopes"`
		Tools         *[]string `json:"tools"`
		GoTrimpath    *bool     `json:"goTrimpath"`
		PnpmLegacyEnv *bool     `json:"pnpmLegacyEnv"`
	}
	if err := json.Unmarshal(b, &wire); err != nil {
		return pol, err
	}
	if wire.Mode != nil {
		switch *wire.Mode {
		case "auto", "off":
			pol.Mode = *wire.Mode
		default:
			return defaultCachePolicy(), fmt.Errorf("unknown cache mode %q", *wire.Mode)
		}
	}
	if wire.DefaultScope != nil {
		if *wire.DefaultScope != "" && !scopeName.MatchString(*wire.DefaultScope) {
			return defaultCachePolicy(), fmt.Errorf("invalid default scope %q", *wire.DefaultScope)
		}
		pol.DefaultScope = *wire.DefaultScope
	}
	if wire.AllowedScopes != nil {
		pol.AllowedScopes = append([]string{}, *wire.AllowedScopes...)
	}
	if wire.Tools != nil {
		pol.Tools = nil
		for _, name := range *wire.Tools {
			kinds, ok := expandCacheTool(name)
			if !ok {
				log.Printf("cache policy: ignoring unknown tool %q", name)
				continue
			}
			for _, k := range kinds {
				if !slices.Contains(pol.Tools, k) {
					pol.Tools = append(pol.Tools, k)
				}
			}
		}
	}
	if wire.GoTrimpath != nil {
		pol.GoTrimpath = *wire.GoTrimpath
	}
	if wire.PnpmLegacyEnv != nil {
		pol.PnpmLegacyEnv = *wire.PnpmLegacyEnv
	}
	return pol, nil
}

func (p cachePolicy) allows(scope string) bool {
	for _, a := range p.AllowedScopes {
		if a == "*" || a == scope || strings.HasSuffix(a, "*") && strings.HasPrefix(scope, strings.TrimSuffix(a, "*")) {
			return true
		}
	}
	return false
}

func (p cachePolicy) digest() string {
	b, _ := json.Marshal(p)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:8])
}

// policyLoader re-reads the policy file at most every 2 s, and only when its
// inode, size or mtime changed. A missing or invalid file means defaults, so
// the engine also works on hosts that never write one.
type policyLoader struct {
	mu      sync.Mutex
	path    string
	checked time.Time
	stamp   [3]int64
	pol     cachePolicy
	loaded  bool
}

func (l *policyLoader) get() cachePolicy {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.loaded && time.Since(l.checked) < 2*time.Second {
		return l.pol
	}
	l.checked = time.Now()
	file := l.path
	if file == "" {
		file = cachePolicyFile
	}
	var st syscall.Stat_t
	if err := syscall.Stat(file, &st); err != nil {
		if l.loaded && l.stamp != [3]int64{} {
			log.Printf("cache policy %s unavailable, using defaults: %v", file, err)
		}
		l.pol, l.loaded, l.stamp = defaultCachePolicy(), true, [3]int64{}
		return l.pol
	}
	stamp := [3]int64{int64(st.Ino), st.Size, st.Mtim.Nano()}
	if l.loaded && stamp == l.stamp {
		return l.pol
	}
	l.stamp, l.loaded = stamp, true
	b, err := os.ReadFile(file)
	if err == nil {
		l.pol, err = parseCachePolicy(b)
	}
	if err != nil {
		log.Printf("cache policy %s invalid, using defaults: %v", file, err)
		l.pol = defaultCachePolicy()
	}
	return l.pol
}

// ---- Docker API routes (through the router's extension hook) ----

func init() { extraRoutes = append(extraRoutes, cacheRoutes) }

// cacheRoutes serves:
//
//	GET  /micropod/caches        effective policy, its digest and the scopes and units on disk
//	POST /micropod/caches/debug  {"scope":"qual-x","kind":"gobuild","uid":null,"acl":false}
//	                             strips (acl=false) or restores the default ACL of a
//	                             qual-*/debug-* store; any other scope is HTTP 400
func cacheRoutes(s *dockerEngine, w http.ResponseWriter, r *http.Request, method, p string) (bool, error) {
	switch {
	case p == "micropod/caches" && method == "GET":
		pol := s.cachePolicy.get()
		scopes := map[string][]string{}
		entries, _ := os.ReadDir(path.Join(cacheRoot, "scopes"))
		for _, e := range entries {
			if !e.IsDir() || !scopeName.MatchString(e.Name()) {
				continue
			}
			units := []string{}
			meta, _ := os.ReadDir(path.Join(cacheRoot, ".meta", e.Name()))
			for _, m := range meta {
				if u, ok := strings.CutSuffix(m.Name(), ".used"); ok {
					units = append(units, u)
				}
			}
			scopes[e.Name()] = units
		}
		writeJSON(w, 200, map[string]any{"root": cacheRoot, "mountPoint": cacheMountRoot, "policy": pol, "policyDigest": pol.digest(), "scopes": scopes})
		return true, nil
	case p == "micropod/caches/debug" && method == "POST":
		b, err := readBody(w, r)
		if err != nil {
			return true, err
		}
		var req struct {
			Scope, Kind string
			UID         *uint32
			ACL         bool
		}
		if err := json.Unmarshal(b, &req); err != nil || cacheToolByKind(req.Kind) == nil {
			return true, fail(400, "expected {scope, kind, uid, acl} with a cache table kind")
		}
		store, err := setStoreACL(req.Scope, req.Kind, req.UID, req.ACL)
		if err != nil {
			return true, err
		}
		writeJSON(w, 200, map[string]any{"store": store, "acl": req.ACL})
		return true, nil
	}
	return false, nil
}

// ---- request vocabulary ----

func expandCacheTool(name string) ([]string, bool) {
	name = strings.ToLower(strings.TrimSpace(name))
	if name == "go" {
		return []string{"gomod", "gobuild"}, true
	}
	if cacheToolByKind(name) != nil {
		return []string{name}, true
	}
	return nil, false
}

// selectCacheTools applies io.micropod.cache (or MICROPOD_CACHE): "auto",
// a list of tools that replaces the policy's set, and +tool / -tool edits.
// +tool also bypasses the tool's presence guard.
func selectCacheTools(pol cachePolicy, value string) (map[string]bool, map[string]bool, error) {
	selected, forced := map[string]bool{}, map[string]bool{}
	value = strings.TrimSpace(value)
	var plus, minus, list []string
	if value != "" && !strings.EqualFold(value, "auto") {
		for _, item := range strings.Split(value, ",") {
			item = strings.TrimSpace(item)
			if item == "" {
				continue
			}
			op := byte(0)
			if item[0] == '+' || item[0] == '-' {
				op, item = item[0], item[1:]
			}
			kinds, ok := expandCacheTool(item)
			if !ok {
				return nil, nil, fail(400, fmt.Sprintf("unknown cache tool %q (known: go, %s)", item, strings.Join(allCacheKinds(), ", ")))
			}
			switch op {
			case '+':
				plus = append(plus, kinds...)
			case '-':
				minus = append(minus, kinds...)
			default:
				list = append(list, kinds...)
			}
		}
	}
	base := pol.Tools
	if list != nil {
		base = list
	}
	for _, k := range base {
		selected[k] = true
	}
	for _, k := range plus {
		selected[k], forced[k] = true, true
	}
	for _, k := range minus {
		delete(selected, k)
		delete(forced, k)
	}
	return selected, forced, nil
}

func cacheLabel(labels map[string]string, keys ...string) (string, bool) {
	for _, k := range keys {
		if v, ok := labels[k]; ok {
			return v, true
		}
	}
	return "", false
}

// envLookup returns the last value of key; fold compares names case-insensitively.
func envLookup(env []string, key string, fold bool) (string, bool) {
	for i := len(env) - 1; i >= 0; i-- {
		k, v, _ := strings.Cut(env[i], "=")
		if k == key || fold && strings.EqualFold(k, key) {
			return v, true
		}
	}
	return "", false
}

func truthy(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "", "0", "false", "no", "off":
		return false
	}
	return true
}

func isOff(v string) bool { return strings.EqualFold(strings.TrimSpace(v), "off") }

// pathsOverlap is true when a equals b or one contains the other.
func pathsOverlap(a, b string) bool {
	a, b = path.Clean(a), path.Clean(b)
	if a == b || a == "/" || b == "/" {
		return true
	}
	return strings.HasPrefix(b, a+"/") || strings.HasPrefix(a, b+"/")
}

// hasTrimpath reports whether GOFLAGS already decides -trimpath either way.
func hasTrimpath(flags string) bool {
	for _, f := range strings.Fields(flags) {
		name := strings.TrimLeft(f, "-")
		if name == "trimpath" || strings.HasPrefix(name, "trimpath=") {
			return true
		}
	}
	return false
}

// mergeGoflags appends -trimpath unless the flags already decide it.
func mergeGoflags(flags string) (string, bool) {
	if hasTrimpath(flags) {
		return flags, false
	}
	if strings.TrimSpace(flags) == "" {
		return "-trimpath", true
	}
	return strings.TrimRight(flags, " ") + " -trimpath", true
}

// mergeEnv appends extra after base; a key extra sets replaces base's entries.
func mergeEnv(base, extra []string) []string {
	if len(extra) == 0 {
		return base
	}
	set := map[string]bool{}
	for _, kv := range extra {
		k, _, _ := strings.Cut(kv, "=")
		set[k] = true
	}
	out := make([]string, 0, len(base)+len(extra))
	for _, kv := range base {
		if k, _, _ := strings.Cut(kv, "="); !set[k] {
			out = append(out, kv)
		}
	}
	return append(out, extra...)
}

// ---- users ----

type runAsUser struct {
	UID      *uint32 `json:"uid,omitempty"`
	GID      *uint32 `json:"gid,omitempty"`
	Username string  `json:"username,omitempty"`
}

// validUserToken accepts a numeric id or a passwd/group name.
func validUserToken(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-' || r == '.' || r == '$') {
			return false
		}
	}
	return true
}

func numericID(s string) (uint32, bool) {
	n, err := strconv.ParseUint(s, 10, 32)
	return uint32(n), err == nil
}

// resolveUser maps a Docker --user value to numeric ids and HOME the way the
// Docker daemon does: names through the image's passwd/group; a uid without a
// group takes its passwd primary group, else 0; HOME is the passwd home, else /.
func resolveUser(user string, facts *imageFacts) (uid, gid uint32, home string, err error) {
	home = "/"
	if user == "" {
		user = "0"
	}
	u, g, hasGroup := strings.Cut(user, ":")
	var entry *passwdEntry
	if n, ok := numericID(u); ok {
		uid = n
		if facts != nil {
			entry = facts.passwdByUID(uid)
		}
	} else {
		if facts == nil || !facts.OK {
			return 0, 0, "", fmt.Errorf("unable to find user %s: image facts unavailable", u)
		}
		if entry = facts.passwdByName(u); entry == nil {
			return 0, 0, "", fmt.Errorf("unable to find user %s: no matching entries in passwd file", u)
		}
		uid = entry.UID
	}
	if entry != nil {
		gid, home = entry.GID, entry.Home
		if home == "" {
			home = "/"
		}
	} else if uid == 0 {
		home = "/root"
	}
	if hasGroup {
		if n, ok := numericID(g); ok {
			gid = n
		} else {
			if facts == nil || !facts.OK {
				return 0, 0, "", fmt.Errorf("unable to find group %s: image facts unavailable", g)
			}
			grp := facts.groupByName(g)
			if grp == nil {
				return 0, 0, "", fmt.Errorf("unable to find group %s: no matching entries in group file", g)
			}
			gid = grp.GID
		}
	}
	return uid, gid, home, nil
}

// ---- the decision ----

// requestCacheValue returns the io.micropod.cache selection (label, alias, or
// the MICROPOD_CACHE request variable for env-only clients).
func requestCacheValue(spec dockerConfig) string {
	if v, ok := cacheLabel(spec.Labels, "io.micropod.cache", "com.micropod.cache"); ok {
		return v
	}
	v, _ := envLookup(spec.Env, "MICROPOD_CACHE", false)
	return v
}

// decideCaches is the whole attach decision. It is pure: everything it reads
// is in its arguments (plus privateRootless), so it is table-tested directly.
func decideCaches(pol cachePolicy, spec dockerConfig, facts imageFacts) (cachePlan, error) {
	plan := cachePlan{Tools: map[string]cacheToolState{}, PolicyDigest: pol.digest()}
	// (0) everything off
	selection := requestCacheValue(spec)
	switch {
	case pol.Mode == "off":
		plan.Reason = planPolicyOff
	case isOff(selection) && (spec.Labels["io.micropod.cache"] != "" || spec.Labels["com.micropod.cache"] != ""):
		plan.Reason = planLabelOff
	case strings.EqualFold(spec.Labels["micropod.cache.shared"], "false"):
		plan.Reason = planLabelOff
	case isOff(selection):
		plan.Reason = planEnvOff
	case privateRootless():
		plan.Reason = planRootless
	}
	if plan.Reason != "" {
		return plan, nil
	}
	if v, ok := envLookup(facts.Env, "MICROPOD_CACHE", false); ok && isOff(v) {
		plan.Reason = planImageOff
		return plan, nil
	}
	// (1) scope
	scope, named := cacheLabel(spec.Labels, "io.micropod.cache.scope", "com.micropod.cache.scope")
	if !named {
		scope, named = envLookup(spec.Env, "MICROPOD_CACHE_SCOPE", false)
	}
	if named {
		if !scopeName.MatchString(scope) || !pol.allows(scope) {
			return plan, fail(400, "cache scope not allowed by machine policy")
		}
	} else {
		scope = pol.DefaultScope
	}
	// (4) selection (validated before anything that can be skipped)
	selected, forced, err := selectCacheTools(pol, selection)
	if err != nil {
		return plan, err
	}
	// Qualification only: force a partitioned kind (pip, yarn) into one
	// shared store, to prove a test detects the silent miss partitioning avoids.
	debugShared := map[string]bool{}
	if v, ok := spec.Labels["io.micropod.cache.debug-shared"]; ok {
		if !debugCacheScope(scope) {
			return plan, fail(400, "io.micropod.cache.debug-shared needs a qual-* or debug-* cache scope")
		}
		for _, name := range strings.Split(v, ",") {
			kinds, ok := expandCacheTool(name)
			if !ok {
				return plan, fail(400, fmt.Sprintf("unknown cache tool %q", name))
			}
			for _, k := range kinds {
				debugShared[k] = true
			}
		}
	}
	if scope == "" {
		plan.Reason = planNoScope
		return plan, nil
	}
	plan.Scope = scope
	if !facts.OK {
		plan.Reason = skipProbeFailed
		for _, t := range cacheTable {
			if selected[t.Kind] {
				plan.Tools[t.Kind] = cacheToolState{Mode: "skipped", Reason: skipProbeFailed}
			}
		}
		return plan, nil
	}
	// (2) identity of the process the container starts
	user := spec.User
	if user == "" {
		user = facts.User
	}
	uid, gid, home, err := resolveUser(user, &facts)
	if err != nil {
		return plan, fail(400, err.Error())
	}
	// (3) effective environment: image, then request
	merged := append(append([]string{}, facts.Env...), spec.Env...)
	if v, ok := envLookup(merged, "HOME", false); ok && path.IsAbs(v) {
		home = path.Clean(v)
	}
	plan.UID, plan.GID, plan.Home = uid, gid, home
	x := toolCtx{env: merged, home: home, uid: uid}
	userMounts, _ := spec.mounts()
	scopedKinds := map[string]bool{}
	for _, m := range userMounts {
		if m.Type == "volume" {
			if _, kind, ok := legacyCacheVolume(m.Source); ok {
				scopedKinds[kind] = true
			}
		}
	}
	overlapsUser := func(p string) bool {
		for _, m := range userMounts {
			if pathsOverlap(m.Target, p) {
				return true
			}
		}
		return false
	}
	reserved := overlapsUser(cacheMountRoot)
	if p, ok := facts.Paths["/micropod"]; ok && p.NonEmpty {
		reserved = true
	}
	trimpath := pol.GoTrimpath && !strings.EqualFold(spec.Labels["io.micropod.cache.go-trimpath"], "false")
	plan.ToolEnv = map[string][]string{}
	scopeBind := false
	var shims []string
	for _, t := range cacheTable {
		if !selected[t.Kind] {
			plan.Tools[t.Kind] = cacheToolState{Mode: "skipped", Reason: skipNotSelected}
			continue
		}
		skip := func(reason, p string) { plan.Tools[t.Kind] = cacheToolState{Mode: "skipped", Path: p, Reason: reason} }
		userSet := false
		for _, k := range t.userKeys() {
			if _, ok := envLookup(spec.Env, k, t.Fold); ok {
				userSet = true
			}
		}
		if userSet {
			skip(skipUserEnv, "")
			continue
		}
		if t.disabledBy(facts.Env) {
			skip(skipDisabledImage, "")
			continue
		}
		def := t.DefaultPath(x)
		imageVal, imageSet := "", false
		if t.Mode == "env" {
			imageVal, imageSet = t.imagePath(facts.Env)
			imageSet = imageSet && path.IsAbs(imageVal)
		}
		var targets []cacheTarget
		switch {
		case t.Mode == "path":
			targets = t.targets(x)
		case imageSet:
			targets = []cacheTarget{{"", path.Clean(imageVal), false}}
		}
		// A row with explicit targets (cargo) is checked against those only, so
		// a user's own $CARGO_HOME/config.toml bind does not count; a mount at
		// or above $CARGO_HOME still overlaps every target.
		hit := scopedKinds[t.Kind] || t.Targets == nil && overlapsUser(def)
		for _, tg := range targets {
			hit = hit || overlapsUser(tg.Target)
		}
		if hit {
			skip(skipUserMount, def)
			continue
		}
		if facts.prewarmed(t.Markers(def)) {
			skip(skipPrewarmed, def)
			continue
		}
		if t.Mode == "path" && !forced[t.Kind] && (t.Presence == nil || !t.Presence(x, &facts)) {
			skip(skipNotInstalled, def)
			continue
		}
		useScope := t.Mode == "env" && !imageSet
		if useScope && reserved {
			skip(skipReserved, def)
			continue
		}
		var storeUID *uint32
		if t.Partition && !debugShared[t.Kind] {
			u := uid
			storeUID = &u
		}
		unit := cacheUnit(t.Kind, storeUID)
		plan.Stores = append(plan.Stores, cacheStoreRef{Kind: t.Kind, Unit: unit, UID: storeUID, Exclusive: t.Exclusive})
		var env []string
		if useScope {
			value := path.Join(cacheMountRoot, cacheStoreSub(t.Kind, storeUID))
			env = append(env, t.EnvKey+"="+value)
			if t.Extra != nil {
				for _, kv := range t.Extra(pol, value) {
					if _, ok := envLookup(merged, kv[0], t.Fold); !ok {
						env = append(env, kv[0]+"="+kv[1])
					}
				}
			}
			scopeBind = true
			plan.Tools[t.Kind] = cacheToolState{Mode: "env", Path: value}
		} else {
			nested := func(tg cacheTarget) bool { // inside another bind of this tool: never needs a shim
				return slices.ContainsFunc(targets, func(o cacheTarget) bool { return !o.File && o.Target == path.Dir(tg.Target) })
			}
			for _, tg := range targets {
				plan.Mounts = append(plan.Mounts, cacheMount{Kind: t.Kind, Unit: unit, Sub: tg.Sub, Target: tg.Target, File: tg.File})
				if t.Mode == "path" && uid != 0 && !tg.File && !nested(tg) {
					if s := shimFor(tg.Target, home, &facts); s != "" && !slices.Contains(shims, s) {
						shims = append(shims, s)
					}
				}
			}
			plan.Tools[t.Kind] = cacheToolState{Mode: "path", Path: targets[0].Target}
		}
		// (7) Go: -trimpath keeps build-cache keys independent of checkout paths.
		if t.Kind == "gobuild" && trimpath {
			flags, ok := envLookup(spec.Env, "GOFLAGS", false)
			if !ok {
				flags, _ = envLookup(facts.Env, "GOFLAGS", false)
			}
			if merged, changed := mergeGoflags(flags); changed {
				env = append(env, "GOFLAGS="+merged)
			}
		}
		if len(env) > 0 {
			plan.ToolEnv[t.Kind] = env
			plan.Env = append(plan.Env, env...)
		}
	}
	// (8) one bind of the scope for every env-mode tool, (9) parent shims first.
	var mounts []cacheMount
	sort.Strings(shims)
	for _, s := range shims {
		mounts = append(mounts, cacheMount{Target: s, Shim: true})
	}
	if scopeBind {
		mounts = append(mounts, cacheMount{Target: cacheMountRoot})
	}
	plan.Mounts = append(mounts, plan.Mounts...)
	if len(plan.ToolEnv) == 0 {
		plan.ToolEnv = nil
	}
	return plan, nil
}

// shimFor returns the first missing directory on the way from HOME to target
// when the image facts positively show it is absent. crun would otherwise
// create it root-owned and leave a non-root user's ~/.cache unwritable.
func shimFor(target, home string, facts *imageFacts) string {
	home = path.Clean(home)
	if home == "/" || !strings.HasPrefix(target, home+"/") {
		return ""
	}
	chain := []string{home}
	if rest := strings.Trim(strings.TrimPrefix(path.Dir(target), home), "/"); rest != "" {
		for _, c := range strings.Split(rest, "/") {
			chain = append(chain, path.Join(chain[len(chain)-1], c))
		}
	}
	for _, cur := range chain {
		p, known := facts.Paths[cur]
		if !known {
			return ""
		}
		if !p.Exists {
			return cur
		}
		if !p.Dir {
			return ""
		}
	}
	return ""
}

// legacyCacheVolume maps micropod-ci-scoped-<scope>-<kind> to its store; the
// longest kind suffix wins.
func legacyCacheVolume(name string) (scope, kind string, ok bool) {
	rest, ok := strings.CutPrefix(name, "micropod-ci-scoped-")
	if !ok {
		return "", "", false
	}
	kinds := allCacheKinds()
	sort.Slice(kinds, func(i, j int) bool { return len(kinds[i]) > len(kinds[j]) })
	for _, k := range kinds {
		if s, found := strings.CutSuffix(rest, "-"+k); found && scopeName.MatchString(s) {
			return s, k, true
		}
	}
	return "", "", false
}

// decideJobCaches is the scheduler job path: the scope is named by the
// trusted scheduler, only env-mode tools attach (one bind at /micropod/cache),
// and the uid comes from the image facts, else 0.
func decideJobCaches(pol cachePolicy, scope string, facts imageFacts) cachePlan {
	spec := dockerConfig{Labels: map[string]string{}}
	var tools []string
	for _, t := range cacheTable {
		if t.Mode == "env" && slices.Contains(pol.Tools, t.Kind) {
			tools = append(tools, t.Kind)
		}
	}
	spec.Labels["io.micropod.cache"] = strings.Join(tools, ",")
	if tools == nil {
		spec.Labels["io.micropod.cache"] = "off"
	}
	spec.Labels["io.micropod.cache.scope"] = scope
	jobPol := pol
	jobPol.Mode, jobPol.AllowedScopes = "auto", []string{"*"}
	if !facts.OK {
		// Jobs asked for a cache explicitly; without facts they run as the
		// image's root default with nothing pre-warm-detected.
		facts = imageFacts{OK: true, Env: facts.Env}
	}
	plan, err := decideCaches(jobPol, spec, facts)
	if err != nil {
		return cachePlan{Scope: scope, Reason: err.Error(), Tools: map[string]cacheToolState{}}
	}
	return plan
}
