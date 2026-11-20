package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const dockerSocket = "/var/lib/micropod/docker.sock"
const engineGate = "/run/micropod-oci/engine.lock"
const dockerAPI = "1.47"

type dockerRecord struct {
	OOMKilled                                    bool
	ID, Name, ImageID, Phase, RuntimeID, Failure string
	Created, Started, Finished                   time.Time
	Exit                                         int32
	Exits                                        uint64
	Config                                       dockerConfig
}
type dockerContainer struct {
	outputBytes int64
	IP          string
	Ports       portMap
	dockerRecord
	changed           chan struct{}
	foregroundReaders int
	readersDone       chan struct{}
	removed           bool
}
type dockerEngine struct {
	startSlots chan struct{}
	metrics    dockerMetrics
	node       node
	workspace  string
	mu         sync.Mutex
	containers map[string]*dockerContainer
	execs      map[string]*dockerExec
}

func engineID() string                 { var id [32]byte; rand.Read(id[:]); return hex.EncodeToString(id[:]) }
func (c *dockerContainer) dir() string { return filepath.Join(engineRoot, "containers", c.ID) }
func (c *dockerContainer) signal()     { close(c.changed); c.changed = make(chan struct{}) }
func (c *dockerContainer) busy() bool  { return c.Phase == "starting" || c.Phase == "running" }
func (c *dockerContainer) save() error {
	b, err := json.Marshal(c.dockerRecord)
	if err != nil {
		return err
	}
	path := filepath.Join(c.dir(), "state")
	f, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(b)
	if err == nil {
		err = f.Sync()
	}
	err = errors.Join(err, f.Close())
	if err != nil {
		return err
	}
	if err = os.Rename(path+".tmp", path); err != nil {
		return err
	}
	return syncDir(c.dir())
}

func syncDir(path string) error {
	d, err := os.Open(path)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func (s *dockerEngine) recover() error {
	retired := filepath.Join(engineRoot, "retired")
	old, err := os.ReadDir(retired)
	if err != nil {
		return err
	}
	for _, e := range old {
		if !e.IsDir() || len(e.Name()) != 64 {
			continue
		}
		if _, err := hex.DecodeString(e.Name()); err != nil {
			return err
		}
		if err := os.RemoveAll(filepath.Join(retired, e.Name())); err != nil {
			return err
		}
	}
	dir := filepath.Join(engineRoot, "containers")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() || len(e.Name()) != 64 {
			continue
		}
		if _, err := hex.DecodeString(e.Name()); err != nil {
			return err
		}
		p := filepath.Join(dir, e.Name())
		b, err := os.ReadFile(filepath.Join(p, "state"))
		if errors.Is(err, os.ErrNotExist) {
			if err := os.RemoveAll(p); err != nil {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		c := &dockerContainer{changed: make(chan struct{})}
		if err := json.Unmarshal(b, &c.dockerRecord); err != nil {
			return err
		}
		if c.ID != e.Name() || !dockerName.MatchString(c.Name) {
			return errors.New("invalid Docker ownership record")
		}
		if c.Phase == "removing" || (c.Config.HostConfig.AutoRemove && c.Phase != "created") {
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
		st, err := os.Stat(filepath.Join(c.dir(), "output"))
		if err != nil {
			return err
		}
		c.outputBytes = st.Size()
		s.containers[c.ID] = c
	}
	return nil
}
func serveEngine(ctx context.Context, n node) error {
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
	g, err := os.OpenFile(engineGate, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	g.Close()
	s := &dockerEngine{node: n, workspace: os.Getenv("MICROPOD_ENGINE_WORKSPACE"), containers: make(map[string]*dockerContainer), execs: make(map[string]*dockerExec)}
	if raw := os.Getenv("MICROPOD_CI_MAX_STARTING"); raw != "" {
		limit, err := strconv.Atoi(raw)
		if err != nil || limit < 0 || limit > 32 {
			return errors.New("invalid native container start limit")
		}
		if limit > 0 {
			s.startSlots = make(chan struct{}, limit)
		}
	}
	if err := s.recover(); err != nil {
		return err
	}
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
	server := &http.Server{Handler: s, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 << 10}
	go func() { <-ctx.Done(); server.Close() }()
	return server.Serve(l)
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
	if name != "" && !dockerName.MatchString(name) {
		return nil, fail(400, "invalid container name")
	}
	img, err := s.node.images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: spec.Image}})
	if err != nil {
		return nil, err
	}
	if img.GetImage().GetId() == "" {
		return nil, fail(404, "No such image: "+spec.Image)
	}
	id := engineID()
	if name == "" {
		name = "mp-" + id[:12]
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.containers {
		if c.Name == name {
			return nil, fail(409, "container name is in use")
		}
	}
	files, _, err := s.openMounts(spec, true, "")
	if err != nil {
		return nil, fail(400, err.Error())
	}
	closeMounts(files)
	c := &dockerContainer{dockerRecord: dockerRecord{ID: id, Name: name, ImageID: img.Image.Id, Phase: "created", Created: time.Now().UTC(), Config: spec}, changed: make(chan struct{})}
	if err := os.Mkdir(c.dir(), 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(c.dir(), "output"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err == nil {
		err = f.Close()
	}
	if err == nil {
		err = c.save()
	}
	if err == nil {
		err = syncDir(filepath.Dir(c.dir()))
	}
	if err != nil {
		os.RemoveAll(c.dir())
		return nil, err
	}
	s.containers[id] = c
	s.metrics.creates.Add(1)
	mounts, _ := spec.mounts()
	for _, m := range mounts {
		if m.Type == "volume" {
			if _, ok := sharedCachePath(m.Source); ok {
				s.metrics.sharedMounts.Add(1)
			}
		}
	}
	return c, nil
}
func (s *dockerEngine) start(c *dockerContainer) (startErr error) {
	defer func() {
		if startErr == nil {
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
	socket, closeSocket, err := s.openCleanupSocket(c)
	if err != nil {
		s.mu.Unlock()
		lease.Close()
		return err
	}
	files, mounts, err := s.openMounts(c.Config, false, socket)
	if err != nil {
		s.mu.Unlock()
		closeSocket()
		lease.Close()
		return err
	}
	f, err := os.OpenFile(filepath.Join(c.dir(), "output"), os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		s.mu.Unlock()
		closeSocket()
		closeMounts(files)
		lease.Close()
		return err
	}
	previous := c.dockerRecord
	c.Phase = "starting"
	c.OOMKilled = false
	c.Failure = ""
	c.RuntimeID = ""
	c.Finished = time.Time{}
	c.Started = time.Time{}
	c.Exit = 0
	if err = c.save(); err != nil {
		c.dockerRecord = previous
		s.mu.Unlock()
		closeSocket()
		f.Close()
		closeMounts(files)
		lease.Close()
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.signal()
	started := make(chan error, 1)
	s.mu.Unlock()
	go func() {
		defer lease.Close()
		defer closeSocket()
		defer closeMounts(files)
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
		res, runErr := s.node.runProcess(ctx, j, "crun", processHooks{
			configure: func(startCtx context.Context, podID string, cfg *cri.ContainerConfig) error {
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
				var err error
				forwards, err = s.publish(startCtx, c, podID)
				if err != nil {
					return err
				}
				return c.Config.configure(cfg, mounts)
			},
			started: func(id string) {
				releaseStart()
				s.mu.Lock()
				c.RuntimeID = id
				c.Started = time.Now().UTC()
				c.Phase = "running"
				// A durable start intent already exists. Recovery treats both starting
				// and running as interrupted if there is no committed exit status.
				c.signal()
				s.mu.Unlock()
				launched = true
				started <- nil
			},
			output: func(stream string, b []byte) error {
				var h [8]byte
				h[0] = 1
				if stream == "stderr" {
					h[0] = 2
				}
				binary.BigEndian.PutUint32(h[4:], uint32(len(b)))
				frameSize := int64(len(h) + len(b))
				if c.outputBytes+frameSize > 8<<20 {
					return errors.New("Docker log exceeded the 8 MiB limit")
				}
				if _, err := f.Write(append(h[:], b...)); err != nil {
					return err
				}
				s.mu.Lock()
				c.outputBytes += frameSize
				c.signal()
				s.mu.Unlock()
				return nil
			},
		})
		for _, p := range forwards {
			p.close()
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		c.IP = ""
		c.Ports = nil
		c.Finished = time.Now().UTC()
		c.RuntimeID = ""
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
		if c.Config.HostConfig.AutoRemove {
			if err := s.removeLocked(c); err != nil {
				c.Phase = "dead"
				c.Exit = -1
				c.Failure = err.Error()
				runErr = errors.Join(runErr, err)
			}
		} else if err := c.save(); err != nil {
			c.Phase = "dead"
			c.Exit = -1
			c.Failure = err.Error()
			runErr = errors.Join(runErr, err)
		}
		c.signal()
		if !launched {
			started <- runErr
		}
	}()
	return <-started
}
func (s *dockerEngine) removeLocked(c *dockerContainer) error {
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
	c.signal()
	return errors.Join(syncDir(filepath.Dir(c.dir())), os.RemoveAll(retired))
}
func (s *dockerEngine) stop(ctx context.Context, c *dockerContainer, timeout int64) error {
	for {
		s.mu.Lock()
		busy, id, changed := c.busy(), c.RuntimeID, c.changed
		s.mu.Unlock()
		if !busy {
			return nil
		}
		if id != "" {
			_, err := s.node.runtime.StopContainer(ctx, &cri.StopContainerRequest{ContainerId: id, Timeout: timeout})
			if err != nil {
				return err
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-changed:
		}
	}
}
func (s *dockerEngine) remove(ctx context.Context, c *dockerContainer, force bool) error {
	for {
		s.mu.Lock()
		if c.removed {
			s.mu.Unlock()
			return nil
		}
		if !c.busy() {
			err := s.removeLocked(c)
			s.mu.Unlock()
			return err
		}
		s.mu.Unlock()
		if !force {
			return fail(409, "container is running")
		}
		if err := s.stop(ctx, c, 0); err != nil {
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
func (c *dockerContainer) inspect() map[string]any {
	network := "bridge"
	if c.Config.HostConfig.NetworkMode == "none" {
		network = "none"
	}
	return map[string]any{"Id": c.ID, "Name": "/" + c.Name, "Created": formatTime(c.Created), "Image": c.ImageID, "Config": c.Config, "HostConfig": c.Config.HostConfig, "Driver": "overlayfs", "Platform": "linux",
		"State":           map[string]any{"Status": c.Phase, "Running": c.Phase == "running", "Dead": c.Phase == "dead", "OOMKilled": c.OOMKilled, "ExitCode": c.Exit, "StartedAt": formatTime(c.Started), "FinishedAt": formatTime(c.Finished), "Error": c.Failure},
		"NetworkSettings": map[string]any{"Ports": c.Ports, "IPAddress": c.IP, "Networks": map[string]any{network: map[string]any{"IPAddress": c.IP}}}}
}
func (s *dockerEngine) info() map[string]any {
	info := map[string]any{"ID": os.Getenv("MICROPOD_CI_WORKER_ID"), "Name": "micropod", "OSType": "linux", "Architecture": "aarch64", "Driver": "overlayfs", "CgroupDriver": "cgroupfs", "CgroupVersion": "2", "DefaultRuntime": "crun", "ServerVersion": "micropod", "NCPU": runtime.NumCPU(), "Labels": []string{"io.micropod.instance=" + os.Getenv("MICROPOD_CI_INSTANCE")}}
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
