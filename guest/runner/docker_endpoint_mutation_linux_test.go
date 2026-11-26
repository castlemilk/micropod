package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type dockerEndpointFixture struct {
	*dockerEngine
	container              *dockerContainer
	primary, second, third *workerNetwork
	stateDir               string
}

func newDockerEndpointFixture(t *testing.T) dockerEndpointFixture {
	t.Helper()
	primary := &workerNetwork{ID: strings.Repeat("a", 64), Name: "primary", Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.1.0/29")}
	second := &workerNetwork{ID: strings.Repeat("b", 64), Name: "secondary", Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.2.0/29")}
	third := &workerNetwork{ID: strings.Repeat("c", 64), Name: "third", Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.3.0/29")}
	c := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("d", 64), Name: "service", Phase: "created", NetworkID: primary.ID,
		NetworkIP: "10.90.1.2", Config: dockerConfig{HostConfig: dockerHost{NetworkMode: primary.Name}, Labels: map[string]string{"owned": "yes"}}}}
	e := &dockerEngine{namedNetworks: map[string]*workerNetwork{primary.ID: primary, second.ID: second, third.ID: third}, containers: map[string]*dockerContainer{c.ID: c}}
	return dockerEndpointFixture{dockerEngine: e, container: c, primary: primary, second: second, third: third, stateDir: t.TempDir()}
}

func (f dockerEndpointFixture) connect(ctx context.Context, key string, aliases ...string) error {
	return f.changeDockerNetwork(ctx, f.container, f.stateDir, key, dockerEndpointOptions{Aliases: aliases}, true)
}

func (f dockerEndpointFixture) disconnect(ctx context.Context, key string) error {
	return f.changeDockerNetwork(ctx, f.container, f.stateDir, key, dockerEndpointOptions{}, false)
}

func (f dockerEndpointFixture) readState(t *testing.T) dockerRecord {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(f.stateDir, "state"))
	if err != nil {
		t.Fatal(err)
	}
	var state dockerRecord
	if err := json.Unmarshal(b, &state); err != nil {
		t.Fatal(err)
	}
	return state
}

func dockerEndpointTestStatus(err error) int {
	if err == nil {
		return http.StatusOK
	}
	var problem apiError
	if errors.As(err, &problem) {
		return problem.code
	}
	return http.StatusInternalServerError
}

func TestDockerBridgeCreateSelectsExplicitPrimaryAndDistinctEndpoints(t *testing.T) {
	f := newDockerEndpointFixture(t)
	body := fmt.Sprintf(`{"Image":"alpine","HostConfig":{"NetworkMode":%q},"NetworkingConfig":{"EndpointsConfig":{
		"secondary":{"NetworkID":%q,"Aliases":["two"]},%q:{"Aliases":["one"]},"third":{"IPAMConfig":null,"Aliases":["three"]}}}}`,
		f.primary.ID[:12], f.second.ID, f.primary.ID)
	spec, err := parseDockerConfig([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	id, ip, secondary, err := f.selectNetwork(&spec)
	if err != nil || id != f.primary.ID || ip != "10.90.1.3" || spec.HostConfig.NetworkMode != "primary" || !slices.Equal(spec.Aliases, []string{"one"}) {
		t.Fatalf("primary id=%s ip=%s config=%+v err=%v", id, ip, spec, err)
	}
	if len(secondary) != 2 || secondary[0].NetworkID != f.second.ID || secondary[0].IP != "10.90.2.2" ||
		!slices.Equal(secondary[0].Aliases, []string{"two"}) || secondary[1].NetworkID != f.third.ID || secondary[1].IP != "10.90.3.2" {
		t.Fatalf("secondary endpoints %+v", secondary)
	}
	t.Run("same network under two identities", func(t *testing.T) {
		spec.Endpoints = map[string]dockerEndpointOptions{f.second.Name: {}, f.second.ID[:10]: {}}
		if _, _, _, err := f.selectNetwork(&spec); dockerEndpointTestStatus(err) != http.StatusBadRequest {
			t.Fatalf("duplicate primary/secondary identity returned %v", err)
		}
	})
	t.Run("static IP and malformed fields are rejected", func(t *testing.T) {
		for _, endpoint := range []string{`{"IPAMConfig":{"IPv4Address":"10.90.2.6"}}`, `{"Aliases":"invalid"}`, `{"NetworkID":7}`, `[]`} {
			body := fmt.Sprintf(`{"Image":"alpine","HostConfig":{"NetworkMode":"primary"},"NetworkingConfig":{"EndpointsConfig":{"secondary":%s}}}`, endpoint)
			if _, err := parseDockerConfig([]byte(body)); err == nil {
				t.Fatalf("accepted endpoint %s", endpoint)
			}
		}
	})
}

func TestDockerBridgeOfflineEndpointsPersistAndFilter(t *testing.T) {
	f := newDockerEndpointFixture(t)
	ctx := context.Background()
	if err := f.connect(ctx, f.second.ID[:12], "service-two"); err != nil {
		t.Fatal(err)
	}
	if err := f.connect(ctx, f.third.Name, "service-three"); err != nil {
		t.Fatal(err)
	}
	state := f.readState(t)
	if len(state.SecondaryNetworks) != 2 || state.BridgeGeneration != nil {
		t.Fatalf("invalid offline state %+v", state)
	}
	want := state.SecondaryNetworks[0]
	if want.NetworkID != f.second.ID || want.IP != "10.90.2.2" || !fullContainerID.MatchString(want.ID) {
		t.Fatalf("invalid persisted endpoint %+v", want)
	}
	if err := f.connect(ctx, f.second.Name, "replacement"); err != nil {
		t.Fatal(err)
	}
	view := f.dockerContainerNetworks(f.container)
	if second := view[f.second.Name]; second.NetworkID != want.NetworkID || second.IPAddress != "" || second.EndpointID != "" || !slices.Equal(second.Aliases, []string{"replacement"}) {
		t.Fatalf("offline alias view %+v", second)
	}
	if updated := f.readState(t).SecondaryNetworks[0]; updated.ID != want.ID || updated.IP != want.IP {
		t.Fatalf("offline update replaced endpoint %+v", updated)
	}
	if ip, err := f.reserveDockerAddress(f.second); ip != "10.90.2.3" || err != nil {
		t.Fatalf("allocate during retained reservation ip=%s err=%v", ip, err)
	}
	remove := httptest.NewRecorder()
	if err := f.deleteNetwork(remove, f.second.ID, nil); dockerEndpointTestStatus(err) != http.StatusConflict {
		t.Fatalf("deletion with retained endpoint returned %v", err)
	}
	for _, filter := range []string{f.second.Name, f.second.ID[:12]} {
		query := url.Values{"all": {"1"}, "filters": {fmt.Sprintf(`{"network":{%q:true},"label":{"owned=yes":true}}`, filter)}}.Encode()
		w := httptest.NewRecorder()
		if err := f.list(w, httptest.NewRequest(http.MethodGet, "/v1.47/containers/json?"+query, nil)); err != nil {
			t.Fatal(err)
		}
		var rows []dockerContainerListRow
		if err := json.Unmarshal(w.Body.Bytes(), &rows); err != nil || len(rows) != 1 || rows[0].ID != f.container.ID || len(rows[0].NetworkSettings.Networks) != 3 {
			t.Fatalf("filtered list %s returned %s (%v)", filter, w.Body.String(), err)
		}
	}
	if err := f.disconnect(ctx, f.second.Name); err != nil {
		t.Fatal(err)
	}
	if f.matchesDockerNetwork(f.container, []string{f.second.Name}) || len(f.readState(t).SecondaryNetworks) != 1 {
		t.Fatal("detached endpoint remains visible")
	}
	if ip, err := f.reserveDockerAddress(f.second); ip != want.IP || err != nil {
		t.Fatalf("detached reservation still occupied: %s %v", ip, err)
	}
}

type testDockerBridgeOperations struct {
	onAttach func(context.Context, *workerNetwork, string) (string, error)
	onDetach func(*workerNetwork) error
	onClose  func() error
	dns      []*workerNetwork
}

func (f *testDockerBridgeOperations) attach(ctx context.Context, n *workerNetwork, ip string) (string, error) {
	return f.onAttach(ctx, n, ip)
}
func (f *testDockerBridgeOperations) detach(n *workerNetwork) error { return f.onDetach(n) }
func (f *testDockerBridgeOperations) close() error                  { return f.onClose() }
func (f *testDockerBridgeOperations) setDNSNetworks(n []*workerNetwork) {
	f.dns = slices.Clone(n)
}

func (f dockerEndpointFixture) simulateRunning(t *testing.T, ops *testDockerBridgeOperations) *dockerRunningBridge {
	t.Helper()
	pod := ownedPod{id: strings.Repeat("1", 32), pod: strings.Repeat("2", 64)}
	if err := f.container.claimDockerNetworkPod(f.stateDir, pod); err != nil {
		t.Fatal(err)
	}
	b := &dockerRunningBridge{sandbox: ops, generation: *f.container.BridgeGeneration, active: make(map[string]string)}
	f.container.bridge, f.container.Phase, f.container.IP = b, "running", f.container.NetworkIP
	return b
}

func TestDockerBridgeLiveReservationFencesNaturalExit(t *testing.T) {
	f := newDockerEndpointFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	attached, unblock, retired := make(chan string, 1), make(chan struct{}), make(chan struct{})
	ops := &testDockerBridgeOperations{
		onAttach: func(ctx context.Context, _ *workerNetwork, ip string) (string, error) {
			attached <- ip
			select {
			case <-unblock:
				return "02:11:22:33:44:55", nil
			case <-ctx.Done():
				return "", ctx.Err()
			}
		},
		onClose: func() error { close(retired); return nil },
	}
	f.simulateRunning(t, ops)
	connected := make(chan error, 1)
	go func() { connected <- f.connect(ctx, f.second.Name, "peer") }()
	select {
	case ip := <-attached:
		if ip != "10.90.2.2" {
			t.Fatalf("unexpected in-flight address %s", ip)
		}
	case <-ctx.Done():
		t.Fatal("attach never reached the data plane")
	}
	if state := f.readState(t); state.BridgeGeneration == nil || len(state.SecondaryNetworks) != 0 {
		t.Fatalf("kernel attach did not follow durable owned generation: %+v", state)
	}
	f.mu.Lock()
	ip, err := f.reserveDockerAddress(f.second)
	members := f.dockerNetworkMembers(f.second)
	f.mu.Unlock()
	if err != nil || ip != "10.90.2.3" || len(members) != 0 {
		t.Fatalf("pending endpoint published or allocated twice, members=%v ip=%s err=%v", members, ip, err)
	}
	if err := f.deleteNetwork(httptest.NewRecorder(), f.second.ID, nil); dockerEndpointTestStatus(err) != http.StatusConflict {
		t.Fatalf("deletion raced pending attach: %v", err)
	}
	closed := make(chan error, 1)
	go func() { closed <- f.retireDockerBridge(f.container) }()
	select {
	case <-retired:
		t.Fatal("retire closed the selected namespace during an attachment mutation")
	default:
	}
	close(unblock)
	if err := <-connected; err != nil {
		t.Fatal(err)
	}
	if err := <-closed; err != nil {
		t.Fatal(err)
	}
	if f.container.bridge != nil || f.container.BridgeGeneration == nil || len(f.dockerNetworkMembers(f.second)) != 0 {
		t.Fatal("retired generation still reports operational state")
	}
	if len(f.container.SecondaryNetworks) != 1 || f.container.SecondaryNetworks[0].IP != "10.90.2.2" {
		t.Fatal("natural exit discarded persisted endpoint allocation")
	}
	if err := f.connect(ctx, f.third.Name); dockerEndpointTestStatus(err) != http.StatusConflict {
		t.Fatalf("late join targeted a retired running generation: %v", err)
	}
	f.acknowledgeDockerPodRetirement(f.container)
	if f.container.BridgeGeneration != nil {
		t.Fatal("CRI cleanup did not acknowledge the original primary")
	}
}

func TestDockerBridgeLiveRollbackPreservesOrQuarantinesReservations(t *testing.T) {
	ctx := context.Background()
	for _, restore := range []bool{true, false} {
		t.Run(fmt.Sprintf("rollback-proven-%t", restore), func(t *testing.T) {
			f := newDockerEndpointFixture(t)
			var attached, detached int
			ops := &testDockerBridgeOperations{
				onAttach: func(context.Context, *workerNetwork, string) (string, error) {
					attached++
					return "02:11:22:33:44:55", nil
				},
				onDetach: func(*workerNetwork) error {
					detached++
					if !restore {
						return errDockerBridgeCleanup
					}
					return nil
				},
			}
			b := f.simulateRunning(t, ops)
			if err := os.Mkdir(filepath.Join(f.stateDir, "state.tmp"), 0700); err != nil {
				t.Fatal(err)
			}
			err := f.connect(ctx, f.second.Name, "new-alias")
			if err == nil || attached != 1 || detached != 1 || len(f.readState(t).SecondaryNetworks) != 0 || len(f.container.SecondaryNetworks) != 0 || len(f.dockerNetworkMembers(f.second)) != 0 {
				t.Fatalf("attach with failed commit escaped rollback: attach=%d detach=%d err=%v", attached, detached, err)
			}
			want := "10.90.2.2"
			if !restore {
				want = "10.90.2.3"
			}
			if ip, err := f.reserveDockerAddress(f.second); ip != want || err != nil || b.uncertain == restore {
				t.Fatalf("wrong rollback quarantine: ip=%s err=%v uncertain=%t", ip, err, b.uncertain)
			}
		})
	}
}

func TestDockerBridgeLiveDetachRollbackAndInspect(t *testing.T) {
	f := newDockerEndpointFixture(t)
	ctx := context.Background()
	var attaches []string
	ops := &testDockerBridgeOperations{
		onAttach: func(_ context.Context, n *workerNetwork, ip string) (string, error) {
			attaches = append(attaches, ip)
			return fmt.Sprintf("02:11:22:33:44:%02d", len(attaches)), nil
		},
		onDetach: func(*workerNetwork) error { return nil },
	}
	f.simulateRunning(t, ops)
	if err := f.connect(ctx, f.second.Name, "live-alias"); err != nil {
		t.Fatal(err)
	}
	if err := f.connect(ctx, f.second.ID); dockerEndpointTestStatus(err) != 403 || err.Error() != "endpoint with name service already exists in network secondary" {
		t.Fatalf("live duplicate did not match Docker conflict: %v", err)
	}
	settings := f.inspectDockerContainer(f.container)["NetworkSettings"].(map[string]any)["Networks"].(map[string]dockerEndpointView)
	member := f.dockerNetworkMembers(f.second)[f.container.ID]
	if second := settings[f.second.Name]; second.IPAddress != "10.90.2.2" || second.IPPrefixLen != 29 ||
		member["IPv4Address"] != "10.90.2.2/29" || member["EndpointID"] != second.EndpointID || member["MacAddress"] != second.MacAddress || len(ops.dns) != 2 {
		t.Fatalf("live inspect mismatch: %v %v", settings, member)
	}
	block := filepath.Join(f.stateDir, "state.tmp")
	if err := os.Mkdir(block, 0700); err != nil {
		t.Fatal(err)
	}
	if err := f.disconnect(ctx, f.second.ID); err == nil || !slices.Equal(attaches, []string{"10.90.2.2", "10.90.2.2"}) || len(f.readState(t).SecondaryNetworks) != 1 {
		t.Fatalf("detach rollback did not restore original address: %v attaches=%v", err, attaches)
	}
	if got := f.dockerNetworkMembers(f.second)[f.container.ID]["MacAddress"]; got != "02:11:22:33:44:02" {
		t.Fatalf("restored peer MAC not visible: %q", got)
	}
	if err := os.Remove(block); err != nil {
		t.Fatal(err)
	}
	if err := f.disconnect(ctx, f.second.ID); err != nil || len(f.readState(t).SecondaryNetworks) != 0 || len(ops.dns) != 1 || len(f.dockerNetworkMembers(f.second)) != 0 {
		t.Fatalf("detach did not remove only the secondary: %v", err)
	}
}

func TestDockerBridgePrimaryMACVisibleOnlyForRunningLink(t *testing.T) {
	f := newDockerEndpointFixture(t)
	c := f.container
	c.Phase, c.IP, c.primaryMAC = "running", c.NetworkIP, "02:42:0a:5a:01:02"
	view := f.dockerContainerNetworks(c)[f.primary.Name]
	member := f.dockerNetworkMembers(f.primary)[c.ID]
	if view.IPAddress != c.IP || member["IPv4Address"] != "10.90.1.2/29" || view.MacAddress != c.primaryMAC || member["MacAddress"] != c.primaryMAC {
		t.Fatalf("running primary endpoint view differs from configured link: %+v %+v", view, member)
	}
	c.Phase = "exited"
	view = f.dockerContainerNetworks(c)[f.primary.Name]
	if view.NetworkID != f.primary.ID || view.IPAddress != "" || view.MacAddress != "" || view.IPPrefixLen != 0 || len(f.dockerNetworkMembers(f.primary)) != 0 {
		t.Fatalf("offline primary reservation still exposes operational settings: %+v", view)
	}
}

func TestDockerBridgeUnverifiedCloseWaitsForPodCleanup(t *testing.T) {
	f := newDockerEndpointFixture(t)
	ctx := context.Background()
	ops := &testDockerBridgeOperations{
		onAttach: func(context.Context, *workerNetwork, string) (string, error) { return "", errDockerBridgeCleanup },
		onDetach: func(*workerNetwork) error { return errDockerBridgeCleanup },
		onClose:  func() error { return errDockerBridgeCleanup },
	}
	f.simulateRunning(t, ops)
	if err := f.connect(ctx, f.second.Name); !errors.Is(err, errDockerBridgeCleanup) {
		t.Fatalf("unexpected uncertain attach: %v", err)
	}
	if err := f.retireDockerBridge(f.container); !errors.Is(err, errDockerBridgeCleanup) {
		t.Fatalf("unexpected unverified close: %v", err)
	}
	if f.container.BridgeGeneration == nil || f.container.bridge == nil || !f.container.bridge.retiring || f.container.bridge.pending == nil {
		t.Fatal("unverified close discarded its generation or pending lease")
	}
	if ip, err := f.reserveDockerAddress(f.second); ip != "10.90.2.3" || err != nil {
		t.Fatalf("unverified close released the address: %s %v", ip, err)
	}
	if err := f.removeLocked(f.container); dockerEndpointTestStatus(err) != http.StatusConflict {
		t.Fatalf("uncertain generation was removable: %v", err)
	}
	f.acknowledgeDockerPodRetirement(f.container)
	if f.container.BridgeGeneration != nil || f.container.bridge != nil {
		t.Fatal("retired pod left an outstanding generation")
	}
	if ip, err := f.reserveDockerAddress(f.second); ip != "10.90.2.2" || err != nil {
		t.Fatalf("confirmed pod removal did not release address: %s %v", ip, err)
	}
}

func TestDockerNamedPrimaryFailedPublishRetirementRetainsPod(t *testing.T) {
	ctx := context.Background()
	revokeFailure := errors.New("published route revocation failed")
	for _, name := range []string{"read-only", "auto-remove"} {
		t.Run(name, func(t *testing.T) {
			f := newDockerEndpointFixture(t)
			c := f.container
			c.Config.HostConfig.ReadonlyRootfs = name == "read-only"
			c.Config.HostConfig.AutoRemove = name == "auto-remove"
			if c.retainsRootFS() || c.RootFSBinding != nil {
				t.Fatal("unexpected writable-rootfs retention guard")
			}
			parent := f.stateDir
			f.stateDir = filepath.Join(parent, c.ID)
			if err := os.Mkdir(f.stateDir, 0700); err != nil {
				t.Fatal(err)
			}
			bridge := f.simulateRunning(t, &testDockerBridgeOperations{onClose: func() error { return nil }})
			if name == "read-only" {
				c.bridge = nil // A failure in initial publication can precede DNS or secondary setup.
			}
			job := ownedPod{id: bridge.generation.JobID, pod: bridge.generation.PodID}
			hooks := processHooks{
				retire: func() error { return errors.Join(f.retireDockerBridge(c), revokeFailure) },
				podRetired: func() {
					t.Fatal("unconfirmed published route retirement acknowledged pod cleanup")
				},
			}
			if err := f.node.retireProcess(ctx, job, hooks, nil, false); !errors.Is(err, revokeFailure) {
				t.Fatalf("retirement failure was discarded: %v", err)
			}
			c.Phase = "dead"
			if c.bridge != nil || c.BridgeGeneration == nil || *c.BridgeGeneration != bridge.generation {
				t.Fatal("closing auxiliary links forgot the live primary generation")
			}
			var err error
			if c.Config.HostConfig.AutoRemove {
				err = f.removeLocked(c) // The process-exit removal path.
			} else {
				err = f.remove(ctx, c, true)
			}
			if dockerEndpointTestStatus(err) != http.StatusConflict || f.containers[c.ID] != c {
				t.Fatalf("removal lost an unconfirmed primary address: %v", err)
			}
			if ip, err := f.reserveDockerAddress(f.primary); ip != "10.90.1.3" || err != nil {
				t.Fatalf("primary address became reusable before cleanup: %s %v", ip, err)
			}
			recovered, err := loadDockerRecord(parent, c.ID)
			if err != nil || recovered.BridgeGeneration == nil || *recovered.BridgeGeneration != bridge.generation {
				t.Fatalf("restart lost the exact named pod generation: %+v %v", recovered, err)
			}
			attempt := 0
			remove := func(_ context.Context, jobID, podID string) error {
				if jobID != job.id || podID != job.pod {
					t.Fatalf("recovery targeted another pod %s/%s", jobID, podID)
				}
				attempt++
				if attempt == 1 {
					return revokeFailure
				}
				return nil
			}
			if err := recovered.recoverDockerNetworkPod(ctx, f.stateDir, remove); !errors.Is(err, revokeFailure) || f.readState(t).BridgeGeneration == nil {
				t.Fatalf("failed recovery lost the durable marker: %v", err)
			}
			if err := recovered.recoverDockerNetworkPod(ctx, f.stateDir, remove); err != nil || recovered.BridgeGeneration != nil ||
				f.readState(t).BridgeGeneration != nil || recovered.NetworkIP != c.NetworkIP || attempt != 2 {
				t.Fatalf("confirmed recovery did not clear just the pod marker: %+v %v", recovered.dockerRecord, err)
			}
		})
	}
}

type testBridgeRecoveryRuntime struct {
	cri.RuntimeServiceClient
	byID, byOwner []*cri.PodSandbox
}

func (f testBridgeRecoveryRuntime) ListPodSandbox(_ context.Context, req *cri.ListPodSandboxRequest, _ ...grpc.CallOption) (*cri.ListPodSandboxResponse, error) {
	if req.GetFilter().GetId() != "" {
		return &cri.ListPodSandboxResponse{Items: f.byID}, nil
	}
	return &cri.ListPodSandboxResponse{Items: f.byOwner}, nil
}

func TestDockerBridgeRecoveryRejectsMismatchedOwnershipAndAllocations(t *testing.T) {
	f := newDockerEndpointFixture(t)
	ctx := context.Background()
	if err := f.connect(ctx, f.second.Name); err != nil {
		t.Fatal(err)
	}
	if err := f.verifyDockerNetworkReservations(); err != nil {
		t.Fatal(err)
	}
	other := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("e", 64), NetworkID: f.second.ID,
		NetworkIP: f.container.SecondaryNetworks[0].IP, Config: dockerConfig{HostConfig: dockerHost{NetworkMode: f.second.Name}}}}
	f.containers[other.ID] = other
	if err := f.verifyDockerNetworkReservations(); err == nil {
		t.Fatal("recovery accepted a conflicting primary/veth address")
	}
	ownedJob, ownedPod := strings.Repeat("1", 32), strings.Repeat("2", 64)
	foreign := &cri.PodSandbox{Id: ownedPod, Metadata: &cri.PodSandboxMetadata{Namespace: "different", Uid: ownedJob}}
	n := node{runtime: testBridgeRecoveryRuntime{byID: []*cri.PodSandbox{foreign}}}
	if err := n.removeOwnedPod(ctx, ownedJob, ownedPod); err == nil || !strings.Contains(err.Error(), "ownership changed") {
		t.Fatalf("unowned namespace reached recovery: %v", err)
	}
	owned := &cri.PodSandbox{Id: ownedPod, Metadata: &cri.PodSandboxMetadata{Namespace: "micropod-ci", Uid: ownedJob}, Labels: map[string]string{owner: ownedJob}}
	n = node{runtime: testBridgeRecoveryRuntime{byID: []*cri.PodSandbox{owned}}}
	if err := n.removeOwnedPod(ctx, ownedJob, ownedPod); err == nil || !strings.Contains(err.Error(), "missing from its ownership scope") {
		t.Fatalf("inconsistent sandbox inventory was considered retired: %v", err)
	}
}

// A gateway relay connection admitted because its peer shared a network with
// the published container ends when the peer is disconnected from that
// network, as a direct connection over the removed interface would; a new
// one is refused.
func TestDockerDisconnectEndsTheRelayItAdmitted(t *testing.T) {
	f := newDockerEndpointFixture(t)
	ctx := context.Background()
	f.simulateRunning(t, &testDockerBridgeOperations{
		onAttach: func(context.Context, *workerNetwork, string) (string, error) { return "02:11:22:33:44:55", nil },
		onDetach: func(*workerNetwork) error { return nil },
	})
	if err := f.connect(ctx, f.second.Name); err != nil {
		t.Fatal(err)
	}
	// The peer dials from loopback in this test; the published container,
	// another job's, is on the network the peer just joined.
	f.mu.Lock()
	f.container.IP = "127.0.0.1"
	target := &dockerContainer{IP: "10.90.2.5", dockerRecord: dockerRecord{ID: strings.Repeat("e", 64), Phase: "running", NetworkID: f.second.ID}}
	f.containers[target.ID] = target
	f.mu.Unlock()
	port := freePort(t)
	p, err := openGatewayRelay(ctx, "127.0.0.1", port, holdTarget(t), f.relayAdmits(target), f.trackRelay(target))
	if err != nil {
		t.Fatal(err)
	}
	defer p.close()
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(int(port)))
	held := dialHeld(t, addr)
	if closedSoon(held) {
		t.Fatal("a peer on the published container's network was refused")
	}
	eventually(t, "the relayed connection was not tracked", func() bool {
		f.relayed.mu.Lock()
		defer f.relayed.mu.Unlock()
		return len(f.relayed.conns) == 1
	})
	if err := f.disconnect(ctx, f.second.Name); err != nil {
		t.Fatal(err)
	}
	if !closedSoon(held) {
		t.Fatal("the relayed connection outlived the network it was admitted for")
	}
	if !closedSoon(dialHeld(t, addr)) {
		t.Fatal("a disconnected peer was relayed again")
	}
}

// A docker network connect is decided where it commits, on the network its
// key names then: a delegated owner that checked its own network, held the
// request on its child's lifecycle lock and removed the network meanwhile
// finds another job's network under that name not there (404), and the
// host's socket does not join a delegated family's network that took a free
// name meanwhile (409).
func TestDockerNetworkConnectDecidesWhereItCommits(t *testing.T) {
	f := newDockerEndpointFixture(t)
	owner := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("e", 64), Name: "job", Phase: "running"}}
	f.containers[owner.ID] = owner
	// The name the owner's own network had is the victim's network's now.
	f.second.Name = "repo_default"
	f.container.CreatedBy = owner.ID
	viewer := withViewer(context.Background(), owner.ID)
	for _, key := range []string{"repo_default", f.second.ID, f.second.ID[:12]} {
		err := f.connect(viewer, key)
		if dockerEndpointTestStatus(err) != http.StatusNotFound || err.Error() != "no such network: "+key {
			t.Errorf("a delegated connect by %q joined another job's network: %v", key, err)
		}
	}
	if len(f.container.SecondaryNetworks) != 0 {
		t.Fatalf("endpoint recorded on another job's network: %+v", f.container.SecondaryNetworks)
	}
	f.second.CreatedBy = owner.ID
	if err := f.connect(viewer, "repo_default"); err != nil {
		t.Fatalf("the owner's own network: %v", err)
	}
	if err := f.disconnect(viewer, "repo_default"); err != nil {
		t.Fatal(err)
	}

	// The host's socket: a host-created container and a name a delegated
	// family's network took.
	f.container.CreatedBy = ""
	if err := f.connect(context.Background(), "repo_default"); dockerEndpointTestStatus(err) != http.StatusConflict {
		t.Fatalf("the host's connect joined a delegated family's network: %v", err)
	}
	if len(f.container.SecondaryNetworks) != 0 {
		t.Fatalf("endpoint recorded on a delegated family's network: %+v", f.container.SecondaryNetworks)
	}
	f.second.CreatedBy = ""
	if err := f.connect(context.Background(), "repo_default"); err != nil {
		t.Fatalf("the host's own network: %v", err)
	}
}
