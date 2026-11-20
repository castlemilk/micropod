package main

import (
	"encoding/json"
	"errors"
	"fmt"
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
	if err := supportedOptions(raw, "ExposedPorts Image WorkingDir User Entrypoint Cmd Env Labels HostConfig AttachStdout AttachStderr NetworkingConfig"); err != nil {
		return spec, err
	}
	if netcfg, ok := raw["NetworkingConfig"].(map[string]any); ok {
		if err := supportedOptions(netcfg, "EndpointsConfig"); err != nil {
			return spec, err
		}
		for name, endpoint := range obj(netcfg["EndpointsConfig"]) {
			if name == "default" {
				name = "bridge"
			}
			selected := "bridge"
			if spec.HostConfig.NetworkMode == "none" {
				selected = "none"
			}
			fields := obj(endpoint)
			if id, ok := fields["NetworkID"].(string); ok && id == networkID(selected) {
				delete(fields, "NetworkID")
			}
			if name != selected || !emptyOption(endpoint) {
				return spec, errors.New("custom endpoint configuration is unavailable")
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
	if h.NetworkMode != "" && h.NetworkMode != "default" && h.NetworkMode != "bridge" && h.NetworkMode != "none" {
		return spec, errors.New("only bridge or none networking is available")
	}
	for _, cap := range h.CapDrop {
		if !strings.EqualFold(cap, "all") {
			return spec, errors.New("only cap-drop ALL is available")
		}
	}
	if spec.WorkingDir != "" && !filepath.IsAbs(spec.WorkingDir) {
		return spec, errors.New("working directory must be absolute")
	}
	if h.Memory < 0 || h.NanoCpus < 0 || h.NanoCpus > 1e12 || h.CpuQuota < 0 || h.CpuPeriod < 0 || h.PidsLimit != nil && *h.PidsLimit < 0 || h.NanoCpus != 0 && (h.CpuQuota != 0 || h.CpuPeriod != 0) {
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
	return spec, nil
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
		if m.Type == "volume" {
			if path, shared := sharedCachePath(m.Source); shared {
				if err = cacheDirectory(path); err != nil {
					break
				}
				root, source = filepath.Dir(path), path
			}
		}
		f, err = openMount(root, source)
		if err != nil {
			break
		}
		files = append(files, f)
		mounts = append(mounts, &cri.Mount{HostPath: fmt.Sprintf("/proc/%d/fd/%d", os.Getpid(), f.Fd()), ContainerPath: m.Target, Readonly: m.ReadOnly})
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

func (s dockerConfig) configure(c *cri.ContainerConfig, mounts []*cri.Mount) error {
	c.Command, c.Args, c.WorkingDir = s.Entrypoint, s.Cmd, s.WorkingDir
	c.Mounts = mounts
	for _, kv := range s.Env {
		k, v, _ := strings.Cut(kv, "=")
		c.Envs = append(c.Envs, &cri.KeyValue{Key: k, Value: v})
	}
	sec := c.Linux.SecurityContext
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
	if h.Memory > 0 {
		r.MemoryLimitInBytes = h.Memory
	}
	if h.CpuPeriod > 0 {
		r.CpuPeriod = h.CpuPeriod
	}
	if h.CpuQuota > 0 {
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
