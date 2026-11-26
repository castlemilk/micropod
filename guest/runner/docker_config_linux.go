package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const engineRoot = "/var/lib/micropod/engine"

var dockerName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$`)

type dockerMount struct {
	Type, Source, Target string
	ReadOnly             bool
}
type dockerHost struct {
	PortBindings                          portMap
	PublishAllPorts                       bool
	Binds                                 []string
	Mounts                                []dockerMount
	AutoRemove, ReadonlyRootfs            bool
	Memory, NanoCpus, CpuQuota, CpuPeriod int64
	PidsLimit                             *int64
	NetworkMode                           string
	CapDrop                               []string
}
type dockerConfig struct {
	Aliases                           []string `json:"MicropodAliases,omitempty"`
	EndpointName                      string   `json:"MicropodEndpointName,omitempty"`
	EndpointID                        string   `json:"MicropodEndpointID,omitempty"`
	ExposedPorts                      map[string]struct{}
	Image, WorkingDir, User, Hostname string
	Entrypoint, Cmd, Env              []string
	Labels                            map[string]string
	HostConfig                        dockerHost
	AttachStdout, AttachStderr        bool
}

// The CLI sends many empty defaults even for a plain "docker run". A meaningful
// unsupported option must fail before acquiring a pod, especially an isolation option.
func emptyOption(v any) bool {
	switch x := v.(type) {
	case nil:
		return true
	case bool:
		return !x
	case float64:
		return x == 0
	case string:
		return x == ""
	case map[string]any:
		for _, e := range x {
			if !emptyOption(e) {
				return false
			}
		}
		return true
	case []any:
		return len(x) == 0
	default:
		return false
	}
}
func obj(v any) map[string]any { m, _ := v.(map[string]any); return m }
func supportedOptions(m map[string]any, names string) error {
	for k, v := range m {
		if !strings.Contains(" "+names+" ", " "+k+" ") && !emptyOption(v) {
			return fmt.Errorf("unsupported Docker option %s", k)
		}
	}
	return nil
}
func parseDockerConfig(body []byte) (dockerConfig, error) {
	var spec dockerConfig
	var raw map[string]any
	if err := json.Unmarshal(body, &spec); err != nil {
		return spec, err
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return spec, err
	}
	if err := supportedOptions(raw, "ExposedPorts Image WorkingDir User Entrypoint Cmd Env Labels HostConfig AttachStdout AttachStderr Hostname NetworkingConfig"); err != nil {
		return spec, err
	}
	if netcfg, ok := raw["NetworkingConfig"].(map[string]any); ok {
		if err := supportedOptions(netcfg, "EndpointsConfig"); err != nil {
			return spec, err
		}
		endpoints := obj(netcfg["EndpointsConfig"])
		if len(endpoints) > 1 {
			return spec, errors.New("multiple endpoint attachments are unavailable")
		}
		for name, endpoint := range endpoints {
			selected := networkName(spec.HostConfig.NetworkMode)
			fields := obj(endpoint)
			if err := supportedOptions(fields, "NetworkID Aliases"); err != nil {
				return spec, err
			}
			id, _ := fields["NetworkID"].(string)
			spec.EndpointName = name
			if builtinNetwork(selected) && networkName(name) != selected && id != selected {
				return spec, errors.New("endpoint does not match selected network")
			}
			if builtinNetwork(selected) && id != "" && id != networkID(selected) {
				return spec, errors.New("endpoint identity differs")
			}
			spec.EndpointID = id
			if list, ok := fields["Aliases"].([]any); ok {
				if builtinNetwork(selected) && len(list) > 0 {
					return spec, errors.New("aliases require a named network")
				}
				if len(list) > 64 {
					return spec, errors.New("too many network aliases")
				}
				for _, v := range list {
					alias, ok := v.(string)
					if !ok || !dockerName.MatchString(alias) {
						return spec, errors.New("invalid network alias")
					}
					spec.Aliases = append(spec.Aliases, alias)
				}
			}
		}
	}
	if h, ok := raw["HostConfig"].(map[string]any); ok {
		// These sentinel values are sent by the Docker CLI for an ordinary container.
		if policy := obj(h["RestartPolicy"]); policy["Name"] == "no" {
			delete(policy, "Name")
		}
		if size, ok := h["ConsoleSize"].([]any); ok && len(size) == 2 && emptyOption(size[0]) && emptyOption(size[1]) {
			delete(h, "ConsoleSize")
		}
		if h["MemorySwappiness"] == float64(-1) {
			delete(h, "MemorySwappiness")
		}
		if err := supportedOptions(h, "PortBindings PublishAllPorts Binds Mounts AutoRemove ReadonlyRootfs Memory NanoCpus CpuQuota CpuPeriod PidsLimit NetworkMode CapDrop"); err != nil {
			return spec, err
		}
		if mounts, ok := h["Mounts"].([]any); ok {
			for _, v := range mounts {
				if obj, ok := v.(map[string]any); ok {
					if vo, ok := obj["VolumeOptions"].(map[string]any); ok && obj["Type"] == "volume" {
						if err := supportedOptions(vo, "NoCopy"); err != nil {
							return spec, err
						}
						delete(obj, "VolumeOptions")
					}
					if err := supportedOptions(obj, "Type Source Target ReadOnly"); err != nil {
						return spec, err
					}
				}
			}
		}
	}
	if _, err := spec.requestedPorts(); err != nil {
		return spec, err
	}
	if spec.Image == "" {
		return spec, errors.New("image is required")
	}
	h := spec.HostConfig
	if !dockerName.MatchString(networkName(h.NetworkMode)) || h.NetworkMode == "host" {
		return spec, errors.New("invalid network mode")
	}
	for _, cap := range h.CapDrop {
		if !strings.EqualFold(cap, "all") {
			return spec, errors.New("only cap-drop ALL is available")
		}
	}
	if spec.WorkingDir != "" && !filepath.IsAbs(spec.WorkingDir) {
		return spec, errors.New("working directory must be absolute")
	}
	if h.Memory < 0 || h.NanoCpus < 0 || h.NanoCpus > 1e12 || h.CpuQuota < -1 || h.CpuPeriod < 0 || h.PidsLimit != nil && *h.PidsLimit < 0 || h.NanoCpus != 0 && (h.CpuQuota != 0 || h.CpuPeriod != 0) {
		return spec, errors.New("invalid requested resources")
	}
	for _, kv := range spec.Env {
		name, _, ok := strings.Cut(kv, "=")
		if !ok || name == "" {
			return spec, errors.New("expected KEY=VALUE in environment")
		}
	}
	if err := validateDockerUser(spec.User); err != nil {
		return spec, err
	}
	return spec, nil
}

// validateDockerUser accepts uid, name, uid:gid, name:group and mixtures.
// Names are resolved against the image at create (see runAsFor).
func validateDockerUser(user string) error {
	if user == "" {
		return nil
	}
	u, g, has := strings.Cut(user, ":")
	if !validUserToken(u) || has && !validUserToken(g) {
		return errors.New("invalid user: expected name|uid[:group|gid]")
	}
	return nil
}

// dockerUser maps --user to CRI ids. Numeric parts need no facts; names are
// resolved through the image's passwd/group in facts.
func dockerUser(user string, facts *imageFacts) (*cri.Int64Value, *cri.Int64Value, error) {
	if user == "" {
		return nil, nil, nil
	}
	u, g, has := strings.Cut(user, ":")
	_, uNum := numericID(u)
	_, gNum := numericID(g)
	if uNum && (!has || gNum) {
		uid, _ := numericID(u)
		if !has {
			return &cri.Int64Value{Value: int64(uid)}, nil, nil
		}
		gid, _ := numericID(g)
		return &cri.Int64Value{Value: int64(uid)}, &cri.Int64Value{Value: int64(gid)}, nil
	}
	if facts == nil || !facts.OK {
		return nil, nil, errors.New("user and group names need the image's passwd and group files")
	}
	uid, gid, _, err := resolveUser(user, facts)
	if err != nil {
		return nil, nil, err
	}
	return &cri.Int64Value{Value: int64(uid)}, &cri.Int64Value{Value: int64(gid)}, nil
}

// runAsFor resolves a --user containing names once, at create. A purely
// numeric user needs no record (configure parses it). Without image facts a
// user name is left to containerd (RunAsUsername); a group name then fails.
func runAsFor(user string, facts *imageFacts) (*runAsUser, error) {
	if user == "" {
		return nil, nil
	}
	u, g, has := strings.Cut(user, ":")
	uid, uNum := numericID(u)
	gid, gNum := numericID(g)
	if uNum && (!has || gNum) {
		return nil, nil
	}
	if facts != nil && facts.OK {
		ruid, rgid, err := dockerUser(user, facts)
		if err != nil {
			return nil, err
		}
		a, b := uint32(ruid.Value), uint32(rgid.Value)
		return &runAsUser{UID: &a, GID: &b}, nil
	}
	if has && !gNum {
		return nil, fmt.Errorf("unable to find group %s: image facts unavailable", g)
	}
	r := &runAsUser{}
	if uNum {
		r.UID = &uid
	} else {
		r.Username = u
	}
	if has {
		r.GID = &gid
	}
	return r, nil
}

func (c dockerConfig) mounts() ([]dockerMount, error) {
	mounts := append([]dockerMount(nil), c.HostConfig.Mounts...)
	for _, b := range c.HostConfig.Binds {
		p := strings.Split(b, ":")
		if len(p) < 2 || len(p) > 3 {
			return nil, errors.New("expected source:destination[:ro|rw]")
		}
		m := dockerMount{Source: p[0], Target: p[1], Type: "volume"}
		if filepath.IsAbs(m.Source) {
			m.Type = "bind"
		}
		if len(p) == 3 {
			switch p[2] {
			case "ro":
				m.ReadOnly = true
			case "rw":
			default:
				return nil, errors.New("unsupported mount mode")
			}
		}
		mounts = append(mounts, m)
	}
	seen := map[string]bool{}
	for _, m := range mounts {
		if !filepath.IsAbs(m.Target) || filepath.Clean(m.Target) != m.Target || m.Target == "/" || seen[m.Target] {
			return nil, errors.New("invalid or duplicate mount target")
		}
		seen[m.Target] = true
		if m.Type == "volume" && dockerName.MatchString(m.Source) {
			continue
		}
		if m.Type == "bind" && filepath.IsAbs(m.Source) && filepath.Clean(m.Source) == m.Source {
			continue
		}
		return nil, errors.New("expected a local named volume or a file in the shared workspace")
	}
	return mounts, nil
}

// Resolve through a pinned directory and retain the exact inode until CRI has
// started the container. A renamed workspace path cannot change the bind source.
func openMount(root, path string) (*os.File, error) {
	if root == "" {
		return nil, errors.New("configure MICROPOD_CI_WORKSPACE for bind mounts")
	}
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return nil, errors.New("bind source is outside the configured workspace")
	}
	dir, err := os.Open(root)
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	fd, err := unix.Openat2(int(dir.Fd()), rel, &unix.OpenHow{Flags: unix.O_PATH | unix.O_CLOEXEC, Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_MAGICLINKS})
	if err != nil {
		return nil, fmt.Errorf("bind source %s: %w", path, err)
	}
	f := os.NewFile(uintptr(fd), path)
	st, err := f.Stat()
	if err != nil || (!st.IsDir() && !st.Mode().IsRegular()) {
		f.Close()
		return nil, errors.New("bind source must be a directory or regular file")
	}
	return f, nil
}

// A volume named micropod-ci-scoped-<scope>-<kind> (any table kind) is an
// alias of the auto-attached store scopes/<scope>/<kind>. The volume
// directory is a removable Docker reference; the bytes belong to the store.
func sharedCachePath(name string) (string, bool) {
	scope, kind, ok := legacyCacheVolume(name)
	if !ok {
		return "", false
	}
	return filepath.Join(cacheRoot, "scopes", scope, kind), true
}

// openStoreBeneath opens a store path below cacheRoot as an O_PATH bind source
// without following any symlink a container may have planted.
func openStoreBeneath(p string) (*os.File, error) {
	rel, err := filepath.Rel(cacheRoot, p)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return nil, errors.New("cache store is outside the cache root")
	}
	root, err := os.Open(cacheRoot)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	fd, err := unix.Openat2(int(root.Fd()), rel, &unix.OpenHow{Flags: unix.O_PATH | unix.O_CLOEXEC, Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS})
	if err != nil {
		return nil, fmt.Errorf("cache store %s: %w", p, err)
	}
	return os.NewFile(uintptr(fd), p), nil
}

func fdPath(f *os.File) string { return fmt.Sprintf("/proc/%d/fd/%d", os.Getpid(), f.Fd()) }

// cacheAttachment is what one start of a container gets from its plan.
type cacheAttachment struct {
	files   []*os.File // pinned bind sources and unit locks; closed when the container exits
	mounts  []*cri.Mount
	env     []string
	units   []string          // locked and stamped units
	skipped map[string]string // tool -> reason, for this start only
}

func (a *cacheAttachment) skip(kind, reason string) {
	if a.skipped == nil {
		a.skipped = map[string]string{}
	}
	a.skipped[kind] = reason
}

// openCacheMounts replays a plan computed at create: it verifies each store,
// takes the unit locks and opens every bind source. It never fails a start; a
// store that cannot be prepared is dropped with its variables for this start.
func openCacheMounts(plan *cachePlan, shimRoot string) cacheAttachment {
	var a cacheAttachment
	if !plan.attached() {
		return a
	}
	dropAll := func(reason string, err error) cacheAttachment {
		log.Printf("cache scope %s: %v", plan.Scope, err)
		closeMounts(a.files)
		a = cacheAttachment{}
		for _, st := range plan.Stores {
			a.skip(st.Kind, reason)
		}
		a.env = plan.env(a.skipped)
		return a
	}
	l, err := openCacheLayout()
	if err != nil {
		return dropAll(skipStoreFailed, err)
	}
	defer l.Close()
	scopeDir, err := openScope(l, plan.Scope)
	if err != nil {
		return dropAll(skipStoreFailed, err)
	}
	a.files = append(a.files, scopeDir)
	stores := map[string]*os.File{}
	for _, st := range plan.Stores {
		lock, err := unitLock(plan.Scope, st.Unit, st.Exclusive)
		if err != nil {
			reason := skipStoreFailed
			if errors.Is(err, unix.EWOULDBLOCK) {
				reason = skipBusyExclusive
			}
			a.skip(st.Kind, reason)
			continue
		}
		dir, err := openStore(l, plan.Scope, scopeDir, st.Kind, st.UID)
		if err != nil {
			log.Printf("cache store %s/%s: %v", plan.Scope, st.Unit, err)
			lock.Close()
			a.skip(st.Kind, skipStoreFailed)
			continue
		}
		a.files = append(a.files, lock, dir)
		stores[st.Unit] = dir
		a.units = append(a.units, st.Unit)
	}
	type opened struct {
		m   cacheMount
		src *os.File
	}
	var binds []opened
	for i, m := range plan.Mounts {
		if m.Kind != "" {
			if _, gone := a.skipped[m.Kind]; gone {
				continue
			}
		}
		var src *os.File
		var err error
		switch {
		case m.Shim:
			dir := filepath.Join(shimRoot, strconv.Itoa(i))
			if err = os.MkdirAll(dir, 0755); err == nil {
				err = errors.Join(os.Chown(dir, int(plan.UID), int(plan.GID)), os.Chmod(dir, 0755))
			}
			if err == nil {
				src, err = os.Open(dir)
			}
			if err != nil {
				// Without the shim crun creates the parent root-owned; the
				// bind below it still works.
				log.Printf("cache shim %s: %v", m.Target, err)
				continue
			}
			a.files = append(a.files, src)
		case m.Kind == "":
			src = scopeDir
		default:
			base := stores[m.Unit]
			switch {
			case base == nil:
				err = fmt.Errorf("store %s not opened", m.Unit)
			case m.Sub == "":
				src = base
			case m.File:
				src, err = ensureFileAt(base, m.Sub, 0666)
			default:
				src, err = ensureDirAt(base, m.Sub, 0777, true, l.trash)
			}
			if err != nil {
				// A path-mode tool that loses one of its binds loses all of them.
				log.Printf("cache mount %s: %v", m.Target, err)
				a.skip(m.Kind, skipStoreFailed)
				continue
			}
			if src != base {
				a.files = append(a.files, src)
			}
		}
		binds = append(binds, opened{m, src})
	}
	scopeUsed := false
	for _, st := range plan.Stores {
		if _, gone := a.skipped[st.Kind]; !gone && plan.Tools[st.Kind].Mode == "env" {
			scopeUsed = true
		}
	}
	for _, b := range binds {
		if b.m.Kind == "" && !b.m.Shim && !scopeUsed {
			continue
		}
		if _, gone := a.skipped[b.m.Kind]; gone && b.m.Kind != "" {
			continue
		}
		a.mounts = append(a.mounts, &cri.Mount{HostPath: fdPath(b.src), ContainerPath: b.m.Target})
	}
	a.env = plan.env(a.skipped)
	for _, u := range a.units {
		if err := touchUsed(plan.Scope, u); err != nil {
			log.Printf("cache stamp %s/%s: %v", plan.Scope, u, err)
		}
	}
	return a
}

func (s *dockerEngine) openMounts(spec dockerConfig, createVolumes bool, cleanupSocket string) ([]*os.File, []*cri.Mount, error) {
	requests, err := spec.mounts()
	if err != nil {
		return nil, nil, err
	}
	var files []*os.File
	var mounts []*cri.Mount
	for _, m := range requests {
		if privateRootless() && m.Type == "bind" && (m.Source == "/var/run/docker.sock" || m.Source == "/run/docker.sock") && m.Target == "/var/run/docker.sock" {
			mounts = append(mounts, &cri.Mount{HostPath: clientSocket(dockerSocket, "docker.sock"), ContainerPath: m.Target, Readonly: m.ReadOnly})
			continue
		}
		if spec.cleanupMount(m) {
			if !createVolumes && cleanupSocket == "" {
				err = errors.New("missing session cleanup socket")
				break
			}
			if !createVolumes {
				mounts = append(mounts, &cri.Mount{HostPath: cleanupSocket, ContainerPath: m.Target, Readonly: true})
			}
			continue
		}
		root, source := s.workspace, m.Source
		if privateRootless() && m.Type == "bind" && m.Source == "/runner/externals" && m.ReadOnly {
			root = "/runner/externals"
		}
		if m.Type == "volume" {
			root = filepath.Join(engineRoot, "volumes")
			source = filepath.Join(root, m.Source)
			if createVolumes {
				if err = ensureVolume(m.Source, nil); err != nil {
					break
				}
			}
		}
		var f *os.File
		if scope, kind, shared := legacyCacheVolume(m.Source); m.Type == "volume" && shared {
			var store string
			if store, err = ensureStore(scope, kind, nil); err != nil {
				break
			}
			f, err = openStoreBeneath(store)
		} else {
			f, err = openMount(root, source)
		}
		if err != nil {
			break
		}
		files = append(files, f)
		mounts = append(mounts, &cri.Mount{HostPath: fdPath(f), ContainerPath: m.Target, Readonly: m.ReadOnly})
	}
	if err != nil {
		closeMounts(files)
		return nil, nil, err
	}
	return files, mounts, nil
}
func closeMounts(files []*os.File) {
	for _, f := range files {
		f.Close()
	}
}

// containerExtras is what the engine adds to a request at start: the cache
// plan's variables and the --user resolved at create.
type containerExtras struct {
	Env   []string
	RunAs *runAsUser
}

func (s dockerConfig) configure(c *cri.ContainerConfig, mounts []*cri.Mount, extra containerExtras) error {
	c.Command, c.Args, c.WorkingDir = s.Entrypoint, s.Cmd, s.WorkingDir
	c.Mounts = mounts
	// The plan only sets variables the request left unset, except GOFLAGS,
	// whose merged value already contains the request's flags.
	for _, kv := range mergeEnv(s.Env, extra.Env) {
		k, v, _ := strings.Cut(kv, "=")
		c.Envs = append(c.Envs, &cri.KeyValue{Key: k, Value: v})
	}
	sec := c.Linux.SecurityContext
	sec.ReadonlyRootfs = s.HostConfig.ReadonlyRootfs
	var err error
	if r := extra.RunAs; r != nil {
		sec.RunAsUser, sec.RunAsGroup = nil, nil
		if r.UID != nil {
			sec.RunAsUser = &cri.Int64Value{Value: int64(*r.UID)}
		} else {
			sec.RunAsUsername = r.Username
		}
		if r.GID != nil {
			sec.RunAsGroup = &cri.Int64Value{Value: int64(*r.GID)}
		}
	} else if sec.RunAsUser, sec.RunAsGroup, err = dockerUser(s.User, nil); err != nil {
		return err
	}
	// Trusted service images initialize files and switch to their packaged service UID.
	sec.Capabilities.AddCapabilities = []string{"CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "SETGID", "SETUID"}
	if len(s.HostConfig.CapDrop) > 0 {
		sec.Capabilities.AddCapabilities = nil
	}
	r := c.Linux.Resources
	h := s.HostConfig
	if h.Memory > 0 {
		r.MemoryLimitInBytes = h.Memory
	}
	if h.CpuPeriod > 0 {
		r.CpuPeriod = h.CpuPeriod
	}
	// Docker's explicit -1 removes the child quota. Zero inherits the job
	// default; the VM and ancestor cgroups bound both cases.
	if h.CpuQuota != 0 {
		r.CpuQuota = h.CpuQuota
	}
	if h.NanoCpus > 0 {
		r.CpuQuota = max(1000, h.NanoCpus/10000)
		r.CpuPeriod = 100000
	}
	if h.PidsLimit != nil && *h.PidsLimit > 0 {
		r.Unified["pids.max"] = strconv.FormatInt(*h.PidsLimit, 10)
	}
	return nil
}
