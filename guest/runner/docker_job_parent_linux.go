package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"

	"golang.org/x/sys/unix"
)

const dockerJobParentLabel = "io.micropod.bench.ci.job-cgroup"
const dockerBenchmarkOwnerLabel = "io.micropod.bench.ci-concurrency"
const dockerJobParentPrefix = "micropod-job-"
const dockerRuntimeNamespace = "k8s.io"
const dockerRuntimeCgroupRoot = "/sys/fs/cgroup/" + dockerRuntimeNamespace

var dockerRuntimeID = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Only the disposable CI fixture can select this experimental OCI layout.
func (s *dockerEngine) requestedJobParent(spec dockerConfig, networkID string) (string, error) {
	value, optedIn := spec.Labels[dockerJobParentLabel]
	if !optedIn {
		return "", nil
	}
	workspace := s.workspace
	scope := filepath.Dir(workspace)
	owner := filepath.Base(scope)
	n := s.namedNetworks[networkID]
	group := spec.Labels[dockerCPUGroupLabel]
	if value != "1" || privateRootless() || workspace != filepath.Join(scope, "workspace") ||
		filepath.Dir(scope) != "/private/tmp" || !strings.HasPrefix(owner, "mp-t-") || len(owner) != 13 ||
		!scopeName.MatchString(owner) || spec.Labels[dockerBenchmarkOwnerLabel] != owner ||
		n == nil || n.deleting || !n.Internal || n.Labels[dockerBenchmarkOwnerLabel] != owner ||
		!dockerRuntimeID.MatchString(networkID) || group == "" {
		return "", fail(400, "experimental job cgroup requires matching ownership on a private CI fixture network and a CPU group label")
	}
	key := sha256.Sum256([]byte(networkID + "\x00" + group))
	return fmt.Sprintf("%s%x", dockerJobParentPrefix, key), nil
}

func validDockerJobParent(name string) bool {
	key, ok := strings.CutPrefix(name, dockerJobParentPrefix)
	return ok && dockerRuntimeID.MatchString(key)
}

// Patch the typed OCI cgroupsPath field without round-tripping unrelated
// fields through a different version of the runtime-spec Go types.
func specWithJobParent(original []byte, name, id string) ([]byte, error) {
	if !validDockerJobParent(name) || !dockerRuntimeID.MatchString(id) {
		return nil, errors.New("invalid experimental job cgroup identity")
	}
	var spec, linux map[string]json.RawMessage
	if err := json.Unmarshal(original, &spec); err != nil {
		return nil, err
	}
	if err := json.Unmarshal(spec["linux"], &linux); err != nil {
		return nil, fmt.Errorf("decode OCI Linux config: %w", err)
	}
	var current string
	if err := json.Unmarshal(linux["cgroupsPath"], &current); err != nil || current != "/"+dockerRuntimeNamespace+"/"+id {
		return nil, errors.New("unexpected default OCI cgroup path for the owned container")
	}
	path, err := json.Marshal("/" + dockerRuntimeNamespace + "/" + name + "/" + id)
	if err != nil {
		return nil, err
	}
	linux["cgroupsPath"] = path
	spec["linux"], err = json.Marshal(linux)
	if err != nil {
		return nil, err
	}
	return json.Marshal(spec)
}

type dockerJobParents struct {
	mu   sync.Mutex
	refs map[string]int
}

func (p *dockerJobParents) retain(name string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.refs[name] == 0 {
		if err := createDockerJobParent(dockerRuntimeCgroupRoot, name); err != nil {
			return err
		}
		if p.refs == nil {
			p.refs = make(map[string]int)
		}
	}
	p.refs[name]++
	return nil
}

func createDockerJobParent(root, name string) (retErr error) {
	if !validDockerJobParent(name) {
		return errors.New("invalid experimental job cgroup parent")
	}
	var fs unix.Statfs_t
	if err := unix.Statfs(root, &fs); err != nil {
		return fmt.Errorf("inspect runtime cgroup mount: %w", err)
	}
	if fs.Type != unix.CGROUP2_SUPER_MAGIC {
		return errors.New("experimental job parent requires cgroup v2")
	}
	available, err := os.ReadFile(filepath.Join(root, "cgroup.subtree_control"))
	if err != nil {
		return fmt.Errorf("read runtime cgroup delegation: %w", err)
	}
	controllers := strings.Fields(string(available))
	for _, required := range []string{"cpu", "cpuset", "memory", "pids"} {
		if !slices.Contains(controllers, required) {
			return fmt.Errorf("runtime cgroup does not delegate %s", required)
		}
	}
	dir := filepath.Join(root, name)
	if err := os.Mkdir(dir, 0755); errors.Is(err, os.ErrExist) {
		// A prior process may have exited before retirement. Only remove an
		// empty parent for this exact fixture group. A surviving leaf blocks it.
		if err := removeDockerJobParent(root, name); err != nil {
			return err
		}
		if err := os.Mkdir(dir, 0755); err != nil {
			return fmt.Errorf("recreate experimental job cgroup: %w", err)
		}
	} else if err != nil {
		return fmt.Errorf("create experimental job cgroup: %w", err)
	}
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, removeDockerJobParent(root, name))
		}
	}()
	// Keep the kernel's default weight and unlimited cpu.max on the taskless
	// parent. The payload retains the quotas and resources supplied by CRI.
	enable := "+" + strings.Join(controllers, " +")
	if err := os.WriteFile(filepath.Join(dir, "cgroup.subtree_control"), []byte(enable), 0); err != nil {
		return fmt.Errorf("delegate controllers to experimental job children: %w", err)
	}
	return nil
}

func (p *dockerJobParents) release(root, name string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.refs[name] > 1 {
		p.refs[name]--
		return nil
	}
	delete(p.refs, name)
	return removeDockerJobParent(root, name)
}

func removeDockerJobParent(root, name string) error {
	if !validDockerJobParent(name) {
		return errors.New("invalid experimental job cgroup parent")
	}
	if err := unix.Rmdir(filepath.Join(root, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("retire empty experimental job cgroup: %w", err)
	}
	return nil
}
