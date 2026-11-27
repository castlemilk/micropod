package main

import (
	"context"
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
	// A reader (untrusted or read-only) of an env-mode store that does not
	// exist yet: nothing to read, and a reader never creates a store.
	skipNoStore = "no-store-to-read"
	// The plan, made by an engine before the sharing rule (cacheTool.Global),
	// shares this tool's store across projects in scope "global" although the
	// tool does not verify it on read. The start leaves it out; recreating
	// the container attaches the store of its own scope.
	skipRetiredShare = "shared-store-retired"
	// The store holds programs built for the machine's own architecture
	// (cacheTool.NativeOnly) and the container runs another's through
	// emulation: it gets no store rather than one its programs cannot run.
	skipEmulatedPlatform = "emulated-platform"
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
	// The policy's own defaultScope is not in its allowedScopes (the host
	// refuses that; a hand-written policy file may still say it).
	planScopeNotAllowed = "scope-not-allowed"
)

// Dependency proxy decisions (cachePlan.Proxy, inspect MicropodCache.proxy).
const (
	proxyInjected = "injected"
	// A reader tier (untrusted, read-only) and no policy proxyUntrusted.
	proxySkipReader = "reader-tier"
	// The request or the image sets the variable itself.
	proxySkipRequest = "request-env"
	// A .npmrc of the project or the image sets an unscoped registry, which
	// npm_config_registry would override.
	proxySkipNpmrc = "npmrc-registry"
	// A go env file (`go env -w`, GOENV) of the image or of a mount sets
	// GOPROXY, which the GOPROXY variable would override.
	proxySkipGoEnv = "goenv-proxy"
	// The proxy did not answer the create-time health check.
	proxySkipUnreachable = "proxy-unreachable"
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

// Cache trust tiers (cachePlan.Trust; "" is trustTrusted in a plan, as every
// plan before tiers were resolved said). A trusted container writes the shared
// stores it uses; an untrusted or read-only one only reads them: it never gets
// a writable path into a store, through the auto-attached caches, a legacy
// alias volume (openMounts) or docker cp (docker_archive_linux.go).
const (
	trustTrusted   = "trusted"
	trustUntrusted = "untrusted"
	trustReadOnly  = "readonly"
)

// Where a plan's tier came from (cachePlan.TrustFrom, inspect trustFrom).
const (
	// No trust label: the machine policy's defaultTrust.
	trustFromPolicy = "policy-default"
	// The request's io.micropod.cache.trust or .readonly: a lowering, or a
	// claim of trusted the engine could grant.
	trustFromLabel = "label"
	// The request claimed trusted where nothing proves the host asked for it
	// (the policy default is untrusted and the request did not arrive on the
	// host-facing socket): it gets the policy default instead.
	trustFromRefused = "claim-refused"
	// The request arrived on a socket bound into a container (or one whose
	// owner is unknown): never more trusted than that container.
	trustFromCreator = "creator"
	// A plan an engine made before tiers were resolved, read under a policy
	// whose default is untrusted (cachePlan.legacyTrust).
	trustFromLegacy = "legacy-policy-default"
)

// cacheOrigin is where a create request came from. Only the engine's own
// Docker socket (dockerSocket) is host-facing: guest init bridges it to the
// host's vsock port, and no container is ever given a path to it (a bind
// source must be a directory or regular file in the workspace, and the kernel
// has no vsock loopback). Every other way in, such as the Testcontainers
// cleanup socket bound into a Ryuk container, is a container's: creatorTier
// is the tier of the container that owns that socket ("" when it is not
// known, which counts as untrusted) and creatorScope its cache scope, the
// only one a container it creates may be in ("" for none: an unknown
// creator's children get no scope).
type cacheOrigin struct {
	hostFacing   bool
	creator      string
	creatorTier  string
	creatorScope string
}

type cacheOriginKey struct{}

// withCacheOrigin marks a request's context with where it came from.
func withCacheOrigin(ctx context.Context, o cacheOrigin) context.Context {
	return context.WithValue(ctx, cacheOriginKey{}, o)
}

// cacheOriginOf is the origin a context carries; none is a container's
// socket with an unknown owner, the least trusted way in.
func cacheOriginOf(ctx context.Context) cacheOrigin {
	o, _ := ctx.Value(cacheOriginKey{}).(cacheOrigin)
	return o
}

// tierRank orders tiers for the creator ceiling: only trusted writes.
func tierRank(tier string) int {
	if tier == "" || tier == trustTrusted {
		return 1
	}
	return 0
}

// resolveCacheTrust decides a create's tier. The policy's defaultTrust is the
// tier of a container that names none. A container may always lower its own
// (io.micropod.cache.trust=untrusted, io.micropod.cache.readonly=1), but it
// may claim trusted only when the policy default is trusted or the request
// arrived on the host-facing socket, which nothing inside the machine can
// reach, and named the tier in a label. MICROPOD_CACHE_TRUST in the request's
// environment only ever lowers: an orchestrator passes a job's own env: block
// (a workflow, a compose file, a service definition) through to the
// containers it creates, so under an untrusted default a job could name its
// own tier there; the scheduler states the tier of the attempts it trusts in
// the label. A request from inside a container is then capped at that
// container's own tier. Unknown values fail the create (HTTP 400).
func resolveCacheTrust(pol cachePolicy, spec dockerConfig, origin cacheOrigin) (tier, from string, err error) {
	raw, _ := cacheLabel(spec.Labels, "io.micropod.cache.trust", "com.micropod.cache.trust")
	fromEnv := false
	if strings.TrimSpace(raw) == "" {
		raw, _ = envLookup(spec.Env, "MICROPOD_CACHE_TRUST", false)
		fromEnv = true
	}
	tier, from = trustTrusted, trustFromPolicy
	if pol.untrustedByDefault() {
		tier = trustUntrusted
	}
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "":
	case trustUntrusted:
		tier, from = trustUntrusted, trustFromLabel
	case trustTrusted:
		if !pol.untrustedByDefault() || origin.hostFacing && !fromEnv {
			tier, from = trustTrusted, trustFromLabel
		} else {
			from = trustFromRefused
		}
	default:
		return "", "", fail(400, fmt.Sprintf("invalid cache trust %q (expected trusted or untrusted)", raw))
	}
	roVal, hasRO := cacheLabel(spec.Labels, "io.micropod.cache.readonly", "com.micropod.cache.readonly")
	if !hasRO {
		roVal, hasRO = envLookup(spec.Env, "MICROPOD_CACHE_READONLY", false)
	}
	if hasRO && truthy(roVal) && tier == trustTrusted {
		tier, from = trustReadOnly, trustFromLabel
	}
	if !origin.hostFacing {
		ceiling := origin.creatorTier
		if ceiling == "" {
			ceiling = trustUntrusted
		}
		if tierRank(tier) > tierRank(ceiling) {
			tier, from = ceiling, trustFromCreator
		}
	}
	return tier, from, nil
}

// planTier is how a plan records a tier: "" for trusted, as before tiers.
func planTier(tier string) string {
	if tier == trustTrusted {
		return ""
	}
	return tier
}

// legacyTrust gives a plan an engine made before tiers were resolved (no
// TrustFrom) the tier the policy now gives a container naming none, never a
// higher one: such an engine read only the request's labels, so nothing in the
// plan proves the host asked for a trusted container. It is decided again at
// every start: once the policy trusts by default again, a plan it demoted
// (trustFromLegacy) is the trusted plan the older engine made, so a machine
// switched back with `cache policy --default-trust trusted` does not leave its
// older containers and compose stacks readers until they are recreated.
func (p *cachePlan) legacyTrust(pol cachePolicy) {
	if p == nil {
		return
	}
	switch {
	case p.TrustFrom == trustFromLegacy && !pol.untrustedByDefault():
		p.Trust, p.ReadOnly, p.TrustFrom = "", false, ""
		p.currentExclusive()
	case p.TrustFrom != "" || p.ReadOnly || !pol.untrustedByDefault():
	default:
		p.Trust, p.ReadOnly, p.TrustFrom = trustUntrusted, true, trustFromLegacy
		p.currentExclusive()
	}
}

// currentExclusive sets each store's Exclusive from the cache table as it is
// now, not as it was when the plan was made: a writer asks for an exclusive
// kind's writer slot (maven became one after its plans first said otherwise),
// a reader never does. The slice is copied, as it may be shared with the plan
// this one was copied from.
func (p *cachePlan) currentExclusive() {
	p.Stores = append([]cacheStoreRef(nil), p.Stores...)
	for i := range p.Stores {
		t := cacheToolByKind(p.Stores[i].Kind)
		p.Stores[i].Exclusive = t != nil && t.Exclusive && !p.ReadOnly
	}
}

// applyCurrentRules brings a plan made at create up to the rules this engine
// applies at start, before the start replays it: its tier under the policy as
// it is now (legacyTrust) and the table's exclusive kinds. A store an engine
// before the sharing rule put in scope "global" for a tool that does not
// verify it on read is left out of the start instead (openCacheMounts,
// skipRetiredShare).
func (p *cachePlan) applyCurrentRules(pol cachePolicy) {
	if p == nil {
		return
	}
	p.legacyTrust(pol)
	p.currentExclusive()
}

// cacheReadOnly reports whether the container may only read the shared
// stores: its plan's tier, decided at create (cachePlan.legacyTrust for a plan
// an older engine made). A record with no plan at all (from an engine before
// plans) is read as such an engine read it, from its labels, and then like a
// legacy plan: never trusted under a policy whose default is untrusted.
func (c *dockerContainer) cacheReadOnly(pol cachePolicy) bool {
	var p cachePlan
	if c.Cache != nil {
		p = *c.Cache
	} else {
		tier, _, err := resolveCacheTrust(pol, c.Config, cacheOrigin{hostFacing: true})
		if err != nil {
			return true
		}
		p.Trust, p.ReadOnly = planTier(tier), tier != trustTrusted
	}
	p.legacyTrust(pol)
	return p.ReadOnly
}

// tier is the plan's tier by name (trustTrusted for "").
func (p *cachePlan) tier() string {
	if p == nil || p.Trust == "" {
		return trustTrusted
	}
	return p.Trust
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
	Scope string `json:"scope"`
	// Trust is the container's tier ("" trusted, trustUntrusted or
	// trustReadOnly), decided at create (resolveCacheTrust) whether or not
	// anything attaches: legacy alias volumes and docker cp follow it too.
	// ReadOnly is true for every tier but trusted.
	Trust        string                    `json:"trust,omitempty"`
	TrustFrom    string                    `json:"trustFrom,omitempty"`
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
	// Proxy is the dependency proxy decision per tool kind ("gomod", "npm",
	// "pnpm"): proxyInjected or why it was left out (decideProxies).
	Proxy map[string]string `json:"proxy,omitempty"`
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
	// NativeOnly: the store holds programs for the architecture that wrote
	// them, under names that do not say which (Playwright's browsers,
	// chromium-<revision>/), so a linux/amd64 container through emulation
	// gets none. Every other store is safe across architectures: Go's build
	// cache keys every entry by the toolchain and its target, the module,
	// npm and pnpm stores are content-addressed sources (pnpm keys its
	// side-effects cache by platform), and pip, uv, cargo, maven, gradle and
	// bun keep sources or name each binary artifact by its platform.
	NativeOnly bool
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
		Markers:    func(p string) []cacheMarker { return []cacheMarker{{p, true}} },
		Presence:   func(_ toolCtx, f *imageFacts) bool { return f.Binaries["playwright"] },
		NativeOnly: true},
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
	// DefaultTrust is the tier of a container that names none: "" (trusted,
	// the shipped default for a developer's own machine, where an unlabeled
	// docker run warms the caches) or trustUntrusted (a rig). Host-owned:
	// only the host writes cache-policy.json.
	DefaultTrust string `json:"defaultTrust,omitempty"`
	// ProxyUntrusted also injects goProxy and npmRegistry into containers
	// that only read the stores (untrusted and read-only tiers).
	ProxyUntrusted bool `json:"proxyUntrusted,omitempty"`
	// DockerSocket says which containers the host may hand the machine's
	// Docker API by binding docker.sock (engineSocketGrant): "" (only a
	// trusted one, the shipped default) or dockerSocketAny (a container of
	// any tier, on a rig whose owner accepts that its jobs share one
	// machine). It changes nothing about cache trust. Host-owned, like
	// DefaultTrust.
	DockerSocket string `json:"dockerSocket,omitempty"`
	// DefaultLimits says what a container that names no CPU, memory or
	// process limit gets: "" (one CPU, 1 GiB, 512 processes: the shipped
	// default) or defaultLimitsNone (no CPU quota, the machine's memory,
	// unlimitedPids processes: what a Docker daemon gives, for a machine
	// whose scheduler admits work by the machine's real load). Host-owned.
	DefaultLimits string `json:"defaultLimits,omitempty"`
}

// The values of cachePolicy.DefaultLimits as the host writes them;
// defaultLimitsJob is recorded as "".
const (
	defaultLimitsJob  = "job"
	defaultLimitsNone = "none"
)

// unlimitedByDefault reports whether a container naming no limit gets none.
func (p cachePolicy) unlimitedByDefault() bool { return p.DefaultLimits == defaultLimitsNone }

// The values of cachePolicy.DockerSocket as the host writes them;
// dockerSocketTrusted is recorded as "".
const (
	dockerSocketTrusted = "trusted"
	dockerSocketAny     = "any"
)

// socketForAnyTier reports whether an untrusted or read-only container may be
// given a delegated Docker socket.
func (p cachePolicy) socketForAnyTier() bool { return p.DockerSocket == dockerSocketAny }

// untrustedByDefault reports whether a container naming no tier is untrusted.
func (p cachePolicy) untrustedByDefault() bool { return p.DefaultTrust == trustUntrusted }

// failClosedCachePolicy stands in for a policy file that exists but cannot be
// read or parsed: the defaults, except that no container is trusted unless the
// host-facing socket asks for it. A missing file is the shipped default.
func failClosedCachePolicy() cachePolicy {
	pol := defaultCachePolicy()
	pol.DefaultTrust = trustUntrusted
	return pol
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

// validProxySetting accepts what the host's policy validation accepts
// (HVFMachineCachePolicy.validate): a GOPROXY list whose entries, separated
// by ',' or '|' as Go separates them, are each an http(s) URL, direct or off.
// A value the host accepted and the guest refused would make the whole
// policy fail closed.
func validProxySetting(v string) bool {
	if v == "" {
		return true
	}
	for _, part := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == '|' }) {
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
		DefaultTrust  *string   `json:"defaultTrust"`
		ProxyUntrust  *bool     `json:"proxyUntrusted"`
		DockerSocket  *string   `json:"dockerSocket"`
		DefaultLimits *string   `json:"defaultLimits"`
	}
	if err := json.Unmarshal(b, &wire); err != nil {
		return pol, err
	}
	if wire.DockerSocket != nil {
		switch *wire.DockerSocket {
		case "", dockerSocketTrusted:
		case dockerSocketAny:
			pol.DockerSocket = dockerSocketAny
		default:
			return failClosedCachePolicy(), fmt.Errorf("unknown dockerSocket %q (expected trusted or any)", *wire.DockerSocket)
		}
	}
	if wire.DefaultLimits != nil {
		switch *wire.DefaultLimits {
		case "", defaultLimitsJob:
		case defaultLimitsNone:
			pol.DefaultLimits = defaultLimitsNone
		default:
			return failClosedCachePolicy(), fmt.Errorf("unknown defaultLimits %q (expected job or none)", *wire.DefaultLimits)
		}
	}
	if wire.DefaultTrust != nil {
		switch *wire.DefaultTrust {
		case "", trustTrusted:
		case trustUntrusted:
			pol.DefaultTrust = trustUntrusted
		default:
			return failClosedCachePolicy(), fmt.Errorf("unknown defaultTrust %q (expected trusted or untrusted)", *wire.DefaultTrust)
		}
	}
	if wire.ProxyUntrust != nil {
		pol.ProxyUntrusted = *wire.ProxyUntrust
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

// The host config share as guest init reports it in MICROPOD_HOST_CONFIG:
// hostConfigMounted, hostConfigUnavailable (the host asked for it with
// mp.config=1 and it did not mount) or "" (none asked for: no host renders a
// policy, and the engine uses its built-in defaults).
const (
	hostConfigMounted     = "mounted"
	hostConfigUnavailable = "unavailable"
)

var hostConfigInit = os.Getenv("MICROPOD_HOST_CONFIG")

// policyLoader re-reads the policy file at most every 2 s, and only when its
// inode, size or mtime changed. Where no host config share was asked for, a
// missing file means defaults, so the engine also works on hosts that never
// write one. Everywhere else it fails closed (failClosedCachePolicy: whatever
// the host meant to write, it never trusts more containers than the
// host-facing socket asks for): a file that exists but is invalid, a share
// the host asked for that did not mount, and a missing file on a mounted
// share (the host renders the policy before every boot). An error reading a
// file that was there keeps the last policy read, as such an error says
// nothing about what the host wrote; with none read yet it fails closed too.
type policyLoader struct {
	mu      sync.Mutex
	path    string
	checked time.Time
	stamp   [3]int64
	pol     cachePolicy
	loaded  bool
	// good: pol was read from the file (not a default or a fail-closed stand-in).
	good bool
	// share stands in for hostConfigInit (tests); "" reads hostConfigInit.
	share string
}

func (l *policyLoader) shareState() string {
	if l.share != "" {
		return l.share
	}
	return strings.TrimSpace(hostConfigInit)
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
	share := l.shareState()
	// none is the policy without a file to read: the shipped default where no
	// share was asked for, else fail closed.
	none := func(why string, err error) cachePolicy {
		if share == "" {
			if l.loaded && l.stamp != [3]int64{} {
				log.Printf("cache policy %s unavailable, using defaults: %v", file, err)
			}
			l.pol = defaultCachePolicy()
		} else {
			if !l.loaded || l.stamp != [3]int64{} || l.good {
				log.Printf("cache policy %s %s, using defaults with defaultTrust untrusted: %v", file, why, err)
			}
			l.pol = failClosedCachePolicy()
		}
		l.loaded, l.stamp, l.good = true, [3]int64{}, false
		return l.pol
	}
	if share == hostConfigUnavailable {
		return none("not shared (the host config share did not mount)", errors.New(share))
	}
	var st syscall.Stat_t
	if err := syscall.Stat(file, &st); err != nil {
		if share != "" && l.good && !errors.Is(err, syscall.ENOENT) {
			log.Printf("cache policy %s unreadable, keeping the last policy read: %v", file, err)
			return l.pol
		}
		return none("unavailable", err)
	}
	stamp := [3]int64{int64(st.Ino), st.Size, st.Mtim.Nano()}
	if l.loaded && stamp == l.stamp {
		return l.pol
	}
	b, err := os.ReadFile(file)
	if err != nil {
		if share != "" && l.good && !errors.Is(err, os.ErrNotExist) {
			log.Printf("cache policy %s unreadable, keeping the last policy read: %v", file, err)
			return l.pol
		}
		if errors.Is(err, os.ErrNotExist) {
			return none("unavailable", err)
		}
	}
	l.stamp, l.loaded = stamp, true
	if err == nil {
		l.pol, err = parseCachePolicy(b)
	}
	l.good = err == nil
	if err != nil {
		log.Printf("cache policy %s invalid, using defaults with defaultTrust untrusted: %v", file, err)
		l.pol = failClosedCachePolicy()
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

// requestScope is the cache scope a create names: io.micropod.cache.scope, or
// MICROPOD_CACHE_SCOPE for env-only clients while the policy trusts by
// default. Under an untrusted default the request's environment names no
// scope, as it names no tier (resolveCacheTrust): it is the job's own, so a
// job could otherwise read another project's stores by naming its scope.
func requestScope(pol cachePolicy, spec dockerConfig) (string, bool) {
	if scope, ok := cacheLabel(spec.Labels, "io.micropod.cache.scope", "com.micropod.cache.scope"); ok {
		return scope, true
	}
	if pol.untrustedByDefault() {
		return "", false
	}
	return envLookup(spec.Env, "MICROPOD_CACHE_SCOPE", false)
}

// containerScope is the scope a container's caches belong to whether or not
// anything attaches: the one it names (requestScope), else the policy's
// default. A reader's alias volumes must name it (openMounts).
func containerScope(pol cachePolicy, spec dockerConfig) string {
	if scope, named := requestScope(pol, spec); named {
		return scope
	}
	return pol.DefaultScope
}

// cacheRequest is what a create brings besides its config and the image facts.
type cacheRequest struct {
	origin cacheOrigin
	// proxyUp reports whether a dependency proxy URL of the policy answers
	// now; nil counts every one as up (table tests).
	proxyUp func(url string) bool
	// projectNpmRegistry: a .npmrc of the project the container works in
	// (its working directory or above, inside the same workspace bind) sets
	// an unscoped registry, which an injected npm_config_registry would
	// override (projectNpmRegistry in docker_engine_linux.go), or an npmrc
	// npm reads (the global or the user config) comes from a bind or a volume
	// of the request and does (mountedConfigSets).
	projectNpmRegistry bool
	// projectGoProxy: a go env file Go reads (GOENV, else
	// $XDG_CONFIG_HOME/go/env or ~/.config/go/env) comes from a bind or a
	// volume of the request and sets GOPROXY (mountedConfigSets).
	projectGoProxy bool
	// emulated: the container's image is for another architecture and runs
	// through x86-64 emulation (cacheTool.NativeOnly).
	emulated bool
}

// hostFacingRequest is a create on the engine's own socket with every proxy up.
var hostFacingRequest = cacheRequest{origin: cacheOrigin{hostFacing: true}}

// decideCaches is decideCachesFor a create on the host-facing socket.
func decideCaches(pol cachePolicy, spec dockerConfig, facts imageFacts) (cachePlan, error) {
	return decideCachesFor(pol, spec, facts, hostFacingRequest)
}

// decideCachesFor is the whole attach decision. It is pure: everything it
// reads is in its arguments (plus privateRootless and cacheDiskUnavailable),
// so it is table-tested directly. The trust tier is decided first and kept in
// every plan, attached or not: alias volumes and docker cp follow it too.
func decideCachesFor(pol cachePolicy, spec dockerConfig, facts imageFacts, req cacheRequest) (cachePlan, error) {
	plan := cachePlan{Tools: map[string]cacheToolState{}, PolicyDigest: pol.digest()}
	tier, from, err := resolveCacheTrust(pol, spec, req.origin)
	if err != nil {
		return plan, err
	}
	plan.Trust, plan.TrustFrom, plan.ReadOnly = planTier(tier), from, tier != trustTrusted
	// A container created through a container's socket is in its creator's
	// scope, whether or not anything attaches (alias volumes follow
	// plan.Scope, volumeRules): naming another would open that project's
	// stores to it, as MICROPOD_CACHE_SCOPE would under an untrusted default.
	if !req.origin.hostFacing {
		if named, ok := requestScope(pol, spec); ok && named != req.origin.creatorScope {
			return plan, fail(403, fmt.Sprintf("a container created through a container's Docker socket is in that container's cache scope %q; it cannot name scope %q", req.origin.creatorScope, named))
		}
		plan.Scope = req.origin.creatorScope
	}
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
	scope, named := requestScope(pol, spec)
	if !req.origin.hostFacing {
		// The creator's (checked above), which the host's policy admitted
		// for the creator; a policy since narrowed attaches nothing.
		scope = req.origin.creatorScope
		if scope != "" && !pol.allows(scope) {
			plan.Reason = planScopeNotAllowed
			return plan, nil
		}
	} else if named {
		if !scopeName.MatchString(scope) || !pol.allows(scope) {
			return plan, fail(400, "cache scope not allowed by machine policy")
		}
	} else {
		scope = pol.DefaultScope
		// The host refuses a default scope its allow-list does not admit;
		// a policy file that has one anyway attaches nothing.
		if scope != "" && !pol.allows(scope) {
			plan.Reason = planScopeNotAllowed
			return plan, nil
		}
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
	// (1b) trust & read-only isolation (resolved above): an untrusted or
	// read-only plan gets warm reads through an ephemeral per-container
	// overlayfs upperdir (or a fail-closed read-only bind), never mutating
	// trusted stores. Every store of such a plan is held as a reader
	// (openCacheMounts): locked so the janitor and the crash discard leave
	// it alone, never marked dirty.
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
		if t.NativeOnly && req.emulated {
			skip(skipEmulatedPlatform, "")
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
		// (7b) Optional rig dependency proxy wiring (depproxy), guarded
		// (decideProxy): never over a setting of the request, the image or
		// the project, never when the proxy does not answer, never into a
		// reader tier unless the policy says so; Go keeps a direct fallback.
		if kv := req.decideProxy(pol, &plan, spec, t.Kind, merged, &facts, home); kv != "" {
			env = append(env, kv)
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

// decideProxy decides the policy's dependency proxy for one tool of a plan
// and returns the KEY=VALUE to inject, or "". It records the decision in
// plan.Proxy. The Go proxy goes with gomod; the npm registry with npm and
// pnpm (one decision, both get it). A setting of the request or the image
// always wins: a variable, a config file the request names
// (npm_config_userconfig, npm_config_globalconfig, GOENV), or a config file
// that sets it in the image or in a mount of the request (an npmrc
// registry=, a go env file GOPROXY=). A reader tier gets nothing unless the
// policy sets proxyUntrusted. A proxy that does not answer the create-time
// health check is left out, and so is one that does not answer at a later
// start (cachePlan.unreachableProxies), so its outage never fails an
// install. The injected GOPROXY always ends in "|direct" (goProxyWithDirect).
// A config file that appears after create (a clone into a volume, a cd into a
// subproject with its own .npmrc) is not seen.
func (req cacheRequest) decideProxy(pol cachePolicy, plan *cachePlan, spec dockerConfig, kind string, merged []string, facts *imageFacts, home string) string {
	workDir := spec.WorkingDir
	var key, list, probe string
	switch {
	case kind == "gomod" && pol.GoProxy != "":
		key, list = "GOPROXY", goProxyWithDirect(pol.GoProxy)
		probe = firstProxyURL(pol.GoProxy)
	case (kind == "npm" || kind == "pnpm") && pol.NpmRegistry != "":
		key, list, probe = "npm_config_registry", pol.NpmRegistry, pol.NpmRegistry
		// One decision for both npm and pnpm.
		for _, other := range []string{"npm", "pnpm"} {
			if why, done := plan.Proxy[other]; done && other != kind {
				plan.setProxy(kind, why)
				if why == proxyInjected {
					return key + "=" + list
				}
				return ""
			}
		}
	default:
		return ""
	}
	why := ""
	switch {
	case plan.ReadOnly && !pol.ProxyUntrusted:
		why = proxySkipReader
	case envSet(merged, key, kind != "gomod"):
		why = proxySkipRequest
	case key == "npm_config_registry" && (envSet(spec.Env, "npm_config_userconfig", true) || envSet(spec.Env, "npm_config_globalconfig", true)):
		// The request points npm at config files of its own.
		why = proxySkipRequest
	case key == "GOPROXY" && requestGoEnvFile(spec.Env):
		why = proxySkipRequest
	case key == "npm_config_registry" && (req.projectNpmRegistry || facts.imageNpmRegistry(home, workDir)):
		why = proxySkipNpmrc
	case key == "GOPROXY" && (req.projectGoProxy || facts.imageGoProxy(merged, home)):
		why = proxySkipGoEnv
	case probe != "" && req.proxyUp != nil && !req.proxyUp(probe):
		why = proxySkipUnreachable
	}
	if why != "" {
		plan.setProxy(kind, why)
		return ""
	}
	plan.setProxy(kind, proxyInjected)
	return key + "=" + list
}

// proxyKey is the variable a tool kind's dependency proxy is injected as.
func proxyKey(kind string) string {
	switch kind {
	case "gomod":
		return "GOPROXY"
	case "npm", "pnpm":
		return "npm_config_registry"
	}
	return ""
}

// unreachableProxies is a start's own check of the proxies its create
// injected (kind -> proxySkipUnreachable for each that does not answer now).
// The create's decision is otherwise replayed, but a container created while
// the proxy answered and started again while it does not (a restart policy, a
// machine reboot, `docker compose start`) would fail every npm install (npm
// has no fallback) and every Go fetch the proxy cannot serve; that start runs
// on the tools' own registries instead, and the next start checks again.
func (p *cachePlan) unreachableProxies(up func(string) bool) map[string]string {
	if p == nil || up == nil {
		return nil
	}
	var down map[string]string
	for kind, why := range p.Proxy {
		key := proxyKey(kind)
		if why != proxyInjected || key == "" {
			continue
		}
		value, ok := envLookup(p.ToolEnv[kind], key, false)
		if !ok {
			continue
		}
		if key == "GOPROXY" {
			value = firstProxyURL(value)
		}
		if value == "" || up(value) {
			continue
		}
		if down == nil {
			down = map[string]string{}
		}
		down[kind] = proxySkipUnreachable
	}
	return down
}

// withoutProxies is env without the variables of the proxies down names.
func withoutProxies(env []string, down map[string]string) []string {
	if len(down) == 0 {
		return env
	}
	drop := map[string]bool{}
	for kind := range down {
		drop[proxyKey(kind)] = true
	}
	out := make([]string, 0, len(env))
	for _, kv := range env {
		if k, _, _ := strings.Cut(kv, "="); !drop[k] {
			out = append(out, kv)
		}
	}
	return out
}

func (p *cachePlan) setProxy(kind, why string) {
	if p.Proxy == nil {
		p.Proxy = map[string]string{}
	}
	p.Proxy[kind] = why
}

// envSet reports whether env sets key at all (an empty value is a setting).
func envSet(env []string, key string, fold bool) bool {
	_, ok := envLookup(env, key, fold)
	return ok
}

// goProxyWithDirect is the GOPROXY a container gets for the policy's list:
// "off" entries dropped (a container always keeps a way to the module's
// origin) and the list ending in "|direct", so Go falls back to the origin on
// any proxy error, not only on 404 and 410: "|direct" is appended, and a
// final direct the list reached with ',' (`http://proxy/go,direct`, the
// usual idiom) is reached with '|' instead, since a proxy that is down
// answers neither 404 nor 410.
func goProxyWithDirect(list string) string {
	type entry struct{ sep, value string } // sep: what Go reaches value after
	var out []entry
	sep := ""
	for len(list) > 0 {
		i := strings.IndexAny(list, ",|")
		value, next := list, ""
		if i >= 0 {
			value, next = list[:i], list[i:i+1]
			list = list[i+1:]
		} else {
			list = ""
		}
		value = strings.TrimSpace(value)
		if value == "" || value == "off" {
			continue
		}
		out = append(out, entry{sep, value})
		if next != "" {
			sep = next
		}
	}
	switch {
	case len(out) == 0:
		return "direct"
	case out[len(out)-1].value != "direct":
		out = append(out, entry{"|", "direct"})
	case len(out) > 1:
		out[len(out)-1].sep = "|"
	}
	var b strings.Builder
	for _, e := range out {
		b.WriteString(e.sep + e.value)
	}
	return b.String()
}

// firstProxyURL is the first http(s) entry of a GOPROXY list, the one the
// health check asks.
func firstProxyURL(list string) string {
	for _, entry := range strings.FieldsFunc(list, func(r rune) bool { return r == ',' || r == '|' }) {
		if entry = strings.TrimSpace(entry); strings.HasPrefix(entry, "http://") || strings.HasPrefix(entry, "https://") {
			return entry
		}
	}
	return ""
}

// requestGoEnvFile reports whether the request names a go env file of its own
// (GOENV=<path>; GOENV=off reads none).
func requestGoEnvFile(env []string) bool {
	v, ok := envLookup(env, "GOENV", false)
	return ok && strings.TrimSpace(v) != "" && strings.TrimSpace(v) != "off"
}

// goEnvCandidates are the go env files Go could read for some container of an
// image with this environment (image then request) and passwd: GOENV when it
// names a file (none for off), else $XDG_CONFIG_HOME/go/env and
// ~/.config/go/env of every plausible HOME (as npmrcCandidates finds them).
func goEnvCandidates(env []string, passwd []passwdEntry, user string) []string {
	if v, ok := envLookup(env, "GOENV", false); ok {
		if v = strings.TrimSpace(v); path.IsAbs(v) {
			return []string{path.Clean(v)}
		}
		return nil
	}
	set := map[string]bool{}
	if v, ok := envLookup(env, "XDG_CONFIG_HOME", false); ok && path.IsAbs(v) {
		set[path.Join(path.Clean(v), "go/env")] = true
	}
	for _, h := range candidateHomes(env, passwd, user) {
		set[path.Join(h, ".config/go/env")] = true
	}
	out := make([]string, 0, len(set))
	for p := range set {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// goEnvSetsProxy reports whether a go env file (KEY=VALUE lines, as `go env
// -w` writes them) sets GOPROXY, to any value: off included.
func goEnvSetsProxy(b []byte) bool {
	for _, line := range strings.Split(string(b), "\n") {
		if key, _, ok := strings.Cut(strings.TrimSpace(line), "="); ok && strings.TrimSpace(key) == "GOPROXY" {
			return true
		}
	}
	return false
}

// npmrcSetsRegistry reports whether an npmrc file sets the unscoped registry
// (`registry=…`, any case and spacing). A scoped `@scope:registry=` is not
// overridden by npm_config_registry and does not count.
func npmrcSetsRegistry(b []byte) bool {
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line[0] == '#' || line[0] == ';' {
			continue
		}
		key, _, ok := strings.Cut(line, "=")
		if ok && strings.EqualFold(strings.TrimSpace(key), "registry") {
			return true
		}
	}
	return false
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
// scheduler, which reaches the guest only over the worker owner's private
// vsock (as host-facing as the Docker socket), so neither the Docker
// allow-list nor the mode applies to it; only env-mode tools attach (one
// bind at /micropod/cache), and the uid comes from the image facts, else 0.
// trust is the job's own classification by the scheduler ("trusted" writes
// the stores; anything else only reads them), never a label of the job's
// image, and the policy's defaultTrust does not lower it: the scheduler is
// the host asking.
func decideJobCaches(pol cachePolicy, scope, trust string, facts imageFacts, proxyUp func(string) bool) cachePlan {
	spec := dockerConfig{Labels: map[string]string{}}
	if trust != trustTrusted {
		spec.Labels["io.micropod.cache.trust"] = trustUntrusted
	} else {
		spec.Labels["io.micropod.cache.trust"] = trustTrusted
	}
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
	plan, err := decideCachesFor(jobPol, spec, facts, cacheRequest{origin: cacheOrigin{hostFacing: true}, proxyUp: proxyUp})
	if err != nil {
		return cachePlan{Scope: scope, Reason: err.Error(), Tools: map[string]cacheToolState{}}
	}
	return plan
}
