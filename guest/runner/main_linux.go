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
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	containers "github.com/containerd/containerd/api/services/containers/v1"
	content "github.com/containerd/containerd/api/services/content/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	leases "github.com/containerd/containerd/api/services/leases/v1"
	snapshots "github.com/containerd/containerd/api/services/snapshots/v1"
	tasks "github.com/containerd/containerd/api/services/tasks/v1"
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
	CPUs    *int64   `json:"cpus,omitempty"`
}

func (j job) handler() (string, error) {
	if j.CPUs != nil && (j.Trust != "trusted" || *j.CPUs < 1 || *j.CPUs > 64) {
		return "", errors.New("only trusted jobs may request a CPU count from 1 to 64")
	}
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
	runtime    cri.RuntimeServiceClient
	images     cri.ImageServiceClient
	imageStore imageMetadataClient
	imagePush  dockerRegistryPusher
	// registry and platformPull serve pulls for a platform CRI does not
	// pull (docker_image_emulated_linux.go).
	registry     registryResolver
	platformPull platformPuller
	// unpacker unpacks a built image of another platform (image_unpack_linux.go).
	unpacker   layerUnpacker
	content    content.ContentClient
	containers containers.ContainersClient
	snapshots  dockerSnapshotClient
	snapStore  snapshotStore // lists and removes snapshots (image recovery)
	imageUsage imageLayerUsageClient
	leases     archiveLeaseClient
	tasks      taskWaitClient
	execTasks  tasks.TasksClient
	watchLog   func(string) (<-chan struct{}, func())
	// probeKeys lists what sweepProbes looks for (image_facts_linux.go).
	probeKeys probeKeyLister
	// reconnect lets a connection to containerd that failed be retried at
	// once rather than after gRPC's reconnect backoff (a second at first).
	reconnect func()
}

func connect() (*grpc.ClientConn, node, error) {
	conn, err := grpc.NewClient(endpoint, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, node{}, err
	}
	taskClient := tasks.NewTasksClient(conn)
	snapshotClient := snapshots.NewSnapshotsClient(conn)
	leaseClient := leases.NewLeasesClient(conn)
	n := node{
		runtime: cri.NewRuntimeServiceClient(conn), images: cri.NewImageServiceClient(conn),
		imageStore:   images.NewImagesClient(conn),
		imagePush:    newDockerRegistryPusher(conn),
		registry:     dockerRegistryResolver{},
		platformPull: newDockerRegistryPusher(conn),
		content:      content.NewContentClient(conn),
		containers:   containers.NewContainersClient(conn),
		snapshots:    snapshotClient,
		snapStore:    snapshotClient,
		imageUsage:   snapshotClient,
		leases:       leaseClient,
		tasks:        taskClient,
		execTasks:    taskClient,
		probeKeys:    grpcProbeKeys{leases: leaseClient, snapshots: snapshotClient},
		reconnect:    conn.ResetConnectBackoff,
	}
	n.unpacker = newLayerUnpacker(conn, n)
	return conn, n, nil
}

// containerdSocket is endpoint's path.
var containerdSocket = strings.TrimPrefix(endpoint, "unix://")

// runtimeStatus is what `job status` reports: containerd's CRI answers and
// says both its runtime and its network are ready.
func (n node) runtimeStatus(ctx context.Context) (*cri.VersionResponse, error) {
	v, err := n.runtime.Version(ctx, &cri.VersionRequest{Version: "v1"})
	if err != nil {
		return nil, err
	}
	health, err := n.runtime.Status(ctx, &cri.StatusRequest{})
	if err != nil {
		return nil, err
	}
	ready := map[string]bool{}
	for _, cond := range health.GetStatus().GetConditions() {
		ready[cond.Type] = cond.Status
	}
	if !ready["RuntimeReady"] || !ready["NetworkReady"] {
		return nil, errors.New("CRI runtime or network is not ready")
	}
	return v, nil
}

// runtimeReady is one poll of awaitRuntime. Until containerd's socket
// accepts, no gRPC call is made: a failed connection would put the channel
// into its reconnect backoff, which would then hold back the first call
// after containerd does listen.
func (n node) runtimeReady(ctx context.Context) error {
	c, err := net.DialTimeout("unix", containerdSocket, time.Second)
	if err != nil {
		return err
	}
	_ = c.Close()
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if _, err := n.runtimeStatus(ctx); err != nil {
		if n.reconnect != nil {
			n.reconnect()
		}
		return err
	}
	return nil
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
	// The next job of this image skips the pull: what was unpacked must be on
	// the disk before anything can depend on it (image_durability_linux.go).
	if err := imageSync.Sync(); err != nil {
		return "", false, err
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

// jobCaches attaches the scheduler-named scope to a job through the same cache
// table as Docker containers, at the job's own trust tier (a job the scheduler
// did not classify trusted only reads the stores): env-mode tools only, one
// bind at /micropod/cache, the uid from the image facts (else 0), and the
// GOFLAGS -trimpath merge. The returned func stamps the units and releases the pins
// after the job ends.
func (n node) jobCaches(ctx context.Context, image string, j job, c *cri.ContainerConfig) func() {
	facts, _ := (&factsLoader{}).load(ctx, n.images, image)
	plan := decideJobCaches((&policyLoader{}).get(), j.Cache, j.Trust, facts, dependencyProxies.up)
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
		a.touchAll()
		a.release()
		closeMounts(a.files)
		// Clear the dirty marks now: a job may run outside the engine's
		// process, where no background syncer would.
		if err := cacheDirty.syncOnce(); err != nil {
			fmt.Fprintf(os.Stderr, "job cache scope %s: sync: %v\n", j.Cache, err)
		}
	}
}

func podConfig(id, dir string) *cri.PodSandboxConfig {
	profile := &cri.SecurityProfile{ProfileType: cri.SecurityProfile_RuntimeDefault}
	return &cri.PodSandboxConfig{Metadata: &cri.PodSandboxMetadata{Name: "mp-" + id, Namespace: "micropod-ci", Uid: id},
		Hostname: "mp-" + id, LogDirectory: dir, Labels: map[string]string{owner: id}, Linux: &cri.LinuxPodSandboxConfig{SecurityContext: &cri.LinuxSandboxSecurityContext{Seccomp: profile}}}
}

// A job's (and a Docker container's) resources unless it asks for others:
// one CPU, 1 GiB and 512 processes.
const (
	jobCPUPeriod = 100000
	jobCPUQuota  = jobCPUPeriod
	jobMemory    = 1 << 30
	jobPids      = 512
)

func config(id, dir, image string, j job) (*cri.PodSandboxConfig, *cri.ContainerConfig, error) {
	pod := podConfig(id, dir)
	profile := pod.Linux.SecurityContext.Seccomp
	labels := pod.Labels
	container := &cri.ContainerConfig{Metadata: &cri.ContainerMetadata{Name: "job"}, Image: &cri.ImageSpec{Image: image},
		Command: j.Command, LogPath: "job.log", Labels: labels,
		Linux: &cri.LinuxContainerConfig{Resources: &cri.LinuxContainerResources{CpuQuota: jobCPUQuota, CpuPeriod: jobCPUPeriod, MemoryLimitInBytes: jobMemory, Unified: map[string]string{"pids.max": strconv.Itoa(jobPids)}},
			SecurityContext: &cri.LinuxContainerSecurityContext{NoNewPrivs: true, Seccomp: profile, Capabilities: &cri.Capability{DropCapabilities: []string{"ALL"}}}}}
	if j.Trust == "trusted" {
		if j.CPUs != nil {
			container.Linux.Resources.CpuQuota = *j.CPUs * container.Linux.Resources.CpuPeriod
		}
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
	ExitKnown bool   `json:"-"`
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
	return n.removeOwnedPod(ctx, id, "")
}

func (n node) removeOwnedPod(ctx context.Context, id, sandboxID string) error {
	if !jobID.MatchString(id) {
		return errors.New("invalid job ownership record")
	}
	owns := func(p *cri.PodSandbox) bool {
		return p.GetLabels()[owner] == id && p.GetMetadata().GetUid() == id && p.GetMetadata().GetNamespace() == "micropod-ci" &&
			(sandboxID == "" || sandboxID == p.GetId())
	}
	// A missing owner label must not make an existing recorded sandbox appear
	// retired. Check its exact ID before cleaning up the job's ownership scope.
	exactPresent := false
	if sandboxID != "" {
		byID, err := n.runtime.ListPodSandbox(ctx, &cri.ListPodSandboxRequest{Filter: &cri.PodSandboxFilter{Id: sandboxID}})
		if err != nil {
			return err
		}
		exactPresent = len(byID.GetItems()) != 0
		for _, pod := range byID.GetItems() {
			if !owns(pod) {
				return errors.New("pod ownership changed")
			}
		}
	}
	pods, err := n.runtime.ListPodSandbox(ctx, &cri.ListPodSandboxRequest{Filter: &cri.PodSandboxFilter{LabelSelector: map[string]string{owner: id}}})
	if err != nil {
		return err
	}
	if exactPresent && len(pods.GetItems()) != 1 {
		return errors.New("recorded pod is missing from its ownership scope")
	}
	for _, p := range pods.Items {
		if !owns(p) {
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
	if _, err := os.Lstat(dir); errors.Is(err, os.ErrNotExist) {
		return nil // nothing is mounted there (a pod removeOrphanPods found)
	}
	if err := syscall.Unmount(dir, 0); err != nil && !errors.Is(err, syscall.EINVAL) && !errors.Is(err, syscall.ENOENT) {
		return err
	}
	return os.RemoveAll(dir)
}

func (n node) recover(ctx context.Context) error {
	lease, err := engineRecoveryLease()
	if err != nil {
		return err
	}
	defer lease.Close()
	if err := n.recoverDockerRootFSBindings(ctx); err != nil {
		return err
	}
	dirs, err := os.ReadDir(filepath.Join(dataRoot, "jobs"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for _, d := range dirs {
		if d.IsDir() && jobID.MatchString(d.Name()) {
			if err := n.remove(ctx, d.Name()); err != nil {
				return err
			}
		}
	}
	if err := n.removeOrphanPods(ctx); err != nil {
		return err
	}
	return os.RemoveAll(readyDir)
}

// removeOrphanPods retires the scheduler's pods that have no job directory.
// newPod makes the directory, the pod's ownership record, without a sync, and
// CRI's commit of the pod can reach the disk before it: a crash then left a
// sandbox no recovery found. Recovery retires every owned pod anyway, so one
// is recognised by what newPod gives it alone (its owner label naming a job
// ID that is also its UID, in the scheduler's namespace); any other CRI
// client's pod is left alone.
func (n node) removeOrphanPods(ctx context.Context) error {
	pods, err := n.runtime.ListPodSandbox(ctx, &cri.ListPodSandboxRequest{})
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, p := range pods.GetItems() {
		id := p.GetLabels()[owner]
		if !jobID.MatchString(id) || p.GetMetadata().GetUid() != id || p.GetMetadata().GetNamespace() != "micropod-ci" || seen[id] {
			continue
		}
		seen[id] = true
		log.Printf("recovery: removing pod %s of job %s, which has no job directory", p.GetId(), id)
		if err := n.remove(ctx, id); err != nil {
			return err
		}
	}
	return nil
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
	configure     func(context.Context, ownedPod, *cri.ContainerConfig) error
	created       func(context.Context, string, string) error
	bindRootFS    func(context.Context, ownedPod, string) (*dockerRootFSBinding, error)
	clearRootFS   func() error
	retire        func() error
	podRetired    func()
	startConsole  func(context.Context, string) error
	runtimeLogDir string
	started       func(string)
	output        outputSink
}

func (n node) run(ctx context.Context, j job, hooks processHooks) (res result, err error) {
	handler, err := j.handler()
	if err != nil {
		return res, err
	}
	return n.runProcess(ctx, j, handler, hooks)
}

func (n node) retireProcess(ctx context.Context, p ownedPod, hooks processHooks, binding *dockerRootFSBinding, rootFSDetached bool) error {
	// Confirm that published routes are revoked before CNI recycles the pod.
	if hooks.retire != nil {
		if err := hooks.retire(); err != nil {
			return err
		}
	}
	var err error
	if binding == nil {
		err = n.cleanup(p.id)
	} else {
		err = n.cleanupDockerRootFSBinding(context.WithoutCancel(ctx), *binding, !rootFSDetached)
	}
	if err != nil {
		return err
	}
	if hooks.podRetired != nil {
		hooks.podRetired()
	}
	if binding != nil {
		return hooks.clearRootFS()
	}
	return nil
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
	var binding *dockerRootFSBinding
	var rootFSDetached bool
	var releaseCaches func()
	defer func() {
		err = errors.Join(err, n.retireProcess(ctx, p, hooks, binding, rootFSDetached))
		if releaseCaches != nil {
			releaseCaches()
		}
	}()
	dir := filepath.Join(dataRoot, "jobs", p.id)
	pod, container, err := config(p.id, dir, image, j)
	if err != nil {
		return res, err
	}
	writeRuntimeLog := hooks.output
	if hooks.runtimeLogDir != "" {
		pod.LogDirectory = hooks.runtimeLogDir
		container.LogPath = dockerRuntimeLogName
	}
	if hooks.startConsole != nil {
		// Docker captures the OCI process's raw descriptors directly. CRI's
		// line-oriented logger and the standalone job cap stay on the job path.
		container.LogPath = ""
		writeRuntimeLog = nil
	}
	if j.Cache != "" && j.Trust == "trusted" {
		releaseCaches = n.jobCaches(ctx, image, j, container)
	}
	startCtx, finishSetup := context.WithTimeout(ctx, 3*time.Minute)
	defer finishSetup()
	if hooks.configure != nil {
		if err := hooks.configure(startCtx, p, container); err != nil {
			return res, err
		}
	}
	create := time.Now()
	c, err := n.createImageContainer(startCtx, &cri.CreateContainerRequest{PodSandboxId: res.Pod, Config: container, SandboxConfig: pod})
	if err != nil {
		return res, err
	}
	res.Container = c.ContainerId
	res.CreateMS = time.Since(create).Milliseconds()
	if hooks.created != nil {
		if err := hooks.created(startCtx, res.Pod, res.Container); err != nil {
			return res, err
		}
	}
	if hooks.bindRootFS != nil {
		binding, err = hooks.bindRootFS(startCtx, p, res.Container)
		if err != nil {
			return res, err
		}
	}
	start := time.Now()
	if _, err = n.runtime.StartContainer(startCtx, &cri.StartContainerRequest{ContainerId: res.Container}); err != nil {
		return res, err
	}
	if binding != nil {
		if err := n.detachDockerRootFS(startCtx, *binding); err != nil {
			return res, fmt.Errorf("restore CRI scratch snapshot after start: %w", err)
		}
		rootFSDetached = true
	}
	if hooks.startConsole != nil {
		if err := hooks.startConsole(startCtx, res.Container); err != nil {
			return res, err
		}
	}
	finishSetup()
	res.StartMS = time.Since(start).Milliseconds()
	res.SetupMS = time.Since(setup).Milliseconds()
	if hooks.started != nil {
		hooks.started(res.Container)
	}
	logSource := criLogSource{path: filepath.Join(pod.LogDirectory, container.LogPath), diskBacked: hooks.runtimeLogDir != ""}
	res.ExitCode, res.Reason, err = n.follow(ctx, res.Container, logSource, writeRuntimeLog, handler == "crun")
	res.ExitKnown = err == nil
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
		v, err := n.runtimeStatus(ctx)
		if err != nil {
			return err
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
	if len(os.Args) > 1 && os.Args[1] == dockerPID1Command {
		os.Exit(launchDockerPID1(os.Args[2:]))
	}
	if err := run(); err != nil {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"error": err.Error()})
		os.Exit(1)
	}
}
