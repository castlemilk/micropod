package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"slices"
	"strings"
)

type dockerEndpointOptions struct {
	NetworkID string
	Aliases   []string
}

type dockerSecondaryEndpoint struct {
	ID, NetworkID, IP string
	Aliases           []string `json:",omitempty"`
}

const maxDockerEndpointAliases = 64

func validDockerEndpointAliases(aliases []string) bool {
	return len(aliases) <= maxDockerEndpointAliases && !slices.ContainsFunc(aliases, func(alias string) bool {
		return !dockerName.MatchString(alias)
	})
}

func parseDockerEndpoint(v any) (dockerEndpointOptions, error) {
	var endpoint dockerEndpointOptions
	if v == nil {
		return endpoint, nil
	}
	fields, ok := v.(map[string]any)
	if !ok {
		return endpoint, errors.New("invalid Docker endpoint settings")
	}
	if err := supportedOptions(fields, "NetworkID Aliases"); err != nil {
		return endpoint, err
	}
	if id := fields["NetworkID"]; id != nil {
		endpoint.NetworkID, ok = id.(string)
		if !ok {
			return endpoint, errors.New("invalid endpoint network ID")
		}
	}
	if raw := fields["Aliases"]; raw != nil {
		aliases, ok := raw.([]any)
		if !ok || len(aliases) > maxDockerEndpointAliases {
			return endpoint, errors.New("invalid Docker network aliases")
		}
		for _, item := range aliases {
			alias, ok := item.(string)
			if !ok || !dockerName.MatchString(alias) {
				return endpoint, errors.New("invalid network alias")
			}
			endpoint.Aliases = append(endpoint.Aliases, alias)
		}
	}
	return endpoint, nil
}

func builtinDockerNetwork(key string) string {
	for _, name := range []string{"bridge", "none"} {
		if networkName(key) == name || key == networkID(name) {
			return name
		}
	}
	return ""
}

func (spec *dockerConfig) parseDockerEndpoints(v any) error {
	if v == nil {
		return nil
	}
	fields, ok := v.(map[string]any)
	if !ok {
		return errors.New("invalid Docker endpoints configuration")
	}
	if len(fields) == 0 {
		return nil
	}
	spec.Endpoints = make(map[string]dockerEndpointOptions, len(fields))
	for key, raw := range fields {
		if key == "" || !dockerName.MatchString(key) {
			return errors.New("invalid Docker endpoint network name")
		}
		endpoint, err := parseDockerEndpoint(raw)
		if err != nil {
			return err
		}
		mode := spec.HostConfig.NetworkMode
		if len(fields) == 1 && (mode == "" || mode == "default") && builtinDockerNetwork(key) == "" {
			// The Docker SDK can supply its primary network only in EndpointsConfig.
			spec.HostConfig.NetworkMode = key
			mode = key
		}
		if builtin := builtinDockerNetwork(mode); builtin != "" {
			if builtinDockerNetwork(key) != builtin {
				return errors.New("additional endpoints require a named IPv4 bridge as the primary network")
			}
			if endpoint.NetworkID != "" && endpoint.NetworkID != networkID(builtin) {
				return errors.New("endpoint network identity differs")
			}
			if len(endpoint.Aliases) != 0 {
				return errors.New("aliases require a named network")
			}
		}
		spec.Endpoints[key] = endpoint
	}
	return nil
}

func (n *workerNetwork) secondaryBridge() bool {
	return n != nil && !n.deleting && n.Driver == "bridge" && n.Subnet.IsValid() && n.Subnet.Addr().Is4() && !privateRootless()
}

func (c *dockerContainer) secondaryEndpoint(networkID string) int {
	return slices.IndexFunc(c.SecondaryNetworks, func(endpoint dockerSecondaryEndpoint) bool {
		return endpoint.NetworkID == networkID
	})
}

// Called with s.mu. Pending joins hold their address across netlink and save.
func (s *dockerEngine) reserveDockerAddress(n *workerNetwork) (string, error) {
	used := make(map[string]bool)
	for _, c := range s.containers {
		if c.NetworkID == n.ID {
			used[c.NetworkIP] = true
		}
		if index := c.secondaryEndpoint(n.ID); index >= 0 {
			used[c.SecondaryNetworks[index].IP] = true
		}
		if c.bridge != nil && c.bridge.pending != nil && c.bridge.pending.NetworkID == n.ID {
			used[c.bridge.pending.IP] = true
		}
	}
	for ip := n.gateway().Next(); ip.IsValid() && n.Subnet.Contains(ip.Next()); ip = ip.Next() {
		if !used[ip.String()] {
			return ip.String(), nil
		}
	}
	return "", fail(http.StatusConflict, "network has no free addresses")
}

func (s *dockerEngine) allocateDockerEndpoint(n *workerNetwork, aliases []string) (dockerSecondaryEndpoint, error) {
	ip, err := s.reserveDockerAddress(n)
	if err != nil {
		return dockerSecondaryEndpoint{}, err
	}
	return dockerSecondaryEndpoint{ID: engineID(), NetworkID: n.ID, IP: ip, Aliases: aliases}, nil
}

func (s *dockerEngine) selectNetwork(spec *dockerConfig) (id, address string, endpoints []dockerSecondaryEndpoint, err error) {
	if builtin := builtinDockerNetwork(spec.HostConfig.NetworkMode); builtin != "" {
		if spec.HostConfig.NetworkMode == networkID(builtin) {
			spec.HostConfig.NetworkMode = builtin
		}
		spec.Endpoints = nil
		return "", "", nil, nil
	}
	primary, err := s.findNetwork(spec.HostConfig.NetworkMode, false)
	if err != nil {
		return "", "", nil, err
	}
	if primary == nil {
		return "", "", nil, fail(http.StatusNotFound, "no such network: "+spec.HostConfig.NetworkMode)
	}
	seen := make(map[string]bool, len(spec.Endpoints))
	for key, config := range spec.Endpoints {
		n, err := s.findNetwork(key, false)
		if err != nil {
			return "", "", nil, err
		}
		if n == nil {
			return "", "", nil, fail(http.StatusNotFound, "no such network: "+key)
		}
		if config.NetworkID != "" && config.NetworkID != n.ID {
			return "", "", nil, fail(http.StatusBadRequest, "endpoint network identity differs")
		}
		if seen[n.ID] {
			return "", "", nil, fail(http.StatusBadRequest, "duplicate endpoint network: "+n.Name)
		}
		seen[n.ID] = true
		if n == primary {
			spec.Aliases = config.Aliases
			continue
		}
		if !primary.secondaryBridge() || !n.secondaryBridge() {
			return "", "", nil, unsupportedDockerSecondaryNetwork()
		}
		endpoint, err := s.allocateDockerEndpoint(n, config.Aliases)
		if err != nil {
			return "", "", nil, err
		}
		endpoints = append(endpoints, endpoint)
	}
	slices.SortFunc(endpoints, func(a, b dockerSecondaryEndpoint) int { return strings.Compare(a.NetworkID, b.NetworkID) })
	spec.HostConfig.NetworkMode = primary.Name
	spec.Endpoints = nil
	address, err = s.reserveDockerAddress(primary)
	return primary.ID, address, endpoints, err
}

func (n *workerNetwork) ownsDockerAddress(raw string) bool {
	ip, err := netip.ParseAddr(raw)
	return err == nil && ip.Is4() && ip.Compare(n.gateway()) > 0 && n.Subnet.Contains(ip.Next())
}

// Revalidate saved reservations after retiring any interrupted sandbox and
// before an address can be claimed by a new container. Old records have only
// their primary reservation.
func (s *dockerEngine) verifyDockerNetworkReservations() error {
	type reservation struct{ network, ip string }
	used := make(map[reservation]string)
	reserve := func(c *dockerContainer, networkID, ip string) error {
		n := s.namedNetworks[networkID]
		if n == nil || !n.ownsDockerAddress(ip) {
			return fmt.Errorf("invalid saved network reservation for container %s", c.ID)
		}
		key := reservation{networkID, ip}
		if owner := used[key]; owner != "" {
			return fmt.Errorf("duplicate saved network reservation for containers %s and %s", owner, c.ID)
		}
		used[key] = c.ID
		return nil
	}
	for _, c := range s.containers {
		primary := s.namedNetworks[c.NetworkID]
		if c.NetworkID != "" {
			if primary == nil || primary.Name != c.Config.HostConfig.NetworkMode {
				return fmt.Errorf("invalid saved primary network for container %s", c.ID)
			}
			if err := reserve(c, c.NetworkID, c.NetworkIP); err != nil {
				return err
			}
		}
		seen := map[string]bool{c.NetworkID: true}
		for _, endpoint := range c.SecondaryNetworks {
			if !primary.secondaryBridge() || !s.namedNetworks[endpoint.NetworkID].secondaryBridge() || seen[endpoint.NetworkID] ||
				!fullContainerID.MatchString(endpoint.ID) || !validDockerEndpointAliases(endpoint.Aliases) {
				return fmt.Errorf("invalid saved secondary network for container %s", c.ID)
			}
			seen[endpoint.NetworkID] = true
			if err := reserve(c, endpoint.NetworkID, endpoint.IP); err != nil {
				return err
			}
		}
	}
	return nil
}

func readDockerNetworkMutation(w http.ResponseWriter, r *http.Request, connect bool) (string, dockerEndpointOptions, error) {
	var req struct {
		Container      string
		EndpointConfig any
		Force          bool
	}
	var endpoint dockerEndpointOptions
	body, err := readBody(w, r)
	if err != nil {
		return "", endpoint, err
	}
	var fields map[string]any
	if json.Unmarshal(body, &req) != nil || json.Unmarshal(body, &fields) != nil || req.Container == "" {
		return "", endpoint, fail(http.StatusBadRequest, "invalid Docker network request")
	}
	allowed := "Container Force"
	if connect {
		allowed = "Container EndpointConfig"
	}
	if err := supportedOptions(fields, allowed); err != nil {
		return "", endpoint, fail(http.StatusBadRequest, err.Error())
	}
	if connect {
		endpoint, err = parseDockerEndpoint(req.EndpointConfig)
		if err != nil {
			return "", endpoint, fail(http.StatusBadRequest, err.Error())
		}
	}
	return req.Container, endpoint, nil
}
