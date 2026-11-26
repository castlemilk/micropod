package main

import (
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"maps"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const engineRoot = "/var/lib/micropod/engine"
const tcpQueueSysctl = "net.ipv4.tcp_limit_output_bytes"
const dockerCPUGroupLabel = "io.micropod.ci.cpu-group"

var dockerName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$`)

type dockerMount struct {
	Type, Source, Target string
	ReadOnly             bool
	tmpfs                *dockerTmpfsOptions
}
type dockerHost struct {
	PortBindings                          portMap
	PublishAllPorts                       bool
	Binds                                 []string
	Mounts                                []dockerMount
	Tmpfs                                 map[string]string `json:",omitempty"`
	AutoRemove, ReadonlyRootfs            bool
	ConsoleSize                           []uint16 `json:",omitempty"`
	Memory, NanoCpus, CpuQuota, CpuPeriod int64
	CpuShares                             int64  `json:",omitempty"`
	CpusetCpus                            string `json:",omitempty"`
	PidsLimit                             *int64
	NetworkMode                           string
	LogConfig                             dockerLogConfig
	CapDrop                               []string
	Sysctls                               map[string]string `json:",omitempty"`
}
type dockerConfig struct {
	Aliases                                 []string                         `json:"MicropodAliases,omitempty"`
	Endpoints                               map[string]dockerEndpointOptions `json:"-"`
	ExposedPorts                            map[string]struct{}
	Image, WorkingDir, User, Hostname       string
	Entrypoint, Cmd, Env                    []string
	Healthcheck                             *dockerHealthConfig `json:",omitempty"`
	Shell                                   []string            `json:",omitempty"`
	Labels                                  map[string]string
	HostConfig                              dockerHost
	AttachStdin, AttachStdout, AttachStderr bool
	Tty, OpenStdin, StdinOnce               bool
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
	if err := supportedOptions(raw, "ExposedPorts Image WorkingDir User Entrypoint Cmd Env Labels HostConfig AttachStdin AttachStdout AttachStderr Tty OpenStdin StdinOnce Hostname NetworkingConfig Healthcheck Shell"); err != nil {
		return spec, err
	}
	if err := supportedOptions(obj(raw["Healthcheck"]), "Test Interval Timeout StartPeriod StartInterval Retries"); err != nil {
		return spec, err
	}
	if err := spec.Healthcheck.validate(); err != nil {
		return spec, err
	}
	if !validDockerHealthShell(spec.Shell) {
		return spec, errors.New("invalid Docker Shell")
	}
	if value := raw["NetworkingConfig"]; value != nil {
		netcfg, ok := value.(map[string]any)
		if !ok {
			return spec, errors.New("invalid Docker networking configuration")
		}
		if err := supportedOptions(netcfg, "EndpointsConfig"); err != nil {
			return spec, err
		}
		if err := spec.parseDockerEndpoints(netcfg["EndpointsConfig"]); err != nil {
			return spec, err
		}
	}
	if h, ok := raw["HostConfig"].(map[string]any); ok {
		// These sentinel values are sent by the Docker CLI for an ordinary container.
		if policy := obj(h["RestartPolicy"]); policy["Name"] == "no" {
			delete(policy, "Name")
		}
		if h["MemorySwappiness"] == float64(-1) {
			delete(h, "MemorySwappiness")
		}
		if err := supportedOptions(h, "PortBindings PublishAllPorts Binds Mounts Tmpfs AutoRemove ReadonlyRootfs ConsoleSize Memory NanoCpus CpuQuota CpuPeriod CpuShares CpusetCpus PidsLimit NetworkMode LogConfig CapDrop Sysctls"); err != nil {
			return spec, err
		}
		for k := range obj(h["LogConfig"]) {
			if k != "Type" && k != "Config" {
				return spec, fmt.Errorf("unsupported Docker log configuration field %q", k)
			}
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
	spec.HostConfig.LogConfig = h.LogConfig.withDefault()
	if err := spec.HostConfig.LogConfig.validate(); err != nil {
		return spec, err
	}
	if size := h.ConsoleSize; len(size) != 0 {
		switch {
		case len(size) == 2 && size[0] == 0 && size[1] == 0:
			spec.HostConfig.ConsoleSize = nil
		case !spec.Tty || len(size) != 2 || size[0] == 0 || size[1] == 0:
			return spec, errors.New("console size requires a TTY and two positive dimensions")
		}
	}
	if h.CpuShares < 0 {
		return spec, errors.New("CPU shares must be nonnegative")
	}
	if err := validateDockerCPUSet(h.CpusetCpus); err != nil {
		return spec, err
	}
	for key, raw := range h.Sysctls {
		if key != tcpQueueSysctl {
			return spec, fmt.Errorf("unsupported container sysctl %q", key)
		}
		value, err := strconv.ParseUint(raw, 10, 31)
		if err != nil {
			return spec, fmt.Errorf("%s requires a nonnegative 32-bit byte count", key)
		}
		h.Sysctls[key] = strconv.FormatUint(value, 10)
	}
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
	if len(h.Tmpfs) != 0 {
		if _, err := spec.mounts(); err != nil {
			return spec, err
		}
	}
	return spec, nil
}

func validateDockerCPUSet(request string) error {
	if request == "" {
		return nil
	}
	allowed, err := dockerAllowedCPUSet()
	if err != nil {
		return err
	}
	return checkDockerCPUSet(request, &allowed)
}

func dockerAllowedCPUSet() (unix.CPUSet, error) {
	controllers, err := os.ReadFile("/sys/fs/cgroup/cgroup.subtree_control")
	if err != nil || !slices.Contains(strings.Fields(string(controllers)), "cpuset") {
		return unix.CPUSet{}, errors.New("container CPU placement requires the delegated cpuset controller")
	}
	return workerCPUAffinity()
}

func workerCPUAffinity() (unix.CPUSet, error) {
	var allowed unix.CPUSet
	if err := unix.SchedGetaffinity(os.Getpid(), &allowed); err != nil {
		return allowed, fmt.Errorf("read worker CPU affinity: %w", err)
	}
	if allowed.Count() == 0 {
		return allowed, errors.New("worker has no available CPUs")
	}
	return allowed, nil
}

func dockerPlacementCPUs(allowed *unix.CPUSet) []string {
	count := allowed.Count()
	cpus := make([]string, 0, count)
	for cpu := 0; len(cpus) < count; cpu++ {
		if allowed.IsSet(cpu) {
			cpus = append(cpus, strconv.Itoa(cpu))
		}
	}
	return cpus
}

func checkDockerCPUSet(request string, allowed *unix.CPUSet) error {
	for _, item := range strings.Split(request, ",") {
		first, last, span := strings.Cut(item, "-")
		if !span {
			last = first
		}
		lo, loErr := strconv.ParseUint(first, 10, 31)
		hi, hiErr := strconv.ParseUint(last, 10, 31)
		if loErr != nil || hiErr != nil || lo > hi {
			return fmt.Errorf("invalid Docker CPU list item %q", item)
		}
		// Check the endpoint before walking a range supplied by the client.
		if !allowed.IsSet(int(hi)) {
			return fmt.Errorf("CPU %d is unavailable to the worker", hi)
		}
		for cpu := lo; cpu < hi; cpu++ {
			if !allowed.IsSet(int(cpu)) {
				return fmt.Errorf("CPU %d is unavailable to the worker", cpu)
			}
		}
	}
	return nil
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

func (h dockerHost) cpuBandwidth(quota, period int64) (int64, int64) {
	if h.NanoCpus > 0 {
		return max(1000, h.NanoCpus/10000), 100000
	}
	if h.CpuPeriod > 0 {
		period = h.CpuPeriod
	}
	// Docker's explicit -1 removes the child quota. Zero inherits the job default.
	return cmp.Or(h.CpuQuota, quota), period
}

func (s dockerConfig) cpuGroup(network string) dockerCPUGroup {
	// Built-in networks have no catalog ID. Their normalized names cannot
	// collide with the IDs of user-defined networks.
	return dockerCPUGroup{network: cmp.Or(network, networkName(s.HostConfig.NetworkMode)), name: s.Labels[dockerCPUGroupLabel]}
}

func (s dockerConfig) requestedCPUGroup(network string) (dockerCPUGroup, error) {
	name, present := s.Labels[dockerCPUGroupLabel]
	if !present || s.HostConfig.CpusetCpus != "" {
		return dockerCPUGroup{}, nil
	}
	// Docker starts with config's one-CPU bandwidth. A wider explicit budget
	// takes precedence over a group that can only use one CPU.
	h := s.HostConfig
	quota, period := h.cpuBandwidth(100000, 100000)
	if h.NanoCpus > 1000000000 || quota < 0 || quota > period {
		return dockerCPUGroup{}, nil
	}
	if name == "" {
		return dockerCPUGroup{}, fail(400, dockerCPUGroupLabel+" requires a nonempty value")
	}
	return s.cpuGroup(network), nil
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
	for _, target := range slices.Sorted(maps.Keys(c.HostConfig.Tmpfs)) {
		options, err := parseDockerTmpfs(c.HostConfig.Tmpfs[target])
		if err != nil {
			return nil, fmt.Errorf("tmpfs %q: %w", target, err)
		}
		mounts = append(mounts, dockerMount{Type: "tmpfs", Target: target,
			ReadOnly: options.flags&unix.MS_RDONLY != 0, tmpfs: &options})
	}
	seen := map[string]bool{}
	for _, m := range mounts {
		if !filepath.IsAbs(m.Target) || filepath.Clean(m.Target) != m.Target || m.Target == "/" || strings.ContainsRune(m.Target, 0) || seen[m.Target] {
			return nil, errors.New("invalid or duplicate mount target")
		}
		seen[m.Target] = true
		if m.Type == "volume" && dockerName.MatchString(m.Source) {
			continue
		}
		if m.Type == "bind" && filepath.IsAbs(m.Source) && filepath.Clean(m.Source) == m.Source {
			continue
		}
		if m.tmpfs != nil {
			continue
		}
		return nil, errors.New("expected a local named volume or a file in the shared workspace")
	}
	return mounts, nil
}

func (c dockerConfig) captureRawOutput() bool {
	if c.Tty || c.OpenStdin {
		return true
	}
	// An ordinary job could previously replace /dev. Avoid placing our
	// launcher in a caller-owned mount. Keep that configuration on CRI I/O.
	mounts, _ := c.mounts()
	return !slices.ContainsFunc(mounts, func(m dockerMount) bool { return m.Target == "/dev" })
}

type dockerTmpfsOptions struct {
	flags uintptr
	size  uint64
	mode  uint64
	uid   uint64
	gid   uint64
}

// The explicit size limit matches the `micropod ci run --scratch-mib` range.
const maxDockerTmpfsBytes = 256 << 30

func dockerTmpfsSize(value string) (uint64, error) {
	shift := uint(0)
	if value != "" {
		switch value[len(value)-1] {
		case 'k', 'K':
			shift = 10
		case 'm', 'M':
			shift = 20
		case 'g', 'G':
			shift = 30
		}
		if shift != 0 {
			value = value[:len(value)-1]
		}
	}
	count, err := strconv.ParseUint(value, 10, 64)
	if err != nil || count == 0 || count > maxDockerTmpfsBytes>>shift {
		return 0, errors.New("size must be positive and at most 256 GiB")
	}
	return count << shift, nil
}

func parseDockerTmpfs(raw string) (dockerTmpfsOptions, error) {
	options := dockerTmpfsOptions{
		flags: unix.MS_NOSUID | unix.MS_NODEV | unix.MS_NOEXEC,
		mode:  01777,
	}
	if raw == "" {
		return options, nil
	}
	for option := range strings.SplitSeq(raw, ",") {
		switch option {
		case "defaults", "nosuid", "nodev":
			continue
		case "ro":
			options.flags |= unix.MS_RDONLY
		case "rw":
			options.flags &^= unix.MS_RDONLY
		case "noexec":
			options.flags |= unix.MS_NOEXEC
		case "exec":
			options.flags &^= unix.MS_NOEXEC
		default:
			key, value, _ := strings.Cut(option, "=")
			var err error
			switch key {
			case "size":
				options.size, err = dockerTmpfsSize(value)
			case "mode":
				options.mode, err = strconv.ParseUint(value, 8, 12)
			case "uid":
				options.uid, err = strconv.ParseUint(value, 10, 32)
			case "gid":
				options.gid, err = strconv.ParseUint(value, 10, 32)
			default:
				return options, fmt.Errorf("unsupported option %q", key)
			}
			if err != nil {
				return options, fmt.Errorf("invalid %s: %w", key, err)
			}
		}
	}
	return options, nil
}

func (options dockerTmpfsOptions) ociOptions() []string {
	flags := []string{"nosuid", "nodev"}
	if options.flags&unix.MS_NOEXEC != 0 {
		flags = append(flags, "noexec")
	} else {
		flags = append(flags, "exec")
	}
	if options.flags&unix.MS_RDONLY != 0 {
		flags = append(flags, "ro")
	} else {
		flags = append(flags, "rw")
	}
	// With no size option Linux supplies the ordinary tmpfs capacity.
	if options.size != 0 {
		flags = append(flags, "size="+strconv.FormatUint(options.size, 10))
	}
	return append(flags, fmt.Sprintf("mode=%o", options.mode), fmt.Sprintf("uid=%d", options.uid), fmt.Sprintf("gid=%d", options.gid))
}

type dockerOCITmpfsMount struct {
	Destination string   `json:"destination"`
	Type        string   `json:"type"`
	Source      string   `json:"source"`
	Options     []string `json:"options"`
}

// CRI translates all of its mounts to binds. A typed OCI tmpfs lets the
// runtime apply all requested flags together when creating the filesystem.
func (c dockerConfig) specWithTmpfs(original []byte) ([]byte, error) {
	requested, err := c.mounts()
	if err != nil {
		return nil, err
	}
	var spec map[string]json.RawMessage
	if err := json.Unmarshal(original, &spec); err != nil {
		return nil, err
	}
	var mounts []json.RawMessage
	if err := json.Unmarshal(spec["mounts"], &mounts); err != nil {
		return nil, fmt.Errorf("decode OCI mounts: %w", err)
	}

	destinations := make([]string, len(mounts))
	for i, raw := range mounts {
		var header struct {
			Destination string `json:"destination"`
		}
		if err := json.Unmarshal(raw, &header); err != nil || !filepath.IsAbs(header.Destination) {
			return nil, errors.New("invalid destination in containerd OCI mounts")
		}
		destinations[i] = filepath.Clean(header.Destination)
	}
	for _, m := range requested {
		if m.tmpfs == nil {
			continue
		}
		mount, err := json.Marshal(dockerOCITmpfsMount{Destination: m.Target, Type: "tmpfs", Source: "tmpfs", Options: m.tmpfs.ociOptions()})
		if err != nil {
			return nil, err
		}
		if i := slices.Index(destinations, m.Target); i >= 0 {
			mounts[i] = mount
			continue
		}
		// Preserve existing order while placing scratch before any child mount.
		i := slices.IndexFunc(destinations, func(dest string) bool { return strings.HasPrefix(dest, m.Target+"/") })
		if i < 0 {
			i = len(mounts)
		}
		mounts = slices.Insert(mounts, i, json.RawMessage(mount))
		destinations = slices.Insert(destinations, i, m.Target)
	}
	updated, err := json.Marshal(mounts)
	if err != nil {
		return nil, err
	}
	spec["mounts"] = updated
	return json.Marshal(spec)
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

// cacheUnitPin names one unit exactly: with shared L0 one plan's stores live
// in two scopes (the container's and "global").
type cacheUnitPin struct {
	Scope string
	Unit  string
}

// cacheAttachment is what one start of a container gets from its plan.
type cacheAttachment struct {
	files   []*os.File // pinned bind sources and unit locks; closed when the container exits
	mounts  []*cri.Mount
	env     []string
	units   []string          // the plan's locked, stamped and dirty-marked unit names (kept for legacy callers)
	stamped []cacheUnitPin    // the same units as exact (scope, unit) pairs: stamped used at start and exit
	pins    []cachePin        // every unit this start locked and marked, alias volumes and failed stores included
	skipped map[string]string // tool -> reason, for this start only
}

// cachePin is one writer's hold on a unit: its lock, held from before the
// unit was marked dirty until the container exited (caches_dirty_linux.go).
type cachePin struct {
	scope, unit string
	lock        *os.File
}

const (
	// A shared pin waits for a mark clearer's LOCK_EX (held for a stat and
	// an unlink), a janitor trim batch (at most janitorBatchHold) or an
	// inventory probe rather than leave the tool out of this start.
	sharedPinWait = 100 * time.Millisecond
	// An exclusive pin (yarn v1) waits only long enough for a probe or a
	// clearer, which hold a unit's lock for microseconds: a container that
	// holds the store keeps it until it exits, and the tool is then skipped
	// as busy-exclusive.
	exclusivePinWait = 20 * time.Millisecond
)

// lockUnitWaiting takes a unit's lock (unitLock), retrying a busy one every
// millisecond for up to wait. It never holds anything while it waits.
func lockUnitWaiting(scope, unit string, exclusive bool, wait time.Duration) (*os.File, error) {
	deadline := time.Now().Add(wait)
	for {
		lock, err := unitLock(scope, unit, exclusive)
		if !errors.Is(err, unix.EWOULDBLOCK) || !time.Now().Before(deadline) {
			return lock, err
		}
		time.Sleep(time.Millisecond)
	}
}

// pinUnit locks a unit for a writer and marks it dirty.
func pinUnit(scope, unit string, exclusive bool) (cachePin, error) {
	wait := sharedPinWait
	if exclusive {
		wait = exclusivePinWait
	}
	lock, err := lockUnitWaiting(scope, unit, exclusive, wait)
	if err != nil {
		return cachePin{}, err
	}
	if err := cacheDirty.attach(scope, unit); err != nil {
		lock.Close()
		return cachePin{}, err
	}
	return cachePin{scope, unit, lock}, nil
}

// holdUnit locks a unit LOCK_SH for a reader and makes no mark: nothing is
// written through the hold. The janitor then treats the unit as in use. A
// clearer cannot tell the reader from a writer and leaves the unit's mark to a
// later release; the hold's own release (releasePins) queues that clear.
func holdUnit(scope, unit string) (cachePin, error) {
	lock, err := lockUnitWaiting(scope, unit, false, sharedPinWait)
	if err != nil {
		return cachePin{}, err
	}
	return cachePin{scope, unit, lock}, nil
}

// release unpins the units after the container exited (or never started): it
// drops their locks, then queues their dirty marks to be cleared once no
// writer is left and a sync has put the writes on disk. Calling it again does
// nothing; stamp the units (touchAll) before, while they are still held.
func (a *cacheAttachment) release() {
	releasePins(a.pins)
	a.pins = nil
	a.units = nil
	a.stamped = nil
}

// releasePins drops each pin's lock, then queues its unit's dirty mark for a
// clear (cacheAttachment.release).
func releasePins(pins []cachePin) {
	for _, p := range pins {
		p.lock.Close()
		cacheDirty.release(p.scope, p.unit)
	}
}

// adopt takes over pins taken outside the plan (legacy alias volumes), so the
// container's release drops them with its own.
func (a *cacheAttachment) adopt(pins []cachePin) {
	a.pins = append(a.pins, pins...)
	for _, p := range pins {
		a.files = append(a.files, p.lock)
	}
}

// touchAll stamps the plan's units as used now, in their exact scopes, for the
// janitor's LRU order. Alias-volume pins are not stamped: their kind-wide unit
// is not a store the plan names.
func (a *cacheAttachment) touchAll() {
	for _, p := range a.stamped {
		_ = touchUsed(p.Scope, p.Unit)
	}
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
	scopeDirs := map[string]*os.File{}
	ensureScopeDir := func(scope string) (*os.File, error) {
		if scope == "" {
			scope = plan.Scope
		}
		if d, ok := scopeDirs[scope]; ok {
			return d, nil
		}
		d, err := openScope(l, scope)
		if err != nil {
			return nil, err
		}
		scopeDirs[scope] = d
		a.files = append(a.files, d)
		return d, nil
	}
	if _, err := ensureScopeDir(plan.Scope); err != nil {
		return dropAll(skipStoreFailed, err)
	}
	stores := map[string]*os.File{} // scope/unit -> store directory
	for _, st := range plan.Stores {
		storeScope := plan.scopeFor(st.Scope)
		scopeDir, err := ensureScopeDir(storeScope)
		if err != nil {
			log.Printf("cache scope %s for %s: %v", storeScope, st.Unit, err)
			a.skip(st.Kind, skipStoreFailed)
			continue
		}
		// Locked and marked in the store's own scope (shared L0 units live in
		// "global") before the container can write, cleared after it exits
		// and a sync (caches_dirty_linux.go): a crash meanwhile discards the
		// unit instead of leaving torn entries for every container. The
		// janitor (caches_manage_linux.go) never touches a unit locked or
		// marked like this.
		pin, err := pinUnit(storeScope, st.Unit, st.Exclusive)
		if err != nil {
			reason := skipStoreFailed
			if errors.Is(err, unix.EWOULDBLOCK) {
				reason = skipBusyExclusive
			} else {
				log.Printf("cache store %s/%s: %v", storeScope, st.Unit, err)
			}
			a.skip(st.Kind, reason)
			continue
		}
		dir, err := openStore(l, storeScope, scopeDir, st.Kind, st.UID)
		if err != nil {
			log.Printf("cache store %s/%s: %v", storeScope, st.Unit, err)
			// The mark stays until a sync after this release: openStore may
			// have created or repaired part of the store.
			a.pins = append(a.pins, pin)
			a.skip(st.Kind, skipStoreFailed)
			continue
		}
		a.files = append(a.files, pin.lock, dir)
		a.pins = append(a.pins, pin)
		stores[storeScope+"/"+st.Unit] = dir
		a.units = append(a.units, st.Unit)
		a.stamped = append(a.stamped, cacheUnitPin{Scope: storeScope, Unit: st.Unit})
	}
	type opened struct {
		m     cacheMount
		scope string
		src   *os.File
	}
	var binds []opened
	for i, m := range plan.Mounts {
		if m.Kind != "" {
			if _, gone := a.skipped[m.Kind]; gone {
				continue
			}
		}
		mountScope := plan.scopeFor(m.Scope)
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
			src = scopeDirs[mountScope]
			if src == nil {
				continue
			}
		default:
			base := stores[mountScope+"/"+m.Unit]
			switch {
			case base == nil:
				err = fmt.Errorf("store %s/%s not opened", mountScope, m.Unit)
			case m.Sub == "":
				src = base
			case m.File:
				src, err = ensureFileAt(base, m.Sub, 0666)
			default:
				src, err = ensureSubdirAt(base, m.Sub, l.trash)
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
		binds = append(binds, opened{m, mountScope, src})
	}
	usedScopes := map[string]bool{}
	for _, st := range plan.Stores {
		if _, gone := a.skipped[st.Kind]; !gone && plan.Tools[st.Kind].Mode == "env" {
			usedScopes[plan.scopeFor(st.Scope)] = true
		}
	}
	for _, b := range binds {
		if b.m.Kind == "" && !b.m.Shim && !usedScopes[b.scope] {
			continue
		}
		if _, gone := a.skipped[b.m.Kind]; gone && b.m.Kind != "" {
			continue
		}
		if b.m.Kind == "" && !b.m.Shim {
			// The scope (at /micropod/cache, or "global" at /micropod/cache-l0
			// with shared L0) is visible read-only; each env-mode unit of that
			// scope this start locked and marked is bound writable over it
			// (deeper mounts are applied after shallower ones). So nothing
			// outside the marked units, a skipped tool's or another uid's
			// partition included, can be written through this mount, and an
			// archive write (docker cp) below the scope is refused as read-only.
			a.mounts = append(a.mounts, &cri.Mount{HostPath: dockerMountFDPath(b.src), ContainerPath: b.m.Target, Readonly: true})
			for _, st := range plan.Stores {
				sc := plan.scopeFor(st.Scope)
				dir := stores[sc+"/"+st.Unit]
				if _, gone := a.skipped[st.Kind]; gone || sc != b.scope || plan.Tools[st.Kind].Mode != "env" || dir == nil {
					continue
				}
				a.mounts = append(a.mounts, &cri.Mount{HostPath: dockerMountFDPath(dir), ContainerPath: path.Join(b.m.Target, cacheStoreSub(st.Kind, st.UID))})
			}
			continue
		}
		a.mounts = append(a.mounts, &cri.Mount{HostPath: dockerMountFDPath(b.src), ContainerPath: b.m.Target})
	}
	a.env = plan.env(a.skipped)
	for _, p := range a.stamped {
		if err := touchUsed(p.Scope, p.Unit); err != nil {
			log.Printf("cache stamp %s/%s: %v", p.Scope, p.Unit, err)
		}
	}
	return a
}

// openMounts opens the request's own mounts. For a start (createVolumes false)
// a legacy alias volume of a cache store also holds that kind's unit: a
// writable one pins it (lock plus dirty mark), a read-only one takes the lock
// alone. The caller hands the pins to the container's cache attachment, whose
// release drops them.
func (s *dockerEngine) openMounts(spec dockerConfig, createVolumes bool, cleanupSocket string) ([]*os.File, []*cri.Mount, []cachePin, error) {
	requests, err := spec.mounts()
	if err != nil {
		return nil, nil, nil, err
	}
	var files []*os.File
	var mounts []*cri.Mount
	var pins []cachePin
	for _, m := range requests {
		if m.tmpfs != nil {
			continue
		}
		if privateRootless() && dockerSocketMount(m) {
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
		// Only a start uses these descriptors; a create opens them to
		// validate the request and closes them at once.
		access := aliasProbe
		if !createVolumes {
			access = aliasWrite
			if m.ReadOnly {
				access = aliasRead
			}
		}
		f, mountPins, e := s.openDockerMount(m, createVolumes, access)
		pins = append(pins, mountPins...)
		if e != nil {
			err = e
			break
		}
		files = append(files, f)
		mounts = append(mounts, &cri.Mount{HostPath: dockerMountFDPath(f), ContainerPath: m.Target, Readonly: m.ReadOnly})
	}
	if err != nil {
		closeMounts(files)
		releasePins(pins)
		return nil, nil, nil, err
	}
	return files, mounts, pins, nil
}

func dockerSocketMount(m dockerMount) bool {
	return m.Type == "bind" && m.Target == "/var/run/docker.sock" &&
		(m.Source == "/var/run/docker.sock" || m.Source == "/run/docker.sock")
}

func dockerMountFDPath(file *os.File) string {
	return fmt.Sprintf("/proc/%d/fd/%d", os.Getpid(), file.Fd())
}

// aliasAccess is what the holder of a legacy alias volume's descriptor does
// through it.
type aliasAccess int

const (
	aliasProbe aliasAccess = iota // a create validates the request and closes the descriptor at once
	aliasRead                     // reads only: a read-only volume at start, a docker cp out of a stopped container
	aliasWrite                    // writes: a writable volume at start, a docker cp into a stopped container
)

// openDockerMount opens a request mount's source. For a legacy alias volume of
// a cache store, access says how the descriptor will be used; the caller
// releases the returned pins once nothing uses the descriptor any more.
func (s *dockerEngine) openDockerMount(m dockerMount, createVolume bool, access aliasAccess) (*os.File, []cachePin, error) {
	root, source := s.workspace, m.Source
	if privateRootless() && m.Type == "bind" && m.Source == "/runner/externals" && m.ReadOnly {
		root = "/runner/externals"
	}
	if m.Type == "volume" {
		if createVolume {
			if err := ensureVolume(m.Source, nil); err != nil {
				return nil, nil, err
			}
		}
		root = filepath.Join(engineRoot, "volumes")
		source = filepath.Join(root, m.Source)
		if scope, kind, shared := legacyCacheVolume(m.Source); shared {
			return openAliasStore(scope, kind, access)
		}
	}
	f, err := openMount(root, source)
	return f, nil, err
}

// cacheAliasHeldHook, when set (tests), runs in openAliasStore once the unit is
// held and before the store is created, verified and opened.
var cacheAliasHeldHook func(scope, kind string)

// openAliasStore opens the store scopes/<scope>/<kind> a legacy alias volume
// names. A writer pins the kind-wide unit (lock plus dirty mark), because the
// whole kind directory, every partition included, is writable through it
// (caches_dirty_linux.go). A reader holds the lock alone, so the janitor
// neither evicts nor trims the store under it. Either is taken before the store
// is created or verified and opened, so a janitor pass cannot move the store
// between the two.
func openAliasStore(scope, kind string, access aliasAccess) (*os.File, []cachePin, error) {
	l, err := openCacheLayout()
	if err != nil {
		return nil, nil, err
	}
	defer l.Close()
	scopeDir, err := openScope(l, scope) // also .meta/<scope>, where the lock lives
	if err != nil {
		return nil, nil, err
	}
	defer scopeDir.Close()
	var pins []cachePin
	if access != aliasProbe {
		hold := holdUnit
		if access == aliasWrite {
			hold = func(scope, unit string) (cachePin, error) { return pinUnit(scope, unit, false) }
		}
		pin, err := hold(scope, kind)
		if err != nil {
			return nil, nil, err
		}
		pins = append(pins, pin)
		if cacheAliasHeldHook != nil {
			cacheAliasHeldHook(scope, kind)
		}
	}
	dir, err := openStore(l, scope, scopeDir, kind, nil)
	if err != nil {
		releasePins(pins)
		return nil, nil, err
	}
	dir.Close()
	f, err := openStoreBeneath(filepath.Join(cacheRoot, "scopes", scope, kind))
	if err != nil {
		releasePins(pins)
		return nil, nil, err
	}
	return f, pins, nil
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
	// Stock Docker starts the image entrypoint as PID 1. CRI's zero value
	// joins the sandbox PID namespace, where that slot belongs to pause.
	sec.NamespaceOptions = &cri.NamespaceOption{Pid: cri.NamespaceMode_CONTAINER}
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
	r.CpusetCpus = h.CpusetCpus
	if h.CpuShares > 0 {
		// Docker accepts positive shares. The Linux shares scale saturates at its endpoints.
		r.CpuShares = min(max(h.CpuShares, 2), 262144)
	}
	if h.Memory > 0 {
		r.MemoryLimitInBytes = h.Memory
	}
	r.CpuQuota, r.CpuPeriod = h.cpuBandwidth(r.CpuQuota, r.CpuPeriod)
	if h.PidsLimit != nil && *h.PidsLimit > 0 {
		r.Unified["pids.max"] = strconv.FormatInt(*h.PidsLimit, 10)
	}
	return nil
}
