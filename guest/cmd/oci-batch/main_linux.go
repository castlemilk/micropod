// A finite, offline batch supervisor. The control image and OCI template are prepared by the runner owner.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	specs "github.com/opencontainers/runtime-spec/specs-go"
)

// Paths are set once by the owner before accepting a batch. A job never supplies mount or cgroup paths.
var state, jobsRoot, diskRoot, lower = "/run/oci", "/run/jobs", "/data", "/image"
var configDir, mods, builds, cgPrefix = "/opt/ci", "/stores/gomod", "/stores/gobuild", ""
var native bool
var nextCPU int

func runtimeBinary() string {
	if native {
		if os.Getenv("MICROPOD_JOB_RUNTIME") == "crun" {
			return "/var/lib/micropod/oci/crun-1.31-arm64"
		}
		return "/usr/local/bin/runc"
	}
	if os.Getenv("MICROPOD_JOB_RUNTIME") == "crun" {
		return "/opt/runtime/crun-1.31-arm64"
	}
	return "/opt/runtime/runc"
}

var goEnv = strings.Fields("GOENV GOTOOLCHAIN GOWORK GOFLAGS GOMAXPROCS CGO_ENABLED GOTELEMETRY GOPROXY GOSUMDB")

func readSpec(data []byte) (*specs.Spec, error) {
	var s specs.Spec
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(&s); err != nil {
		return nil, err
	}
	if s.Process == nil || s.Root == nil || s.Linux == nil || s.Hooks != nil || s.Linux.Seccomp == nil ||
		s.Linux.Seccomp.DefaultAction == specs.ActAllow || len(s.Linux.NetDevices) != 0 {
		return nil, errors.New("expected stock isolated Linux Docker spec with seccomp")
	}
	res := s.Linux.Resources
	if res == nil || res.CPU == nil || res.CPU.Quota == nil || res.CPU.Period == nil ||
		*res.CPU.Quota != 100000 || *res.CPU.Period != 100000 ||
		res.Memory == nil || res.Memory.Limit == nil || *res.Memory.Limit != 1<<30 {
		return nil, errors.New("expected one CPU and 1 GiB per job")
	}
	want := map[specs.LinuxNamespaceType]bool{specs.MountNamespace: true, specs.NetworkNamespace: true, specs.UTSNamespace: true,
		specs.PIDNamespace: true, specs.IPCNamespace: true, specs.CgroupNamespace: true}
	for _, ns := range s.Linux.Namespaces {
		if !want[ns.Type] || ns.Path != "" {
			return nil, fmt.Errorf("unexpected shared namespace %q", ns.Type)
		}
		delete(want, ns.Type)
	}
	if len(want) != 0 {
		return nil, errors.New("incomplete job namespaces")
	}
	return &s, nil
}

func jobSpec(data []byte, dir, id string, argv []string) (*specs.Spec, error) {
	s, err := readSpec(data)
	if err != nil {
		return nil, err
	}
	// Only kernel pseudo-filesystems, private identity files and two explicitly mounted caches enter a job.
	kernelMounts := map[string]string{"/proc": "proc", "/dev": "tmpfs", "/dev/pts": "devpts", "/sys": "sysfs", "/sys/fs/cgroup": "cgroup", "/dev/mqueue": "mqueue", "/dev/shm": "tmpfs"}
	binds := map[string]string{"/etc/hostname": dir + "/hostname", "/etc/hosts": dir + "/hosts", "/etc/resolv.conf": configDir + "/resolv.conf",
		"/cache/gomod": mods, "/cache/gobuild": builds}
	for i, m := range s.Mounts {
		if t, ok := kernelMounts[m.Destination]; ok && t == m.Type {
			delete(kernelMounts, m.Destination)
		} else if src, ok := binds[m.Destination]; ok && m.Type == "bind" {
			s.Mounts[i].Source = src
			delete(binds, m.Destination)
		} else {
			return nil, fmt.Errorf("unsupported OCI mount %q (%s)", m.Destination, m.Type)
		}
	}
	if len(kernelMounts)+len(binds) != 0 {
		return nil, errors.New("missing kernel or cache mounts")
	}
	s.Root.Path = "rootfs"
	s.Root.Readonly = false
	s.Hostname = id[:12]
	s.Linux.CgroupsPath = cgPrefix + "/" + id
	s.Process.Args = argv
	env := slices.DeleteFunc(s.Process.Env, func(v string) bool {
		key, _, _ := strings.Cut(v, "=")
		if key == "HOSTNAME" {
			return true
		}
		_, present := os.LookupEnv(key)
		return present && slices.Contains(goEnv, key)
	})
	s.Process.Env = append(env, "HOSTNAME="+s.Hostname)
	for _, key := range goEnv {
		if val, ok := os.LookupEnv(key); ok {
			s.Process.Env = append(s.Process.Env, key+"="+val)
		}
	}
	return s, nil
}

// OCI policy and the image's environment are immutable for the lifetime of a native session.
// Each goroutine owns the few slices and structures it changes.
type jobTemplate struct {
	raw                              []byte
	base                             *specs.Spec
	hostEnv, hostnameBind, hostsBind int
}

func prepareTemplate(raw []byte, cache bool) (jobTemplate, error) {
	t := jobTemplate{raw: raw}
	s, err := jobSpec(raw, "/run/probe", strings.Repeat("0", 64), []string{"true"})
	if err != nil || !cache {
		return t, err
	}
	t.base = s
	for i, item := range s.Process.Env {
		if strings.HasPrefix(item, "HOSTNAME=") {
			t.hostEnv = i
			break
		}
	}
	for i, m := range s.Mounts {
		switch m.Destination {
		case "/etc/hostname":
			t.hostnameBind = i
		case "/etc/hosts":
			t.hostsBind = i
		}
	}
	return t, nil
}
func (t jobTemplate) spec(dir, id string, argv []string) (*specs.Spec, error) {
	if t.base == nil {
		return jobSpec(t.raw, dir, id, argv)
	}
	s := *t.base
	process := *s.Process
	linux := *s.Linux
	s.Hostname = id[:12]
	process.Args = argv
	process.Env = slices.Clone(process.Env)
	process.Env[t.hostEnv] = "HOSTNAME=" + s.Hostname
	linux.CgroupsPath = cgPrefix + "/" + id
	s.Process, s.Linux = &process, &linux
	s.Mounts = slices.Clone(s.Mounts)
	s.Mounts[t.hostnameBind].Source = dir + "/hostname"
	s.Mounts[t.hostsBind].Source = dir + "/hosts"
	return &s, nil
}

type result struct {
	BeginNS   int64  `json:"begin_ns"`
	Index     int    `json:"index"`
	ID        string `json:"id"`
	Exit      int    `json:"exit"`
	QueueNS   int64  `json:"queue_ns,omitempty"`
	SetupNS   int64  `json:"setup_ns"`
	RuntimeNS int64  `json:"runtime_ns"`
	CleanupNS int64  `json:"cleanup_ns"`
	Error     string `json:"error,omitempty"`
}

func runJob(ctx context.Context, template jobTemplate, argv []string, r *result, stdout, stderr io.Writer, gate *launchGate, policy launchPolicy, cpuIndex int) (err error) {
	begin := time.Now()
	r.BeginNS = begin.UnixNano()
	var ident [32]byte
	if _, err = rand.Read(ident[:]); err != nil {
		return err
	}
	id := hex.EncodeToString(ident[:])
	r.ID = id
	dir := jobsRoot + "/" + id
	disk := diskRoot + "/" + id
	root := dir + "/rootfs"
	for _, path := range []string{root, disk + "/upper", disk + "/work"} {
		if err = os.MkdirAll(path, 0700); err != nil {
			return errors.Join(err, os.RemoveAll(dir), os.RemoveAll(disk))
		}
	}
	// /data is an ext4-backed anonymous volume. Every write goes to this job's private upper directory.
	if err = syscall.Mount("overlay", root, "overlay", 0, "lowerdir="+lower+",upperdir="+disk+"/upper,workdir="+disk+"/work"); err != nil {
		return errors.Join(fmt.Errorf("mount job overlay: %w", err), os.RemoveAll(dir), os.RemoveAll(disk))
	}
	defer func() {
		start := time.Now()
		if _, e := os.Stat(filepath.Join(state, id)); e == nil {
			clean, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			msg, e := exec.CommandContext(clean, runtimeBinary(), "--root", state, "delete", "--force", id).CombinedOutput()
			if e != nil {
				err = errors.Join(err, fmt.Errorf("delete job: %w: %s", e, msg))
			}
		}
		if e := syscall.Unmount(root, syscall.MNT_DETACH); e != nil {
			err = errors.Join(err, e)
		} else {
			err = errors.Join(err, os.RemoveAll(dir), os.RemoveAll(disk))
		}
		r.CleanupNS = time.Since(start).Nanoseconds()
	}()
	s, err := template.spec(dir, id, argv)
	if err != nil {
		return err
	}
	if err = policy.apply(s, cpuIndex); err != nil {
		return err
	}
	if err = os.WriteFile(dir+"/hostname", []byte(s.Hostname+"\n"), 0644); err != nil {
		return err
	}
	if err = os.WriteFile(dir+"/hosts", []byte("127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n"), 0644); err != nil {
		return err
	}
	config, err := json.Marshal(s)
	if err != nil {
		return err
	}
	if err = os.WriteFile(dir+"/config.json", config, 0600); err != nil {
		return err
	}
	args := []string{"--root", state, "run", "--bundle", dir}
	if gate != nil {
		wait := time.Now()
		release, e := gate.acquire(ctx, id)
		if e != nil {
			return e
		}
		defer release()
		r.QueueNS = time.Since(wait).Nanoseconds()
		args = append(args, "--pid-file", gate.dir+"/"+id)
	}
	cmd := exec.CommandContext(ctx, runtimeBinary(), append(args, id)...)
	if policy.oneThread {
		cmd.Env = append(os.Environ(), "GOMAXPROCS=1")
	}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	// A running payload can still own the stream pipes after the foreground OCI client exits.
	cmd.WaitDelay = 2 * time.Second
	cmd.Cancel = func() error {
		kill, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = exec.CommandContext(kill, runtimeBinary(), "--root", state, "kill", id, "KILL").Run()
		return cmd.Process.Kill()
	}
	start := time.Now()
	r.SetupNS = start.Sub(begin).Nanoseconds()
	err = cmd.Run()
	r.RuntimeNS = time.Since(start).Nanoseconds()
	var exit *exec.ExitError
	if errors.As(err, &exit) && ctx.Err() == nil {
		r.Exit = exit.ExitCode()
		if r.Exit < 0 {
			r.Exit = 1
		}
		return nil
	}
	return err
}

// Delegate controllers only inside the disposable launcher's private cgroup namespace.
func setup() error {
	if native {
		for _, dir := range []string{"/sys/fs/cgroup/micropod-oci", "/sys/fs/cgroup" + cgPrefix} {
			if err := os.MkdirAll(dir, 0755); err != nil {
				return err
			}
			controllers, err := os.ReadFile(dir + "/cgroup.controllers")
			if err != nil {
				return err
			}
			control := "+cpu +memory +pids"
			if strings.Contains(" "+strings.TrimSpace(string(controllers))+" ", " cpuset ") {
				control += " +cpuset"
			}
			if err := os.WriteFile(dir+"/cgroup.subtree_control", []byte(control), 0644); err != nil {
				return err
			}
		}
		parent := "/sys/fs/cgroup" + cgPrefix
		controllers, err := os.ReadFile(parent + "/cgroup.controllers")
		if err != nil {
			return err
		}
		allocationCPUs, err = availableCPUs(parent, string(controllers))
		if err != nil {
			return err
		}
		return os.MkdirAll(state, 0700)
	}
	loc, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(loc)) != "0::/" {
		return errors.New("launcher requires a private cgroup v2 namespace")
	}
	const cg = "/sys/fs/cgroup"
	if err = os.Mkdir(cg+"/controller", 0755); err != nil {
		return err
	}
	if err = os.WriteFile(cg+"/controller/cgroup.procs", []byte(strconv.Itoa(os.Getpid())), 0644); err != nil {
		return err
	}
	if err = os.WriteFile(cg+"/cgroup.subtree_control", []byte("+cpu +memory +pids"), 0644); err != nil {
		return err
	}
	return os.MkdirAll(state, 0700)
}

func launch(ctx context.Context, template jobTemplate, argv []string, n int, streams func(int) (io.Writer, io.Writer)) ([]result, int) {
	var group sync.WaitGroup
	results := make([]result, n)
	policy, err := policyFor(os.Getenv("MICROPOD_NATIVE_POLICY"), n)
	if err != nil {
		results[0].Exit = 1
		results[0].Error = err.Error()
		return results, 1
	}
	offset := nextCPU
	if len(allocationCPUs) > 0 {
		nextCPU = (nextCPU + n) % len(allocationCPUs)
	}
	gate, err := newLaunchGate(state, n, policy.window)
	if err != nil {
		results[0].Exit = 1
		results[0].Error = err.Error()
		return results, 1
	}
	if gate != nil {
		defer gate.close()
	}
	for i := range results {
		r := &results[i]
		r.Index = i
		group.Go(func() {
			out, errout := streams(i)
			if e := runJob(ctx, template, argv, r, out, errout, gate, policy, offset+r.Index); e != nil {
				r.Exit = 1
				r.Error = e.Error()
			}
		})
	}
	group.Wait()
	for _, r := range results {
		if r.Exit != 0 {
			return results, r.Exit
		}
	}
	return results, 0
}

func batch() (int, error) {
	session := len(os.Args) == 2 && os.Args[1] == "session"
	if !session && len(os.Args) < 3 {
		return 2, errors.New("expected a client count and command, or session")
	}
	n := 0
	if !session {
		var err error
		n, err = strconv.Atoi(os.Args[1])
		if err != nil || n < 1 || n > 64 {
			return 2, errors.New("expected 1–64 clients")
		}
	}
	if sid := os.Getenv("MICROPOD_NATIVE_SESSION"); sid != "" {
		key, scope := os.Getenv("MICROPOD_NATIVE_HANDLE"), os.Getenv("MICROPOD_NATIVE_SCOPE")
		if !validToken(sid, 32) || !validToken(key, 64) || !validScope(scope) {
			return 1, errors.New("invalid native OCI session")
		}
		native = true
		seed, _ := strconv.ParseUint(sid[:4], 16, 16)
		nextCPU = int(seed)
		base := "/run/micropod-oci/sessions/" + sid
		state, jobsRoot, diskRoot = base+"/state", base+"/jobs", "/var/lib/micropod/oci-native/jobs/"+sid
		configDir, lower = "/var/lib/micropod/oci-native/handles/"+key, "/run/micropod-oci/lowers/"+key
		volume := "/var/lib/docker/volumes/micropod-ci-scoped-" + scope
		mods, builds, cgPrefix = volume+"-gomod/_data", volume+"-gobuild/_data", "/micropod-oci/"+sid
		defer os.Remove("/sys/fs/cgroup" + cgPrefix)
	}
	raw, err := os.ReadFile(configDir + "/template.json")
	if err != nil {
		return 1, err
	}
	template, err := prepareTemplate(raw, native)
	if err != nil {
		return 1, err
	}
	if err = setup(); err != nil {
		return 1, err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer cancel()
	if session {
		if err := serve(ctx, template); err != nil {
			return 1, err
		}
		return 0, nil
	}
	results, code := launch(ctx, template, os.Args[2:], n, func(int) (io.Writer, io.Writer) { return os.Stdout, os.Stderr })
	for _, r := range results {
		if os.Getenv("MICROPOD_OCI_TRACE") == "1" {
			b, err := json.Marshal(r)
			if err != nil {
				return 1, err
			}
			fmt.Fprintf(os.Stderr, "micropod-oci %s\n", b)
		} else if r.Error != "" {
			fmt.Fprintf(os.Stderr, "OCI job %d: %s\n", r.Index, r.Error)
		}
	}
	return code, nil
}
func main() {
	code, err := batch()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	os.Exit(code)
}
