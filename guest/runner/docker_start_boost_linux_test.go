package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestStartBoostOnlyForContainersThatNameNoShares(t *testing.T) {
	r := &cri.LinuxContainerResources{}
	if !boostStartShares(r, 4*time.Second) || r.CpuShares != startBoostShares {
		t.Fatalf("a container without shares was not boosted: %v", r)
	}
	asked := &cri.LinuxContainerResources{CpuShares: 512}
	if boostStartShares(asked, 4*time.Second) || asked.CpuShares != 512 {
		t.Fatalf("requested shares were replaced: %v", asked)
	}
	off := &cri.LinuxContainerResources{}
	if boostStartShares(off, 0) || off.CpuShares != 0 {
		t.Fatal("a zero window still boosted")
	}
}

func TestStartBoostWindowSetting(t *testing.T) {
	for raw, want := range map[string]time.Duration{
		"": 4 * time.Second, "0": 0, "1500": 1500 * time.Millisecond,
		"-1": 4 * time.Second, "60001": 4 * time.Second, "soon": 4 * time.Second,
	} {
		if got := startBoostDuration(raw); got != want {
			t.Errorf("MICROPOD_START_BOOST_MS=%q: %v, want %v", raw, got, want)
		}
	}
}

func TestStartBoostEndRestoresOnlyTheBoostedWeight(t *testing.T) {
	root := t.TempDir()
	cgroup := dockerRuntimeCgroup(root, "", "c1")
	if err := os.MkdirAll(cgroup, 0o755); err != nil {
		t.Fatal(err)
	}
	weight := filepath.Join(cgroup, "cpu.weight")
	write := func(v string) {
		if err := os.WriteFile(weight, []byte(v+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	read := func() string {
		b, err := os.ReadFile(weight)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	write(startBoostWeight)
	if done, err := restoreStartWeight(cgroup); !done || err != nil || read() != defaultCPUWeight {
		t.Fatalf("boosted weight not restored: %v %v %q", done, err, read())
	}
	write("39") // someone else set it since
	if done, err := restoreStartWeight(cgroup); done || err != nil || read() != "39\n" {
		t.Fatalf("a weight set by someone else was replaced: %v %v %q", done, err, read())
	}
	if done, err := restoreStartWeight(filepath.Join(root, "gone")); done || err != nil {
		t.Fatalf("an exited container's cgroup: %v %v", done, err)
	}
	if got := dockerRuntimeCgroup(dockerRuntimeCgroupRoot, "job-x", "c2"); got != "/sys/fs/cgroup/k8s.io/job-x/c2" {
		t.Fatalf("job parent cgroup %q", got)
	}

	s := &dockerEngine{}
	write(startBoostWeight)
	timer := s.scheduleStartBoostEnd(cgroup, time.Millisecond)
	deadline := time.Now().Add(5 * time.Second)
	for s.metrics.startBoost.restored.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	timer.Stop()
	if read() != defaultCPUWeight || s.metrics.startBoost.restored.Load() != 1 || s.metrics.startBoost.restoreFailures.Load() != 0 {
		t.Fatalf("scheduled end: weight %q, metrics %v", read(), s.metrics.startBoost.snapshot())
	}
}
