package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// Image facts are what the attach decision needs to know about an image:
// its configured Env/User/WorkingDir (from CRI) and a handful of rootfs facts
// (passwd/group, whether candidate cache paths exist and hold content, which
// tool binaries are on PATH). They are probed once per image ID through a
// read-only `ctr images mount` view and cached on disk. factsVersion changes
// whenever the probe learns something new (version 2: the mvn, gradle, bun,
// sccache and playwright binaries), so facts an older engine cached are
// probed again.

const factsVersion = 2
const probeRoot = "/run/micropod/probe"

var imageFactsDir = filepath.Join(engineRoot, "image-facts")

type passwdEntry struct {
	Name     string `json:"name"`
	UID, GID uint32
	Home     string `json:"home"`
}

type groupEntry struct {
	Name string `json:"name"`
	GID  uint32 `json:"gid"`
}

type pathFact struct {
	Exists       bool   `json:"exists"`
	Dir          bool   `json:"dir,omitempty"`
	NonEmpty     bool   `json:"nonEmpty,omitempty"`
	ParentExists bool   `json:"parentExists,omitempty"`
	UID          uint32 `json:"uid,omitempty"`
	GID          uint32 `json:"gid,omitempty"`
	Mode         uint32 `json:"mode,omitempty"`
}

type imageFacts struct {
	Version    int                 `json:"version"`
	ImageID    string              `json:"imageID"`
	Env        []string            `json:"env"`
	User       string              `json:"user"`
	WorkingDir string              `json:"workingDir"`
	Passwd     []passwdEntry       `json:"passwd"`
	Group      []groupEntry        `json:"group"`
	Paths      map[string]pathFact `json:"paths"`
	Binaries   map[string]bool     `json:"binaries"`
	OK         bool                `json:"ok"`
	ProbeMS    int64               `json:"probeMS"`
	Error      string              `json:"error,omitempty"`
}

func (f *imageFacts) passwdByUID(uid uint32) *passwdEntry {
	for i := range f.Passwd {
		if f.Passwd[i].UID == uid {
			return &f.Passwd[i]
		}
	}
	return nil
}

func (f *imageFacts) passwdByName(name string) *passwdEntry {
	for i := range f.Passwd {
		if f.Passwd[i].Name == name {
			return &f.Passwd[i]
		}
	}
	return nil
}

func (f *imageFacts) groupByName(name string) *groupEntry {
	for i := range f.Group {
		if f.Group[i].Name == name {
			return &f.Group[i]
		}
	}
	return nil
}

// prewarmed is true when any marker is known to be present. An unknown path
// (not probed) never counts as pre-warmed.
func (f *imageFacts) prewarmed(markers []cacheMarker) bool {
	for _, m := range markers {
		p, ok := f.Paths[path.Clean(m.Path)]
		if ok && p.Exists && (!m.NonEmpty || p.NonEmpty) {
			return true
		}
	}
	return false
}

func parsePasswd(b []byte) []passwdEntry {
	var out []passwdEntry
	s := bufio.NewScanner(bytes.NewReader(b))
	for s.Scan() {
		f := strings.Split(s.Text(), ":")
		if len(f) < 6 || f[0] == "" || strings.HasPrefix(f[0], "#") {
			continue
		}
		uid, ok1 := numericID(f[2])
		gid, ok2 := numericID(f[3])
		if ok1 && ok2 {
			out = append(out, passwdEntry{Name: f[0], UID: uid, GID: gid, Home: f[5]})
		}
	}
	return out
}

func parseGroup(b []byte) []groupEntry {
	var out []groupEntry
	s := bufio.NewScanner(bytes.NewReader(b))
	for s.Scan() {
		f := strings.Split(s.Text(), ":")
		if len(f) < 3 || f[0] == "" || strings.HasPrefix(f[0], "#") {
			continue
		}
		if gid, ok := numericID(f[2]); ok {
			out = append(out, groupEntry{Name: f[0], GID: gid})
		}
	}
	return out
}

// factCandidates lists every rootfs path the decision may ask about: each
// table row's default location, markers and bind targets (with all their
// ancestors) for every plausible HOME, root and non-root, plus /micropod.
func factCandidates(env []string, passwd []passwdEntry, user string) []string {
	homes := []string{"/root", "/"}
	addHome := func(h string) {
		if path.IsAbs(h) && len(homes) < 24 {
			h = path.Clean(h)
			for _, x := range homes {
				if x == h {
					return
				}
			}
			homes = append(homes, h)
		}
	}
	if h, ok := envLookup(env, "HOME", false); ok {
		addHome(h)
	}
	if user != "" {
		if _, _, h, err := resolveUser(user, &imageFacts{OK: true, Passwd: passwd}); err == nil {
			addHome(h)
		}
	}
	for _, p := range passwd {
		if p.UID == 0 || p.UID >= 1000 && p.UID != 65534 {
			addHome(p.Home)
		}
	}
	set := map[string]bool{"/micropod": true}
	add := func(p string) {
		for p = path.Clean(p); p != "/" && p != "."; p = path.Dir(p) {
			set[p] = true
		}
	}
	for _, h := range homes {
		for _, uid := range []uint32{0, 1000} {
			x := toolCtx{env: env, home: h, uid: uid}
			for _, t := range cacheTable {
				def := t.DefaultPath(x)
				add(def)
				for _, m := range t.Markers(def) {
					add(m.Path)
				}
				for _, tg := range t.targets(x) {
					add(tg.Target)
				}
			}
		}
	}
	out := make([]string, 0, len(set))
	for p := range set {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// Paths are resolved inside the mounted image with RESOLVE_IN_ROOT, so an
// absolute symlink in the image can never reach the guest's own files.
func openInRoot(root int, p string, flags uint64) (int, error) {
	rel := strings.TrimPrefix(path.Clean(p), "/")
	if rel == "" {
		rel = "."
	}
	return unix.Openat2(root, rel, &unix.OpenHow{Flags: flags | unix.O_CLOEXEC, Resolve: unix.RESOLVE_IN_ROOT | unix.RESOLVE_NO_MAGICLINKS})
}

func statInRoot(root int, p string) pathFact {
	fd, err := openInRoot(root, p, unix.O_PATH)
	if err != nil {
		return pathFact{}
	}
	var st unix.Stat_t
	err = unix.Fstat(fd, &st)
	unix.Close(fd)
	if err != nil {
		return pathFact{}
	}
	f := pathFact{Exists: true, Dir: st.Mode&unix.S_IFMT == unix.S_IFDIR, UID: st.Uid, GID: st.Gid, Mode: st.Mode & 07777}
	if f.Dir {
		if d, err := openInRoot(root, p, unix.O_RDONLY|unix.O_DIRECTORY); err == nil {
			dir := os.NewFile(uintptr(d), p)
			names, _ := dir.Readdirnames(1)
			dir.Close()
			f.NonEmpty = len(names) > 0
		}
	} else {
		f.NonEmpty = st.Size > 0
	}
	return f
}

func readInRoot(root int, p string) []byte {
	fd, err := openInRoot(root, p, unix.O_RDONLY|unix.O_NONBLOCK)
	if err != nil {
		return nil
	}
	f := os.NewFile(uintptr(fd), p)
	defer f.Close()
	if st, err := f.Stat(); err != nil || !st.Mode().IsRegular() {
		return nil
	}
	b, _ := io.ReadAll(io.LimitReader(f, 1<<20))
	return b
}

// rootfsFacts reads everything the decision needs from a mounted rootfs.
func rootfsFacts(dir string, f *imageFacts) error {
	rootFd, err := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer unix.Close(rootFd)
	f.Passwd = parsePasswd(readInRoot(rootFd, "/etc/passwd"))
	f.Group = parseGroup(readInRoot(rootFd, "/etc/group"))
	f.Paths = map[string]pathFact{}
	for _, p := range factCandidates(f.Env, f.Passwd, f.User) {
		f.Paths[p] = statInRoot(rootFd, p)
	}
	for p, fact := range f.Paths {
		parent := path.Dir(p)
		if pf, ok := f.Paths[parent]; parent == "/" || ok && pf.Exists && pf.Dir {
			fact.ParentExists = true
			f.Paths[p] = fact
		}
	}
	searchPath, ok := envLookup(f.Env, "PATH", false)
	if !ok {
		searchPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	}
	f.Binaries = map[string]bool{}
	for _, name := range []string{"node", "yarn", "corepack", "cargo", "mvn", "gradle", "bun", "sccache", "playwright"} {
		for _, d := range filepath.SplitList(searchPath) {
			if !path.IsAbs(d) {
				continue
			}
			if b := statInRoot(rootFd, path.Join(d, name)); b.Exists && !b.Dir && b.Mode&0111 != 0 {
				f.Binaries[name] = true
				break
			}
		}
	}
	return nil
}

// imageConfigFacts fills Env/User/WorkingDir from CRI's verbose status, the
// same imageSpec blob `docker image inspect` decodes.
func imageConfigFacts(ctx context.Context, images cri.ImageServiceClient, imageID string, f *imageFacts) error {
	st, err := images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: imageID}, Verbose: true})
	if err != nil {
		return err
	}
	if st.GetImage().GetId() == "" {
		return errors.New("image not found")
	}
	var info struct {
		ImageSpec struct {
			Config struct {
				User, WorkingDir string
				Env              []string
			}
		}
	}
	if err := json.Unmarshal([]byte(st.Info["info"]), &info); err != nil {
		return fmt.Errorf("decode image status: %w", err)
	}
	f.Env, f.User, f.WorkingDir = info.ImageSpec.Config.Env, info.ImageSpec.Config.User, info.ImageSpec.Config.WorkingDir
	return nil
}

func runCtr(ctx context.Context, args ...string) ([]byte, error) {
	// ctrPath is the bundled ctr (docker_image_transfer_linux.go).
	cmd := exec.CommandContext(ctx, ctrPath, append([]string{"-n", "k8s.io"}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("ctr %s: %w: %.300s", strings.Join(args, " "), err, bytes.TrimSpace(out))
	}
	return out, nil
}

// probeImage mounts the image read-only, reads its facts and always unmounts
// with --rm, which also drops the probe's lease and View snapshot.
func probeImage(ctx context.Context, images cri.ImageServiceClient, imageID string) (f imageFacts) {
	begin := time.Now()
	f = imageFacts{Version: factsVersion, ImageID: imageID}
	defer func() { f.ProbeMS = time.Since(begin).Milliseconds() }()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := imageConfigFacts(ctx, images, imageID, &f); err != nil {
		f.Error = err.Error()
		return f
	}
	if err := os.MkdirAll(probeRoot, 0700); err != nil {
		f.Error = err.Error()
		return f
	}
	dir, err := os.MkdirTemp(probeRoot, "p")
	if err != nil {
		f.Error = err.Error()
		return f
	}
	defer func() {
		// A fresh context: the probe's own may already be cancelled.
		done, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if _, err := runCtr(done, "images", "unmount", "--rm", dir); err != nil {
			log.Printf("image facts: %v", err)
		}
		os.Remove(dir)
	}()
	if _, err := runCtr(ctx, "images", "mount", "--platform", "linux/arm64", imageID, dir); err != nil {
		f.Error = err.Error()
		return f
	}
	if err := rootfsFacts(dir, &f); err != nil {
		f.Error = err.Error()
		return f
	}
	f.OK = true
	return f
}

func factsFile(imageID string) (string, bool) {
	h := strings.TrimPrefix(imageID, "sha256:")
	if _, err := hex.DecodeString(h); err != nil || len(h) != 64 {
		return "", false
	}
	return filepath.Join(imageFactsDir, h+".json"), true
}

func readCachedFacts(imageID string) (imageFacts, bool) {
	var f imageFacts
	file, ok := factsFile(imageID)
	if !ok {
		return f, false
	}
	b, err := os.ReadFile(file)
	if err != nil || json.Unmarshal(b, &f) != nil || f.Version != factsVersion || !f.OK || f.ImageID != imageID {
		return imageFacts{}, false
	}
	return f, true
}

func writeCachedFacts(f imageFacts) error {
	file, ok := factsFile(f.ImageID)
	if !ok {
		return nil
	}
	if err := os.MkdirAll(imageFactsDir, 0700); err != nil {
		return err
	}
	b, err := json.Marshal(f)
	if err != nil {
		return err
	}
	tmp := file + "." + trashName("tmp")
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, file)
}

// factsLoader serialises probes per image so concurrent creates of one new
// image probe it once.
type factsLoader struct {
	mu       sync.Mutex
	inflight map[string]chan struct{}
}

// load returns cached facts, or probes. probed reports a real probe (for the
// cache_probe_ms metric). Failures are never cached and never an error.
func (l *factsLoader) load(ctx context.Context, images cri.ImageServiceClient, imageID string) (f imageFacts, probed bool) {
	for {
		if f, ok := readCachedFacts(imageID); ok {
			return f, false
		}
		l.mu.Lock()
		if l.inflight == nil {
			l.inflight = map[string]chan struct{}{}
		}
		wait, busy := l.inflight[imageID]
		if !busy {
			done := make(chan struct{})
			l.inflight[imageID] = done
			l.mu.Unlock()
			f = probeImage(ctx, images, imageID)
			if f.OK {
				if err := writeCachedFacts(f); err != nil {
					log.Printf("image facts: cache %s: %v", imageID, err)
				}
			} else {
				log.Printf("image facts: probe %s failed: %s", imageID, f.Error)
			}
			l.mu.Lock()
			delete(l.inflight, imageID)
			close(done)
			l.mu.Unlock()
			return f, true
		}
		l.mu.Unlock()
		select {
		case <-wait:
		case <-ctx.Done():
			return imageFacts{ImageID: imageID, Error: ctx.Err().Error()}, false
		}
	}
}

// sweepProbes removes probe views left by an engine that died mid-probe. /run
// is a tmpfs, so after a reboot the directories are gone while containerd
// still holds the lease and View snapshot; `unmount --rm` of the vanished
// path removes both. Keys are read from containerd, not /proc/mounts.
func sweepProbes(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	keys := map[string]bool{}
	if out, err := runCtr(ctx, "leases", "ls", "-q"); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			if k := strings.TrimSpace(line); strings.HasPrefix(k, probeRoot+"/") {
				keys[k] = true
			}
		}
	}
	if out, err := runCtr(ctx, "snapshots", "ls"); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			if f := strings.Fields(line); len(f) > 0 && strings.HasPrefix(f[0], probeRoot+"/") {
				keys[f[0]] = true
			}
		}
	}
	for k := range keys {
		if _, err := runCtr(ctx, "images", "unmount", "--rm", k); err != nil {
			log.Printf("image facts: sweep %s: %v", k, err)
		} else {
			log.Printf("image facts: removed stale probe %s", k)
		}
	}
}
