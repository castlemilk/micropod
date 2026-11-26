package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

const siblingTCPOption = "com.micropod.network.tcp-congestion"

type workerNetwork struct {
	Name, ID, Driver     string
	Subnet               netip.Prefix
	MTU                  int
	TCPCongestion        string `json:",omitempty"`
	Internal, Attachable bool
	Labels               map[string]string
	Created              time.Time
	// CreatedBy is the container whose delegated socket created the network
	// ("" for the host's): only that container may remove it there.
	CreatedBy string `json:",omitempty"`
	dns       *networkDNS
	services  serviceDirectory
	deleting  bool
}

func networkID(name string) string {
	hash := sha256.Sum256([]byte(os.Getenv("MICROPOD_CI_WORKER_ID") + "/" + name))
	return hex.EncodeToString(hash[:])
}
func networkName(name string) string {
	if name == "" || name == "default" {
		return "bridge"
	}
	return name
}
func builtinNetwork(name string) bool { return name == "bridge" || name == "none" }
func (n *workerNetwork) dir() string  { return filepath.Join(engineRoot, "networks", n.ID) }

// Resolve exact IDs and names before trying a unique ID prefix. Caller holds s.mu.
func (s *dockerEngine) findNetwork(key string, includeDeleting bool) (*workerNetwork, error) {
	if n := s.namedNetworks[key]; n != nil && (includeDeleting || !n.deleting) {
		return n, nil
	}
	var match *workerNetwork
	ambiguous := false
	for _, n := range s.namedNetworks {
		if n.deleting && !includeDeleting {
			continue
		}
		if n.Name == key {
			return n, nil
		}
		if key != "" && strings.HasPrefix(n.ID, key) {
			ambiguous = match != nil
			match = n
		}
	}
	if ambiguous {
		return nil, fail(http.StatusBadRequest, "ambiguous network ID: "+key)
	}
	return match, nil
}

func automaticSubnet(index int) netip.Prefix {
	return netip.PrefixFrom(netip.AddrFrom4([4]byte{10, 90, byte(index), 0}), 24)
}

func firstAutomaticSubnet(readRoutes workerRouteReader) netip.Prefix {
	routes, err := readRoutes()
	if err != nil {
		// A changing route table can interrupt a dump. Retry once and discard
		// incomplete results before choosing an address.
		routes, err = readRoutes()
		if err != nil {
			return netip.Prefix{}
		}
	}
	occupied := make([]netip.Prefix, 0, len(routes))
	for _, route := range routes {
		if subnet := routeSubnet(route); subnet.IsValid() {
			occupied = append(occupied, subnet)
		}
	}
	for index := range 256 {
		subnet := automaticSubnet(index)
		if !slices.ContainsFunc(occupied, subnet.Overlaps) {
			return subnet
		}
	}
	return netip.Prefix{}
}

func (s *dockerEngine) startNetwork(ctx context.Context, n *workerNetwork) error {
	if err := n.setup(ctx); err != nil {
		return err
	}
	dns, err := s.listenDNS(n)
	if err != nil {
		return errors.Join(err, n.teardown())
	}
	n.dns = dns
	return nil
}
func (s *dockerEngine) recoverNetworks(ctx context.Context) error {
	dir := filepath.Join(engineRoot, "networks")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		p := filepath.Join(dir, e.Name())
		b, err := os.ReadFile(filepath.Join(p, "network.json"))
		if errors.Is(err, os.ErrNotExist) {
			if err = os.RemoveAll(p); err != nil {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		n := new(workerNetwork)
		if json.Unmarshal(b, n) != nil || n.ID != e.Name() || !fullContainerID.MatchString(n.ID) || !dockerName.MatchString(n.Name) || !n.Subnet.IsValid() || !n.Subnet.Addr().Is4() || (n.Driver != "bridge" && n.Driver != "ipvlan" && n.Driver != "macvlan") {
			return errors.New("invalid saved network")
		}
		if _, e := os.Stat(filepath.Join(p, "removing")); e == nil {
			if err := n.teardown(); err != nil {
				return err
			}
			if err := os.RemoveAll(p); err != nil {
				return err
			}
			continue
		} else if !errors.Is(e, os.ErrNotExist) {
			return e
		}
		if err := os.Chmod(filepath.Join(p, "resolv.conf"), 0644); err != nil {
			return err
		}
		if err := s.startNetwork(ctx, n); err != nil {
			return err
		}
		s.namedNetworks[n.ID] = n
	}
	return nil
}
func (s *dockerEngine) createNetwork(w http.ResponseWriter, r *http.Request) error {
	b, err := readBody(w, r)
	if err != nil {
		return err
	}
	var raw map[string]any
	var req struct {
		Name, Driver, Scope  string
		Internal, Attachable bool
		Labels, Options      map[string]string
		IPAM                 struct {
			Driver  string
			Options map[string]string
			Config  []struct {
				Subnet, Gateway, IPRange string
				AuxAddress               map[string]string
			}
		}
	}
	if json.Unmarshal(b, &req) != nil || json.Unmarshal(b, &raw) != nil || !dockerName.MatchString(req.Name) || builtinNetwork(req.Name) || req.Name == "default" || req.Name == "host" {
		return fail(400, "invalid network name or configuration")
	}
	if err = supportedOptions(raw, "Name Driver Scope Internal Labels Options IPAM CheckDuplicate Attachable EnableIPv4"); err != nil {
		return fail(400, err.Error())
	}
	if req.Scope != "" && req.Scope != "local" || raw["EnableIPv4"] == false {
		return fail(400, "network needs local IPv4 scope")
	}
	if req.Driver == "" {
		req.Driver = "bridge"
	}
	if req.Driver != "bridge" && req.Driver != "ipvlan" && req.Driver != "macvlan" {
		return fail(400, "supported network drivers are bridge, macvlan and ipvlan")
	}
	mtu := 1500
	var congestion string
	for k, v := range req.Options {
		switch k {
		case "com.docker.network.driver.mtu":
			mtu, err = strconv.Atoi(v)
			if err != nil || mtu < 576 || mtu > 9000 {
				return fail(400, "invalid MTU")
			}
		case siblingTCPOption:
			if !req.Internal || req.Driver == "macvlan" || privateRootless() {
				return fail(400, "TCP congestion control requires an internal bridge or ipvlan network on a native worker")
			}
			available, err := os.ReadFile("/proc/sys/net/ipv4/tcp_available_congestion_control")
			if err != nil {
				return fmt.Errorf("read guest TCP congestion controls: %w", err)
			}
			if !slices.Contains(strings.Fields(string(available)), v) {
				return fail(400, "TCP congestion control unavailable in the guest kernel: "+v)
			}
			congestion = v
		default:
			return fail(400, "unsupported network option "+k)
		}
	}
	if req.IPAM.Driver != "" && req.IPAM.Driver != "default" || len(req.IPAM.Options) != 0 || len(req.IPAM.Config) > 1 {
		return fail(400, "unsupported IPAM configuration")
	}
	n := &workerNetwork{Name: req.Name, ID: engineID(), Driver: req.Driver, Internal: req.Internal, Attachable: req.Attachable, Labels: req.Labels, Created: time.Now().UTC(), MTU: mtu, TCPCongestion: congestion, CreatedBy: viewerOf(r.Context())}
	s.networkMu.Lock()
	defer s.networkMu.Unlock()
	s.mu.Lock()
	exists := false
	for _, other := range s.namedNetworks {
		if other.Name == n.Name {
			exists = true
			break
		}
	}
	s.mu.Unlock()
	if exists {
		return fail(409, "network name in use")
	}
	if len(req.IPAM.Config) > 0 {
		cfg := req.IPAM.Config[0]
		n.Subnet, err = netip.ParsePrefix(cfg.Subnet)
		if err != nil || !n.Subnet.Addr().Is4() || !n.Subnet.Addr().IsPrivate() || n.Subnet != n.Subnet.Masked() || n.Subnet.Bits() < 16 || n.Subnet.Bits() > 29 || (cfg.Gateway != "" && cfg.Gateway != n.gateway().String()) || cfg.IPRange != "" || len(cfg.AuxAddress) > 0 {
			return fail(400, "expected a private IPv4 subnet with the first usable address as gateway")
		}
		if !routeAvailable(n.Subnet) {
			return fail(409, "subnet overlaps a worker route")
		}
	} else {
		// networkMu serializes network creation and deletion until the chosen
		// subnet's route is installed. Use a fresh snapshot for this allocation.
		n.Subnet = firstAutomaticSubnet(workerIPv4Routes)
		if !n.Subnet.IsValid() {
			return fail(409, "no free network subnet")
		}
	}
	if err = os.Mkdir(n.dir(), 0700); err != nil {
		return err
	}
	resolver := filepath.Join(n.dir(), "resolv.conf")
	if err = os.WriteFile(resolver, []byte("nameserver "+n.gateway().String()+"\noptions ndots:1\n"), 0644); err == nil {
		err = os.Chmod(resolver, 0644)
	}
	if err != nil {
		return errors.Join(err, os.RemoveAll(n.dir()))
	}
	// Commit ownership before creating links. Startup can finish an interrupted
	// operation using the same ID; incomplete catalog writes own no interfaces.
	payload, _ := json.Marshal(n)
	f, err := os.OpenFile(filepath.Join(n.dir(), "network.tmp"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err == nil {
		_, err = f.Write(payload)
		if err == nil {
			err = f.Sync()
		}
		err = errors.Join(err, f.Close())
	}
	if err == nil {
		err = os.Rename(filepath.Join(n.dir(), "network.tmp"), filepath.Join(n.dir(), "network.json"))
	}
	if err == nil {
		err = errors.Join(syncDir(n.dir()), syncDir(filepath.Dir(n.dir())))
	}
	if err != nil {
		return errors.Join(err, os.RemoveAll(n.dir()))
	}
	if err = s.startNetwork(r.Context(), n); err != nil {
		// Any partial start has its own rollback. Keep a removal intent until
		// a subsequent boot can finish cleanup if a firewall or unlink failed.
		if mark := os.WriteFile(filepath.Join(n.dir(), "removing"), nil, 0600); mark != nil {
			return errors.Join(err, mark)
		}
		if clean := n.teardown(); clean != nil {
			return errors.Join(err, clean)
		}
		return errors.Join(err, os.RemoveAll(n.dir()), syncDir(filepath.Dir(n.dir())))
	}
	s.mu.Lock()
	s.namedNetworks[n.ID] = n
	s.mu.Unlock()
	writeJSON(w, 201, map[string]string{"Id": n.ID, "Warning": ""})
	return nil
}
func (s *dockerEngine) deleteNetwork(w http.ResponseWriter, key string, canRemove func(*workerNetwork) bool) error {
	s.networkMu.Lock()
	defer s.networkMu.Unlock()
	s.mu.Lock()
	n, err := s.findNetwork(key, true)
	if err != nil {
		s.mu.Unlock()
		return err
	}
	// Check the current network under the same locks that protect deletion.
	// A new network can otherwise acquire the same deterministic ID.
	if n == nil || canRemove != nil && !canRemove(n) {
		s.mu.Unlock()
		return fail(404, "no such network")
	}
	for _, c := range s.containers {
		if c.NetworkID == n.ID || c.secondaryEndpoint(n.ID) >= 0 || (c.bridge != nil && c.bridge.pending != nil && c.bridge.pending.NetworkID == n.ID) {
			s.mu.Unlock()
			return fail(409, "network has container endpoints")
		}
	}
	n.deleting = true
	s.mu.Unlock()
	if err := os.WriteFile(filepath.Join(n.dir(), "removing"), nil, 0600); err != nil {
		return err
	}
	if err := syncDir(n.dir()); err != nil {
		return err
	}
	if n.dns != nil {
		n.dns.close()
		n.dns = nil
	}
	if err := n.teardown(); err != nil {
		return err
	}
	if err := os.RemoveAll(n.dir()); err != nil {
		return err
	}
	s.mu.Lock()
	delete(s.namedNetworks, n.ID)
	s.mu.Unlock()
	if err := syncDir(filepath.Dir(n.dir())); err != nil {
		return err
	}
	w.WriteHeader(204)
	return nil
}
func (s *dockerEngine) networks(w http.ResponseWriter, r *http.Request, path string) error {
	key := strings.TrimPrefix(path, "/")
	if r.Method == "POST" && key == "create" {
		return s.createNetwork(w, r)
	}
	if r.Method == http.MethodPost {
		if network, op, ok := strings.Cut(key, "/"); ok && network != "" && (op == "connect" || op == "disconnect") {
			return s.mutateDockerNetwork(w, r, network, op == "connect")
		}
	}
	viewer := viewerOf(r.Context())
	if r.Method == "DELETE" && key != "" {
		var canRemove func(*workerNetwork) bool
		if viewer != "" {
			// Only a network created on this delegated socket.
			canRemove = func(n *workerNetwork) bool { return n.CreatedBy == viewer }
		}
		return s.deleteNetwork(w, key, canRemove)
	}
	if r.Method != "GET" {
		return fail(501, "unsupported network operation")
	}
	filters, err := dockerFilters(r.URL.Query().Get("filters"), "name", "id", "driver", "label", "type", "scope")
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	defaults := []*workerNetwork{{Name: "bridge", ID: networkID("bridge"), Driver: "bridge", Subnet: netip.MustParsePrefix("10.88.0.0/16")}, {Name: "none", ID: networkID("none"), Driver: "null"}}
	nets := defaults
	for _, n := range s.namedNetworks {
		if !n.deleting && s.seesNetworkLocked(viewer, n) {
			nets = append(nets, n)
		}
	}
	if key != "" {
		if builtin := builtinDockerNetwork(key); builtin != "" {
			key = builtin
		} else {
			n, err := s.findNetwork(key, false)
			if err != nil {
				return err
			}
			if n == nil || !s.seesNetworkLocked(viewer, n) {
				return fail(404, "no such network")
			}
			key = n.ID
		}
	}
	list := []map[string]any{}
	for _, n := range nets {
		if key != "" && key != n.Name && key != n.ID {
			continue
		}
		typ := "custom"
		if builtinNetwork(n.Name) {
			typ = "builtin"
		}
		match := matchesLabels(n.Labels, filters["label"])
		for field, values := range filters {
			if field == "label" || len(values) == 0 {
				continue
			}
			found := false
			for _, v := range values {
				found = found || field == "name" && strings.Contains(n.Name, v) || field == "id" && strings.HasPrefix(n.ID, v) || field == "driver" && n.Driver == v || field == "type" && typ == v || field == "scope" && v == "local"
			}
			match = match && found
		}
		if !match && key == "" {
			continue
		}
		ranges := []map[string]string{}
		opts := map[string]string{}
		if n.TCPCongestion != "" {
			opts[siblingTCPOption] = n.TCPCongestion
		}
		if n.Subnet.IsValid() {
			ranges = append(ranges, map[string]string{"Subnet": n.Subnet.String(), "Gateway": n.gateway().String()})
			if n.Name == "bridge" {
				opts["com.docker.network.bridge.name"] = "mpci0"
			} else if n.Driver == "bridge" {
				opts["com.docker.network.bridge.name"] = n.linkName()
			}
		}
		details := map[string]any{"Name": n.Name, "Id": n.ID, "Driver": n.Driver, "Scope": "local", "Internal": n.Internal, "Attachable": n.Attachable, "Labels": n.Labels, "Created": n.Created, "EnableIPv4": true, "Options": opts, "IPAM": map[string]any{"Driver": "default", "Config": ranges}}
		if key != "" {
			details["Containers"] = s.dockerNetworkMembersFor(n, viewer)
			writeJSON(w, 200, details)
			return nil
		}
		list = append(list, details)
	}
	if key != "" {
		return fail(404, "no such network")
	}
	slices.SortFunc(list, func(a, b map[string]any) int { return strings.Compare(a["Name"].(string), b["Name"].(string)) })
	writeJSON(w, 200, list)
	return nil
}
