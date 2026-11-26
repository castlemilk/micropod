package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// A child of a delegated socket binds only paths inside its creator's own
// binds, read-only where they are, and resolves them below those binds.
func TestDelegatedBindsStayInsideTheCreatorsBinds(t *testing.T) {
	ws := t.TempDir()
	for _, d := range []string{"job/src", "ro/conf", "other", "job/real"} {
		if err := os.MkdirAll(filepath.Join(ws, d), 0755); err != nil {
			t.Fatal(err)
		}
	}
	// Relative, so they stay beneath the workspace: openMount would follow them.
	if err := os.Symlink("../other", filepath.Join(ws, "job", "escape")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("real", filepath.Join(ws, "job", "inside")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("job", filepath.Join(ws, "joblink")); err != nil {
		t.Fatal(err)
	}
	owner := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("a", 64), Config: dockerConfig{Image: "golang:1", HostConfig: dockerHost{
		Binds: []string{ws + "/job:/work", ws + "/ro:/ro:ro", ws + "/joblink:/jl", "/var/run/docker.sock:/var/run/docker.sock"}}}}}
	bind := func(b ...string) dockerConfig {
		return dockerConfig{Image: "postgres", HostConfig: dockerHost{Binds: b}}
	}

	for _, refused := range []dockerConfig{
		bind(ws + ":/h"), bind(ws + "/other:/o"), bind("/:/host:ro"), bind(filepath.Dir(ws) + ":/up"),
		{Image: "alpine", HostConfig: dockerHost{Mounts: []dockerMount{{Type: "bind", Source: ws, Target: "/h", ReadOnly: true}}}},
	} {
		_, err := delegatedBinds(owner, &refused)
		var api apiError
		if !errors.As(err, &api) || api.code != 403 {
			t.Errorf("%v: %v, want 403", refused.HostConfig, err)
		}
	}

	spec := bind(ws+"/job/src:/src", ws+"/ro/conf:/conf", ws+"/job:/w:ro")
	roots, err := delegatedBinds(owner, &spec)
	if err != nil {
		t.Fatal(err)
	}
	if roots["/src"] != ws+"/job" || roots["/conf"] != ws+"/ro" || roots["/w"] != ws+"/job" {
		t.Fatalf("roots %v", roots)
	}
	if !slices.Equal(spec.HostConfig.Binds, []string{ws + "/job/src:/src", ws + "/ro/conf:/conf:ro", ws + "/job:/w:ro"}) {
		t.Fatalf("binds %v: a bind below a read-only one of the creator's must be read-only", spec.HostConfig.Binds)
	}
	s := &dockerEngine{workspace: ws}
	files, mounts, _, err := s.openMountsWith(spec, cacheVolumeRules{}, false, mountSockets{bindRoots: roots}, t.TempDir())
	closeMounts(files)
	if err != nil || len(mounts) != 3 || mounts[0].Readonly || !mounts[1].Readonly || !mounts[2].Readonly {
		t.Fatalf("start: %+v %v", mounts, err)
	}
	// A symlink inside the creator's bind resolves inside it; one leading out
	// of it is refused, though it stays inside the workspace.
	inside := bind(ws + "/job/inside:/i")
	if roots, err := delegatedBinds(owner, &inside); err != nil {
		t.Fatal(err)
	} else if files, _, _, err := s.openMountsWith(inside, cacheVolumeRules{}, false, mountSockets{bindRoots: roots}, t.TempDir()); err != nil {
		t.Fatalf("a symlink within the creator's bind: %v", err)
	} else {
		closeMounts(files)
	}
	escape := bind(ws + "/job/escape:/e")
	roots, err = delegatedBinds(owner, &escape)
	if err != nil {
		t.Fatal(err)
	}
	for _, create := range []bool{true, false} {
		if files, _, _, err := s.openMountsWith(escape, cacheVolumeRules{}, create, mountSockets{bindRoots: roots}, t.TempDir()); err == nil {
			closeMounts(files)
			t.Fatalf("a symlink out of the creator's bind was followed (create %v)", create)
		}
	}
	// The creator's own bind through a symlink is no root: someone who can
	// write its parent could point it anywhere in the workspace.
	viaLink := bind(ws + "/joblink/src:/s")
	if roots, err := delegatedBinds(owner, &viaLink); err != nil {
		t.Fatal(err)
	} else if files, _, _, err := s.openMountsWith(viaLink, cacheVolumeRules{}, false, mountSockets{bindRoots: roots}, t.TempDir()); err == nil {
		closeMounts(files)
		t.Fatal("a root reached through a symlink was used")
	}
	// A bind with no recorded root never resolves from the workspace.
	if files, _, _, err := s.openMountsWith(bind(ws+":/h"), cacheVolumeRules{}, false, mountSockets{bindRoots: map[string]string{}}, t.TempDir()); err == nil {
		closeMounts(files)
		t.Fatal("a child's bind without a root opened")
	}
	// The reaper's socket bind is not a path.
	ryuk := ryukSpec()
	if roots, err := delegatedBinds(owner, &ryuk); err != nil || len(roots) != 0 {
		t.Fatalf("reaper: %v %v", roots, err)
	}
}

// The create itself: a child of a delegated socket that binds the workspace
// is refused before anything is made.
func TestDelegatedCreateRefusesAWorkspaceBind(t *testing.T) {
	ws := t.TempDir()
	if err := os.MkdirAll(filepath.Join(ws, "job"), 0755); err != nil {
		t.Fatal(err)
	}
	imageID := healthConfigDigest([]byte("{}"))
	owner := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("a", 64), Name: "job", Phase: "running",
		Config: dockerConfig{Image: "golang:1", HostConfig: dockerHost{Binds: []string{ws + "/job:/work"}}}}}
	s := &dockerEngine{
		node:         node{images: dockerHealthTestImages{id: imageID}, imageStore: dockerHealthTestImageStore{}},
		containers:   map[string]*dockerContainer{owner.ID: owner},
		healthImages: dockerImageHealthCache{byID: map[string]dockerImageHealth{imageID: {}}},
		cachePolicy:  policyLoader{path: filepath.Join(t.TempDir(), "absent.json")},
		workspace:    ws,
	}
	ctx := withViewer(withCacheOrigin(context.Background(), cacheOrigin{creator: owner.ID}), owner.ID)
	spec := dockerConfig{Image: "alpine:3.23", Labels: map[string]string{"io.micropod.cache": "off"},
		HostConfig: dockerHost{Binds: []string{ws + ":/h"}}}
	_, err := s.create(ctx, spec, "")
	var api apiError
	if !errors.As(err, &api) || api.code != 403 || !strings.Contains(api.message, "own binds") {
		t.Fatalf("create binding the workspace through a delegated socket: %v, want 403", err)
	}
	if len(s.containers) != 1 {
		t.Fatal("a refused create left a container")
	}
}

// A trusted child of a delegated socket is a writer, yet its alias volumes
// are held to its creator's scope as a reader's are, at create, at start and
// through docker cp: naming another project's store by its volume name
// reaches it no more than naming the scope does.
func TestDelegatedChildAliasVolumesStayInItsCreatorsScope(t *testing.T) {
	useVolumeStore(t)
	imageID := healthConfigDigest([]byte("{}"))
	owner := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("a", 64), Name: "job", Phase: "running",
		Config: dockerConfig{Image: "golang:1"}, Cache: &cachePlan{Scope: "proj-a"}}}
	s := &dockerEngine{
		node:         node{images: dockerHealthTestImages{id: imageID}, imageStore: dockerHealthTestImageStore{}},
		containers:   map[string]*dockerContainer{owner.ID: owner},
		healthImages: dockerImageHealthCache{byID: map[string]dockerImageHealth{imageID: {}}},
		cachePolicy:  policyLoader{path: filepath.Join(t.TempDir(), "absent.json")},
		workspace:    t.TempDir(),
	}
	ctx := withViewer(withCacheOrigin(context.Background(), cacheOrigin{creator: owner.ID}), owner.ID)
	pol := s.cachePolicy.get()
	for _, bind := range []string{"micropod-ci-scoped-proj-b-gomod:/go/pkg/mod", "micropod-ci-scoped-proj-b-gomod:/go/pkg/mod:ro", "micropod-ci-scoped-default-gobuild:/root/.cache/go-build"} {
		spec := dockerConfig{Image: "alpine:3.23", Labels: map[string]string{"io.micropod.cache": "off"}, HostConfig: dockerHost{Binds: []string{bind}}}
		_, err := s.create(ctx, spec, "")
		var api apiError
		if !errors.As(err, &api) || api.code != 400 || !strings.Contains(api.message, "creator's scope") {
			t.Errorf("create with %s through a delegated socket: %v, want 400", bind, err)
		}
		// A start replays the record's rules: the same child, made before
		// this rule, does not start.
		plan := cachePlan{Scope: "proj-a"}
		if _, _, _, err := s.openMountsWith(spec, containerVolumeRules(pol, spec, &plan, owner.ID), false, mountSockets{bindRoots: map[string]string{}}, t.TempDir()); err == nil || !strings.Contains(err.Error(), "creator's scope") {
			t.Errorf("start with %s: %v", bind, err)
		}
		// Nor does docker cp reach it, stopped.
		child := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("c", 64), Phase: "created", CreatedBy: owner.ID, Config: spec, Cache: &plan}, changed: make(chan struct{})}
		for _, write := range []bool{false, true} {
			_, _, err := s.pinArchive(context.Background(), child, "/go/pkg/mod/cache", write)
			if strings.Contains(bind, "gobuild") {
				_, _, err = s.pinArchive(context.Background(), child, "/root/.cache/go-build/x", write)
			}
			if !errors.As(err, &api) || api.code != 403 {
				t.Errorf("docker cp (write %v) into %s of a stopped child: %v, want 403", write, bind, err)
			}
		}
	}
	// Its own scope stays open to it, and the host's containers keep theirs.
	plan := cachePlan{Scope: "proj-a"}
	spec := dockerConfig{HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-proj-b-gomod:/go/pkg/mod"}}}
	if r := containerVolumeRules(pol, spec, &plan, owner.ID); r.readOnly || !r.confined || !r.readerMay("proj-a", "gomod") || r.readerMay("proj-b", "gomod") {
		t.Fatalf("child rules %+v", r)
	}
	if r := containerVolumeRules(pol, spec, &plan, ""); r.confined {
		t.Fatalf("a host container is held to its scope: %+v", r)
	}
}

// A child reaches a path no more writably than its owner does: the most
// specific of the owner's binds over it decides, ignoring case as the host's
// file system does, and a read-only bind of the owner's nested in a writable
// one is read-only in a child that binds the parent too.
func TestDelegatedBindsKeepTheOwnersNestedReadOnlyBinds(t *testing.T) {
	ws := t.TempDir()
	for _, d := range []string{"job/.git/hooks", "job/keys", "job/src"} {
		if err := os.MkdirAll(filepath.Join(ws, d), 0755); err != nil {
			t.Fatal(err)
		}
	}
	job := ws + "/job"
	owner := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("a", 64), Config: dockerConfig{Image: "golang:1", HostConfig: dockerHost{
		// .git is shadowed read-only inside the writable checkout; keys is
		// read-only only at another path, so the owner writes it at /work/keys.
		Binds: []string{job + ":/work", job + "/.git:/work/.git:ro", job + "/keys:/keys:ro", "/var/run/docker.sock:/var/run/docker.sock"}}}}}
	for _, tc := range []struct {
		bind, want string
	}{
		{job + "/.git:/g", job + "/.git:/g:ro"},
		{job + "/.git/hooks:/h", job + "/.git/hooks:/h:ro"},
		{job + "/.GIT/hooks:/H", job + "/.GIT/hooks:/H:ro"},
		{job + "/keys:/k", job + "/keys:/k"},
		{job + "/src:/s", job + "/src:/s"},
	} {
		spec := dockerConfig{Image: "alpine", HostConfig: dockerHost{Binds: []string{tc.bind}}}
		if _, err := delegatedBinds(owner, &spec); err != nil {
			t.Fatal(err)
		}
		if spec.HostConfig.Binds[0] != tc.want || len(spec.HostConfig.Mounts) != 0 {
			t.Errorf("%s: %v %+v, want %s", tc.bind, spec.HostConfig.Binds, spec.HostConfig.Mounts, tc.want)
		}
	}
	// The checkout itself: writable, with .git read-only below it as in the
	// owner; keys stays writable, as the owner writes it there.
	spec := dockerConfig{Image: "alpine", HostConfig: dockerHost{Binds: []string{job + ":/x", job + ":/y"}, Tmpfs: map[string]string{"/y/.git": ""}}}
	roots, err := delegatedBinds(owner, &spec)
	if err != nil {
		t.Fatal(err)
	}
	want := []dockerMount{{Type: "bind", Source: job + "/.git", Target: "/x/.git", ReadOnly: true}}
	if !slices.Equal(spec.HostConfig.Mounts, want) || roots["/x/.git"] != job+"/.git" || roots["/x"] != job {
		t.Fatalf("mounts %+v roots %v, want .git read-only below /x only", spec.HostConfig.Mounts, roots)
	}
	s := &dockerEngine{workspace: ws}
	files, mounts, _, err := s.openMountsWith(spec, cacheVolumeRules{}, false, mountSockets{bindRoots: roots}, t.TempDir())
	closeMounts(files)
	if err != nil {
		t.Fatal(err)
	}
	modes := map[string]bool{}
	for _, m := range mounts {
		modes[m.ContainerPath] = m.Readonly
	}
	if ro, ok := modes["/x/.git"]; !ok || !ro || modes["/x"] || modes["/y"] {
		t.Fatalf("start mounts %v", modes)
	}
	// Read-only already: nothing to add.
	ro := dockerConfig{Image: "alpine", HostConfig: dockerHost{Binds: []string{job + ":/x:ro"}}}
	if _, err := delegatedBinds(owner, &ro); err != nil || len(ro.HostConfig.Mounts) != 0 {
		t.Fatalf("read-only child: %+v %v", ro.HostConfig.Mounts, err)
	}
}

// A child is held to what its running creator holds by identity, not by the
// spelling its create saw: once the owner renames a directory above its
// read-only bind (it writes the parent), or plants a symlink to it, binding
// the new path reaches that bind no more writably than the owner does, at
// create, at start and through docker cp.
func TestDelegatedBindsHoldTheOwnersReadOnlyBindsByIdentity(t *testing.T) {
	ws := t.TempDir()
	for _, d := range []string{"job/.git/hooks", "job/src"} {
		if err := os.MkdirAll(filepath.Join(ws, d), 0755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(ws, "job/.git/config"), []byte("[core]\n"), 0644); err != nil {
		t.Fatal(err)
	}
	imageID := healthConfigDigest([]byte("{}"))
	owner := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("a", 64), Name: "job", Phase: "running", Config: dockerConfig{Image: "golang:1", HostConfig: dockerHost{
		Binds: []string{ws + ":/h", ws + "/job/.git:/h/job/.git:ro", "/var/run/docker.sock:/var/run/docker.sock"}}}}}
	s := &dockerEngine{
		node:         node{images: dockerHealthTestImages{id: imageID}, imageStore: dockerHealthTestImageStore{}},
		containers:   map[string]*dockerContainer{owner.ID: owner},
		healthImages: dockerImageHealthCache{byID: map[string]dockerImageHealth{imageID: {}}},
		cachePolicy:  policyLoader{path: filepath.Join(t.TempDir(), "absent.json")},
		workspace:    ws,
	}
	// The owner's start: the descriptors its mounts are made from.
	files, mounts, _, err := s.openMountsWith(owner.Config, cacheVolumeRules{}, false, mountSockets{engine: filepath.Join(t.TempDir(), "docker.sock")}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer closeMounts(files)
	owner.binds = &heldBinds{byTarget: mountFiles(files, mounts)}
	viewer := owner.ID
	child := func(binds []string, tmpfs ...string) (dockerConfig, map[string]string) {
		t.Helper()
		spec := dockerConfig{Image: "alpine", HostConfig: dockerHost{Binds: binds, Tmpfs: map[string]string{}}}
		for _, p := range tmpfs {
			spec.HostConfig.Tmpfs[p] = ""
		}
		roots, err := delegatedBinds(owner, &spec)
		if err != nil {
			t.Fatalf("%v: %v", binds, err)
		}
		return spec, roots
	}
	// open is a create's check, then a start's: the mounts the start makes.
	open := func(spec dockerConfig, roots map[string]string) (map[string]bool, error) {
		t.Helper()
		var modes map[string]bool
		for _, create := range []bool{true, false} {
			s.mu.Lock()
			creator, err := s.creatorHoldLocked(owner.ID, viewer, roots)
			s.mu.Unlock()
			if err != nil {
				return nil, err
			}
			files, mounts, _, err := s.openMountsWith(spec, cacheVolumeRules{}, create, mountSockets{bindRoots: roots, creator: creator}, t.TempDir())
			closeMounts(files)
			if err != nil {
				return nil, err
			}
			modes = map[string]bool{}
			for _, m := range mounts {
				modes[m.ContainerPath] = m.Readonly
			}
		}
		return modes, nil
	}
	refused := func(why string, binds []string, tmpfs ...string) {
		t.Helper()
		spec, roots := child(binds, tmpfs...)
		_, err := open(spec, roots)
		var api apiError
		if !errors.As(err, &api) || api.code != 403 {
			t.Errorf("%s (%v): %v, want 403", why, binds, err)
		}
	}
	admitted := func(why string, binds []string, tmpfs ...string) map[string]bool {
		t.Helper()
		spec, roots := child(binds, tmpfs...)
		modes, err := open(spec, roots)
		if err != nil {
			t.Errorf("%s (%v): %v", why, binds, err)
		}
		return modes
	}

	// As the create spelled it: .git read-only below the checkout.
	if m := admitted("the checkout", []string{ws + "/job:/x"}); !m["/x/.git"] || m["/x"] {
		t.Errorf("checkout mounts %v", m)
	}
	admitted("the read-only bind, made read-only by its name", []string{ws + "/job/.git:/g"})

	// The owner renames the checkout through its writable /h, leaves a
	// decoy .git at the old path and plants a symlink to the read-only bind
	// inside its writable one.
	if err := os.Rename(filepath.Join(ws, "job"), filepath.Join(ws, "job2")); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(ws, "job/.git"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("job2/.git", filepath.Join(ws, "gitlink")); err != nil {
		t.Fatal(err)
	}
	job := ws + "/job2"
	refused("the renamed checkout holds .git with no read-only mount over it", []string{job + ":/x"})
	refused("the read-only bind by its new name", []string{job + "/.git:/g"})
	refused("below the read-only bind", []string{job + "/.git/hooks:/hk"})
	refused("through a symlink to it", []string{ws + "/gitlink:/l"})
	refused("the decoy at the old path covers nothing", []string{ws + ":/w"})
	if m := admitted("the rest of the checkout", []string{job + "/src:/s"}); m["/s"] {
		t.Errorf("a writable path of the owner's became read-only: %v", m)
	}
	admitted("the read-only bind, read-only", []string{job + "/.git:/g:ro", ws + "/gitlink:/l:ro"})
	admitted("the checkout read-only", []string{job + ":/x:ro"})
	if m := admitted("the checkout with .git read-only over it", []string{job + ":/x", job + "/.git:/x/.git:ro"}); !m["/x/.git"] || m["/x"] {
		t.Errorf("mounts %v", m)
	}
	admitted("the checkout with a tmpfs over .git", []string{job + ":/x"}, "/x/.git")
	refused("a tmpfs elsewhere covers nothing", []string{job + ":/x"}, "/x/src")

	// The create itself, through the owner's socket.
	ctx := withViewer(withCacheOrigin(context.Background(), cacheOrigin{creator: owner.ID}), owner.ID)
	_, err = s.create(ctx, dockerConfig{Image: "alpine:3.23", Labels: map[string]string{"io.micropod.cache": "off"}, HostConfig: dockerHost{Binds: []string{job + ":/x"}}}, "")
	var api apiError
	if !errors.As(err, &api) || api.code != 403 || !strings.Contains(api.message, "binds read-only") || len(s.containers) != 1 {
		t.Fatalf("create of the renamed checkout through the owner's socket: %v, want 403", err)
	}

	// docker cp into a stopped child made before this rule: no write
	// through the bind that holds .git; reading stays the owner's.
	spec, roots := child([]string{job + ":/x"})
	stopped := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("c", 64), Phase: "created", CreatedBy: owner.ID, Config: spec, BindRoots: roots}, changed: make(chan struct{})}
	if _, _, err := s.pinArchive(ctx, stopped, "/x/.git/config", true); !errors.As(err, &api) || api.code != 403 {
		t.Errorf("docker cp into .git of a stopped child: %v, want 403", err)
	}
	if _, closeView, err := s.pinArchive(ctx, stopped, "/x/.git/config", false); err != nil {
		t.Errorf("docker cp out of a stopped child: %v", err)
	} else {
		closeView()
	}

	// Its creator stopped: a request on its socket cannot be checked and is
	// refused; the host's own start keeps the create-time decision.
	owner.binds = nil
	s.mu.Lock()
	_, onSocket := s.creatorHoldLocked(owner.ID, viewer, roots)
	byHost, hostErr := s.creatorHoldLocked(owner.ID, "", roots)
	s.mu.Unlock()
	if !errors.As(onSocket, &api) || api.code != 409 || byHost != nil || hostErr != nil {
		t.Fatalf("creator stopped: socket %v, host %v %v", onSocket, byHost, hostErr)
	}
}

// The config probes a create runs on a child's binds (an .npmrc registry, a
// go env GOPROXY) read below the creator's binds, as the bind itself would
// open: a symlink the owner plants there does not read another project's
// file into a bit of the child's environment. A volume's probe stays in that
// volume.
func TestDelegatedConfigProbesStayInsideTheCreatorsBinds(t *testing.T) {
	ws := t.TempDir()
	for _, d := range []string{"job/real", "job/go", "other-project"} {
		if err := os.MkdirAll(filepath.Join(ws, d), 0755); err != nil {
			t.Fatal(err)
		}
	}
	for name, body := range map[string]string{"other-project/.npmrc": "registry=https://npm.other/\n", "other-project/goenv": "GOPROXY=https://proxy.other\n", "job/real/.npmrc": "registry=https://npm.job/\n"} {
		if err := os.WriteFile(filepath.Join(ws, name), []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
	}
	for link, to := range map[string]string{"job/.npmrc": "../other-project/.npmrc", "job/go/env": "../../other-project/goenv"} {
		if err := os.Symlink(to, filepath.Join(ws, link)); err != nil {
			t.Fatal(err)
		}
	}
	owner := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("a", 64), Phase: "running", Config: dockerConfig{Image: "node", HostConfig: dockerHost{Binds: []string{ws + "/job:/work"}}}}}
	s := &dockerEngine{workspace: ws, containers: map[string]*dockerContainer{owner.ID: owner}}
	ctx := withViewer(context.Background(), owner.ID)
	spec := dockerConfig{Image: "node", WorkingDir: "/w", HostConfig: dockerHost{Binds: []string{ws + "/job:/w"}}}
	roots := s.probeRoots(ctx, spec)
	if roots["/w"] != ws+"/job" || len(spec.HostConfig.Mounts) != 0 {
		t.Fatalf("roots %v", roots)
	}
	if s.projectNpmRegistry(spec, "", roots) {
		t.Error("the working directory's .npmrc was read through a symlink out of the creator's bind")
	}
	if s.mountedConfigSets(spec, []string{"/w/.npmrc"}, npmrcSetsRegistry, roots) || s.mountedConfigSets(spec, []string{"/w/go/env"}, goEnvSetsProxy, roots) {
		t.Error("a mounted config file was read through a symlink out of the creator's bind")
	}
	if !s.mountedConfigSets(spec, []string{"/w/real/.npmrc"}, npmrcSetsRegistry, roots) {
		t.Error("a config file inside the creator's bind was not read")
	}
	// The host's own containers resolve from the workspace, as their binds do.
	if s.probeRoots(context.Background(), spec) != nil || !s.projectNpmRegistry(spec, "", nil) {
		t.Error("the host's create lost its workspace probe")
	}
	// A bind outside the creator's (the create is refused anyway) reads nothing.
	outside := dockerConfig{WorkingDir: "/o", HostConfig: dockerHost{Binds: []string{ws + "/other-project:/o"}}}
	if r := s.probeRoots(ctx, outside); r == nil || s.projectNpmRegistry(outside, "", r) {
		t.Error("a probe read outside the creator's binds")
	}

	vols := t.TempDir()
	old := configVolumesDir
	configVolumesDir = vols
	t.Cleanup(func() { configVolumesDir = old })
	for _, d := range []string{"tc-data", "job-b"} {
		if err := os.Mkdir(filepath.Join(vols, d), 0755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(vols, "job-b", ".npmrc"), []byte("registry=https://npm.b/\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../job-b/.npmrc", filepath.Join(vols, "tc-data", ".npmrc")); err != nil {
		t.Fatal(err)
	}
	inVolume := dockerConfig{HostConfig: dockerHost{Binds: []string{"tc-data:/data"}}}
	if s.mountedConfigSets(inVolume, []string{"/data/.npmrc"}, npmrcSetsRegistry, roots) || s.mountedConfigSets(inVolume, []string{"/data/.npmrc"}, npmrcSetsRegistry, nil) {
		t.Error("a volume's .npmrc was read through a symlink into another volume")
	}
}
