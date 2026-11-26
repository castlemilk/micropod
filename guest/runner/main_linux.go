// The guest receives requests only from the worker owner's private vsock.
// Workload containers never receive the runtime socket or a scheduler credential.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const endpoint = "unix:///run/containerd/containerd.sock"
const owner = "io.micropod.runner.job"
const dataRoot = "/var/lib/micropod/runner"

var jobID = regexp.MustCompile(`^[0-9a-f]{32}$`)
var immutableImage = regexp.MustCompile(`^[^[:space:]@]+@sha256:[a-f0-9]{64}$`)
var scopeName = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,62}$`)

type job struct {
	Trust   string   `json:"trust"`
	Image   string   `json:"image"`
	Command []string `json:"args"`
	Cache   string   `json:"cache_scope,omitempty"`
}

func (j job) handler() (string, error) {
	if j.Image == "" || len(j.Command) == 0 || j.Command[0] == "" {
		return "", errors.New("a job needs an image and a command")
	}
	switch j.Trust {
	case "trusted":
		if j.Cache != "" && !scopeName.MatchString(j.Cache) {
			return "", errors.New("invalid cache scope")
		}
		return "crun", nil
	case "untrusted":
		if j.Cache != "" {
			return "", errors.New("untrusted jobs cannot open a shared writable cache")
		}
		if !immutableImage.MatchString(j.Image) {
			return "", errors.New("an untrusted job needs a scheduler-approved image digest")
		}
		return "kata", nil
	default:
		return "", errors.New("the scheduler must classify the job as trusted or untrusted")
	}
}

type node struct {
	runtime cri.RuntimeServiceClient
	images  cri.ImageServiceClient
}

func connect() (*grpc.ClientConn, node, error) {
	conn, err := grpc.NewClient(endpoint, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, node{}, err
	}
	return conn, node{cri.NewRuntimeServiceClient(conn), cri.NewImageServiceClient(conn)}, nil
}

func (n node) image(ctx context.Context, ref string) (string, bool, error) {
	spec := &cri.ImageSpec{Image: ref}
	find := func() (string, error) {
		r, err := n.images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: spec})
		if err != nil {
			return "", err
		}
		return r.GetImage().GetId(), nil
	}
	if id, err := find(); id != "" || err != nil {
		return id, true, err
	}
	dir := filepath.Join(dataRoot, "pulls")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", false, err
	}
	// Bound the number of permanent lock inodes. A warm hit never takes a lock.
	digest := sha256.Sum256([]byte(ref))
	f, err := os.OpenFile(filepath.Join(dir, fmt.Sprintf("%02x", digest[0])), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return "", false, err
	}
	defer f.Close()
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			return "", false, err
		}
		if err := pause(ctx); err != nil {
			return "", false, err
		}
	}
	if id, err := find(); id != "" || err != nil {
		return id, true, err
	}
	r, err := n.images.PullImage(ctx, &cri.PullImageRequest{Image: spec})
	if err != nil {
		return "", false, err
	}
	if r.ImageRef == "" {
		return "", false, errors.New("runtime returned an empty image reference")
	}
	return r.ImageRef, false, nil
}

func pause(ctx context.Context) error {
	t := time.NewTimer(100 * time.Millisecond)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// jobCaches attaches the scheduler-named scope to a trusted job through the
// same cache table as Docker containers: env-mode tools only, one bind at
// /micropod/cache, the uid from the image facts (else 0), and the GOFLAGS
// -trimpath merge. The returned func stamps the units and releases the pins
// after the job ends.
func (n node) jobCaches(ctx context.Context, image string, j job, c *cri.ContainerConfig) func() {
	facts, _ := (&factsLoader{}).load(ctx, n.images, image)
	plan := decideJobCaches((&policyLoader{}).get(), j.Cache, facts)
	if !plan.attached() {
		if plan.Reason != "" {
			fmt.Fprintf(os.Stderr, "job cache scope %s not attached: %s\n", j.Cache, plan.Reason)
		}
		return func() {}
	}
	a := openCacheMounts(&plan, "")
	c.Mounts = append(c.Mounts, a.mounts...)
	for _, kv := range mergeEnv(nil, a.env) {
		k, v, _ := strings.Cut(kv, "=")
		c.Envs = append(c.Envs, &cri.KeyValue{Key: k, Value: v})
	}
	return func() {
		for _, u := range a.units {
			_ = touchUsed(plan.Scope, u)
		}
		closeMounts(a.files)
	}
}

func podConfig(id, dir string) *cri.PodSandboxConfig {
	profile := &cri.SecurityProfile{ProfileType: cri.SecurityProfile_RuntimeDefault}
	return &cri.PodSandboxConfig{Metadata: &cri.PodSandboxMetadata{Name: "mp-" + id, Namespace: "micropod-ci", Uid: id},
		Hostname: "mp-" + id, LogDirectory: dir, Labels: map[string]string{owner: id}, Linux: &cri.LinuxPodSandboxConfig{SecurityContext: &cri.LinuxSandboxSecurityContext{Seccomp: profile}}}
}

func config(id, dir, image string, j job) (*cri.PodSandboxConfig, *cri.ContainerConfig, error) {
	pod := podConfig(id, dir)
	profile := pod.Linux.SecurityContext.Seccomp
	labels := pod.Labels
	container := &cri.ContainerConfig{Metadata: &cri.ContainerMetadata{Name: "job"}, Image: &cri.ImageSpec{Image: image},
		Command: j.Command, LogPath: "job.log", Labels: labels,
		Linux: &cri.LinuxContainerConfig{Resources: &cri.LinuxContainerResources{CpuQuota: 100000, CpuPeriod: 100000, MemoryLimitInBytes: 1 << 30, Unified: map[string]string{"pids.max": "512"}},
			SecurityContext: &cri.LinuxContainerSecurityContext{NoNewPrivs: true, Seccomp: profile, Capabilities: &cri.Capability{DropCapabilities: []string{"ALL"}}}}}
	if j.Trust == "trusted" {
		// CI packaging preserves an existing file's set-ID bits across writes. no_new_privs
		// still prevents acquiring privilege by executing that file.
		container.Linux.SecurityContext.Capabilities.AddCapabilities = []string{"FSETID"}
	}
	return pod, container, nil
}

type result struct {
	Reason    string `json:"exit_reason,omitempty"`
	Type      string `json:"type"`
	ExitCode  int32  `json:"exit_code"`
	Runtime   string `json:"runtime"`
	Prepared  bool   `json:"prepared_pod"`
	Image     string `json:"image_id"`
	Hit       bool   `json:"image_cache_hit"`
	Pod       string `json:"pod_id"`
	Container string `json:"container_id"`
	ImageMS   int64  `json:"image_ms"`
	SetupMS   int64  `json:"setup_ms"`
	PodMS     int64  `json:"pod_ms"`
	CreateMS  int64  `json:"create_ms"`
	StartMS   int64  `json:"start_ms"`
}

// Only the scheduler can create these durable ownership records. Never enumerate or
// remove another CRI client's pods, including other pods in the same namespace.
func (n node) remove(ctx context.Context, id string) error {
	if !jobID.MatchString(id) {
		return errors.New("invalid job ownership record")
	}
	pods, err := n.runtime.ListPodSandbox(ctx, &cri.ListPodSandboxRequest{Filter: &cri.PodSandboxFilter{LabelSelector: map[string]string{owner: id}}})
	if err != nil {
		return err
	}
	for _, p := range pods.Items {
		if p.Labels[owner] != id || p.Metadata.GetUid() != id || p.Metadata.GetNamespace() != "micropod-ci" {
			return errors.New("pod ownership changed")
		}
		if _, err := n.runtime.StopPodSandbox(ctx, &cri.StopPodSandboxRequest{PodSandboxId: p.Id}); err != nil {
			return err
		}
		if _, err := n.runtime.RemovePodSandbox(ctx, &cri.RemovePodSandboxRequest{PodSandboxId: p.Id}); err != nil {
			return err
		}
	}
	dir := filepath.Join(dataRoot, "jobs", id)
	if err := syscall.Unmount(dir, 0); err != nil && !errors.Is(err, syscall.EINVAL) && !errors.Is(err, syscall.ENOENT) {
		return err
	}
	return os.RemoveAll(dir)
}

func (n node) recover(ctx context.Context) error {
	dirs, err := os.ReadDir(filepath.Join(dataRoot, "jobs"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, d := range dirs {
		if d.IsDir() && jobID.MatchString(d.Name()) {
			if err := n.remove(ctx, d.Name()); err != nil {
				return err
			}
		}
	}
	return os.RemoveAll(readyDir)
}

func kataPrerequisites() error {
	for _, device := range []string{"/dev/kvm", "/dev/vhost-vsock"} {
		st, err := os.Stat(device)
		if err != nil || st.Mode()&os.ModeCharDevice == 0 {
			return fmt.Errorf("Kata requires %s in the worker kernel", device)
		}
	}
	if st, err := os.Stat("/opt/kata/bin/containerd-shim-kata-v2"); err != nil || st.Mode().Perm()&0111 == 0 {
		return errors.New("Kata is not installed on this node")
	}
	return nil
}

type processHooks struct {
	configure func(context.Context, string, *cri.ContainerConfig) error
	retire    func() error
	started   func(string)
	output    outputSink
}

func (n node) run(ctx context.Context, j job, hooks processHooks) (res result, err error) {
	handler, err := j.handler()
	if err != nil {
		return res, err
	}
	return n.runProcess(ctx, j, handler, hooks)
}

func (n node) runProcess(ctx context.Context, j job, handler string, hooks processHooks) (res result, err error) {
	if handler == "kata" {
		if err := kataPrerequisites(); err != nil {
			return res, err
		}
	}
	begin := time.Now()
	image, hit, err := n.image(ctx, j.Image)
	if err != nil {
		return res, err
	}
	res = result{Type: "done", Runtime: handler, Image: image, Hit: hit, ImageMS: time.Since(begin).Milliseconds()}
	setup := time.Now()
	p, prepared, err := n.acquire(ctx, handler)
	if err != nil {
		return res, err
	}
	res.Pod = p.pod
	res.Prepared = prepared
	res.PodMS = time.Since(setup).Milliseconds()
	defer func() {
		// Revoke published routes before CNI can recycle the pod address.
		if hooks.retire != nil {
			if e := hooks.retire(); e != nil {
				err = errors.Join(err, e)
				return
			}
		}
		err = errors.Join(err, n.cleanup(p.id))
	}()
	dir := filepath.Join(dataRoot, "jobs", p.id)
	pod, container, err := config(p.id, dir, image, j)
	if err != nil {
		return res, err
	}
	if j.Cache != "" && j.Trust == "trusted" {
		release := n.jobCaches(ctx, image, j, container)
		defer release()
	}
	startCtx, finishSetup := context.WithTimeout(ctx, 3*time.Minute)
	defer finishSetup()
	if hooks.configure != nil {
		if err := hooks.configure(startCtx, p.pod, container); err != nil {
			return res, err
		}
	}
	create := time.Now()
	c, err := n.runtime.CreateContainer(startCtx, &cri.CreateContainerRequest{PodSandboxId: res.Pod, Config: container, SandboxConfig: pod})
	if err != nil {
		return res, err
	}
	res.Container = c.ContainerId
	res.CreateMS = time.Since(create).Milliseconds()
	start := time.Now()
	if _, err = n.runtime.StartContainer(startCtx, &cri.StartContainerRequest{ContainerId: res.Container}); err != nil {
		return res, err
	}
	finishSetup()
	res.StartMS = time.Since(start).Milliseconds()
	res.SetupMS = time.Since(setup).Milliseconds()
	if hooks.started != nil {
		hooks.started(res.Container)
	}
	res.ExitCode, res.Reason, err = n.follow(ctx, res.Container, filepath.Join(dir, "job.log"), hooks.output)
	return res, err
}

func decodeJob(r io.Reader) (job, error) {
	var j job
	d := json.NewDecoder(io.LimitReader(r, 128<<10))
	d.DisallowUnknownFields()
	if err := d.Decode(&j); err != nil {
		return j, err
	}
	var extra json.RawMessage
	if err := d.Decode(&extra); err != io.EOF {
		return j, errors.New("expected one job request")
	}
	return j, nil
}

func run() error {
	conn, n, err := connect()
	if err != nil {
		return err
	}
	defer conn.Close()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	out := json.NewEncoder(os.Stdout)
	if len(os.Args) == 2 && os.Args[1] == "engine" {
		return serveEngine(ctx, n)
	}
	if len(os.Args) == 3 && os.Args[1] == "prime" {
		count, err := strconv.Atoi(os.Args[2])
		if err != nil {
			return err
		}
		ctx, end := context.WithTimeout(ctx, 3*time.Minute)
		defer end()
		start := time.Now()
		newPods, err := n.prime(ctx, count)
		if err != nil {
			return err
		}
		return out.Encode(map[string]any{"created": newPods, "max_parallelism": primeWorkers, "elapsed_ms": time.Since(start).Milliseconds()})
	}
	if len(os.Args) == 2 && os.Args[1] == "recover" {
		ctx, end := context.WithTimeout(ctx, 5*time.Minute)
		defer end()
		return n.recover(ctx)
	}
	if len(os.Args) == 2 && os.Args[1] == "status" {
		ctx, end := context.WithTimeout(ctx, 2*time.Second)
		defer end()
		v, err := n.runtime.Version(ctx, &cri.VersionRequest{Version: "v1"})
		if err != nil {
			return err
		}
		health, err := n.runtime.Status(ctx, &cri.StatusRequest{})
		if err != nil {
			return err
		}
		ready := map[string]bool{}
		for _, cond := range health.GetStatus().GetConditions() {
			ready[cond.Type] = cond.Status
		}
		if !ready["RuntimeReady"] || !ready["NetworkReady"] {
			return errors.New("CRI runtime or network is not ready")
		}
		return out.Encode(map[string]any{"engine": v.RuntimeName, "version": v.RuntimeVersion, "kata_prerequisites_present": kataPrerequisites() == nil})
	}
	j, err := decodeJob(os.Stdin)
	if err != nil {
		return err
	}
	ctx, end := context.WithTimeout(ctx, 6*time.Hour)
	defer end()
	res, err := n.run(ctx, j, processHooks{output: jsonOutput(out)})
	if err != nil {
		return err
	}
	return out.Encode(res)
}

func main() {
	if err := run(); err != nil {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"error": err.Error()})
		os.Exit(1)
	}
}
