package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type dockerStopRuntime struct {
	cri.RuntimeServiceClient
	stop func(context.Context, *cri.StopContainerRequest) (*cri.StopContainerResponse, error)
}

func (r dockerStopRuntime) StopContainer(ctx context.Context, req *cri.StopContainerRequest, _ ...grpc.CallOption) (*cri.StopContainerResponse, error) {
	return r.stop(ctx, req)
}

type observedStopContext struct {
	context.Context
	waiting chan<- struct{}
}

func (ctx observedStopContext) Done() <-chan struct{} {
	select {
	case ctx.waiting <- struct{}{}:
	default:
	}
	return ctx.Context.Done()
}

func TestDockerStopKeepsOriginalGeneration(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	const timeout = 7
	c := &dockerContainer{dockerRecord: dockerRecord{Phase: "starting"}, changed: make(chan struct{})}
	waiting := make(chan struct{}, 1)
	requestStarted, releaseRequest := make(chan struct{}), make(chan struct{})
	runtime := dockerStopRuntime{stop: func(ctx context.Context, req *cri.StopContainerRequest) (*cri.StopContainerResponse, error) {
		if req.ContainerId != "original" || req.Timeout != timeout {
			return nil, fmt.Errorf("stop targeted runtime %q with timeout %d", req.ContainerId, req.Timeout)
		}
		close(requestStarted)
		select {
		case <-releaseRequest:
			return &cri.StopContainerResponse{}, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}}
	engine := dockerEngine{node: node{runtime: runtime}}
	done := make(chan error, 1)
	go func() { done <- engine.stop(observedStopContext{Context: ctx, waiting: waiting}, c, timeout, "stop") }()
	select {
	case <-waiting:
	case err := <-done:
		t.Fatalf("stop returned before the original runtime was available: %v", err)
	case <-ctx.Done():
		t.Fatal("stop did not wait for the starting runtime")
	}
	engine.mu.Lock()
	c.Phase, c.RuntimeID = "running", "original"
	c.signal()
	engine.mu.Unlock()
	select {
	case <-requestStarted:
	case err := <-done:
		t.Fatalf("stop returned before requesting the original runtime: %v", err)
	case <-ctx.Done():
		t.Fatal("stop did not request the original runtime")
	}

	engine.mu.Lock()
	c.Exits++
	c.Phase, c.RuntimeID = "exited", ""
	c.signal()
	c.Phase = "starting"
	c.signal()
	c.Phase, c.RuntimeID = "running", "replacement"
	c.signal()
	engine.mu.Unlock()
	close(releaseRequest)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("original stop did not return after its runtime exited")
	}
}

func TestDockerCPUSetWithinAllocation(t *testing.T) {
	var allowed unix.CPUSet
	for _, cpu := range []int{0, 2, 3, 5} {
		allowed.Set(cpu)
	}
	for _, value := range []string{"0", "2-3,5", "0,2-3,3"} {
		if err := checkDockerCPUSet(value, &allowed); err != nil {
			t.Errorf("CPU list %q: %v", value, err)
		}
	}
	for _, value := range []string{"-1", "3-2", "0-2", "0,4", "2,", "2-3-5", "0-2147483647"} {
		if err := checkDockerCPUSet(value, &allowed); err == nil {
			t.Errorf("accepted invalid or unavailable CPUs %q", value)
		}
	}
	_, c, err := config("cpuset-test", t.TempDir(), "qa", job{Trust: "trusted", Command: []string{"true"}})
	if err != nil {
		t.Fatal(err)
	}
	s := dockerConfig{HostConfig: dockerHost{CpusetCpus: "2-3,5", NanoCpus: 1000000000}}
	if err := s.configure(c, nil, containerExtras{}); err != nil {
		t.Fatal(err)
	}
	if r := c.Linux.Resources; r.CpusetCpus != "2-3,5" || r.CpuQuota != 100000 || r.CpuPeriod != 100000 {
		t.Fatalf("unexpected CPU list or quota %+v", r)
	}
}

func TestDockerEntrypointOwnsPIDNamespace(t *testing.T) {
	_, c, err := config("docker-pid", t.TempDir(), "qa", job{Trust: "trusted"})
	if err != nil {
		t.Fatal(err)
	}
	if err := (dockerConfig{}).configure(c, nil, containerExtras{}); err != nil {
		t.Fatal(err)
	}
	ns := c.Linux.SecurityContext.GetNamespaceOptions()
	if ns.GetPid() != cri.NamespaceMode_CONTAINER || ns.GetNetwork() != cri.NamespaceMode_POD || ns.GetIpc() != cri.NamespaceMode_POD {
		t.Fatalf("unexpected Docker namespaces: %+v", ns)
	}
}

func TestDockerCPUGroupNetwork(t *testing.T) {
	n := &workerNetwork{Name: "ci-private", ID: strings.Repeat("a", 64), Subnet: netip.MustParsePrefix("10.90.0.0/24")}
	s := &dockerEngine{namedNetworks: map[string]*workerNetwork{n.ID: n}}
	for _, mode := range []string{n.Name, n.ID, "bridge", "none", "default", ""} {
		t.Run(mode, func(t *testing.T) {
			const label = " test / pair @ 1 "
			raw := fmt.Sprintf(`{"Image":"qa","Labels":{%q:%q},"HostConfig":{"NetworkMode":%q}}`, dockerCPUGroupLabel, label, mode)
			cfg, err := parseDockerConfig([]byte(raw))
			if err != nil {
				t.Fatal(err)
			}
			network, address, _, err := s.selectNetwork(&cfg)
			if err != nil {
				t.Fatal(err)
			}
			group, err := cfg.requestedCPUGroup(network)
			wantScope := "bridge"
			switch mode {
			case n.Name, n.ID:
				wantScope = n.ID
			case "none":
				wantScope = "none"
				if network != "" || address != "" || cfg.HostConfig.NetworkMode != "none" {
					t.Fatalf("offline group acquired network identity %q, address %q, or mode %q", network, address, cfg.HostConfig.NetworkMode)
				}
			}
			container := &dockerContainer{dockerRecord: dockerRecord{Config: cfg, NetworkID: network}}
			if err != nil || group != (dockerCPUGroup{network: wantScope, name: label}) || container.cpuGroup() != group {
				t.Fatalf("group %v, stored group %v, want scope %q, error %v", group, container.cpuGroup(), wantScope, err)
			}
		})
	}
}

func TestDockerOfflineCPUGroupsDistributeAndRecover(t *testing.T) {
	cpus := []string{"0", "2", "5", "64"}
	s := &dockerEngine{containers: make(map[string]*dockerContainer)}
	counts := make(map[string]int)
	for i := range 32 {
		name := fmt.Sprintf("job-%02d", i)
		cfg := dockerConfig{Labels: map[string]string{dockerCPUGroupLabel: name}, HostConfig: dockerHost{NetworkMode: "none"}}
		group, err := cfg.requestedCPUGroup("")
		if err != nil || group != (dockerCPUGroup{network: "none", name: name}) {
			t.Fatalf("offline group %q resolved to %v, error %v", name, group, err)
		}
		cpu, err := s.chooseGroupCPULocked(group, cpus)
		if err != nil {
			t.Fatal(err)
		}
		counts[cpu]++
		cfg.HostConfig.CpusetCpus = cpu
		record := dockerRecord{ID: name, Config: cfg, CPUGrouped: true, Phase: "exited"}
		payload, err := json.Marshal(record)
		if err != nil {
			t.Fatal(err)
		}
		var restored dockerContainer
		if err := json.Unmarshal(payload, &restored.dockerRecord); err != nil {
			t.Fatal(err)
		}
		s.containers[name] = &restored
	}
	for _, cpu := range cpus {
		if counts[cpu] != 8 {
			t.Fatalf("offline allocations = %v, want eight per CPU", counts)
		}
	}
	group := s.containers["job-01"].cpuGroup()
	if cpu, err := s.chooseGroupCPULocked(group, cpus); err != nil || cpu != "2" {
		t.Fatalf("offline member did not reuse the stopped group's placement: %q, %v", cpu, err)
	}
	if cpu, err := s.chooseGroupCPULocked(dockerCPUGroup{network: "bridge", name: group.name}, cpus); err != nil || cpu != "0" {
		t.Fatalf("bridge group inherited offline placement: %q, %v", cpu, err)
	}
	remaining := cpus[:3]
	changes := recoverCPUGroupAssignments(s.cpuGroups(), remaining)
	if len(changes) != 8 {
		t.Fatalf("recovery moved %d groups, want eight on the removed CPU", len(changes))
	}
	for c, cpu := range changes {
		if !c.CPUGrouped || c.cpuGroup().network != "none" || c.NetworkID != "" || c.Config.HostConfig.CpusetCpus != "64" || !slices.Contains(remaining, cpu) {
			t.Errorf("unexpected recovery assignment %q -> %q: %+v", c.ID, cpu, c.dockerRecord)
		}
	}
}

func TestDockerCPUGroupEligibilityAndResourcePrecedence(t *testing.T) {
	const groupName = "pair"
	const networkID = "private"
	pids := int64(128)
	for _, tc := range []struct {
		name          string
		labels        map[string]string
		host          dockerHost
		wantGrouped   bool
		wantError     bool
		quota, period int64
	}{
		{name: "compose labels only", labels: map[string]string{"com.docker.compose.project": "a"}, quota: 100000, period: 100000},
		{name: "empty label", labels: map[string]string{dockerCPUGroupLabel: ""}, wantError: true},
		{name: "default", wantGrouped: true, quota: 100000, period: 100000},
		{name: "fractional cpu", host: dockerHost{NanoCpus: 500000000}, wantGrouped: true, quota: 50000, period: 100000},
		{name: "single cpu", host: dockerHost{NanoCpus: 1000000000}, wantGrouped: true, quota: 100000, period: 100000},
		{name: "above one cpu even before rounding", host: dockerHost{NanoCpus: 1000000001}, quota: 100000, period: 100000},
		{name: "two cpus", host: dockerHost{NanoCpus: 2000000000}, quota: 200000, period: 100000},
		{name: "unlimited quota", host: dockerHost{CpuQuota: -1}, quota: -1, period: 100000},
		{name: "wide quota", host: dockerHost{CpuQuota: 200000}, quota: 200000, period: 100000},
		{name: "shorter period", host: dockerHost{CpuPeriod: 50000}, quota: 100000, period: 50000},
		{name: "compatible period and quota", host: dockerHost{CpuPeriod: 50000, CpuQuota: 50000}, wantGrouped: true, quota: 50000, period: 50000},
		{name: "wide period and quota", host: dockerHost{CpuPeriod: 50000, CpuQuota: 75000}, quota: 75000, period: 50000},
		{name: "explicit singleton cpuset", host: dockerHost{CpusetCpus: "5"}, quota: 100000, period: 100000},
		{name: "explicit multi-CPU cpuset", host: dockerHost{CpusetCpus: "2-3,5", NanoCpus: 1000000000}, quota: 100000, period: 100000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			labels := tc.labels
			if labels == nil {
				labels = map[string]string{dockerCPUGroupLabel: groupName}
			}
			cfg := dockerConfig{Labels: labels, HostConfig: tc.host}
			cfg.HostConfig.Memory, cfg.HostConfig.PidsLimit, cfg.HostConfig.CpuShares = 32<<20, &pids, 512
			group, err := cfg.requestedCPUGroup(networkID)
			if tc.wantError {
				if problem, ok := err.(apiError); !ok || problem.code != 400 {
					t.Fatalf("expected label validation failure, got group %v, error %v", group, err)
				}
				return
			}
			wantGroup := dockerCPUGroup{}
			if tc.wantGrouped {
				wantGroup = dockerCPUGroup{network: networkID, name: groupName}
			}
			if err != nil || group != wantGroup {
				t.Fatalf("group %v, want %v, error %v", group, wantGroup, err)
			}
			wantCPUSet := tc.host.CpusetCpus
			if tc.wantGrouped {
				wantCPUSet = "8"
				cfg.HostConfig.CpusetCpus = wantCPUSet
			}
			_, c, err := config("cpu-group", t.TempDir(), "qa", job{Trust: "trusted"})
			if err != nil {
				t.Fatal(err)
			}
			if err := cfg.configure(c, nil, containerExtras{}); err != nil {
				t.Fatal(err)
			}
			r := c.Linux.Resources
			if r.CpusetCpus != wantCPUSet || r.CpuQuota != tc.quota || r.CpuPeriod != tc.period || r.MemoryLimitInBytes != 32<<20 || r.Unified["pids.max"] != "128" || r.CpuShares != 512 {
				t.Fatalf("unexpected resources %+v", r)
			}
		})
	}
}

func cpuGroupTestContainer(id string, group dockerCPUGroup, cpu string, grouped bool) *dockerContainer {
	return &dockerContainer{dockerRecord: dockerRecord{
		ID: id, NetworkID: group.network, CPUGrouped: grouped, Phase: "created",
		Config: dockerConfig{Labels: map[string]string{dockerCPUGroupLabel: group.name}, HostConfig: dockerHost{CpusetCpus: cpu}},
	}}
}

func TestDockerCPUGroupDistributionAndReuse(t *testing.T) {
	var allowed unix.CPUSet
	for _, cpu := range []int{64, 2, 5, 0} {
		allowed.Set(cpu)
	}
	cpus := dockerPlacementCPUs(&allowed)
	if !slices.Equal(cpus, []string{"0", "2", "5", "64"}) {
		t.Fatalf("unexpected sparse CPU list %v", cpus)
	}
	s := &dockerEngine{containers: make(map[string]*dockerContainer)}
	choose := func(group dockerCPUGroup, want string) {
		t.Helper()
		if got, err := s.chooseGroupCPULocked(group, cpus); err != nil || got != want {
			t.Fatalf("group %v placed on %q, want %q, error %v", group, got, want, err)
		}
	}
	// The label on an explicitly pinned container predates or bypasses automatic placement.
	s.containers["manual"] = cpuGroupTestContainer("manual", dockerCPUGroup{"isolated-0", "pair-0"}, "5", false)
	for i := range 32 {
		// Reusing every label across both networks still produces 32 allocations.
		group := dockerCPUGroup{network: fmt.Sprintf("isolated-%d", i%2), name: fmt.Sprintf("pair-%d", i/2)}
		cpu := cpus[i%len(cpus)]
		for j := range 2 {
			choose(group, cpu)
			id := fmt.Sprintf("%d-%d", i, j)
			s.containers[id] = cpuGroupTestContainer(id, group, cpu, true)
		}
	}
	for i := range 16 {
		id := fmt.Sprintf("extra-%d", i)
		s.containers[id] = cpuGroupTestContainer(id, dockerCPUGroup{"isolated-0", "pair-0"}, "0", true)
	}
	next := dockerCPUGroup{"isolated-0", "next"}
	choose(next, "0") // Count groups, regardless of how many containers each owns.
	delete(s.containers, "31-0")
	s.containers["31-1"].Phase = "exited"
	choose(next, "0") // The stopped member can still restart on its original CPU.
	choose(dockerCPUGroup{"isolated-1", "pair-15"}, "64")
	delete(s.containers, "31-1")
	choose(next, "64") // The last removal releases its allocation.
	if _, err := s.chooseGroupCPULocked(dockerCPUGroup{"isolated-0", "pair-0"}, []string{"2", "5"}); err == nil {
		t.Fatal("accepted placement for a live group whose CPU became unavailable")
	}
}

func TestDockerCPUGroupRecovery(t *testing.T) {
	s := &dockerEngine{containers: make(map[string]*dockerContainer)}
	for _, tc := range []struct {
		id, group, cpu string
		grouped        bool
	}{
		{"stable", "a", "2", true},
		{"partially persisted", "b", "5", true},
		{"old placement", "b", "64", true},
		{"displaced 1", "c", "64", true},
		{"displaced 2", "c", "64", true},
		{"displaced later", "d", "64", true},
		{"explicit", "c", "64", false},
	} {
		original := cpuGroupTestContainer(tc.id, dockerCPUGroup{"private", tc.group}, tc.cpu, tc.grouped)
		payload, err := json.Marshal(original.dockerRecord)
		if err != nil {
			t.Fatal(err)
		}
		c := new(dockerContainer)
		if err := json.Unmarshal(payload, &c.dockerRecord); err != nil {
			t.Fatal(err)
		}
		if c.CPUGrouped != tc.grouped || c.cpuGroup() != original.cpuGroup() || c.inspect()["HostConfig"].(dockerHost).CpusetCpus != tc.cpu {
			t.Fatalf("recovered record differs from original %+v", c.dockerRecord)
		}
		s.containers[c.ID] = c
	}
	for _, cpus := range [][]string{{"2", "5", "64"}, {"2", "5"}} {
		if _, err := s.chooseGroupCPULocked(dockerCPUGroup{"private", "b"}, cpus); err == nil {
			t.Fatal("admitted a group with inconsistent placements before reconciliation")
		}
	}
	cpus := []string{"2", "5"}
	groups := s.cpuGroups()
	changes := recoverCPUGroupAssignments(groups, cpus)
	want := map[string]string{"old placement": "5", "displaced 1": "2", "displaced 2": "2", "displaced later": "5"}
	if len(changes) != len(want) {
		t.Fatalf("got %d assignments, want %d", len(changes), len(want))
	}
	for c, cpu := range changes {
		if cpu != want[c.ID] {
			t.Errorf("container %q recovered on API CPU %q, want %q", c.ID, cpu, want[c.ID])
		}
	}
	persisted := s.containers["displaced 1"]
	persisted.Config.HostConfig.CpusetCpus = changes[persisted] // Interrupt recovery between writes.
	changes = recoverCPUGroupAssignments(groups, cpus)
	if len(changes) != len(want)-1 {
		t.Fatalf("replayed %d assignments, want %d", len(changes), len(want)-1)
	}
	for c, cpu := range changes {
		if cpu != want[c.ID] {
			t.Errorf("replayed container %q on CPU %q, want %q", c.ID, cpu, want[c.ID])
		}
		c.Config.HostConfig.CpusetCpus = cpu
	}
	if changes := recoverCPUGroupAssignments(groups, cpus); len(changes) != 0 {
		t.Fatalf("stable worker had %d unexpected placement changes", len(changes))
	}
	for key, members := range groups {
		cpu, err := s.chooseGroupCPULocked(key, cpus)
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range members {
			if c.Config.HostConfig.CpusetCpus != cpu {
				t.Fatalf("group %v readback %q differs from admitting new member to CPU %q", key, c.Config.HostConfig.CpusetCpus, cpu)
			}
		}
	}
}

func TestDockerCPUShares(t *testing.T) {
	for _, tc := range []struct{ requested, effective int64 }{
		{0, 0}, {1, 2}, {512, 512}, {1024, 1024}, {262144, 262144}, {262145, 262144},
	} {
		t.Run(fmt.Sprint(tc.requested), func(t *testing.T) {
			raw := fmt.Sprintf(`{"Image":"qa","HostConfig":{"CpuShares":%d,"NanoCpus":500000000}}`, tc.requested)
			spec, err := parseDockerConfig([]byte(raw))
			if err != nil || spec.HostConfig.CpuShares != tc.requested {
				t.Fatalf("requested shares %d, config %+v, error %v", tc.requested, spec.HostConfig, err)
			}
			_, c, err := config("weight-test", t.TempDir(), "qa", job{Trust: "trusted"})
			if err != nil {
				t.Fatal(err)
			}
			if err := spec.configure(c, nil, containerExtras{}); err != nil {
				t.Fatal(err)
			}
			if r := c.Linux.Resources; r.CpuShares != tc.effective || r.CpuQuota != 50000 || r.CpuPeriod != 100000 {
				t.Fatalf("unexpected weighted CPU resources %+v", r)
			}
		})
	}
	if _, err := parseDockerConfig([]byte(`{"Image":"qa","HostConfig":{"CpuShares":-1}}`)); err == nil {
		t.Fatal("accepted negative CPU shares")
	}
}

func TestDockerCPUQuotaPreservesDefaultsAndExplicitLimits(t *testing.T) {
	for _, tc := range []struct {
		host    string
		want    int64
		invalid bool
	}{
		{`{}`, 100000, false},
		{`{"CpuQuota":-1}`, -1, false},
		{`{"CpuQuota":50000}`, 50000, false},
		{`{"NanoCpus":4000000000}`, 400000, false},
		{`{"CpuQuota":-2}`, 0, true},
		{`{"NanoCpus":4000000000,"CpuQuota":-1}`, 0, true},
	} {
		t.Run(tc.host, func(t *testing.T) {
			spec, err := parseDockerConfig([]byte(fmt.Sprintf(`{"Image":"qa","HostConfig":%s}`, tc.host)))
			if tc.invalid {
				if err == nil {
					t.Fatal("accepted invalid resources")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			_, c, err := config("cpu-test", t.TempDir(), "qa", job{Trust: "trusted", Command: []string{"true"}})
			if err != nil {
				t.Fatal(err)
			}
			if err := spec.configure(c, nil, containerExtras{}); err != nil {
				t.Fatal(err)
			}
			if got := c.Linux.Resources; got.CpuQuota != tc.want || got.CpuPeriod != 100000 || got.MemoryLimitInBytes != 1<<30 || got.Unified["pids.max"] != "512" {
				t.Fatalf("unexpected resources %+v", got)
			}
		})
	}
}

func TestDockerTCPQueueSysctl(t *testing.T) {
	raw := []byte(`{"Image":"qa","HostConfig":{"Sysctls":{"net.ipv4.tcp_limit_output_bytes":"0163840"}}}`)
	cfg, err := parseDockerConfig(raw)
	if err != nil || cfg.HostConfig.Sysctls[tcpQueueSysctl] != "163840" {
		t.Fatalf("parsed sysctls %v, error %v", cfg.HostConfig.Sysctls, err)
	}
	for _, input := range []string{
		`{"kernel.hostname":"ci"}`,
		`{"net.ipv4.tcp_limit_output_bytes":"-1"}`,
		`{"net.ipv4.tcp_limit_output_bytes":"2147483648"}`,
		`{"net.ipv4.tcp_limit_output_bytes":""}`,
	} {
		if _, err := parseDockerConfig([]byte(`{"Image":"qa","HostConfig":{"Sysctls":` + input + `}}`)); err == nil {
			t.Fatalf("accepted unsupported sysctls %s", input)
		}
	}
}

func TestDockerOptionsAndMounts(t *testing.T) {
	for _, raw := range []string{`{"label":{"cuttle.test=x":true}}`, `{"label":["cuttle.test=x"]}`} {
		filters, err := dockerFilters(raw, "label")
		if err != nil || len(filters["label"]) != 1 || filters["label"][0] != "cuttle.test=x" {
			t.Fatalf("failed to decode %s: %v %v", raw, filters, err)
		}
	}
	const ordinary = `{"Image":"alpine","HostConfig":{"RestartPolicy":{"Name":"no","MaximumRetryCount":0},"ConsoleSize":[0,0],"PidsLimit":0,"MemorySwappiness":-1,"Mounts":[{"Type":"volume","Source":"cache","Target":"/cache","VolumeOptions":{"NoCopy":true}}]},"NetworkingConfig":{"EndpointsConfig":{"default":{"Aliases":null}}}}`
	spec, err := parseDockerConfig([]byte(ordinary))
	if err != nil {
		t.Fatal(err)
	}
	mounts, err := spec.mounts()
	if err != nil || len(mounts) != 1 || mounts[0].Source != "cache" {
		t.Fatalf("mounts %v %v", mounts, err)
	}
	for _, v := range []string{`{"Image":"a","HostConfig":{"Privileged":true}}`, `{"Image":"a","HostConfig":{"RestartPolicy":{"Name":"always"}}}`, `{"Image":"a","HostConfig":{"NetworkMode":"bridge"},"NetworkingConfig":{"EndpointsConfig":{"other":{}}}}`, `{"Image":"a","HostConfig":{"NetworkMode":"none","PortBindings":{"80/tcp":[{}]}}}`} {
		if _, err := parseDockerConfig([]byte(v)); err == nil {
			t.Fatalf("accepted unsupported configuration %s", v)
		}
	}
	// Every table kind keeps its legacy alias, now resolving to the ACL store.
	for _, kind := range allCacheKinds() {
		p, ok := sharedCachePath("micropod-ci-scoped-go-1-26-" + kind)
		if !ok || p != filepath.Join(cacheRoot, "scopes", "go-1-26", kind) {
			t.Fatal(kind, p, ok)
		}
	}
	// The longest kind suffix wins: "-yarnberry" is not scope "x-yarn" + "berry".
	if scope, kind, ok := legacyCacheVolume("micropod-ci-scoped-x-yarnberry"); !ok || scope != "x" || kind != "yarnberry" {
		t.Fatal(scope, kind, ok)
	}
	if _, ok := sharedCachePath("ordinary-gobuild"); ok {
		t.Fatal("adopted a non-scoped volume")
	}
	if _, ok := sharedCachePath("micropod-ci-scoped-Bad-gomod"); ok {
		t.Fatal("adopted an invalid scope")
	}
}

func TestDockerCreateConflictIdentifiesCurrentNameOwner(t *testing.T) {
	const name = "reaper_test-session"
	const ownerID = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	const message = `Conflict. The container name "/reaper_test-session" is already in use by container "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef". You have to remove (or rename) that container to be able to reuse that name.`
	for _, phase := range []string{"created", "running", "exited"} {
		t.Run(phase, func(t *testing.T) {
			imageID := healthConfigDigest([]byte("{}"))
			owner := &dockerContainer{dockerRecord: dockerRecord{ID: ownerID, Name: name, Phase: phase}}
			engine := &dockerEngine{
				node:         node{images: dockerHealthTestImages{id: imageID}, imageStore: dockerHealthTestImageStore{}},
				containers:   map[string]*dockerContainer{owner.ID: owner},
				healthImages: dockerImageHealthCache{byID: map[string]dockerImageHealth{imageID: {}}},
			}
			spec := dockerConfig{Image: "alpine:3.23"}
			const clients = 8
			start := make(chan struct{})
			results := make(chan error, clients)
			for range clients {
				go func() {
					<-start
					_, err := engine.create(context.Background(), spec, name)
					results <- err
				}()
			}
			close(start)
			for range clients {
				err := <-results
				if err != (apiError{code: http.StatusConflict, message: message}) {
					t.Errorf("duplicate create returned %v, want 409 naming original container", err)
				}
			}
			if len(engine.containers) != 1 || engine.containers[ownerID] != owner || owner.Phase != phase {
				t.Fatal("duplicate creates changed the original name owner")
			}
		})
	}
}

func TestDockerCreateAcceptsSingleSDKNamedEndpoint(t *testing.T) {
	network := &workerNetwork{Name: "ci-net", ID: strings.Repeat("a", 64), Subnet: netip.MustParsePrefix("10.90.1.0/24")}
	engine := &dockerEngine{namedNetworks: map[string]*workerNetwork{network.ID: network}}
	for _, tc := range []struct {
		name, mode, endpoint, endpointID string
		wantParse, wantResolve           bool
	}{
		{name: "omitted mode", endpoint: network.Name, endpointID: network.ID, wantParse: true, wantResolve: true},
		{name: "default mode", mode: "default", endpoint: network.Name, endpointID: network.ID, wantParse: true, wantResolve: true},
		{name: "resolve by ID", endpoint: network.ID, endpointID: network.ID, wantParse: true, wantResolve: true},
		{name: "explicit matching mode", mode: network.Name, endpoint: network.Name, endpointID: network.ID, wantParse: true, wantResolve: true},
		{name: "conflicting explicit mode", mode: "bridge", endpoint: network.Name, endpointID: network.ID},
		{name: "unknown named endpoint", endpoint: "ci-missing", wantParse: true},
		{name: "wrong endpoint ID", endpoint: network.Name, endpointID: strings.Repeat("b", 64), wantParse: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := fmt.Appendf(nil, `{"Image":"alpine","HostConfig":{"NetworkMode":%q},
				"NetworkingConfig":{"EndpointsConfig":{%q:{"NetworkID":%q,"Aliases":["postgres"]}}}}`,
				tc.mode, tc.endpoint, tc.endpointID)
			spec, err := parseDockerConfig(body)
			if (err == nil) != tc.wantParse {
				t.Fatalf("parse named endpoint: %v", err)
			}
			if err != nil {
				return
			}
			id, ip, _, err := engine.selectNetwork(&spec)
			if (err == nil) != tc.wantResolve {
				t.Fatalf("resolve named endpoint: %v", err)
			}
			if err == nil && (id != network.ID || ip != "10.90.1.2" || spec.HostConfig.NetworkMode != network.Name ||
				!slices.Equal(spec.Aliases, []string{"postgres"})) {
				t.Fatalf("selected id %s, ip %s, network %s, aliases %v", id, ip, spec.HostConfig.NetworkMode, spec.Aliases)
			}
		})
	}
}

func TestDockerTmpfsConfig(t *testing.T) {
	const options = "rw,exec,nosuid,nodev,size=128m,mode=1777"
	spec, err := parseDockerConfig([]byte(`{"Image":"alpine","HostConfig":{"Tmpfs":{"/tmp":"` + options + `"}}}`))
	if err != nil {
		t.Fatal(err)
	}
	mounts, err := spec.mounts()
	if err != nil || len(mounts) != 1 || mounts[0].Type != "tmpfs" || mounts[0].Target != "/tmp" || mounts[0].ReadOnly {
		t.Fatalf("mounts %v, error %v", mounts, err)
	}
	if *mounts[0].tmpfs != (dockerTmpfsOptions{flags: unix.MS_NOSUID | unix.MS_NODEV, size: 128 << 20, mode: 01777}) {
		t.Fatalf("wrong CLI options: %+v", *mounts[0].tmpfs)
	}
	files, criMounts, pins, err := (&dockerEngine{}).openMounts(spec, true, "")
	if err != nil || len(criMounts) != 0 || len(files) != 0 || len(pins) != 0 {
		t.Fatalf("Docker create materialized scratch: %+v, %v, %v", files, criMounts, err)
	}
	encoded, err := json.Marshal(dockerRecord{Config: spec})
	if err != nil {
		t.Fatal(err)
	}
	var recovered dockerContainer
	if err := json.Unmarshal(encoded, &recovered.dockerRecord); err != nil {
		t.Fatal(err)
	}
	if got := recovered.inspect()["HostConfig"].(dockerHost).Tmpfs["/tmp"]; got != options {
		t.Fatalf("inspect contains tmpfs options %q, want %q", got, options)
	}
}

func TestDockerTmpfsValidation(t *testing.T) {
	defaults, err := parseDockerTmpfs("")
	if err != nil || defaults != (dockerTmpfsOptions{flags: unix.MS_NOSUID | unix.MS_NODEV | unix.MS_NOEXEC,
		mode: 01777}) {
		t.Fatalf("default tmpfs options: %+v, %v", defaults, err)
	}
	if got := defaults.ociOptions(); !slices.Equal(got, []string{"nosuid", "nodev", "noexec", "rw", "mode=1777", "uid=0", "gid=0"}) {
		t.Fatalf("default tmpfs mount opts: %v", got)
	}

	ro, err := parseDockerTmpfs("ro,exec,noexec,size=16K,mode=700,uid=1001,gid=1002")
	if err != nil || ro != (dockerTmpfsOptions{flags: unix.MS_NOSUID | unix.MS_NODEV | unix.MS_NOEXEC | unix.MS_RDONLY,
		size: 16 << 10, mode: 0700, uid: 1001, gid: 1002}) {
		t.Fatalf("read-only tmpfs options: %+v, %v", ro, err)
	}
	for _, raw := range []string{"size=0", "size=-1", "size=12%", "size=257g", "size=18446744073709551616m", "mode=0788",
		"uid=4294967296", "gid=-1", "rw,", "dev", "suid", "nr_blocks=0", "shared"} {
		if _, err := parseDockerTmpfs(raw); err == nil {
			t.Errorf("accepted unsupported tmpfs options %q", raw)
		}
	}
	for _, body := range []string{
		`{"Tmpfs":{"/":""}}`,
		`{"Tmpfs":{"relative":""}}`,
		`{"Tmpfs":{"/tmp/../run":""}}`,
		`{"Tmpfs":{"/tmp\u0000":""}}`,
		`{"Tmpfs":{"/tmp":""},"Binds":["cache:/tmp"]}`,
		`{"Tmpfs":{"/tmp":""},"Mounts":[{"Type":"volume","Source":"cache","Target":"/tmp"}]}`,
	} {
		if _, err := parseDockerConfig([]byte(`{"Image":"alpine","HostConfig":` + body + `}`)); err == nil {
			t.Errorf("accepted unsupported scratch destination %s", body)
		}
	}
}

func TestDockerTmpfsOCISpec(t *testing.T) {
	const base = `{"ociVersion":"1.2.1","process":{"user":{"uid":99},"unrecognizedSetting":123},"linux":{"cgroupsPath":"/bench"},"unknown":["preserve me"],"mounts":[{"destination":"/proc","type":"proc","source":"proc"},{"destination":"/tmp/cache","type":"bind","source":"/owned-cache","options":["rbind","readonly"],"extension":1},{"destination":"/dev/shm","type":"tmpfs","source":"shm","options":["size=65536k"]}]}`
	cfg, err := parseDockerConfig([]byte(`{"Image":"alpine","HostConfig":{"Tmpfs":{"/tmp":"rw,exec,nosuid,nodev,size=128m,mode=1777","/dev/shm":"ro,mode=700,uid=1001,gid=1002"}}}`))
	if err != nil {
		t.Fatal(err)
	}
	edited, err := cfg.specWithTmpfs([]byte(base))
	if err != nil {
		t.Fatal(err)
	}

	var before, after map[string]json.RawMessage
	if err := json.Unmarshal([]byte(base), &before); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(edited, &after); err != nil {
		t.Fatal(err)
	}
	if len(before) != len(after) {
		t.Fatalf("OCI fields changed: %s", edited)
	}
	for key, original := range before {
		if key != "mounts" && !bytes.Equal(original, after[key]) {
			t.Fatalf("unrelated OCI field %s changed: %s", key, edited)
		}
	}
	var mounts []json.RawMessage
	if err := json.Unmarshal(after["mounts"], &mounts); err != nil {
		t.Fatal(err)
	}
	if len(mounts) != 4 || string(mounts[0]) != `{"destination":"/proc","type":"proc","source":"proc"}` ||
		string(mounts[2]) != `{"destination":"/tmp/cache","type":"bind","source":"/owned-cache","options":["rbind","readonly"],"extension":1}` {
		t.Fatalf("OCI mounts lost settings or ordering: %s", after["mounts"])
	}
	for _, testcase := range []struct {
		index       int
		destination string
		options     []string
	}{
		{1, "/tmp", []string{"nosuid", "nodev", "exec", "rw", "size=134217728", "mode=1777", "uid=0", "gid=0"}},
		{3, "/dev/shm", []string{"nosuid", "nodev", "noexec", "ro", "mode=700", "uid=1001", "gid=1002"}},
	} {
		var mount dockerOCITmpfsMount
		if err := json.Unmarshal(mounts[testcase.index], &mount); err != nil {
			t.Fatal(err)
		}
		if mount.Destination != testcase.destination || mount.Type != "tmpfs" || mount.Source != "tmpfs" ||
			!slices.Equal(mount.Options, testcase.options) {
			t.Fatalf("unexpected OCI scratch mount: %+v", mount)
		}
	}
}

func TestDockerJobParentSelection(t *testing.T) {
	t.Setenv("MICROPOD_ENGINE_ROOTLESS", "")
	const owner = "mp-t-as1234d_"
	network := strings.Repeat("b", 64)
	other := strings.Repeat("c", 64)
	s := &dockerEngine{workspace: "/private/tmp/" + owner + "/workspace", namedNetworks: map[string]*workerNetwork{
		network: {Internal: true, Labels: map[string]string{dockerBenchmarkOwnerLabel: owner}},
		other:   {Internal: true, Labels: map[string]string{dockerBenchmarkOwnerLabel: owner}},
	}}
	spec := dockerConfig{Labels: map[string]string{
		dockerBenchmarkOwnerLabel: owner, dockerCPUGroupLabel: "../opaque", dockerJobParentLabel: "1",
	}, HostConfig: dockerHost{CpusetCpus: "0-3", CpuQuota: 100000, CpuPeriod: 100000}}
	parent, err := s.requestedJobParent(spec, network)
	if err != nil || !validDockerJobParent(parent) {
		t.Fatalf("expected safe fixture parent, got %q, %v", parent, err)
	}
	if again, err := s.requestedJobParent(spec, network); err != nil || again != parent {
		t.Fatalf("fixture group has an unstable parent: %q, %v", again, err)
	}
	if separate, err := s.requestedJobParent(spec, other); err != nil || separate == parent {
		t.Fatalf("different network shares the same parent: %q, %v", separate, err)
	}
	if c := spec.HostConfig; c.CpusetCpus != "0-3" || c.CpuQuota != 100000 || c.CpuPeriod != 100000 {
		t.Fatalf("explicit leaf controls changed: %+v", c)
	}
	if _, err := s.requestedJobParent(spec, ""); err == nil {
		t.Fatal("built-in network passed the fixture gate")
	}
	s.namedNetworks[network].Labels[dockerBenchmarkOwnerLabel] = "different-owner"
	if _, err := s.requestedJobParent(spec, network); err == nil {
		t.Fatal("different network owner passed the fixture gate")
	}
	delete(spec.Labels, dockerJobParentLabel)
	if defaultParent, err := s.requestedJobParent(spec, network); defaultParent != "" || err != nil {
		t.Fatalf("standard CPU group unexpectedly changed hierarchy: %q, %v", defaultParent, err)
	}
}

func TestDockerJobParentOCISpec(t *testing.T) {
	id := strings.Repeat("a", 64)
	parent := dockerJobParentPrefix + strings.Repeat("b", 64)
	const linuxFields = `"resources":{"cpu":{"cpus":"0","quota":100000,"period":100000},"memory":{"limit":536870912}},"vendorKey":[1,true]`
	base := []byte(`{"ociVersion":"1.2.1","linux":{"cgroupsPath":"/k8s.io/` + id + `",` + linuxFields + `},"mounts":[]}`)
	cfg := dockerConfig{HostConfig: dockerHost{Tmpfs: map[string]string{"/tmp": "rw,exec,nosuid,nodev,size=128m,mode=1777"}}}
	withScratch, err := cfg.specWithTmpfs(base)
	if err != nil {
		t.Fatal(err)
	}
	edited, err := specWithJobParent(withScratch, parent, id)
	if err != nil {
		t.Fatal(err)
	}
	expected := bytes.Replace(withScratch, []byte(`"/k8s.io/`+id+`"`), []byte(`"/k8s.io/`+parent+`/`+id+`"`), 1)
	if !bytes.Equal(edited, expected) {
		t.Fatalf("expected only cgroupsPath to change:\n%s\n%s", expected, edited)
	}
	if _, err := specWithJobParent(edited, parent, id); err == nil {
		t.Fatal("unexpected existing cgroup path was accepted")
	}
	if _, err := specWithJobParent(withScratch, "../"+parent, id); err == nil {
		t.Fatal("non-generated parent path was accepted")
	}
}

func TestDockerJobParentRetiresAfterLastLease(t *testing.T) {
	root := t.TempDir()
	parent := dockerJobParentPrefix + strings.Repeat("b", 64)
	dir := filepath.Join(root, parent)
	child := filepath.Join(dir, strings.Repeat("a", 64))
	if err := os.MkdirAll(child, 0755); err != nil {
		t.Fatal(err)
	}
	owned := &dockerJobParents{refs: map[string]int{parent: 1}}
	if err := owned.retain(parent); err != nil {
		t.Fatal(err)
	}
	if err := owned.release(root, parent); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(child); err != nil {
		t.Fatalf("live sibling leaf was touched: %v", err)
	}
	if err := owned.release(root, parent); err == nil {
		t.Fatal("parent retirement accepted an existing leaf")
	}
	if err := os.Remove(child); err != nil {
		t.Fatal(err)
	}
	if err := removeDockerJobParent(root, parent); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("empty parent remains: %v", err)
	}
}

func TestBoundWorkspaceUsesOpenedInode(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "marker")
	os.WriteFile(p, []byte("first"), 0600)
	f, err := openMount(dir, p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	before, err := f.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(p, p+"-old"); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(p, []byte("second"), 0600)
	now, err := os.Stat(p)
	if err != nil || os.SameFile(before, now) {
		t.Fatal("fixture did not replace inode")
	}
	st, err := f.Stat()
	if err != nil || !os.SameFile(before, st) {
		t.Fatal("opened mount changed")
	}
	if _, err := openMount(dir, filepath.Dir(dir)); err == nil {
		t.Fatal("accepted parent directory")
	}
}
func TestCRILogSplitAcrossReads(t *testing.T) {
	var source bytes.Buffer
	s := criOutput{reader: bufio.NewReader(&source)}
	var out, stderr bytes.Buffer
	write := func(stream string, b []byte) error {
		if stream == "stdout" {
			_, _ = out.Write(b)
		} else {
			_, _ = stderr.Write(b)
		}
		return nil
	}
	source.WriteString("time stdout P ab")
	if err := s.drain(write); err != nil || out.Len() != 0 {
		t.Fatal(err, out.String())
	}
	source.WriteString("c\ntime stderr F complete\ntime stdout P z\n")
	if err := s.drain(write); err != nil {
		t.Fatal(err)
	}
	if out.String() != "abcz" || stderr.String() != "complete\n" {
		t.Fatal(out.String(), stderr.String())
	}
}
func TestFramesAndMetrics(t *testing.T) {
	frame := []byte{1, 0, 0, 0, 0, 0, 0, 2, 'o', 'k', 2, 0, 0, 0, 0, 0, 0, 1, 'e'}
	var b bytes.Buffer
	if err := copyFrames(bufio.NewReader(bytes.NewReader(frame)), &b, false, true); err != nil || !bytes.Equal(b.Bytes(), frame[10:]) {
		t.Fatal(err, b.Bytes())
	}
	if err := copyFrames(bufio.NewReader(strings.NewReader("")), io.Discard, true, true); err != nil {
		t.Fatal(err)
	}
	m := dockerMetrics{}
	m.record(result{Prepared: true, Hit: true, StartMS: 7}, nil)
	got, _ := json.Marshal(m.snapshot())
	if !strings.Contains(string(got), `"start_ms_total":7`) {
		t.Fatal(string(got))
	}
}

func TestSessionCleanupOwnership(t *testing.T) {
	const session = "qualification-session-001"
	self := strings.Repeat("1", 64)
	other := strings.Repeat("2", 64)
	own := strings.Repeat("3", 64)
	makeContainer := func(id, scope string) *dockerContainer {
		return &dockerContainer{dockerRecord: dockerRecord{ID: id, Name: "job-" + id[:4], Phase: "running", Config: dockerConfig{Labels: map[string]string{tcSession: scope, tcReap: "true"}}}}
	}
	s := &dockerEngine{containers: map[string]*dockerContainer{other: makeContainer(other, "another-session"), own: makeContainer(own, session)}}
	api := cleanupAPI{s, session, self}
	for _, tc := range []struct {
		method, path string
		code         int
	}{
		{"GET", "/v1.47/containers/json", 200}, {"DELETE", "/containers/" + other, 404}, {"POST", "/containers/create", 403}, {"GET", "/v1.47/containers/" + other + "/json", 403},
	} {
		w := httptest.NewRecorder()
		api.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, nil))
		if w.Code != tc.code || strings.Contains(w.Body.String(), other) {
			t.Fatalf("unexpected %s %s status %d: %s", tc.method, tc.path, w.Code, w.Body.String())
		}
		if tc.code == 200 && !strings.Contains(w.Body.String(), own) {
			t.Fatal("missing owned container")
		}
	}
}
