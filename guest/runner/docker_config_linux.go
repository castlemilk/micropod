package main

import (
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

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
	if _, _, err := dockerUser(spec.User); err != nil {
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

func dockerUser(user string) (*cri.Int64Value, *cri.Int64Value, error) {
	if user == "" {
		return nil, nil, nil
	}
	u, g, has := strings.Cut(user, ":")
	id := func(s string) (*cri.Int64Value, error) {
		n, e := strconv.ParseUint(s, 10, 32)
		if e != nil {
			return nil, errors.New("numeric uid and gid required")
		}
		return &cri.Int64Value{Value: int64(n)}, nil
	}
	uid, e := id(u)
	if e != nil || !has {
		return uid, nil, e
	}
	gid, e := id(g)
	return uid, gid, e
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

// Both interfaces address the same physical Go and npm stores. The volume
// directory is a removable Docker reference, while the scheduler owns the bytes.
func sharedCachePath(name string) (string, bool) {
	rest, ok := strings.CutPrefix(name, "micropod-ci-scoped-")
	if !ok {
		return "", false
	}
	for _, kind := range []string{"gomod", "gobuild", "npm"} {
		scope, ok := strings.CutSuffix(rest, "-"+kind)
		if ok && scopeName.MatchString(scope) {
			return filepath.Join(dataRoot, "scopes", scope, kind), true
		}
	}
	return "", false
}

func (s *dockerEngine) openMounts(spec dockerConfig, createVolumes bool, cleanupSocket string) ([]*os.File, []*cri.Mount, error) {
	requests, err := spec.mounts()
	if err != nil {
		return nil, nil, err
	}
	var files []*os.File
	var mounts []*cri.Mount
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
		f, e := s.openDockerMount(m, createVolumes)
		if e != nil {
			err = e
			break
		}
		files = append(files, f)
		mounts = append(mounts, &cri.Mount{HostPath: dockerMountFDPath(f), ContainerPath: m.Target, Readonly: m.ReadOnly})
	}
	if err != nil {
		closeMounts(files)
		return nil, nil, err
	}
	return files, mounts, nil
}

func dockerSocketMount(m dockerMount) bool {
	return m.Type == "bind" && m.Target == "/var/run/docker.sock" &&
		(m.Source == "/var/run/docker.sock" || m.Source == "/run/docker.sock")
}

func dockerMountFDPath(file *os.File) string {
	return fmt.Sprintf("/proc/%d/fd/%d", os.Getpid(), file.Fd())
}

func (s *dockerEngine) openDockerMount(m dockerMount, createVolume bool) (*os.File, error) {
	root, source := s.workspace, m.Source
	if privateRootless() && m.Type == "bind" && m.Source == "/runner/externals" && m.ReadOnly {
		root = "/runner/externals"
	}
	if m.Type == "volume" {
		if createVolume {
			if err := ensureVolume(m.Source, nil); err != nil {
				return nil, err
			}
		}
		root = filepath.Join(engineRoot, "volumes")
		source = filepath.Join(root, m.Source)
		if path, shared := sharedCachePath(m.Source); shared {
			if err := cacheDirectory(path); err != nil {
				return nil, err
			}
			root, source = filepath.Dir(path), path
		}
	}
	return openMount(root, source)
}

func closeMounts(files []*os.File) {
	for _, f := range files {
		f.Close()
	}
}

func (s dockerConfig) configure(c *cri.ContainerConfig, mounts []*cri.Mount) error {
	c.Command, c.Args, c.WorkingDir = s.Entrypoint, s.Cmd, s.WorkingDir
	c.Mounts = mounts
	for _, kv := range s.Env {
		k, v, _ := strings.Cut(kv, "=")
		c.Envs = append(c.Envs, &cri.KeyValue{Key: k, Value: v})
	}
	sec := c.Linux.SecurityContext
	// Stock Docker starts the image entrypoint as PID 1. CRI's zero value
	// joins the sandbox PID namespace, where that slot belongs to pause.
	sec.NamespaceOptions = &cri.NamespaceOption{Pid: cri.NamespaceMode_CONTAINER}
	sec.ReadonlyRootfs = s.HostConfig.ReadonlyRootfs
	var err error
	sec.RunAsUser, sec.RunAsGroup, err = dockerUser(s.User)
	if err != nil {
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
