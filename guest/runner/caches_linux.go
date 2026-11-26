package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Every container started through the Docker socket gets the machine's tool
// caches unless something below says otherwise. The decision is made once at
// create from the request, the image facts and the machine policy, persisted
// with the container and replayed on every start.

const cacheMountRoot = "/micropod/cache"
const cacheMountL0Root = "/micropod/cache-l0"
const cacheL0GlobalScope = "global"
const cachePolicyFile = "/run/micropod/host-config/cache-policy.json"

const (
	// cacheLayerL0 holds verified content-addressed artifacts (module zips,
	// tarballs, wheels, crates) whose correctness comes from hash verification.
	cacheLayerL0 = "L0"
	// cacheLayerL1 holds content-addressed build artifacts (Go compile objects).
	cacheLayerL1 = "L1"
)

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
	// The plan was made in a boot with the cache disk; this start's boot has
	// none mounted (cacheDiskUnavailable), so no store is reachable.
	skipNoCacheDisk = "cache-disk-unavailable"
)

// Plan-level reasons for attaching nothing.
const (
	planPolicyOff   = "policy-off"
	planLabelOff    = "label-off"
	planEnvOff      = "env-off"
	planImageOff    = "image-off"
	planRootless    = "rootless"
	planNoScope     = "no-scope"
	planNoCacheDisk = "cache-disk-unavailable"
)

// How one start reaches a store it uses (cacheToolState.Access; empty is the
// store itself, read-write, as its writer).
const (
	// A per-container overlayfs over the store: reads are warm, writes land
	// in an upper directory of the container's own that goes with the start.
	accessCopyOnWrite = "copy-on-write"
	// The store bound read-only (an untrusted or read-only plan on a guest
	// without overlayfs).
	accessReadOnly = "read-only"
)

type cacheToolState struct {
	Mode   string `json:"mode"` // env, path or skipped
	Path   string `json:"path,omitempty"`
	Reason string `json:"reason,omitempty"`
	Layer  string `json:"layer,omitempty"`
	Scope  string `json:"scope,omitempty"`
	// Access is set in inspect for the latest start only (accessCopyOnWrite,
	// accessReadOnly); never in a persisted plan.
	Access string `json:"access,omitempty"`
}

// cacheTrustOf reads a request's cache trust: io.micropod.cache.trust (or
// MICROPOD_CACHE_TRUST) "untrusted", or io.micropod.cache.readonly (or
// MICROPOD_CACHE_READONLY) set, makes the container a reader of every shared
// store: it never gets a writable path into one, through the auto-attached
// caches or a legacy alias volume (openMounts).
func cacheTrustOf(spec dockerConfig) (trust string, readOnly bool, err error) {
	trust, _ = cacheLabel(spec.Labels, "io.micropod.cache.trust", "com.micropod.cache.trust")
	if trust == "" {
		trust, _ = envLookup(spec.Env, "MICROPOD_CACHE_TRUST", false)
	}
	switch strings.ToLower(strings.TrimSpace(trust)) {
	case "", "trusted":
		trust = ""
	case "untrusted":
		trust, readOnly = "untrusted", true
	default:
		return "", false, fail(400, fmt.Sprintf("invalid cache trust %q (expected trusted or untrusted)", trust))
	}
	roVal, hasRO := cacheLabel(spec.Labels, "io.micropod.cache.readonly", "com.micropod.cache.readonly")
	if !hasRO {
		roVal, hasRO = envLookup(spec.Env, "MICROPOD_CACHE_READONLY", false)
	}
	if hasRO && truthy(roVal) {
		readOnly = true
		if trust == "" {
			trust = "readonly"
		}
	}
	return trust, readOnly, nil
}

// The persistent cache disk (caches.ext4, /dev/vdb). Guest init mounts it at
// cacheRoot before the engine starts and reports the outcome in
// MICROPOD_CACHE_DISK: "mounted", "unavailable" (the host attached one but it
// is missing or did not mount) or unset (no cache disk: the stores, the
// fence's metadata, .trash and the clean-stop record all live on the OS disk,
// as before). The fence keeps everything it needs on the filesystem that holds
// the stores, so it stays valid when the OS disk is replaced. Without a
// mounted cache disk that should be there, shared caches are off for the
// boot: nothing may create stores below the mount point on the OS disk, where
// the next boot's mount would hide them and their marks. GET /micropod/caches
// reports it, with what mountinfo shows, as cacheDisk (observeCacheDisk) and
// the reason caches are off as unavailable.
var cacheDiskInit = os.Getenv("MICROPOD_CACHE_DISK")

// cacheDiskUnavailable says why no shared store may be used this boot, or "".
// A disk reported mounted must really be mounted at cacheRoot (another device
// than its parent directory's).
func cacheDiskUnavailable() string {
	switch strings.TrimSpace(cacheDiskInit) {
	case "":
		return ""
	case "mounted":
		var root, parent unix.Stat_t
		if err := unix.Stat(cacheRoot, &root); err != nil {
			return "the cache disk is not mounted at " + cacheRoot + ": " + err.Error()
		}
		if err := unix.Stat(filepath.Dir(cacheRoot), &parent); err != nil || root.Dev == parent.Dev {
			return "the cache disk is not mounted at " + cacheRoot
		}
		return ""
	case "unavailable":
		return "guest init found the cache disk missing or unmountable"
	default:
		return fmt.Sprintf("unknown cache disk state %q", cacheDiskInit)
	}
}

var errNoCacheDisk = errors.New("shared caches are off this boot")

// cacheStoreRef names one store a plan uses: it is created/verified, locked and
// stamped on every start. Empty Scope means the plan's own Scope.
type cacheStoreRef struct {
	Scope     string  `json:"scope,omitempty"`
	Kind      string  `json:"kind"`
	Unit      string  `json:"unit"`
	UID       *uint32 `json:"uid,omitempty"`
	Exclusive bool    `json:"exclusive,omitempty"`
}

// cacheMount is one bind of a plan. Kind "" with Shim false is a scope bind
// at /micropod/cache (or /micropod/cache-l0 for shared L0); Sub is relative to
// the store directory of Unit. Empty Scope means the plan's own Scope.
type cacheMount struct {
	Scope  string `json:"scope,omitempty"`
	Kind   string `json:"kind,omitempty"`
	Unit   string `json:"unit,omitempty"`
	Sub    string `json:"sub,omitempty"`
	Target string `json:"target"`
	File   bool   `json:"file,omitempty"`
	Shim   bool   `json:"shim,omitempty"`
}

type cachePlan struct {
	Scope        string                    `json:"scope"`
	Trust        string                    `json:"trust,omitempty"`
	ReadOnly     bool                      `json:"readOnly,omitempty"`
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
	Layer       string // cacheLayerL0 (downloads) or cacheLayerL1 (build artifacts)
	// Global: the tool itself verifies the store's contents by content hash
	// every time it reads them, so one project cannot substitute an entry
	// another project then uses. Only such stores move to the shared scope
	// "global" under sharedL0; every other store stays in the container's
	// scope (see the rule above cacheTable).
	Global      bool
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
//
// Sharing across projects (sharedL0, scope "global"): a store may be shared
// read-write by every project only when the tool verifies what it reads from
// it by content hash on every read, so a project that plants an entry cannot
// change what another project builds. That is gomod (go.sum and the checksum
// database decide every module zip; the store is keyed by those hashes), npm
// (cacache: every entry is addressed and checked by its integrity hash) and
// pnpm (a content-addressable store checked against the lockfile integrity).
// Every other store (yarn, yarnberry, pip, uv, cargo, corepack, maven,
// gradle, bun, playwright, and the L1 build caches) is trusted as written:
// it stays in the container's own scope whatever sharedL0 says.
var cacheTable = []*cacheTool{
	{Kind: "gomod", Group: "go", Layer: cacheLayerL0, Global: true, Mode: "env", EnvKey: "GOMODCACHE",
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
	{Kind: "gobuild", Group: "go", Layer: cacheLayerL1, Mode: "env", EnvKey: "GOCACHE", OffValues: map[string]string{"GOCACHE": "off"},
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "GOCACHE"); v != "" {
				return v
			}
			return path.Join(x.cacheHome(), "go-build")
		},
		// Go creates all 256 two-hex shard directories when it opens a cache.
		Markers: func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "00"), false}} }},
	{Kind: "npm", Layer: cacheLayerL0, Global: true, Mode: "env", EnvKey: "npm_config_cache", Fold: true,
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
	{Kind: "pnpm", Layer: cacheLayerL0, Global: true, Mode: "env", EnvKey: "pnpm_config_store_dir", AltKeys: []string{"npm_config_store_dir"}, Fold: true,
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
	{Kind: "yarn", Layer: cacheLayerL0, Mode: "path", AltKeys: []string{"YARN_CACHE_FOLDER"}, Fold: true, Partition: true, Exclusive: true,
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
	{Kind: "yarnberry", Layer: cacheLayerL0, Mode: "path", AltKeys: []string{"YARN_GLOBAL_FOLDER", "YARN_CACHE_FOLDER", "YARN_ENABLE_GLOBAL_CACHE"}, Fold: true,
		OffValues: map[string]string{"YARN_ENABLE_GLOBAL_CACHE": "false"},
		DefaultPath: func(x toolCtx) string {
			if v := x.get("XDG_DATA_HOME"); path.IsAbs(v) {
				return path.Join(v, "yarn/berry")
			}
			return path.Join(x.home, ".yarn/berry")
		},
		Markers:  func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "cache"), true}} },
		Presence: nodeOnPath},
	{Kind: "pip", Layer: cacheLayerL0, Mode: "env", EnvKey: "PIP_CACHE_DIR", DisableKeys: []string{"PIP_NO_CACHE_DIR"}, Partition: true,
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "PIP_CACHE_DIR"); v != "" {
				return v
			}
			return path.Join(x.cacheHome(), "pip")
		},
		Markers: func(p string) []cacheMarker {
			return []cacheMarker{{path.Join(p, "http-v2"), false}, {path.Join(p, "http"), false}, {path.Join(p, "wheels"), false}}
		}},
	{Kind: "uv", Layer: cacheLayerL0, Mode: "env", EnvKey: "UV_CACHE_DIR", DisableKeys: []string{"UV_NO_CACHE"},
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
	{Kind: "cargo", Layer: cacheLayerL0, Mode: "path",
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
	{Kind: "corepack", Layer: cacheLayerL0, Mode: "env", EnvKey: "COREPACK_HOME",
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "COREPACK_HOME"); v != "" {
				return v
			}
			return path.Join(x.cacheHome(), "node/corepack")
		},
		Markers: func(p string) []cacheMarker { return []cacheMarker{{path.Join(p, "v1"), false}} }},
	// Extended CI ecosystems (path-mode with binary/dir presence probes so
	// containers without these tools receive zero extra mounts or env vars).
	// None of them verifies its store on read, so none is Global. Maven's
	// local repository is not safe for concurrent writers (two builds
	// resolving one artifact write the same files without a lock unless the
	// named-locks resolver is configured), so one writer at a time: the
	// others read it copy-on-write, as yarn v1 does.
	{Kind: "maven", Layer: cacheLayerL0, Mode: "path", Exclusive: true,
		DefaultPath: func(x toolCtx) string { return path.Join(x.home, ".m2/repository") },
		Markers:     func(p string) []cacheMarker { return []cacheMarker{{p, true}} },
		Presence: func(x toolCtx, f *imageFacts) bool {
			if f.Binaries["mvn"] {
				return true
			}
			p, ok := f.Paths[path.Join(x.home, ".m2")]
			return ok && p.Dir
		}},
	{Kind: "gradle", Layer: cacheLayerL0, Mode: "path", AltKeys: []string{"GRADLE_USER_HOME"},
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "GRADLE_USER_HOME"); v != "" {
				return path.Join(v, "caches/modules-2")
			}
			return path.Join(x.home, ".gradle/caches/modules-2")
		},
		Markers: func(p string) []cacheMarker { return []cacheMarker{{p, true}} },
		Presence: func(x toolCtx, f *imageFacts) bool {
			if f.Binaries["gradle"] {
				return true
			}
			p, ok := f.Paths[path.Join(x.home, ".gradle")]
			return ok && p.Dir
		}},
	{Kind: "bun", Layer: cacheLayerL0, Mode: "path", AltKeys: []string{"BUN_INSTALL_CACHE_DIR"},
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "BUN_INSTALL_CACHE_DIR"); v != "" {
				return v
			}
			return path.Join(x.home, ".bun/install/cache")
		},
		Markers: func(p string) []cacheMarker { return []cacheMarker{{p, true}} },
		Presence: func(x toolCtx, f *imageFacts) bool {
			if f.Binaries["bun"] {
				return true
			}
			p, ok := f.Paths[path.Join(x.home, ".bun")]
			return ok && p.Dir
		}},
	{Kind: "sccache", Layer: cacheLayerL1, Mode: "path", AltKeys: []string{"SCCACHE_DIR"},
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "SCCACHE_DIR"); v != "" {
				return v
			}
			return path.Join(x.cacheHome(), "sccache")
		},
		Markers:  func(p string) []cacheMarker { return []cacheMarker{{p, true}} },
		Presence: func(_ toolCtx, f *imageFacts) bool { return f.Binaries["sccache"] }},
	{Kind: "playwright", Layer: cacheLayerL0, Mode: "path", AltKeys: []string{"PLAYWRIGHT_BROWSERS_PATH"},
		DefaultPath: func(x toolCtx) string {
			if v := firstEnv(x, false, "PLAYWRIGHT_BROWSERS_PATH"); v != "" {
				return v
			}
			return path.Join(x.cacheHome(), "ms-playwright")
		},
		Markers:  func(p string) []cacheMarker { return []cacheMarker{{p, true}} },
		Presence: func(_ toolCtx, f *imageFacts) bool { return f.Binaries["playwright"] }},
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
	// Fleet-aligned extensions (all omitempty so default policy JSON/digest is unchanged):
	// SharedL0 shares the stores their tools verify on read (cacheTool.Global)
	// in scope "global" even when containers name a project scope; every other
	// store, L1 build caches included, stays in the container's scope.
	SharedL0     bool   `json:"sharedL0,omitempty"`
	GoProxy      string `json:"goProxy,omitempty"`
	NpmRegistry  string `json:"npmRegistry,omitempty"`
	MaxBytes     uint64 `json:"maxBytes,omitempty"`
	MaxAgeDays   int    `json:"maxAgeDays,omitempty"`
	MinFreeBytes uint64 `json:"minFreeBytes,omitempty"`
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

func validProxySetting(v string) bool {
	if v == "" {
		return true
	}
	for _, part := range strings.Split(v, ",") {
		part = strings.TrimSpace(part)
		if part == "direct" || part == "off" {
			continue
		}
		if !strings.HasPrefix(part, "http://") && !strings.HasPrefix(part, "https://") {
			return false
		}
	}
	return true
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
		SharedL0      *bool     `json:"sharedL0"`
		GoProxy       *string   `json:"goProxy"`
		NpmRegistry   *string   `json:"npmRegistry"`
		MaxBytes      *uint64   `json:"maxBytes"`
		MaxAgeDays    *int      `json:"maxAgeDays"`
		MinFreeBytes  *uint64   `json:"minFreeBytes"`
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
	if wire.SharedL0 != nil {
		pol.SharedL0 = *wire.SharedL0
	}
	if wire.GoProxy != nil {
		v := strings.TrimSpace(*wire.GoProxy)
		if !validProxySetting(v) {
			return defaultCachePolicy(), fmt.Errorf("invalid goProxy %q", v)
		}
		pol.GoProxy = v
	}
	if wire.NpmRegistry != nil {
		v := strings.TrimSpace(*wire.NpmRegistry)
		if v != "" && !strings.HasPrefix(v, "http://") && !strings.HasPrefix(v, "https://") {
			return defaultCachePolicy(), fmt.Errorf("invalid npmRegistry %q", v)
		}
		pol.NpmRegistry = v
	}
	if wire.MaxBytes != nil {
		pol.MaxBytes = *wire.MaxBytes
	}
	if wire.MaxAgeDays != nil {
		if *wire.MaxAgeDays < 0 {
			return defaultCachePolicy(), fmt.Errorf("invalid maxAgeDays %d", *wire.MaxAgeDays)
		}
		pol.MaxAgeDays = *wire.MaxAgeDays
	}
	if wire.MinFreeBytes != nil {
		pol.MinFreeBytes = *wire.MinFreeBytes
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
//	GET    /micropod/caches        policy, digest, scopes, per-unit sizes/locks/dirty marks/ages,
//	                               budget & evictions, and the units this start discarded or kept
//	                               after the previous stop (?stats=0 skips the size walk)
//	GET    /micropod/caches/dedupe cross-scope Go build-cache duplication sampler
//	POST   /micropod/caches/prune  lock-safe LRU & partial gobuild eviction (supports dryRun); a
//	                               unit a writer holds or one marked dirty is skipped
//	DELETE /micropod/caches        alias for prune via query params
//	POST   /micropod/caches/debug  {"scope":"qual-x","kind":"gobuild","uid":null,"acl":false}
//	                               strips (acl=false) or restores the default ACL of a
//	                               qual-*/debug-* store; any other scope is HTTP 400
//
// GET reports cacheDisk and, without the cache disk a boot should have,
// unavailable (and no units); prune, DELETE and debug then answer 503.
func cacheRoutes(s *dockerEngine, w http.ResponseWriter, r *http.Request, method, p string) (bool, error) {
	switch {
	case p == "micropod/caches" && method == "GET":
		includeStats := r.URL.Query().Get("stats") != "0"
		snap := s.inspectCaches(includeStats)
		writeJSON(w, 200, snap)
		return true, nil
	case p == "micropod/caches/dedupe" && method == "GET":
		buckets := 16
		if raw := r.URL.Query().Get("buckets"); raw != "" {
			n, err := strconv.Atoi(raw)
			if err != nil || n < 1 || n > 256 {
				return true, fail(400, "buckets must be an integer between 1 and 256")
			}
			buckets = n
		}
		writeJSON(w, 200, sampleCacheDedupe(buckets))
		return true, nil
	case (p == "micropod/caches/prune" && method == "POST") || (p == "micropod/caches" && method == "DELETE"):
		return true, s.handleCachePrune(w, r)
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
		if why := cacheDiskUnavailable(); why != "" {
			return true, fail(http.StatusServiceUnavailable, "no shared caches this boot: "+why)
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
// is in its arguments (plus privateRootless and cacheDiskUnavailable), so it
// is table-tested directly.
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
	case cacheDiskUnavailable() != "":
		plan.Reason = planNoCacheDisk
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
	// (1b) trust & read-only isolation: untrusted PR builds or explicit readonly
	// requests get warm reads through an ephemeral per-container overlayfs upperdir
	// (or fail-closed read-only bind), never mutating trusted stores. Every
	// store of such a plan is held as a reader (openCacheMounts): locked so the
	// janitor and the crash discard leave it alone, never marked dirty.
	if plan.Trust, plan.ReadOnly, err = cacheTrustOf(spec); err != nil {
		return plan, err
	}
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
	reserved := overlapsUser(cacheMountRoot) || (pol.SharedL0 && overlapsUser(cacheMountL0Root))
	if p, ok := facts.Paths["/micropod"]; ok && p.NonEmpty {
		reserved = true
	}
	trimpath := pol.GoTrimpath && !strings.EqualFold(spec.Labels["io.micropod.cache.go-trimpath"], "false")
	plan.ToolEnv = map[string][]string{}
	scopeBind := false
	scopeL0Bind := false
	var shims []string
	for _, t := range cacheTable {
		if !selected[t.Kind] {
			plan.Tools[t.Kind] = cacheToolState{Mode: "skipped", Reason: skipNotSelected, Layer: t.Layer}
			continue
		}
		skip := func(reason, p string) {
			plan.Tools[t.Kind] = cacheToolState{Mode: "skipped", Path: p, Reason: reason, Layer: t.Layer}
		}
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
		// Fleet sharing: only a store its tool verifies on every read (Global)
		// resolves into the shared "global" scope when SharedL0 is enabled,
		// even for named project scopes; everything else stays in the
		// container's scope.
		storeScope := ""
		mountRoot := cacheMountRoot
		if pol.SharedL0 && t.Global && scope != cacheL0GlobalScope {
			storeScope = cacheL0GlobalScope
			mountRoot = cacheMountL0Root
		}
		effectiveScope := scope
		if storeScope != "" {
			effectiveScope = storeScope
		}
		unit := cacheUnit(t.Kind, storeUID)
		exclusive := t.Exclusive && !plan.ReadOnly
		plan.Stores = append(plan.Stores, cacheStoreRef{Scope: storeScope, Kind: t.Kind, Unit: unit, UID: storeUID, Exclusive: exclusive})
		var env []string
		if useScope {
			value := path.Join(mountRoot, cacheStoreSub(t.Kind, storeUID))
			env = append(env, t.EnvKey+"="+value)
			if t.Extra != nil {
				for _, kv := range t.Extra(pol, value) {
					if _, ok := envLookup(merged, kv[0], t.Fold); !ok {
						env = append(env, kv[0]+"="+kv[1])
					}
				}
			}
			if storeScope != "" {
				scopeL0Bind = true
			} else {
				scopeBind = true
			}
			plan.Tools[t.Kind] = cacheToolState{Mode: "env", Path: value, Layer: t.Layer, Scope: effectiveScope}
		} else {
			nested := func(tg cacheTarget) bool { // inside another bind of this tool: never needs a shim
				return slices.ContainsFunc(targets, func(o cacheTarget) bool { return !o.File && o.Target == path.Dir(tg.Target) })
			}
			for _, tg := range targets {
				plan.Mounts = append(plan.Mounts, cacheMount{Scope: storeScope, Kind: t.Kind, Unit: unit, Sub: tg.Sub, Target: tg.Target, File: tg.File})
				if t.Mode == "path" && uid != 0 && !tg.File && !nested(tg) {
					if s := shimFor(tg.Target, home, &facts); s != "" && !slices.Contains(shims, s) {
						shims = append(shims, s)
					}
				}
			}
			plan.Tools[t.Kind] = cacheToolState{Mode: "path", Path: targets[0].Target, Layer: t.Layer, Scope: effectiveScope}
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
		// (7b) Optional L0 rig dependency proxy wiring (depproxy): inject only
		// when neither the container request nor the image set the registry.
		if t.Kind == "gomod" && pol.GoProxy != "" {
			if _, ok := envLookup(merged, "GOPROXY", false); !ok {
				env = append(env, "GOPROXY="+pol.GoProxy)
			}
		}
		if (t.Kind == "npm" || t.Kind == "pnpm") && pol.NpmRegistry != "" {
			if _, ok := envLookup(merged, "npm_config_registry", true); !ok {
				env = append(env, "npm_config_registry="+pol.NpmRegistry)
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
	if scopeL0Bind {
		mounts = append(mounts, cacheMount{Scope: cacheL0GlobalScope, Target: cacheMountL0Root})
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
