package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	containers "github.com/containerd/containerd/api/services/containers/v1"
	"github.com/containerd/platforms"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/fieldmaskpb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const dockerSocket = "/var/lib/micropod/docker.sock"
const engineGate = "/run/micropod-oci/engine.lock"
const dockerAPI = "1.47"

type dockerRecord struct {
	NetworkID, NetworkIP                         string
	SecondaryNetworks                            []dockerSecondaryEndpoint `json:",omitempty"`
	BridgeGeneration                             *dockerBridgeGeneration   `json:",omitempty"`
	OOMKilled                                    bool
	CPUGrouped                                   bool `json:",omitempty"`
	ID, Name, ImageID, Phase, RuntimeID, Failure string
	// ImagePlatform is the image's platform ("linux/amd64" for an emulated
	// container); "" for a record an older engine wrote, which is linux/arm64.
	ImagePlatform              string `json:",omitempty"`
	Created, Started, Finished time.Time
	Exit                       int32
	Exits                      uint64
	LogOffset                  int64              `json:",omitempty"`
	LogError                   string             `json:",omitempty"`
	Health                     *dockerHealthState `json:",omitempty"`
	Config                     dockerConfig
	RootFS                     *dockerRootFS        `json:",omitempty"`
	RootFSBinding              *dockerRootFSBinding `json:",omitempty"`
	// Cache is the attach decision made once at create and replayed on every
	// start; CacheSkipped lists tools the latest start had to leave out.
	Cache        *cachePlan        `json:",omitempty"`
	CacheSkipped map[string]string `json:",omitempty"`
	// CacheAccess lists tools the latest start reached through a
	// copy-on-write view or read-only (accessCopyOnWrite, accessReadOnly):
	// an untrusted or read-only plan, or an exclusive kind another container
	// writes.
	CacheAccess map[string]string `json:",omitempty"`
	// CacheProxy lists the dependency proxies the latest start left out
	// although the create injected them, because they did not answer then
	// (tool kind -> proxySkipUnreachable; cachePlan.unreachableProxies).
	CacheProxy map[string]string `json:",omitempty"`
	// RunAs is a --user containing names, resolved against the image at create.
	RunAs *runAsUser `json:",omitempty"`
	// EngineSocket: the host granted this trusted container the machine's
	// Docker API at create (engineSocketGrant); every start serves it a
	// socket of its own at its docker.sock bind (openEngineSocket).
	EngineSocket bool `json:",omitempty"`
	// ImageEnv is the image's own environment at create: what inspect shows
	// under the container's (Docker reports the two merged, and a client
	// such as a GitHub Actions runner reads the container's PATH there).
	ImageEnv []string `json:",omitempty"`
	// CreatedBy is the container whose delegated socket created this one
	// ("" for the host's): its family on that socket (docker_delegated_linux.go).
	CreatedBy string `json:",omitempty"`
	// BindRoots maps each bind target of a container made through a
	// delegated socket to its creator's bind source it lies in; every open
	// of the bind resolves below that root (openMountWithin).
	BindRoots map[string]string `json:",omitempty"`
}
type dockerContainer struct {
	outputBytes int64
	IP          string
	primaryMAC  string
	Ports       portMap
	dockerRecord
	changed            chan struct{}
	lifecycle          chan struct{}
	bridgeOps          sync.Mutex
	bridge             *dockerRunningBridge
	archive            *dockerLiveArchive
	console            *dockerPID1
	healthMonitor      *dockerHealthMonitor
	killEventDone      chan struct{}
	exitReceipt        *dockerExitReceipt
	foregroundReaders  int
	readersDone        chan struct{}
	generationLogError string
	removed            bool
	// binds are the descriptors the running start opened, from before the
	// container runs until it has exited: what a child of its delegated
	// socket is held to by identity (creatorHoldLocked).
	binds *heldBinds
	// reaped closes once what c's delegated socket created is gone, after
	// c's removal (reapFamily); nil for a container that owns no family.
	reaped chan struct{}
}
type dockerEngine struct {
	buildkitSocket string
	// builds records the socket each build solved through the Docker
	// socket proxy came from, so a delegated socket reaches only its own
	// (dockerBuildRefs).
	builds        dockerBuildRefs
	direct        *directNetwork
	networkMu     sync.Mutex
	namedNetworks map[string]*workerNetwork
	startSlots    chan struct{}
	jobParents    dockerJobParents
	metrics       dockerMetrics
	node          node
	imageMu       sync.RWMutex
	healthImages  dockerImageHealthCache
	// imageConfigs remembers each listed image's config creation time and
	// layer chain (docker_image_list_linux.go).
	imageConfigs dockerImageConfigCache
	workspace    string
	// machineDir guards the machine's own directory inside the workspace
	// (docker_private_linux.go); nil when it is outside or unknown.
	machineDir *privateRoot
	// relayed are the gateway relays' connections, rechecked when a
	// network change can withdraw their admission (recheckRelaysLocked).
	relayed     relayedConns
	events      dockerEventLog
	mu          sync.Mutex
	containers  map[string]*dockerContainer
	execs       map[string]*dockerExec
	execPipeDir string
	cachePolicy policyLoader
	imageFacts  factsLoader
	// capacity: the kernel's figures and the start latencies GET
	// /micropod/capacity answers from (docker_capacity_linux.go).
	capacity capacityState
}

type dockerCPUGroup struct {
	network, name string
}

func (c *dockerContainer) cpuGroup() dockerCPUGroup {
	return c.Config.cpuGroup(c.NetworkID)
}

// Call with s.mu held, or during recovery before the API opens. The persisted
// catalog is the reservation, including stopped containers that can restart.
func (s *dockerEngine) cpuGroups() map[dockerCPUGroup][]*dockerContainer {
	groups := make(map[dockerCPUGroup][]*dockerContainer)
	for _, c := range s.containers {
		if c.CPUGrouped {
			key := c.cpuGroup()
			groups[key] = append(groups[key], c)
		}
	}
	return groups
}

func leastAssignedCPU(cpus []string, counts map[string]int) string {
	best := cpus[0]
	for _, cpu := range cpus[1:] {
		if counts[cpu] < counts[best] {
			best = cpu
		}
	}
	return best
}

func (s *dockerEngine) chooseGroupCPULocked(group dockerCPUGroup, cpus []string) (string, error) {
	groups := s.cpuGroups()
	if members := groups[group]; len(members) > 0 {
		cpu := members[0].Config.HostConfig.CpusetCpus
		if slices.Contains(cpus, cpu) && !slices.ContainsFunc(members[1:], func(c *dockerContainer) bool {
			return c.Config.HostConfig.CpusetCpus != cpu
		}) {
			return cpu, nil
		}
		return "", fail(409, "CPU group placement changed or is unavailable. Restart the worker to reconcile the group")
	}
	counts := make(map[string]int, len(cpus))
	for _, members := range groups {
		counts[members[0].Config.HostConfig.CpusetCpus]++
	}
	return leastAssignedCPU(cpus, counts), nil
}

func (s *dockerEngine) groupCPULocked(group dockerCPUGroup) (string, error) {
	allowed, err := dockerAllowedCPUSet()
	if err != nil {
		return "", fail(400, err.Error())
	}
	return s.chooseGroupCPULocked(group, dockerPlacementCPUs(&allowed))
}

func recoverCPUGroupAssignments(groups map[dockerCPUGroup][]*dockerContainer, cpus []string) map[*dockerContainer]string {
	assignments := make(map[dockerCPUGroup]string, len(groups))
	counts := make(map[string]int, len(cpus))
	var unplaced []dockerCPUGroup
	for key, members := range groups {
		// A crash during recovery can commit one member before another. Keep an
		// already persisted available CPU, using the lowest if more than one fits.
		for _, cpu := range cpus {
			if slices.ContainsFunc(members, func(c *dockerContainer) bool { return c.Config.HostConfig.CpusetCpus == cpu }) {
				assignments[key] = cpu
				counts[cpu]++
				break
			}
		}
		if assignments[key] == "" {
			unplaced = append(unplaced, key)
		}
	}
	slices.SortFunc(unplaced, func(a, b dockerCPUGroup) int {
		if a.network != b.network {
			return strings.Compare(a.network, b.network)
		}
		return strings.Compare(a.name, b.name)
	})
	for _, key := range unplaced {
		cpu := leastAssignedCPU(cpus, counts)
		assignments[key] = cpu
		counts[cpu]++
	}
	changes := make(map[*dockerContainer]string)
	for key, members := range groups {
		for _, c := range members {
			if cpu := assignments[key]; c.Config.HostConfig.CpusetCpus != cpu {
				changes[c] = cpu
			}
		}
	}
	return changes
}

func (s *dockerEngine) recoverCPUGroupPlacements() error {
	groups := s.cpuGroups()
	if len(groups) == 0 {
		return nil
	}
	// The node has already retired interrupted processes. An offline CPU can
	// now be replaced for the entire group before any member starts again.
	allowed, err := workerCPUAffinity()
	if err != nil {
		return fmt.Errorf("recover Docker CPU group placements: %w", err)
	}
	for c, cpu := range recoverCPUGroupAssignments(groups, dockerPlacementCPUs(&allowed)) {
		c.Config.HostConfig.CpusetCpus = cpu
		if err := c.save(); err != nil {
			return fmt.Errorf("save recovered Docker CPU group placement: %w", err)
		}
	}
	return nil
}

func engineID() string                 { var id [32]byte; rand.Read(id[:]); return hex.EncodeToString(id[:]) }
func (c *dockerContainer) dir() string { return filepath.Join(engineRoot, "containers", c.ID) }
func (c *dockerContainer) signal() {
	c.completeExitReceipt()
	close(c.changed)
	c.changed = make(chan struct{})
}
func (c *dockerContainer) busy() bool { return c.Phase == "starting" || c.Phase == "running" }

// save makes c's record durable before it returns (only whole, for an
// AutoRemove container: commitIn).
func (c *dockerContainer) save() error {
	return c.dockerRecord.saveIn(c.dir())
}

// saveVisible replaces c's record whole without waiting for the disk: a crash
// leaves this record or the one before it, never a torn one. Only for a write
// that a durable save repeats before anything depends on it surviving a
// crash, or that recovery does not need; each caller says which.
func (c *dockerContainer) saveVisible() error {
	_, err := writeRecord(c.dockerRecord, c.dir(), false)
	return err
}

// saveStartIntent saves a start's record (Phase starting). The intent must be
// durable before the process can run, so that recovery never reports an
// earlier exit for an interrupted run. A retained rootfs puts it on the disk
// with its attachment record (bindDockerRootFS), durably and before CRI starts
// the task, so until then this record need only be whole: losing it in a
// crash loses a start nobody was told about. Any other container saves it as
// save does (an AutoRemove one is never durable: recovery removes it).
func (c *dockerContainer) saveStartIntent() error {
	if c.retainsRootFS() {
		return c.saveVisible()
	}
	return c.save()
}

func (r dockerRecord) saveIn(directory string) error {
	_, err := r.commitIn(directory)
	return err
}

func (r dockerRecord) commitIn(directory string) (bool, error) {
	// Ephemeral AutoRemove containers are deleted on exit and cleaned up on
	// crash recovery: their record must be whole, never durable.
	return writeRecord(r, directory, !r.Config.HostConfig.AutoRemove)
}

// writeRecord is dockerRecord.writeIn; a variable only so tests can see which
// saves are durable.
var writeRecord = dockerRecord.writeIn

// writeIn replaces directory/state with r. The new record's data is on the
// disk before the rename (writeOut), so a crash leaves the old record or the
// new one, whole. durable then syncs the directory, so the new one survives a
// crash: on the journaled OS disk that is the save's only journal commit.
func (r dockerRecord) writeIn(directory string, durable bool) (bool, error) {
	b, err := json.Marshal(r)
	if err != nil {
		return false, err
	}
	path := filepath.Join(directory, "state")
	f, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return false, err
	}
	_, err = f.Write(b)
	if err == nil {
		err = writeOut(f)
	}
	err = errors.Join(err, f.Close())
	if err != nil {
		return false, err
	}
	if err = os.Rename(path+".tmp", path); err != nil {
		return false, err
	}
	if !durable {
		recordWrites.Add(1)
		return true, nil
	}
	recordCommits.Add(1)
	return true, syncRecordDir(directory)
}

// syncRecordDir is syncDir for the records' directories; a variable only so
// tests can see when a record becomes durable.
var syncRecordDir = syncDir

func syncDir(path string) error {
	d, err := os.Open(path)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func (s *dockerEngine) recover(ctx context.Context) error {
	lease, err := engineRecoveryLease()
	if err != nil {
		return err
	}
	defer lease.Close()
	retired := filepath.Join(engineRoot, "retired")
	old, err := os.ReadDir(retired)
	if err != nil {
		return err
	}
	for _, e := range old {
		if !e.IsDir() || !fullContainerID.MatchString(e.Name()) {
			continue
		}
		path := filepath.Join(retired, e.Name())
		c, err := loadDockerRecord(retired, e.Name())
		if errors.Is(err, os.ErrNotExist) {
			err = os.RemoveAll(path)
		} else if err == nil {
			err = s.reclaimDockerRootFS(ctx, c, path)
		}
		if err != nil {
			return err
		}
	}
	dir := filepath.Join(engineRoot, "containers")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() || !fullContainerID.MatchString(e.Name()) {
			continue
		}
		p := filepath.Join(dir, e.Name())
		c, err := loadDockerRecord(dir, e.Name())
		if errors.Is(err, os.ErrNotExist) {
			if err := os.RemoveAll(p); err != nil {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		if err := s.node.recoverDockerRootFSBinding(ctx, c); err != nil {
			return fmt.Errorf("recover Docker container %s: %w", c.ID, err)
		}
		if err := c.recoverDockerNetworkPod(ctx, p, s.node.removeOwnedPod); err != nil {
			return fmt.Errorf("recover named network sandbox for %s: %w", c.ID, err)
		}
		if c.Phase == "removing" || (c.Config.HostConfig.AutoRemove && c.Phase != "created") {
			if c.RootFS != nil {
				return errors.New("retired rootfs record remains in the active Docker catalog")
			}
			if err := os.RemoveAll(p); err != nil {
				return err
			}
			continue
		}
		if c.busy() {
			// The node reconciles all owned pods before this socket opens. The exit
			// of an interrupted process is unknown and must never become success.
			c.Phase = "dead"
			c.RuntimeID = ""
			c.Exit = -1
			c.Failure = "worker restarted before it recorded the process exit"
			if err := c.save(); err != nil {
				return err
			}
		}
		if err := c.recoverDockerOutput(p); err != nil {
			return fmt.Errorf("recover Docker log for %s: %w", c.ID, err)
		}
		if err := removeDockerRuntimeLog(p); err != nil {
			return fmt.Errorf("remove retired CRI log for %s: %w", c.ID, err)
		}
		s.containers[c.ID] = c
	}
	if err := s.verifyDockerNetworkReservations(); err != nil {
		return err
	}
	return s.recoverCPUGroupPlacements()
}
func serveEngine(ctx context.Context, n node) error {
	// Everything up to the open socket is bounded (startup_watchdog.go).
	watch := armStartupWatchdog(startupBudget, os.Exit)
	defer watch.disarm()
	// start.sh runs everything under umask 077. Directories the engine creates
	// (named volumes, cache scopes) set their modes explicitly as well.
	unix.Umask(022)
	if privateRootless() && !inAllocationUserNS() {
		return errors.New("private engine requires the allocation user namespace")
	}
	dockerSocket := clientSocket(dockerSocket, "docker.sock")
	for _, d := range []string{filepath.Join(engineRoot, "containers"), filepath.Join(engineRoot, "volumes"), filepath.Join(engineRoot, "volume-meta"), filepath.Join(engineRoot, "retired"), filepath.Dir(engineGate)} {
		if err := os.MkdirAll(d, 0700); err != nil {
			return err
		}
	}
	owner, err := os.OpenFile(filepath.Join(filepath.Dir(engineGate), "docker.owner"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer owner.Close()
	if err := syscall.Flock(int(owner.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("Docker API already has an owner")
	}
	if kernelPublishedPorts() && os.Getenv("MICROPOD_CI_PUBLISH_IPV4") != "" && os.Getenv("MICROPOD_CI_PORT_THROUGHPUT") == "1" {
		if err := pacePublishedLink(); err != nil {
			log.Printf("published interface fair queuing: %v", err)
		}
	}
	if kernelPublishedPorts() {
		// The exclusive API owner recovers interrupted jobs below. Discard their
		// mappings before either a pod address or a guest port can be reused.
		if out, err := exec.CommandContext(ctx, "iptables", "-w", "5", "-t", "nat", "-F", "MP-PUB-IN").CombinedOutput(); err != nil {
			return fmt.Errorf("recover published ports: %w: %.512s", err, out)
		}
		if _, err := netlink.ConntrackTableList(netlink.ConntrackTable, netlink.FAMILY_V4); err != nil && !errors.Is(err, netlink.ErrDumpInterrupted) {
			log.Printf("published flows unavailable, using guest TCP relay: %v", err)
			if err := os.Unsetenv("MICROPOD_PUBLISH_IPV4"); err != nil {
				return err
			}
		}
	}
	g, err := os.OpenFile(engineGate, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	g.Close()
	logWatcher, watchErr := newCRILogWatcher()
	if watchErr != nil {
		log.Printf("CRI log notifications unavailable: %v", watchErr)
	} else {
		defer logWatcher.close()
		n.watchLog = logWatcher.watch
	}
	s := &dockerEngine{node: n, workspace: os.Getenv("MICROPOD_ENGINE_WORKSPACE"), containers: make(map[string]*dockerContainer), execs: make(map[string]*dockerExec)}
	if !privateRootless() {
		s.machineDir = engineMachineDir()
	}
	if !privateRootless() && os.Getenv("MICROPOD_CI_PUBLISHED_PATH") == "macvlan" {
		s.direct, err = newDirectNetwork(ctx)
		if err != nil {
			return fmt.Errorf("initialize direct published ports: %w", err)
		}
	}
	if raw := os.Getenv("MICROPOD_CI_MAX_STARTING"); raw != "" {
		limit, err := strconv.Atoi(raw)
		if err != nil || limit < 0 || limit > 32 {
			return errors.New("invalid native container start limit")
		}
		if limit > 0 {
			s.startSlots = make(chan struct{}, limit)
		}
	}
	s.namedNetworks = make(map[string]*workerNetwork)
	if !privateRootless() {
		if err := guardHostOutput(ctx); err != nil {
			return fmt.Errorf("refuse the machine's own connections into container networks: %w", err)
		}
		if _, err := prepareDockerBridgeResolver(); err != nil {
			return fmt.Errorf("prepare the native bridge resolver: %w", err)
		}
	}
	if !privateRootless() {
		// Before the socket opens and before buildkitd can start: BuildKit
		// lists the platforms it builds by running a test binary of each,
		// once (emulation_linux.go). Needs no containerd.
		watch.enter("setting up linux/amd64 emulation")
		setupAmd64Emulation(ctx)
	}
	// start.sh starts the engine beside containerd: what is above needs no
	// containerd, and overlaps its start. Recovery does need it, and the
	// socket opens only after recovery, so a _ping is never answered by an
	// engine that cannot serve yet.
	watch.enter("waiting for containerd's CRI")
	if err := awaitRuntime(ctx, systemClock{}, runtimeWaitInterval, runtimeWaitBudget, n.runtimeReady); err != nil {
		return err
	}
	// Before anything can use an image: after an unclean stop, what may not
	// have reached the disk goes (image_durability_linux.go).
	var repull []string
	buildkitOK := true
	if !privateRootless() {
		watch.enter("checking the image store")
		if repull, buildkitOK, err = n.recoverImageStore(ctx); err != nil {
			return err
		}
	}
	// The scheduler jobs a previous boot left, as `job recover` did before
	// start.sh started the engine.
	watch.enter("recovering interrupted jobs")
	if err := n.recover(ctx); err != nil {
		return fmt.Errorf("recover interrupted jobs: %w", err)
	}
	watch.enter("recovering networks")
	if err := s.recoverNetworks(ctx); err != nil {
		return err
	}
	watch.enter("recovering containers")
	if err := s.recover(ctx); err != nil {
		return err
	}
	watch.enter("sweeping what the previous engine left")
	// Recovery has retired the previous owner's tasks. Their transient FIFO
	// names can be reclaimed while this engine still owns the worker lock.
	s.execPipeDir = filepath.Join(filepath.Dir(engineGate), "exec")
	if err := os.RemoveAll(s.execPipeDir); err != nil {
		return err
	}
	if err := os.Mkdir(s.execPipeDir, 0700); err != nil {
		return err
	}
	// Before any volume is removed, so the sweep deletes only what an
	// earlier engine left.
	sweepVolumeTrash()
	if !privateRootless() {
		// Before the socket opens, so a job of the same project finds the
		// names free; for orphanReapWait at most, within startupBudget.
		s.reapOrphanFamilies(ctx)
	}
	if !privateRootless() {
		// Before the socket opens, so no probe of this engine can be swept
		// and no container of this engine holds a cache unit yet (a unit a
		// scheduler job still holds is left alone).
		sweepProbes(ctx, n.probeKeys, unmountProbe)
		sweepCacheViews()
		// The crash fence's recovery completes before the janitor exists:
		// it discards what an unclean stop left marked, then empties .trash
		// (earlier boots' and its own) in the background. Recovery and every
		// janitor or prune pass also hold the cache maintenance lock
		// (caches_manage_linux.go), so they never overlap in any process.
		// Guest init mounted the cache disk before it started the engine, so
		// recovery reads the marks and the clean-stop record on the disk that
		// holds the stores; without that disk it and the janitor do nothing.
		if why := cacheDiskUnavailable(); why != "" {
			log.Printf("shared caches are off this boot: %s", why)
		}
		watch.enter("recovering the shared caches (dirty marks)")
		discardDirtyCaches()
		go cacheDirty.run(ctx)
		go s.runCacheJanitor(ctx)
	}
	raiseFileLimit()
	s.capacity.proc = "/proc"
	go s.capacity.run(ctx.Done())
	if st, err := os.Lstat(dockerSocket); err == nil && st.Mode()&os.ModeSocket == 0 {
		return errors.New("Docker API path is occupied")
	}
	if err := os.Remove(dockerSocket); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	l, err := net.Listen("unix", dockerSocket)
	if err != nil {
		return err
	}
	defer l.Close()
	if err := os.Chmod(dockerSocket, 0600); err != nil {
		return err
	}
	watch.enter("starting the BuildKit socket")
	// A BuildKit that still holds cache records recovery could not have it
	// prune would build on files that may never have reached the disk.
	if buildkitOK {
		s.buildkitSocket, err = serveBuildKit(ctx)
		if err != nil {
			return err
		}
	}
	watch.disarm()
	if len(repull) > 0 {
		go n.repullPinnedImages(ctx, repull)
	}
	// Every request on this socket is the host's (cacheOrigin): only guest
	// init's vsock bridge reaches it. In the rootless engine the socket is
	// also bound into the job's containers (dockerSocketMount), which have
	// no shared caches at all (planRootless).
	origin := cacheOrigin{hostFacing: true}
	server := &http.Server{Handler: s, BaseContext: func(net.Listener) context.Context { return withCacheOrigin(ctx, origin) },
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 << 10}
	go func() { <-ctx.Done(); server.Close() }()
	err = server.Serve(l)
	if !privateRootless() {
		// An orderly stop: units no writer holds are synced and unmarked.
		// Containers still running keep theirs marked; guest init's
		// clean-stop record clears them at the next start.
		cacheDirty.shutdown()
		// The image store's record then covers everything this boot
		// committed, whether or not guest init records a clean stop.
		syncImageStoreAtStop()
	}
	return err
}
func engineLease() (*os.File, error) {
	f, err := os.Open(engineGate)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fail(409, "worker is draining")
	}
	return f, nil
}

// Recovery can run in a separate job process. Keep both startup and its job
// sweep out of the window between binding intent and CRI cleanup.
func engineRecoveryLease() (*os.File, error) {
	if err := os.MkdirAll(filepath.Dir(engineGate), 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(engineGate, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("cannot reconcile while the native engine is active: %w", err)
	}
	return f, nil
}

type apiError struct {
	code    int
	message string
}

func (e apiError) Error() string      { return e.message }
func fail(code int, msg string) error { return apiError{code, msg} }
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
func (s *dockerEngine) lookup(key string) (*dockerContainer, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c := s.containers[key]; c != nil {
		return c, nil
	}
	var found *dockerContainer
	for _, c := range s.containers {
		if c.Name == key {
			return c, nil
		}
		if len(key) >= 4 && strings.HasPrefix(c.ID, key) {
			if found != nil {
				return nil, fail(409, "ambiguous container ID")
			}
			found = c
		}
	}
	if found == nil {
		return nil, fail(404, "no such container: "+key)
	}
	return found, nil
}
func (s *dockerEngine) create(ctx context.Context, spec dockerConfig, name string) (*dockerContainer, error) {
	return s.createFor(ctx, spec, name, nil)
}

// createFor creates a container from the image ref means for platform (nil:
// the request names none).
func (s *dockerEngine) createFor(ctx context.Context, spec dockerConfig, name string, platform *ocispec.Platform) (*dockerContainer, error) {
	if name != "" && !dockerName.MatchString(name) {
		return nil, fail(400, "invalid container name")
	}
	s.capacity.creating.Add(1)
	defer s.capacity.creating.Add(-1)
	spec.Labels = stampFamily(ctx, spec.Labels)
	spec.HostConfig.applyDefaultLimits(s.cachePolicy.get())
	s.imageMu.RLock()
	defer s.imageMu.RUnlock()
	img, err := s.node.dockerPlatformImageStatus(ctx, spec.Image, platform)
	if err != nil {
		return nil, err
	}
	if img.GetImage().GetId() == "" {
		return nil, fail(404, "No such image: "+spec.Image)
	}
	// An image of another platform runs only through emulation; without it,
	// say so now rather than with an exec format error at start.
	imagePlatformName := ""
	if p, ok := imagePlatform(img); ok {
		if runs, why := runsHere(p); !runs {
			return nil, fail(http.StatusBadRequest, "cannot create a container from "+spec.Image+": "+why)
		}
		imagePlatformName = platforms.Format(p)
	}
	spec.ExposedPorts = mergeImageExposedPorts(spec.ExposedPorts, img.GetInfo()["info"])
	if err := s.configureDockerHealth(ctx, &spec, img.GetImage().GetId()); err != nil {
		return nil, err
	}
	if spec.HostConfig.PublishAllPorts {
		if _, err := spec.requestedPorts(); err != nil {
			return nil, fail(400, err.Error())
		}
	}
	// Before s.mu: a first probe of an image mounts it (tens of ms, seconds
	// when containerd must unpack it first).
	plan, runAs, err := s.cacheDecisionFor(ctx, spec, img.Image.Id, imagePlatformName)
	if err != nil {
		return nil, err
	}
	engineSocket, err := s.engineSocketGrant(ctx, spec)
	if err != nil {
		return nil, err
	}
	id := engineID()
	if name == "" {
		name = "mp-" + id[:12]
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.containers {
		if c.Name != name {
			continue
		}
		if !seesContainer(viewerOf(ctx), c) {
			// Names are the machine's; another job's container is not there.
			return nil, fail(http.StatusConflict, fmt.Sprintf("Conflict. The container name %q is already in use by another job's container. %s", "/"+c.Name, ownNamesAdvice))
		}
		return nil, fail(http.StatusConflict, fmt.Sprintf("Conflict. The container name %q is already in use by container %q. You have to remove (or rename) that container to be able to reuse that name.", "/"+c.Name, c.ID))
	}
	network, ip, endpoints, err := s.selectNetworkFor(&spec, viewerOf(ctx))
	if err != nil {
		return nil, err
	}
	// A create through a container's delegated socket: its child sees only
	// what that container may hand it (docker_delegated_linux.go).
	var createdBy string
	var bindRoots map[string]string
	if viewer := viewerOf(ctx); viewer != "" && !privateRootless() {
		createdBy = viewer
		if bindRoots, err = s.delegatedCreateLocked(viewer, &spec); err != nil {
			return nil, err
		}
	} else if viewer == "" {
		if err := s.hostJoinLocked("", append([]string{network}, endpointNetworks(endpoints)...), &spec); err != nil {
			return nil, err
		}
	}
	if _, err := s.requestedJobParent(spec, network); err != nil {
		return nil, err
	}
	group, err := spec.requestedCPUGroup(network)
	if err != nil {
		return nil, err
	}
	if group.name != "" {
		spec.HostConfig.CpusetCpus, err = s.groupCPULocked(group)
		if err != nil {
			return nil, err
		}
	}
	creator, err := s.creatorHoldLocked(createdBy, createdBy, bindRoots)
	if err != nil {
		return nil, err
	}
	files, _, _, err := s.openMountsWith(spec, containerVolumeRules(s.cachePolicy.get(), spec, plan, createdBy), true, mountSockets{bindRoots: bindRoots, creator: creator}, "")
	if err != nil {
		var api apiError
		if !errors.As(err, &api) {
			err = fail(400, err.Error())
		}
		return nil, err
	}
	closeMounts(files)
	c := &dockerContainer{dockerRecord: dockerRecord{ID: id, Name: name, NetworkID: network, NetworkIP: ip, SecondaryNetworks: endpoints, ImageID: img.Image.Id, ImagePlatform: imagePlatformName, ImageEnv: imageEnv(img.GetInfo()["info"]), Phase: "created", Created: time.Now().UTC(), Config: spec, CPUGrouped: group.name != "", Cache: plan, RunAs: runAs, EngineSocket: engineSocket, CreatedBy: createdBy, BindRoots: bindRoots}, changed: make(chan struct{})}
	if err := os.Mkdir(c.dir(), 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(c.logPath(), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err == nil {
		err = f.Close()
	}
	if err == nil {
		err = c.save()
	}
	if err == nil && !c.Config.HostConfig.AutoRemove {
		err = syncDir(filepath.Dir(c.dir()))
	}
	if err != nil {
		os.RemoveAll(c.dir())
		return nil, err
	}
	s.containers[id] = c
	s.containerEvent(c, "create", nil)
	s.metrics.creates.Add(1)
	mounts, _ := spec.mounts()
	for _, m := range mounts {
		if m.Type == "volume" {
			if _, ok := sharedCachePath(m.Source); ok {
				s.metrics.sharedMounts.Add(1)
			}
		}
	}
	s.metrics.cache.recordPlan(plan)
	return c, nil
}

// volumeRules is what openMounts enforces on alias volumes for a container
// with this request and plan under this policy.
func volumeRules(pol cachePolicy, spec dockerConfig, plan *cachePlan) cacheVolumeRules {
	c := dockerContainer{dockerRecord: dockerRecord{Config: spec, Cache: plan}}
	scope := containerScope(pol, spec)
	if plan != nil && plan.Scope != "" {
		scope = plan.Scope // decided at create, as the tier
	}
	return cacheVolumeRules{readOnly: c.cacheReadOnly(pol), allows: pol.allows, scope: scope, sharedL0: pol.SharedL0}
}

// containerVolumeRules is volumeRules for a container createdBy made through
// its Docker socket ("" for the host): such a child is held to its scope, its
// creator's (decideCachesFor), whatever its tier.
func containerVolumeRules(pol cachePolicy, spec dockerConfig, plan *cachePlan, createdBy string) cacheVolumeRules {
	rules := volumeRules(pol, spec, plan)
	rules.confined = createdBy != ""
	return rules
}

// cacheDecision loads the image facts when anything needs them and makes the
// attach decision. Only a disallowed scope, an unknown tool name or trust
// value or an unresolvable user fails the create; a failed probe attaches
// nothing. The request's origin (withCacheOrigin; none is a container's
// socket) bounds its trust: a create through a socket bound into a container
// is never more trusted than that container's own plan.
func (s *dockerEngine) cacheDecision(ctx context.Context, spec dockerConfig, imageID string) (*cachePlan, *runAsUser, error) {
	return s.cacheDecisionFor(ctx, spec, imageID, "")
}

// cacheDecisionFor is cacheDecision for an image of the platform named ("":
// the engine's own). An emulated container gets the same scope, trust, read-
// only views and stores as a native one, except a store that holds programs
// of the architecture that wrote it (cacheTool.NativeOnly).
func (s *dockerEngine) cacheDecisionFor(ctx context.Context, spec dockerConfig, imageID, platform string) (*cachePlan, *runAsUser, error) {
	pol := s.cachePolicy.get()
	req := cacheRequest{origin: cacheOriginOf(ctx), proxyUp: dependencyProxies.up}
	if platform != "" && platform != enginePlatform {
		req.emulated = true
	}
	if !req.origin.hostFacing && req.origin.creator != "" {
		s.mu.Lock()
		if creator := s.containers[req.origin.creator]; creator != nil {
			req.origin.creatorScope = containerScope(pol, creator.Config)
			if creator.Cache != nil && creator.Cache.Scope != "" {
				req.origin.creatorScope = creator.Cache.Scope // decided at its create
			}
			req.origin.creatorTier = trustTrusted
			if creator.cacheReadOnly(pol) {
				// A reader's own name for its tier (readonly or untrusted);
				// a legacy plan read as untrusted has none.
				req.origin.creatorTier = trustUntrusted
				if creator.Cache != nil && creator.Cache.ReadOnly {
					req.origin.creatorTier = creator.Cache.tier()
				}
			}
		}
		s.mu.Unlock()
	}
	off := pol.Mode == "off" || isOff(requestCacheValue(spec)) || strings.EqualFold(spec.Labels["micropod.cache.shared"], "false")
	u, g, _ := strings.Cut(spec.User, ":")
	_, uNum := numericID(u)
	_, gNum := numericID(g)
	named := spec.User != "" && (!uNum || g != "" && !gNum)
	needFacts := !privateRootless() && (!off || named)
	var facts imageFacts
	if needFacts {
		var probed bool
		facts, probed = s.imageFacts.load(ctx, s.node.images, imageID)
		if probed {
			s.metrics.cache.recordProbe(facts.ProbeMS, facts.OK)
		}
	}
	runAs, err := runAsFor(spec.User, &facts)
	if err != nil {
		return nil, nil, fail(400, err.Error())
	}
	// The config files the container's tools would read, where a request's
	// bind or volume puts them: a registry or a GOPROXY they set wins over
	// the policy's proxy as the image's own files do (decideProxy).
	env := append(append([]string{}, facts.Env...), spec.Env...)
	user := spec.User
	if user == "" {
		user = facts.User
	}
	var roots *childProbeRoots
	if (pol.NpmRegistry != "" || pol.GoProxy != "") && !off {
		roots = s.probeRoots(ctx, spec)
		defer roots.close()
	}
	if pol.NpmRegistry != "" && !off {
		wd := spec.WorkingDir
		if wd == "" {
			wd = facts.WorkingDir
		}
		// The working directory and every one above it, as the project's
		// own .npmrc, wherever a bind or a volume puts them.
		req.projectNpmRegistry = s.projectNpmRegistry(spec, facts.WorkingDir, roots) ||
			s.mountedConfigSets(spec, npmrcCandidates(env, facts.Passwd, user, wd), npmrcSetsRegistry, roots)
	}
	if pol.GoProxy != "" && !off {
		req.projectGoProxy = s.mountedConfigSets(spec, goEnvCandidates(env, facts.Passwd, user), goEnvSetsProxy, roots)
	}
	plan, err := decideCachesFor(pol, spec, facts, req)
	if err != nil {
		return nil, nil, err
	}
	return &plan, runAs, nil
}

// childProbeRoots holds the config probes of a create through a delegated
// socket (projectNpmRegistry, mountedConfigSets) to what its child may bind:
// each bind's root (delegatedBinds on a copy of the request; empty when its
// binds are not inside its creator's, so no probe reads outside them:
// whether a probe found a setting shows in the child's environment), and a
// copy of the descriptor the running creator binds each root from, so a
// probe resolves a root as the creator binds it (openMountWithin).
type childProbeRoots struct {
	roots map[string]string
	held  map[string]*os.File
}

func (r *childProbeRoots) close() {
	if r == nil {
		return
	}
	for _, f := range r.held {
		f.Close()
	}
}

// probeRoots is the childProbeRoots of a create: nil for the host's socket,
// whose binds resolve from the workspace. Close it once the probes are done.
func (s *dockerEngine) probeRoots(ctx context.Context, spec dockerConfig) *childProbeRoots {
	viewer := viewerOf(ctx)
	if viewer == "" || privateRootless() {
		return nil
	}
	spec.HostConfig.Binds = slices.Clone(spec.HostConfig.Binds)
	spec.HostConfig.Mounts = slices.Clone(spec.HostConfig.Mounts)
	s.mu.Lock()
	defer s.mu.Unlock()
	probe := &childProbeRoots{roots: map[string]string{}, held: map[string]*os.File{}}
	owner := s.containers[viewer]
	if owner == nil {
		return probe
	}
	roots, err := delegatedBinds(owner, &spec)
	if err != nil {
		return probe
	}
	probe.roots = roots
	creator, err := s.creatorHoldLocked(viewer, viewer, roots)
	if err != nil {
		return probe
	}
	for _, root := range roots {
		if f := creator.rootOf(root); f != nil && probe.held[root] == nil {
			if fd, err := unix.FcntlInt(f.Fd(), unix.F_DUPFD_CLOEXEC, 0); err == nil {
				probe.held[root] = os.NewFile(uintptr(fd), root)
			}
		}
	}
	return probe
}

// openConfigFile opens the file at p, which the request mount m covers, for a
// config probe: below m's root for a child of a delegated socket (roots, nil
// for the host's), else below the workspace for a bind, and below the volume
// itself for a named one, so a symlink a mount carries cannot lead a probe
// into another job's files.
func (s *dockerEngine) openConfigFile(m dockerMount, p string, roots *childProbeRoots) (*os.File, error) {
	switch {
	case m.Type == "bind" && roots != nil:
		root := roots.roots[m.Target]
		if root == "" {
			return nil, errors.New("bind source is outside the creating container's binds")
		}
		return openMountWithin(s.workspace, root, p, roots.held[root])
	case m.Type == "bind":
		return openMount(s.workspace, p)
	case m.Type == "volume" && dockerName.MatchString(m.Source):
		return openMount(filepath.Join(configVolumesDir, m.Source), p)
	}
	return nil, errors.New("not a bind or a named volume")
}

// projectNpmRegistry reports whether the project a container works in sets
// its own npm registry: an unscoped registry= in a .npmrc in its working
// directory (the request's, else the image's) or in any directory above it
// that the same workspace bind covers. Files are opened below the workspace
// (below roots, openConfigFile) without following symlinks out of it; a
// missing or unreadable file counts as no setting.
func (s *dockerEngine) projectNpmRegistry(spec dockerConfig, imageWorkDir string, roots *childProbeRoots) bool {
	wd := spec.WorkingDir
	if wd == "" {
		wd = imageWorkDir
	}
	if s.workspace == "" || !filepath.IsAbs(wd) {
		return false
	}
	wd = filepath.Clean(wd)
	mounts, _ := spec.mounts()
	var bind *dockerMount
	for i, m := range mounts {
		if m.Type != "bind" || m.tmpfs != nil || !filepath.IsAbs(m.Target) {
			continue
		}
		t := filepath.Clean(m.Target)
		if (wd == t || strings.HasPrefix(wd, t+"/") || t == "/") && (bind == nil || len(t) > len(filepath.Clean(bind.Target))) {
			bind = &mounts[i]
		}
	}
	if bind == nil {
		return false
	}
	target := filepath.Clean(bind.Target)
	rel, err := filepath.Rel(target, wd)
	if err != nil || strings.HasPrefix(rel, "..") {
		return false
	}
	dir := filepath.Join(bind.Source, rel)
	for i := 0; i < 32; i++ {
		if f, err := s.openConfigFile(*bind, filepath.Join(dir, ".npmrc"), roots); err == nil {
			b := readNpmrc(f)
			f.Close()
			if npmrcSetsRegistry(b) {
				return true
			}
		}
		if dir == filepath.Clean(bind.Source) || dir == "/" {
			break
		}
		dir = filepath.Dir(dir)
	}
	return false
}

// configVolumesDir is where mountedConfigSets finds named volumes (volumePath);
// a variable only so tests can point it at a temporary directory.
var configVolumesDir = filepath.Join(engineRoot, "volumes")

// mountedConfigSets reports whether one of the files at the container paths
// comes from a bind or a named volume of the request (the mount with the
// longest target that covers the path decides) and match accepts what it
// holds now. Files are opened below the bind (openConfigFile) or the volume
// without following symlinks out of it; a missing or unreadable file counts
// as no setting. A file a step writes after create (a clone into a volume, a
// cd into a subproject) is not seen: the policy's proxy then wins over it.
func (s *dockerEngine) mountedConfigSets(spec dockerConfig, paths []string, match func([]byte) bool, roots *childProbeRoots) bool {
	mounts, _ := spec.mounts()
	for _, p := range paths {
		if !filepath.IsAbs(p) {
			continue
		}
		p = filepath.Clean(p)
		var cover *dockerMount
		for i, m := range mounts {
			if !filepath.IsAbs(m.Target) {
				continue
			}
			t := filepath.Clean(m.Target)
			if (p == t || strings.HasPrefix(p, t+"/") || t == "/") && (cover == nil || len(t) > len(filepath.Clean(cover.Target))) {
				cover = &mounts[i]
			}
		}
		if cover == nil || cover.tmpfs != nil {
			continue
		}
		rel, err := filepath.Rel(filepath.Clean(cover.Target), p)
		if err != nil || strings.HasPrefix(rel, "..") {
			continue
		}
		var f *os.File
		switch {
		case cover.Type == "bind" && s.workspace != "":
			f, err = s.openConfigFile(*cover, filepath.Join(cover.Source, rel), roots)
		case cover.Type == "volume" && dockerName.MatchString(cover.Source):
			if _, _, shared := legacyCacheVolume(cover.Source); shared {
				continue
			}
			f, err = s.openConfigFile(*cover, filepath.Join(configVolumesDir, cover.Source, rel), roots)
		default:
			continue
		}
		if err != nil {
			continue
		}
		b := readNpmrc(f)
		f.Close()
		if match(b) {
			return true
		}
	}
	return false
}

// readNpmrc reads up to 64 KiB of a config file (an npmrc, a go env file)
// opened O_PATH by openMount.
func readNpmrc(f *os.File) []byte {
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		return nil
	}
	r, err := os.Open(dockerMountFDPath(f))
	if err != nil {
		return nil
	}
	defer r.Close()
	b, _ := io.ReadAll(io.LimitReader(r, 64<<10))
	return b
}

// start starts c; viewer is the container whose delegated socket asked for
// it ("" for the host's socket).
func (s *dockerEngine) start(c *dockerContainer, restart bool, viewer string) (startErr error) {
	begun := time.Now()
	s.capacity.starting.Add(1)
	defer func() {
		s.capacity.starting.Add(-1)
		if startErr == nil {
			s.capacity.recordStart(time.Since(begun))
			return
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if c.removed || c.Phase != "created" {
			return
		}
		c.Phase = "dead"
		c.Failure = startErr.Error()
		c.Exit = -1
		c.Exits++
		c.Finished = time.Now().UTC()
		if c.Config.HostConfig.AutoRemove {
			startErr = errors.Join(startErr, s.removeLocked(c))
		} else {
			startErr = errors.Join(startErr, c.save())
		}
		c.signal()
	}()
	lease, err := engineLease()
	if err != nil {
		return err
	}
	// Before s.mu (a check waits up to proxyProbeTimeout): the proxies the
	// create injected that do not answer now are left out of this start. The
	// plan's proxy fields are written only at create.
	proxyDown := c.Cache.unreachableProxies(dependencyProxies.up)
	s.mu.Lock()
	if c.removed || c.Phase == "removing" {
		s.mu.Unlock()
		lease.Close()
		return fail(404, "container removed")
	}
	if c.busy() {
		s.mu.Unlock()
		lease.Close()
		return fail(304, "already started")
	}
	if c.RootFSBinding != nil {
		s.mu.Unlock()
		lease.Close()
		return fail(409, "previous writable rootfs attachment needs worker recovery")
	}
	if c.BridgeGeneration != nil {
		s.mu.Unlock()
		lease.Close()
		return fail(409, "previous named network sandbox needs worker recovery")
	}
	namedPrimary := c.NetworkID != ""
	bridgeEnabled := s.namedNetworks[c.NetworkID].secondaryBridge()
	jobParent, err := s.requestedJobParent(c.Config, c.NetworkID)
	if err != nil {
		s.mu.Unlock()
		lease.Close()
		return err
	}
	// A persisted container may be restarted on a differently sized worker.
	if err := validateDockerCPUSet(c.Config.HostConfig.CpusetCpus); err != nil {
		grouped := c.CPUGrouped
		s.mu.Unlock()
		lease.Close()
		if grouped {
			return fail(409, "CPU group placement is unavailable. Restart the worker to reconcile the group. "+err.Error())
		}
		return fail(400, err.Error())
	}
	socket, closeSocket, err := s.openCleanupSocket(c)
	if err != nil {
		s.mu.Unlock()
		lease.Close()
		return err
	}
	engineSocket, closeEngineSocket, err := s.openEngineSocket(c)
	if err != nil {
		s.mu.Unlock()
		closeSocket()
		lease.Close()
		return err
	}
	// From here every path that closes the cleanup socket closes both.
	if closeCleanup := closeSocket; engineSocket != "" {
		closeSocket = func() { closeEngineSocket(); closeCleanup() }
	}
	pol := s.cachePolicy.get()
	// A plan an older engine made has no tier of its own yet, or an older
	// table's exclusive kinds.
	c.Cache.applyCurrentRules(pol)
	creator, err := s.creatorHoldLocked(c.CreatedBy, viewer, c.BindRoots)
	if err != nil {
		s.mu.Unlock()
		closeSocket()
		lease.Close()
		return err
	}
	files, mounts, aliasPins, err := s.openMountsWith(c.Config, containerVolumeRules(pol, c.Config, c.Cache, c.CreatedBy), false,
		mountSockets{cleanup: socket, engine: engineSocket, bindRoots: c.delegatedBindRoots(), creator: creator}, filepath.Join(c.dir(), "shim"))
	if err != nil {
		s.mu.Unlock()
		closeSocket()
		lease.Close()
		return err
	}
	held := &heldBinds{byTarget: mountFiles(files, mounts)}
	// Replay the create-time decision; never recompute it. The unit locks and
	// pinned store directories stay open until the container exits.
	caches := openCacheMounts(c.Cache, filepath.Join(c.dir(), "shim"))
	caches.env = withoutProxies(caches.env, proxyDown)
	// The attachment's descriptors close with the start's own; release()
	// (on every failure below and after the container exits) first tears
	// down its copy-on-write views, then drops its holds and pins.
	caches.adopt(aliasPins)
	files = append(files, caches.files...)
	mounts = append(mounts, caches.mounts...)
	if m := dockerEnvMount(c.Config); m != nil {
		mounts = append(mounts, m)
	}
	for _, reason := range caches.skipped {
		s.metrics.cache.skip(reason)
	}
	f, err := os.OpenFile(c.logPath(), os.O_APPEND|os.O_WRONLY, 0)
	if err == nil && c.LogError != "" {
		// A previous failed write may have left bytes beyond the last complete
		// frame. Remove that suffix before this generation can append.
		err = f.Truncate(c.outputBytes)
		if err != nil {
			f.Close()
		}
	}
	if err != nil {
		s.mu.Unlock()
		closeSocket()
		caches.release()
		closeMounts(files)
		lease.Close()
		return err
	}
	var console *dockerPID1
	if c.Config.captureRawOutput() {
		console, err = newDockerPID1(s.execPipeDir, c.Config)
		if err != nil {
			s.mu.Unlock()
			closeSocket()
			f.Close()
			caches.release()
			closeMounts(files)
			lease.Close()
			return err
		}
	}
	previous := c.dockerRecord
	c.CacheSkipped = caches.skipped
	c.CacheAccess = caches.access
	c.CacheProxy = proxyDown
	c.Phase = "starting"
	c.OOMKilled = false
	c.Failure = ""
	c.RuntimeID = ""
	c.Finished = time.Time{}
	c.Started = time.Time{}
	c.Exit = 0
	if err = c.saveStartIntent(); err != nil {
		c.dockerRecord = previous
		s.mu.Unlock()
		closeSocket()
		f.Close()
		caches.release()
		closeMounts(files)
		lease.Close()
		if console != nil {
			_ = console.finish(context.Background())
		}
		return err
	}
	c.console = console
	c.binds = held // until the exit below, before its files close
	c.generationLogError = ""
	write, sealLog := s.appendDockerOutput(c, f, c.outputBytes)
	ctx, cancel := context.WithCancel(context.Background())
	c.signal()
	started := make(chan error, 1)
	s.mu.Unlock()
	go func() {
		defer lease.Close()
		defer closeSocket()
		// release is idempotent: the exit path below releases the caches
		// itself once it has stamped them; this covers every other way out.
		defer func() { caches.release(); closeMounts(files) }()
		defer f.Close()
		defer cancel()
		var forwards []*publishedPort
		launched := false
		var slotHeld bool
		releaseStart := func() {
			if slotHeld {
				<-s.startSlots
				slotHeld = false
			}
		}
		defer releaseStart()
		j := job{Trust: "trusted", Image: c.ImageID}
		var parentHeld bool
		var bridgeRetireErr error
		hooks := processHooks{
			created: func(ctx context.Context, podID, id string) error {
				if console == nil && len(c.Config.HostConfig.Tmpfs) == 0 && jobParent == "" {
					return nil
				}
				if jobParent != "" {
					if err := s.jobParents.retain(jobParent); err != nil {
						return err
					}
					parentHeld = true
				}
				return s.node.installDockerOCI(ctx, podID, id, c.Config, jobParent, console)
			},
			retire: func() error {
				if bridgeEnabled {
					bridgeRetireErr = s.retireDockerBridge(c)
				}
				if c.Config.Healthcheck != nil {
					s.stopDockerHealth(c)
				}
				s.retireDockerArchive(c)
				var err error
				for i := len(forwards) - 1; i >= 0; i-- {
					err = errors.Join(err, forwards[i].close())
				}
				return err
			},
			podRetired: func() {
				if !namedPrimary {
					return
				}
				if bridgeRetireErr != nil {
					log.Printf("cleaned up bridge sandbox for %s with CRI: %v", c.ID, bridgeRetireErr)
					bridgeRetireErr = nil
				}
				s.acknowledgeDockerPodRetirement(c)
			},
			configure: func(startCtx context.Context, pod ownedPod, cfg *cri.ContainerConfig) error {
				if s.startSlots != nil {
					begin := time.Now()
					select {
					case s.startSlots <- struct{}{}:
						slotHeld = true
						s.metrics.setupWaitUS.Add(time.Since(begin).Microseconds())
					case <-startCtx.Done():
						return startCtx.Err()
					}
				}
				if size, ok := c.Config.HostConfig.Sysctls[tcpQueueSysctl]; ok {
					if err := s.node.setPodTCPQueue(startCtx, pod.pod, size); err != nil {
						return err
					}
				}
				var err error
				if namedPrimary {
					s.mu.Lock()
					err = c.claimDockerNetworkPod(c.dir(), pod)
					s.mu.Unlock()
					if err != nil {
						return err
					}
				}
				forwards, err = s.publish(startCtx, c, pod.pod)
				if err != nil {
					return err
				}
				resolver, err := s.configureDockerBridge(startCtx, c, pod)
				if err != nil {
					return err
				}
				if resolver != "" {
					mounts = append(mounts, &cri.Mount{HostPath: resolver, ContainerPath: "/etc/resolv.conf", Readonly: true})
				}
				return c.Config.configure(cfg, mounts, containerExtras{Env: caches.env, RunAs: c.RunAs})
			},
			started: func(id string) {
				releaseStart()
				s.mu.Lock()
				c.RuntimeID = id
				c.archive = newDockerLiveArchive(files, mounts)
				c.Started = time.Now().UTC()
				c.Phase = "running"
				s.publishDockerBridgeNames(c, true)
				s.containerEvent(c, "start", nil)
				if restart {
					s.containerEvent(c, "restart", nil)
				}
				s.startDockerHealth(ctx, c)
				// A durable start intent already exists. Recovery treats both starting
				// and running as interrupted if there is no committed exit status.
				c.signal()
				s.mu.Unlock()
				launched = true
				started <- nil
			},
		}
		if console != nil {
			hooks.startConsole = func(ctx context.Context, id string) error {
				return console.accept(ctx, s.node, id, write, cancel)
			}
		} else {
			hooks.output = write
			hooks.runtimeLogDir = c.dir()
		}
		if c.retainsRootFS() {
			hooks.bindRootFS = func(ctx context.Context, pod ownedPod, id string) (*dockerRootFSBinding, error) {
				return s.bindDockerRootFS(ctx, c, pod, id)
			}
			hooks.clearRootFS = func() error {
				s.mu.Lock()
				defer s.mu.Unlock()
				// The exit's save below makes this durable. A crash before it
				// leaves the attachment recorded, and recovery repeats the
				// cleanup, which finds nothing left to do.
				return saveRootFSBinding(c, nil, false)
			}
		}
		res, runErr := s.node.runProcess(ctx, j, "crun", hooks)
		runErr = errors.Join(runErr, bridgeRetireErr)
		if console != nil {
			runErr = errors.Join(runErr, console.finish(ctx))
		} else if err := removeDockerRuntimeLog(c.dir()); err != nil {
			log.Printf("remove runtime log for Docker container %s: %v", c.ID, err)
		}
		logOffset, logPersisted := sealLog()
		if parentHeld {
			runErr = errors.Join(runErr, s.jobParents.release(dockerRuntimeCgroupRoot, jobParent))
		}
		// Stamp the units in their own scopes while still held, then unpin
		// them and queue their marks for a clear.
		caches.touchAll()
		caches.release()
		s.mu.Lock()
		defer s.mu.Unlock()
		if c.binds == held {
			c.binds = nil // its files close as this goroutine returns
		}
		// An admitted explicit kill publishes only after its CRI acknowledgement.
		// Let that acknowledgement precede exit and automatic removal events.
		for c.killEventDone != nil {
			done := c.killEventDone
			s.mu.Unlock()
			<-done
			s.mu.Lock()
		}
		s.publishDockerBridgeNames(c, false)
		c.IP = ""
		c.primaryMAC = ""
		c.Ports = nil
		c.Finished = time.Now().UTC()
		c.RuntimeID = ""
		c.console = nil
		if logPersisted {
			c.LogOffset = logOffset
		}
		c.Exits++
		c.Exit = res.ExitCode
		c.OOMKilled = res.Reason == "OOMKilled"
		c.Phase = "exited"
		if runErr != nil {
			c.Exit = -1
			c.Failure = runErr.Error()
			c.Phase = "dead"
		}
		s.metrics.record(res, runErr)
		if res.ExitKnown {
			if c.OOMKilled {
				s.containerEvent(c, "oom", nil)
			}
			s.containerEvent(c, "die", map[string]string{
				"exitCode":     strconv.Itoa(int(res.ExitCode)),
				"execDuration": strconv.FormatInt(max(0, int64(c.Finished.Sub(c.Started)/time.Second)), 10),
			})
		}
		if c.Config.HostConfig.AutoRemove {
			if err := s.removeLocked(c); err != nil {
				c.Phase = "dead"
				if !res.ExitKnown || runErr != nil {
					c.Exit = -1
					c.Failure = err.Error()
				}
				log.Printf("remove Docker container %s after exit %d: %v", c.ID, c.Exit, err)
				runErr = errors.Join(runErr, err)
				if c.BridgeGeneration != nil {
					runErr = errors.Join(runErr, c.save())
				}
			}
		} else if err := c.save(); err != nil {
			c.Phase = "dead"
			if !res.ExitKnown || runErr != nil {
				c.Exit = -1
				c.Failure = err.Error()
			}
			log.Printf("save Docker container %s after exit %d: %v", c.ID, c.Exit, err)
			runErr = errors.Join(runErr, err)
		}
		c.signal()
		if !launched {
			started <- runErr
		}
	}()
	return <-started
}

func (n node) installDockerOCI(ctx context.Context, podID, id string, config dockerConfig, jobParent string, console *dockerPID1) error {
	// CRI creates this owned container in k8s.io. The task service reads the
	// OCI spec from container metadata when CRI subsequently starts the task.
	ctx = metadata.AppendToOutgoingContext(ctx, "containerd-namespace", dockerRuntimeNamespace)
	response, err := n.containers.Get(ctx, &containers.GetContainerRequest{ID: id})
	if err != nil {
		return fmt.Errorf("read owned OCI spec: %w", err)
	}
	record := response.GetContainer()
	if record.GetID() != id || record.GetSandbox() != podID ||
		record.GetSpec().GetTypeUrl() != dockerExecSpecType {
		return errors.New("containerd OCI spec does not match the owned CRI container")
	}
	if len(config.HostConfig.Tmpfs) != 0 {
		record.Spec.Value, err = config.specWithTmpfs(record.Spec.Value)
		if err != nil {
			return fmt.Errorf("configure OCI tmpfs: %w", err)
		}
	}
	if jobParent != "" {
		record.Spec.Value, err = specWithJobParent(record.Spec.Value, jobParent, id)
		if err != nil {
			return fmt.Errorf("configure OCI job parent: %w", err)
		}
	}
	if console != nil {
		record.Spec.Value, err = console.spec(record.Spec.Value)
		if err != nil {
			return fmt.Errorf("configure OCI console: %w", err)
		}
	}
	_, err = n.containers.Update(ctx, &containers.UpdateContainerRequest{
		Container:  &containers.Container{ID: id, Spec: record.Spec},
		UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"spec"}},
	})
	if err != nil {
		return fmt.Errorf("install owned OCI spec: %w", err)
	}
	return nil
}

func (s *dockerEngine) removeLocked(c *dockerContainer) (err error) {
	if c.RootFSBinding != nil {
		return fail(409, "previous writable rootfs attachment needs worker recovery")
	}
	if c.BridgeGeneration != nil {
		return fail(409, "previous named network sandbox needs worker recovery")
	}
	defer func() {
		if err == nil && c.RootFS == nil {
			s.containerEvent(c, "destroy", nil)
		}
	}()
	// Retire the catalog entry atomically. An already attached log reader
	// retains its open inode while the next boot can finish any interrupted unlink.
	retired := filepath.Join(engineRoot, "retired", c.ID)
	if err := os.Rename(c.dir(), retired); err != nil {
		return err
	}
	c.Phase = "removing"
	delete(s.containers, c.ID)
	c.removed = true
	for id, e := range s.execs {
		if e.container == c {
			delete(s.execs, id)
		}
	}
	if c.ownsFamily() {
		// What its socket created goes with it (docker_family_linux.go). A
		// removal on exit does not wait for it; every answer that c is
		// removed (remove, a wait for removal) does (awaitFamily), for the
		// first reaping only: what that leaves is retried in the background.
		c.reaped = make(chan struct{})
		go func() {
			err := s.reapFamily(context.Background(), c.ID)
			close(c.reaped)
			s.retryReap(context.Background(), c.ID, err)
		}()
	}
	c.signal()
	if c.Config.HostConfig.AutoRemove {
		return os.RemoveAll(retired)
	}
	if c.RootFS != nil {
		// Commit both sides of the rename before deleting the snapshot. A
		// crash must leave a tombstone, never a live record with a lost layer.
		return errors.Join(syncDir(filepath.Dir(c.dir())), syncDir(filepath.Dir(retired)))
	}
	return errors.Join(syncDir(filepath.Dir(c.dir())), os.RemoveAll(retired))
}
func (s *dockerEngine) stop(ctx context.Context, c *dockerContainer, timeout int64, action string) error {
	s.mu.Lock()
	// Starting and running share the same exit count. A replacement can start
	// before this waiter observes the original runtime's exit notification.
	exits := c.Exits
	requested := false
	for c.Exits == exits && c.busy() {
		id, changed := c.RuntimeID, c.changed
		var killDone chan struct{}
		if !requested && id != "" && action == "kill" && timeout == 0 {
			if pending := c.killEventDone; pending != nil {
				s.mu.Unlock()
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-pending:
				}
				s.mu.Lock()
				continue
			}
			killDone = make(chan struct{})
			c.killEventDone = killDone
		}
		s.mu.Unlock()
		if !requested && id != "" {
			if err := s.requestContainerStop(ctx, c, id, timeout, killDone); err != nil {
				return err
			}
			requested = true
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-changed:
		}
		s.mu.Lock()
	}
	if requested && c.Exits != exits && action == "stop" {
		s.containerEvent(c, "stop", nil)
	}
	s.mu.Unlock()
	return nil
}

func (s *dockerEngine) requestContainerStop(ctx context.Context, c *dockerContainer, id string, timeout int64, killDone chan struct{}) error {
	if killDone != nil {
		// Exit publication is waiting for this response. A stalled CRI RPC
		// must not hold the container in its running phase indefinitely.
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 45*time.Second)
		defer cancel()
	}
	_, err := s.node.runtime.StopContainer(ctx, &cri.StopContainerRequest{ContainerId: id, Timeout: timeout})
	if killDone != nil {
		s.mu.Lock()
		if err == nil {
			s.containerEvent(c, "kill", map[string]string{"signal": "9"})
		}
		c.killEventDone = nil
		close(killDone)
		s.mu.Unlock()
	}
	return err
}

// awaitFamily waits, once c is removed, until what its delegated socket
// created is gone too (c.reaped), so that the next job of the same compose
// project finds the names free when it learns c is gone; false when ctx ends
// first. It returns at once for a container that owns no family.
func (s *dockerEngine) awaitFamily(ctx context.Context, c *dockerContainer) bool {
	s.mu.Lock()
	reaped := c.reaped
	if !c.removed {
		reaped = nil
	}
	s.mu.Unlock()
	if reaped == nil {
		return true
	}
	select {
	case <-reaped:
		return true
	case <-ctx.Done():
		return false
	}
}

func (s *dockerEngine) remove(ctx context.Context, c *dockerContainer, force bool) error {
	for {
		s.mu.Lock()
		if c.removed {
			// Removed meanwhile: on its exit (AutoRemove) or by another
			// request. This answer, too, waits for its family.
			s.mu.Unlock()
			s.awaitFamily(ctx, c)
			return nil
		}
		if !c.busy() {
			err := s.removeLocked(c)
			s.mu.Unlock()
			if err == nil && c.RootFS != nil {
				if err := s.reclaimDockerRootFS(context.WithoutCancel(ctx), c, filepath.Join(engineRoot, "retired", c.ID)); err != nil {
					return err
				}
				s.mu.Lock()
				s.containerEvent(c, "destroy", nil)
				s.mu.Unlock()
			}
			if err == nil {
				s.awaitFamily(ctx, c)
			}
			return err
		}
		s.mu.Unlock()
		if !force {
			return fail(409, "container is running")
		}
		if err := s.stop(ctx, c, 0, ""); err != nil {
			return err
		}
	}
}
func readBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	b, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 256<<10))
	if e != nil {
		return nil, fail(400, "invalid or oversized request body")
	}
	return b, nil
}
func formatTime(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }
func (c *dockerContainer) effectivePorts() portMap {
	if c.Phase != "running" || networkName(c.Config.HostConfig.NetworkMode) == "none" {
		return portMap{}
	}
	return c.Ports.withExposed(c.Config.ExposedPorts)
}

// dockerStatus maps internal engine phases onto valid Docker Engine API v1.47
// container states ("created", "running", "paused", "restarting", "removing",
// "exited", "dead"). Moby keeps a container in "created" (or "exited" on
// restart) until start transitions it directly into "running"; exposing the
// internal "starting" phase breaks stock clients such as testcontainers-go
// during concurrent Ryuk startup races.
func (c *dockerContainer) dockerStatus() string {
	if c.Phase == "starting" {
		if c.Exits > 0 {
			return "exited"
		}
		return "created"
	}
	return c.Phase
}

func (c *dockerContainer) inspect() map[string]any {
	network := networkName(c.Config.HostConfig.NetworkMode)
	config := c.Config
	config.Env = mergeEnv(mergeEnv(c.ImageEnv, c.Config.Env), withoutProxies(c.Cache.env(c.CacheSkipped), c.CacheProxy))
	config.HostConfig.LogConfig = config.HostConfig.LogConfig.withDefault()
	state := map[string]any{"Status": c.dockerStatus(), "Running": c.Phase == "running", "Dead": c.Phase == "dead", "OOMKilled": c.OOMKilled, "ExitCode": c.Exit, "StartedAt": formatTime(c.Started), "FinishedAt": formatTime(c.Finished), "Error": c.Failure, "LogError": c.LogError}
	if c.Health != nil {
		state["Health"] = c.Health.snapshot()
	}
	v := map[string]any{"Id": c.ID, "Name": "/" + c.Name, "Created": formatTime(c.Created), "Image": c.ImageID, "Config": config, "HostConfig": config.HostConfig, "Driver": "overlayfs", "Platform": "linux",
		"State":           state,
		"NetworkSettings": map[string]any{"Ports": c.effectivePorts(), "IPAddress": c.IP, "Networks": map[string]any{network: map[string]any{"IPAddress": c.IP, "NetworkID": c.NetworkID, "Aliases": c.Config.Aliases}}},
		"Mounts":          c.mountList()}
	if c.Cache != nil {
		mc := map[string]any{"scope": c.Cache.Scope, "uid": c.Cache.UID, "tools": c.cacheToolStates()}
		if c.Cache.Reason != "" {
			mc["reason"] = c.Cache.Reason
		}
		if c.Cache.Trust != "" {
			mc["trust"] = c.Cache.Trust
		}
		if c.Cache.TrustFrom != "" {
			mc["trustFrom"] = c.Cache.TrustFrom
		}
		if c.Cache.PolicyDigest != "" {
			// The policy the plan was decided under (create), not the one
			// in force now: a later hot-apply does not rewrite it.
			mc["policyDigest"] = c.Cache.PolicyDigest
		}
		if len(c.Cache.Proxy) > 0 {
			// The create's decisions, with what the latest start left out.
			proxy := map[string]string{}
			for k, why := range c.Cache.Proxy {
				proxy[k] = why
			}
			for k, why := range c.CacheProxy {
				proxy[k] = why
			}
			mc["proxy"] = proxy
		}
		v["MicropodCache"] = mc
	}
	return v
}

// cacheToolStates is the plan's per-tool decision as the latest start applied
// it: a tool that start had to leave out shows as skipped with its reason, and
// one it reached copy-on-write or read-only carries that access.
func (c *dockerContainer) cacheToolStates() map[string]cacheToolState {
	tools := map[string]cacheToolState{}
	for k, st := range c.Cache.Tools {
		if reason, gone := c.CacheSkipped[k]; gone {
			st = cacheToolState{Mode: "skipped", Path: st.Path, Reason: reason}
		} else if how := c.CacheAccess[k]; how != "" && st.Mode != "skipped" {
			st.Access = how
		}
		tools[k] = st
	}
	return tools
}

// mountList is Docker's inspect Mounts: the request's mounts, then the cache
// binds the latest start used.
func (c *dockerContainer) mountList() []map[string]any {
	list := []map[string]any{}
	user, _ := c.Config.mounts()
	for _, m := range user {
		e := map[string]any{"Type": m.Type, "Source": m.Source, "Destination": m.Target, "RW": !m.ReadOnly, "Mode": "", "Propagation": "rprivate"}
		if m.Type == "volume" {
			e["Name"], e["Driver"], e["Source"] = m.Source, "local", volumePath(m.Source)
			if p, ok := sharedCachePath(m.Source); ok {
				e["Source"] = p
			}
		}
		list = append(list, e)
	}
	p := c.Cache
	if !p.attached() {
		return list
	}
	scopeUsed := false
	for _, st := range p.Stores {
		if _, gone := c.CacheSkipped[st.Kind]; !gone && p.Tools[st.Kind].Mode == "env" {
			scopeUsed = true
		}
	}
	for i, m := range p.Mounts {
		// A unit in "global" (shared L0) lives in that scope, not the plan's.
		scope := p.scopeFor(m.Scope)
		scopeDir := filepath.Join(cacheRoot, "scopes", scope)
		e := map[string]any{"Type": "volume", "Driver": "local", "Destination": m.Target, "RW": true, "Mode": "", "Propagation": "rprivate"}
		switch {
		case m.Shim:
			e["Type"], e["Source"] = "bind", filepath.Join(c.dir(), "shim", strconv.Itoa(i))
		case m.Kind == "":
			if !scopeUsed {
				continue
			}
			// Bound read-only; the units this start uses are bound over it.
			// A reader sees its own directory of their mount points instead.
			e["Name"], e["Source"], e["RW"] = "micropod-cache-"+scope, scopeDir, false
			if p.ReadOnly {
				e["Source"] = filepath.Join(c.dir(), "shim", "ro-scope-"+scope)
			}
		default:
			if _, gone := c.CacheSkipped[m.Kind]; gone {
				continue
			}
			var uid *uint32
			for _, st := range p.Stores {
				if st.Unit == m.Unit {
					uid = st.UID
				}
			}
			e["Name"], e["Source"] = "micropod-cache-"+scope+"-"+m.Kind, filepath.Join(scopeDir, cacheStoreSub(m.Kind, uid), m.Sub)
			if c.CacheAccess[m.Kind] == accessReadOnly && !m.File {
				e["RW"] = false
			}
		}
		list = append(list, e)
	}
	return list
}
func (s *dockerEngine) info() map[string]any {
	labels := []string{"io.micropod.instance=" + os.Getenv("MICROPOD_CI_INSTANCE")}
	if s.workspace != "" {
		labels = append(labels, fmt.Sprintf("io.micropod.workspace-sha256=%x", sha256.Sum256([]byte(s.workspace))))
	}
	if s.direct != nil {
		labels = append(labels, "io.micropod.published-path=macvlan")
	}
	// The platforms containers run on, and how linux/amd64 runs (or why not).
	labels = append(labels, "io.micropod.platforms="+strings.Join(enginePlatforms(), ","))
	emulation := currentEmulation()
	if emulation.available() {
		labels = append(labels, "io.micropod.amd64="+emulation.Emulator)
	} else {
		labels = append(labels, "io.micropod.amd64=unavailable")
	}
	info := map[string]any{"ID": os.Getenv("MICROPOD_CI_WORKER_ID"), "Name": "micropod", "OSType": "linux", "Architecture": "aarch64", "Driver": "overlayfs", "CgroupDriver": "cgroupfs", "CgroupVersion": "2", "DefaultRuntime": "crun", "ServerVersion": "micropod", "NCPU": runtime.NumCPU(), "Labels": labels}
	info["LoggingDriver"] = dockerDefaultLogDriver
	if emulation != nil {
		info["MicropodEmulation"] = emulation
	}
	if controllers, err := os.ReadFile("/sys/fs/cgroup/cgroup.subtree_control"); err == nil {
		info["CPUShares"] = slices.Contains(strings.Fields(string(controllers)), "cpu")
	}
	if release, err := os.ReadFile("/proc/sys/kernel/osrelease"); err == nil {
		info["KernelVersion"] = strings.TrimSpace(string(release))
	}
	if privateRootless() {
		info["SecurityOptions"] = []string{"name=rootless", "name=no-new-privileges", "name=seccomp,profile=builtin"}
	}
	var sys unix.Sysinfo_t
	if unix.Sysinfo(&sys) == nil {
		info["MemTotal"] = sys.Totalram * uint64(sys.Unit)
	}
	s.mu.Lock()
	total, running, stopped := len(s.containers), 0, 0
	for _, c := range s.containers {
		switch c.Phase {
		case "running":
			running++
		case "exited", "dead":
			stopped++
		}
	}
	s.mu.Unlock()
	info["Containers"], info["ContainersRunning"], info["ContainersStopped"] = total, running, stopped
	return info
}
