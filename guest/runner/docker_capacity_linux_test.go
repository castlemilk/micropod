package main

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParsePSI(t *testing.T) {
	p, ok := parsePSI("some avg10=1.50 avg60=0.25 avg300=0.01 total=12345\nfull avg10=0.75 avg60=0.10 avg300=0.00 total=99\n")
	if !ok || p.Some.Avg10 != 1.5 || p.Some.Avg60 != 0.25 || p.Some.Avg300 != 0.01 || p.Full.Avg10 != 0.75 || p.Full.Avg60 != 0.1 {
		t.Fatalf("%+v %v", p, ok)
	}
	// An older kernel's cpu file has no "full" line.
	if p, ok = parsePSI("some avg10=3.00 avg60=2.00 avg300=1.00 total=1\n"); !ok || p.Some.Avg10 != 3 || p.Full.Avg10 != 0 {
		t.Fatalf("%+v %v", p, ok)
	}
	for _, bad := range []string{"", "garbage", "some avg10=x avg60=y avg300=z total=1", "most avg10=1.00 avg60=1.00 avg300=1.00 total=1"} {
		if _, ok := parsePSI(bad); ok {
			t.Errorf("%q parsed", bad)
		}
	}
}

// The recommendation: counted on what is used, the smallest resource wins,
// and any pressure signal withdraws it whole.
func TestHeadroomFor(t *testing.T) {
	const gib = 1 << 30
	idle := kernelSample{cpus: 16, memTotal: 48 * gib, memAvailable: 47 * gib, pidMax: 4194304, tasks: 200,
		osDiskTotal: 64 * gib, osDiskFree: 40 * gib, psi: map[string]psiResource{}}
	h := headroomFor(idle, containerLoad{}, 0)
	// (16*0.9)/0.5 = 28 by CPU; (47-2.4)/0.5 = 89 by memory.
	if h.Containers != 28 || h.LimitedBy != "cpu" || h.ByMemory != 89 || h.UnderPressure || len(h.Reasons) != 0 || h.UnitCPU != 0.5 || h.UnitMemory != 512<<20 {
		t.Fatalf("idle: %+v", h)
	}
	// 40 containers that together keep 4 CPUs busy and use 20 GiB: the unit
	// is what one of them uses (0.1 CPU held to the 0.25 floor, 512 MiB).
	busy := idle
	busy.cpuBusyFraction, busy.memAvailable = 0.25, 28*gib
	h = headroomFor(busy, containerLoad{running: 40}, 300)
	if h.UnitCPU != 0.25 || h.UnitMemory != 512<<20 || h.ByCPU != 41 || h.ByMemory != 51 || h.Containers != 41 || h.LimitedBy != "cpu" || h.UnderPressure {
		t.Fatalf("busy: %+v", h)
	}
	// Memory runs out first.
	tight := busy
	tight.memAvailable = 4 * gib
	h = headroomFor(tight, containerLoad{running: 40}, 300)
	if h.LimitedBy != "memory" || h.Containers != h.ByMemory || h.Containers >= h.ByCPU || h.UnderPressure {
		t.Fatalf("tight memory: %+v", h)
	}
	// The container ceiling.
	h = headroomFor(idle, containerLoad{running: headroomContainerCeiling - 3}, 0)
	if h.Containers != 3 || h.LimitedBy != "containers" {
		t.Fatalf("ceiling: %+v", h)
	}
	// A saturated machine has no CPU headroom and is not thereby "under pressure".
	full := idle
	full.cpuBusyFraction = 0.97
	if h = headroomFor(full, containerLoad{running: 16}, 0); h.Containers != 0 || h.UnderPressure || h.LimitedBy != "cpu" {
		t.Fatalf("saturated: %+v", h)
	}
	pressure := func(name string, change func(*kernelSample), p95 uint32, limited string) {
		t.Helper()
		k := idle
		k.psi = map[string]psiResource{}
		change(&k)
		h := headroomFor(k, containerLoad{running: 4}, p95)
		if !h.UnderPressure || h.Containers != 0 || len(h.Reasons) != 1 || h.LimitedBy != limited {
			t.Errorf("%s: %+v", name, h)
		}
	}
	pressure("memory some", func(k *kernelSample) { k.psi["memory"] = psiResource{Some: psiLine{Avg10: 12}} }, 0, "pressure")
	pressure("memory full", func(k *kernelSample) { k.psi["memory"] = psiResource{Full: psiLine{Avg10: 2.5}} }, 0, "pressure")
	pressure("cpu", func(k *kernelSample) { k.psi["cpu"] = psiResource{Some: psiLine{Avg10: 85}} }, 0, "pressure")
	pressure("io", func(k *kernelSample) { k.psi["io"] = psiResource{Full: psiLine{Avg10: 30}} }, 0, "pressure")
	pressure("memory reserve", func(k *kernelSample) { k.memAvailable = gib }, 0, "memory")
	pressure("os disk", func(k *kernelSample) { k.osDiskFree = gib }, 0, "os-disk")
	pressure("cache disk", func(k *kernelSample) { k.cacheDisk, k.cacheTotal, k.cacheFree = true, 32*gib, gib }, 0, "cache-disk")
	pressure("slow starts", func(k *kernelSample) {}, 12000, "pressure")
	// Below every threshold: a busy machine is not under pressure.
	calm := idle
	calm.psi = map[string]psiResource{"memory": {Some: psiLine{Avg10: 9.9}, Full: psiLine{Avg10: 1.9}}, "cpu": {Some: psiLine{Avg10: 79}}, "io": {Full: psiLine{Avg10: 24}}}
	if h = headroomFor(calm, containerLoad{running: 4}, 9999); h.UnderPressure || h.Containers == 0 {
		t.Fatalf("calm: %+v", h)
	}
	// A cache disk that is not there is never the reason.
	noCache := idle
	noCache.cacheTotal, noCache.cacheFree = 32*gib, 0
	if h = headroomFor(noCache, containerLoad{}, 0); h.UnderPressure {
		t.Fatalf("no cache disk: %+v", h)
	}
}

// One pass over a /proc: CPU use is the busy share since the pass before.
func TestCapacitySample(t *testing.T) {
	proc := t.TempDir()
	write := func(rel, body string) {
		t.Helper()
		path := filepath.Join(proc, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("stat", "cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 1 1 1 1\n")
	write("loadavg", "1.50 0.75 0.25 3/412 9999\n")
	write("meminfo", "MemTotal:       1048576 kB\nMemFree: 1 kB\nMemAvailable:    524288 kB\nSwapTotal: 2048 kB\nSwapFree: 1024 kB\n")
	write("pressure/memory", "some avg10=4.00 avg60=1.00 avg300=0.00 total=1\nfull avg10=1.00 avg60=0.00 avg300=0.00 total=1\n")
	write("sys/fs/file-nr", "640\t0\t99999\n")
	write("sys/kernel/pid_max", "4194304\n")
	c := &capacityState{proc: proc}
	first := c.read(kernelSample{})
	if first.cpuBusyFraction != 0 || first.load1 != 1.5 || first.load15 != 0.25 || first.runnable != 3 || first.tasks != 412 ||
		first.memTotal != 1<<30 || first.memAvailable != 512<<20 || first.swapTotal-first.swapFree != 1<<20 ||
		!first.hasPSI || first.psi["memory"].Some.Avg10 != 4 || first.psi["memory"].Full.Avg10 != 1 ||
		first.openFiles != 640 || first.openFilesMax != 99999 || first.pidMax != 4194304 {
		t.Fatalf("%+v", first)
	}
	if _, ok := first.psi["cpu"]; ok {
		t.Fatal("a pressure file that is not there was reported")
	}
	// 300 more busy ticks of 400.
	write("stat", "cpu  300 0 200 900 0 0 0 0 0 0\n")
	if second := c.read(first); second.cpuBusyFraction != 0.75 {
		t.Fatalf("busy fraction %v, want 0.75", second.cpuBusyFraction)
	}
	// No PSI at all: said so, not zeros taken for calm.
	bare := &capacityState{proc: t.TempDir()}
	if s := bare.read(kernelSample{}); s.hasPSI || len(s.psi) != 0 || s.memTotal != 0 {
		t.Fatalf("%+v", s)
	}
}

func TestStartLatency(t *testing.T) {
	var c capacityState
	if p50, p95, n := c.startLatency(); p50 != 0 || p95 != 0 || n != 0 {
		t.Fatal(p50, p95, n)
	}
	for i := 1; i <= 100; i++ {
		c.recordStart(time.Duration(i) * time.Millisecond)
	}
	if p50, p95, n := c.startLatency(); p50 != 50 || p95 != 95 || n != 100 {
		t.Fatal(p50, p95, n)
	}
	// Only the latest window counts.
	for i := 0; i < startLatencyWindow; i++ {
		c.recordStart(7 * time.Millisecond)
	}
	if p50, p95, n := c.startLatency(); p50 != 7 || p95 != 7 || n != startLatencyWindow {
		t.Fatal(p50, p95, n)
	}
}

// Families: a delegated socket's children count under their owner whatever
// they label themselves, a host container under its label, the rest under "".
func TestContainerLoadByFamily(t *testing.T) {
	s, owner, child, other, otherChild := delegatedFixture(t)
	owner.EngineSocket, other.EngineSocket = true, true
	owner.Config.Labels[familyLabel] = "attempt-1"
	child.Config.Labels[familyLabel] = "someone-else" // a child cannot move itself
	child.Config.HostConfig.NanoCpus, child.Config.HostConfig.Memory = 2e9, 2<<30
	otherChild.Phase = "exited"
	labelled := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("e", 64), Name: "gha", Phase: "running",
		Config: dockerConfig{Labels: map[string]string{familyLabel: "gha-job-9"}}}}
	plain := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("f", 64), Name: "plain", Phase: "created", Config: dockerConfig{}}}
	s.containers[labelled.ID], s.containers[plain.ID] = labelled, plain
	load := s.containerLoad()
	if load.total != 6 || load.running != 4 || load.created != 1 || load.exited != 1 {
		t.Fatalf("%+v", load)
	}
	want := map[string][2]int{"attempt-1": {2, 2}, "job-b": {1, 2}, "gha-job-9": {1, 1}, "": {0, 1}}
	if len(load.families) != len(want) {
		t.Fatalf("families %v", load.families)
	}
	for name, counts := range want {
		f := load.families[name]
		if f == nil || f.Running != counts[0] || f.Total != counts[1] {
			t.Errorf("family %q: %+v, want running %d of %d", name, f, counts[0], counts[1])
		}
	}
	if f := load.families["attempt-1"]; f.MilliCPU != 3000 || f.Memory != 3<<30 {
		t.Errorf("attempt-1 limits: %+v (a child's 2 CPUs and 2 GiB, the owner's default 1 and 1)", f)
	}
}

// The route: host only, one JSON object with every part, never recorded as
// a request (a scheduler polls it every second).
func TestCapacityRoute(t *testing.T) {
	s, owner, _, _, _ := delegatedFixture(t)
	s.capacity.proc = t.TempDir()
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, httptest.NewRequest("GET", "/v1.47/micropod/capacity", nil))
	var body map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &body); rec.Code != 200 || err != nil {
		t.Fatalf("%d %s %v", rec.Code, rec.Body, err)
	}
	for _, part := range []string{"sampled_unix_ms", "capacity", "usage", "containers", "engine", "pressure", "disks", "headroom"} {
		if _, ok := body[part]; !ok {
			t.Errorf("no %q in %s", part, rec.Body)
		}
	}
	var containers struct {
		Running  int
		Families []familyLoad
	}
	if err := json.Unmarshal(body["containers"], &containers); err != nil || containers.Running != 4 || len(containers.Families) == 0 {
		t.Fatalf("%s %v", body["containers"], err)
	}
	if snap, _ := s.metrics.api.snapshot(); snap["requests_total"] != uint64(0) {
		t.Fatalf("reading the capacity was counted as a request: %v", snap["requests_total"])
	}
	if delegatedRoute("GET", "/micropod/capacity") || delegatedRoute("POST", "/v1.47/micropod/families/prune") {
		t.Fatal("a delegated socket serves the engine's own routes")
	}
	rec = httptest.NewRecorder()
	delegatedAPI{s}.ServeHTTP(rec, httptest.NewRequest("GET", "/micropod/capacity", nil).WithContext(withViewer(context.Background(), owner.ID)))
	if rec.Code != 403 {
		t.Fatalf("on a delegated socket: %d %s", rec.Code, rec.Body)
	}
}

func TestApplyDefaultLimits(t *testing.T) {
	none, err := parseCachePolicy([]byte(`{"defaultLimits":"none"}`))
	if err != nil || !none.unlimitedByDefault() {
		t.Fatalf("%+v %v", none, err)
	}
	for _, body := range []string{`{}`, `{"defaultLimits":"job"}`, `{"defaultLimits":""}`} {
		if pol, err := parseCachePolicy([]byte(body)); err != nil || pol.unlimitedByDefault() || pol.digest() != defaultCachePolicy().digest() {
			t.Fatalf("%s: %+v %v", body, pol, err)
		}
	}
	for _, body := range []string{`{"defaultLimits":"NONE"}`, `{"defaultLimits":"unlimited"}`, `{"defaultLimits":false}`} {
		if pol, err := parseCachePolicy([]byte(body)); err == nil || pol.unlimitedByDefault() {
			t.Fatalf("%s parsed: %+v", body, pol)
		}
	}
	if failClosedCachePolicy().unlimitedByDefault() || defaultCachePolicy().unlimitedByDefault() {
		t.Fatal("a default policy lifts the limits")
	}
	// The shipped default leaves a create as it came.
	var h dockerHost
	h.applyDefaultLimits(defaultCachePolicy())
	if l := h.limits(); h.CpuQuota != 0 || h.Memory != 0 || h.PidsLimit != nil || l.memory != jobMemory || l.pids != jobPids || l.quota != jobCPUQuota {
		t.Fatalf("%+v %+v", h, l)
	}
	// none: no quota, the machine's memory, unlimitedPids.
	h = dockerHost{}
	h.applyDefaultLimits(none)
	if l := h.limits(); l.quota >= 0 || l.memory != machineMemory() || l.memory <= jobMemory || l.pids != unlimitedPids {
		t.Fatalf("%+v %+v", h, l)
	}
	// What the create names is kept, each on its own.
	pids := int64(100)
	h = dockerHost{NanoCpus: 2e9, Memory: 512 << 20, PidsLimit: &pids}
	h.applyDefaultLimits(none)
	if l := h.limits(); l.quota != 200000 || l.memory != 512<<20 || l.pids != 100 || h.CpuQuota != 0 {
		t.Fatalf("%+v %+v", h, l)
	}
	h = dockerHost{CpuQuota: 50000}
	h.applyDefaultLimits(none)
	if l := h.limits(); l.quota != 50000 || l.memory != machineMemory() {
		t.Fatalf("%+v %+v", h, l)
	}
	// A child of a delegated socket still gets at most its owner's.
	child := dockerHost{}
	child.applyDefaultLimits(none)
	child.clampTo(dockerHost{NanoCpus: 2e9, Memory: 1 << 30}.limits())
	if l := child.limits(); l.quota != 200000 || l.memory != 1<<30 || l.pids != jobPids {
		t.Fatalf("clamped child: %+v", l)
	}
}

func TestFamilyHeader(t *testing.T) {
	for _, ok := range []string{"a", "gha-job-1", "Run_42.attempt-3", strings.Repeat("x", 128)} {
		if !validFamilyName(ok) {
			t.Errorf("%q refused", ok)
		}
	}
	for _, bad := range []string{"", "-a", ".a", "a b", "a/b", "a=b", strings.Repeat("x", 129), "é"} {
		if validFamilyName(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
	ctx := withRequestFamily(context.Background(), "job-7")
	if got := stampFamily(ctx, nil); len(got) != 1 || got[familyLabel] != "job-7" {
		t.Fatal(got)
	}
	own := map[string]string{familyLabel: "mine", "k": "v"}
	if got := stampFamily(ctx, own); got[familyLabel] != "mine" || len(got) != 2 {
		t.Fatal(got)
	}
	in := map[string]string{"k": "v"}
	if got := stampFamily(ctx, in); got[familyLabel] != "job-7" || got["k"] != "v" || len(in) != 1 {
		t.Fatalf("%v (the caller's map %v)", got, in)
	}
	if got := stampFamily(context.Background(), in); len(got) != 1 {
		t.Fatal(got)
	}
	// A malformed header is refused, not dropped: a job whose containers
	// went unattributed would never be cleaned up.
	s, owner, _, _, _ := delegatedFixture(t)
	req := httptest.NewRequest("GET", "/_ping", nil)
	req.Header.Set(familyHeader, "not a name")
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	if rec.Code != 400 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	// On a delegated socket the header is not read at all.
	req = httptest.NewRequest("GET", "/_ping", nil).WithContext(withViewer(context.Background(), owner.ID))
	req.Header.Set(familyHeader, "not a name")
	rec = httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("delegated: %d %s", rec.Code, rec.Body)
	}
}

// A prune takes exactly the host's containers and networks carrying the
// label: not another family's, not an unlabelled one, and not one made
// through a delegated socket, whatever it labels itself.
func TestPruneFamilySelection(t *testing.T) {
	s, owner, child, other, _ := delegatedFixture(t)
	volumeStoreForTest(t)
	owner.Config.Labels[familyLabel] = "job-1"
	child.Config.Labels[familyLabel] = "job-2" // made on owner's socket: owner's, not job-2's
	other.Config.Labels[familyLabel] = "job-2"
	s.namedNetworks = map[string]*workerNetwork{
		"n1": {ID: "n1", Name: "net-1", Labels: map[string]string{familyLabel: "job-1"}},
		"n2": {ID: "n2", Name: "net-2", Labels: map[string]string{familyLabel: "job-2"}},
		"n3": {ID: "n3", Name: "net-3", Labels: map[string]string{familyLabel: "job-1"}, CreatedBy: other.ID},
		"n4": {ID: "n4", Name: "net-4"},
	}
	report := s.pruneFamily(context.Background(), "job-1", true)
	if !report.DryRun || len(report.Containers) != 1 || report.Containers[0] != owner.ID || len(report.Networks) != 1 || report.Networks[0] != "n1" || len(report.Errors) != 0 || report.Remaining {
		t.Fatalf("%+v", report)
	}
	if report = s.pruneFamily(context.Background(), "job-2", true); len(report.Containers) != 1 || report.Containers[0] != other.ID || len(report.Networks) != 1 || report.Networks[0] != "n2" {
		t.Fatalf("%+v", report)
	}
	if report = s.pruneFamily(context.Background(), "nobody", true); len(report.Containers)+len(report.Networks)+len(report.Volumes) != 0 {
		t.Fatalf("%+v", report)
	}
	if len(s.containers) != 4 || len(s.namedNetworks) != 4 {
		t.Fatal("a dry run removed something")
	}
	for _, target := range []string{"/micropod/families/prune", "/micropod/families/prune?family=", "/micropod/families/prune?family=a%20b"} {
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, httptest.NewRequest("POST", target, nil))
		if rec.Code != 400 {
			t.Errorf("%s: %d %s", target, rec.Code, rec.Body)
		}
	}
}

// volumeStoreForTest points the volume store at an empty directory.
func volumeStoreForTest(t *testing.T) {
	t.Helper()
	old := volumeStore
	volumeStore = t.TempDir()
	t.Cleanup(func() { volumeStore = old })
}

func TestImageEnv(t *testing.T) {
	got := imageEnv(`{"imageSpec":{"config":{"Env":["PATH=/usr/local/bin:/usr/bin","LANG=C.UTF-8"]}}}`)
	if len(got) != 2 || got[0] != "PATH=/usr/local/bin:/usr/bin" {
		t.Fatal(got)
	}
	for _, none := range []string{"", "not json", `{"imageSpec":{"config":{}}}`} {
		if got := imageEnv(none); len(got) != 0 {
			t.Errorf("%q: %v", none, got)
		}
	}
	// inspect shows the image's environment under the container's own.
	c := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("a", 64), Name: "job", Phase: "created",
		ImageEnv: []string{"PATH=/usr/bin", "LANG=C"}, Config: dockerConfig{Env: []string{"LANG=en_AU.UTF-8", "CI=true"}}}}
	config, _ := c.inspect()["Config"].(dockerConfig)
	if strings.Join(config.Env, " ") != "PATH=/usr/bin LANG=en_AU.UTF-8 CI=true" {
		t.Fatalf("%q", config.Env)
	}
}
