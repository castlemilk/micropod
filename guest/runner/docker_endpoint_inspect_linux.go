package main

import (
	"fmt"
	"slices"
	"strings"
)

type dockerEndpointView struct {
	NetworkID, EndpointID, Gateway, IPAddress, MacAddress string
	IPPrefixLen                                           int
	Aliases                                               []string
}

type dockerNetworkSettings struct {
	Networks map[string]dockerEndpointView
}

func (s *dockerEngine) inspectDockerContainer(c *dockerContainer) map[string]any {
	value := c.inspect()
	settings := value["NetworkSettings"].(map[string]any)
	settings["Networks"] = s.dockerContainerNetworks(c)
	return value
}

// The catalog lock protects the live generation and its committed allocations.
// Offline addresses are reservations, so operational fields remain empty.
func (s *dockerEngine) dockerContainerNetworks(c *dockerContainer) map[string]dockerEndpointView {
	name := networkName(c.Config.HostConfig.NetworkMode)
	primary := dockerEndpointView{NetworkID: c.NetworkID, Aliases: c.Config.Aliases}
	if c.Phase == "running" {
		primary.IPAddress, primary.MacAddress = c.IP, c.primaryMAC
	}
	if n := s.namedNetworks[c.NetworkID]; n != nil && primary.IPAddress != "" {
		primary.IPPrefixLen = n.Subnet.Bits()
		if !n.Internal {
			primary.Gateway = n.gateway().String()
		}
	}
	result := map[string]dockerEndpointView{name: primary}
	for _, ep := range c.SecondaryNetworks {
		n := s.namedNetworks[ep.NetworkID]
		if n == nil {
			continue
		}
		view := dockerEndpointView{NetworkID: ep.NetworkID, Aliases: ep.Aliases}
		if mac, attached := c.activeDockerSecondary(ep.NetworkID); attached {
			view.EndpointID, view.IPAddress, view.MacAddress = ep.ID, ep.IP, mac
			view.IPPrefixLen = n.Subnet.Bits()
			if !n.Internal {
				view.Gateway = n.gateway().String()
			}
		}
		result[n.Name] = view
	}
	return result
}

func (c *dockerContainer) activeDockerSecondary(networkID string) (string, bool) {
	if c.Phase != "running" || c.bridge == nil || c.bridge.retiring {
		return "", false
	}
	mac, attached := c.bridge.active[networkID]
	return mac, attached
}

func (s *dockerEngine) dockerNetworkMembers(n *workerNetwork) map[string]map[string]string {
	return s.dockerNetworkMembersFor(n, "")
}

// dockerNetworkMembersFor lists the members viewer may see (viewerOf).
func (s *dockerEngine) dockerNetworkMembersFor(n *workerNetwork, viewer string) map[string]map[string]string {
	members := make(map[string]map[string]string)
	for _, c := range s.containers {
		if c.Phase != "running" || !seesContainer(viewer, c) {
			continue
		}
		var ip, endpointID, mac string
		if c.NetworkID == n.ID || (c.NetworkID == "" && networkName(c.Config.HostConfig.NetworkMode) == n.Name) {
			ip, mac = c.IP, c.primaryMAC
		} else if idx := c.secondaryEndpoint(n.ID); idx >= 0 {
			var active bool
			if mac, active = c.activeDockerSecondary(n.ID); !active {
				continue
			}
			endpoint := c.SecondaryNetworks[idx]
			ip, endpointID = endpoint.IP, endpoint.ID
		} else {
			continue
		}
		if ip != "" && n.Subnet.IsValid() {
			ip = fmt.Sprintf("%s/%d", ip, n.Subnet.Bits())
		}
		members[c.ID] = map[string]string{"Name": c.Name, "IPv4Address": ip, "EndpointID": endpointID, "MacAddress": mac, "IPv6Address": ""}
	}
	return members
}

func (s *dockerEngine) matchesDockerNetwork(c *dockerContainer, values []string) bool {
	name := networkName(c.Config.HostConfig.NetworkMode)
	id := c.NetworkID
	if id == "" {
		id = networkID(name)
	}
	if slices.ContainsFunc(values, func(value string) bool { return value == name || strings.HasPrefix(id, value) }) {
		return true
	}
	for _, endpoint := range c.SecondaryNetworks {
		n := s.namedNetworks[endpoint.NetworkID]
		if n != nil && slices.ContainsFunc(values, func(value string) bool { return value == n.Name || strings.HasPrefix(n.ID, value) }) {
			return true
		}
	}
	return false
}
