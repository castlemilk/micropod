package main

import (
	"cmp"
	"encoding/json"
	"maps"
	"slices"
	"strconv"
	"strings"
)

type portBinding struct {
	HostIP   string `json:"HostIp"`
	HostPort string
}

type portMap map[string][]portBinding

type dockerSummaryPort struct {
	IP          string `json:",omitempty"`
	PrivatePort uint16
	PublicPort  uint16 `json:",omitempty"`
	Type        string
}

// withExposed builds the running port map shared by list and inspect. A nil
// binding slice encodes as null for an exposed port without a host mapping.
func (published portMap) withExposed(exposed map[string]struct{}) portMap {
	if len(exposed) == 0 && published != nil {
		return published
	}
	ports := make(portMap, len(exposed)+len(published))
	maps.Copy(ports, published)
	for key := range exposed {
		if port, valid := parseDockerSummaryPort(key); valid {
			key := port.key()
			if _, exists := ports[key]; !exists {
				ports[key] = nil
			}
		}
	}
	return ports
}

func (effective portMap) summary() []dockerSummaryPort {
	ports := make([]dockerSummaryPort, 0, len(effective))
	for key, bindings := range effective {
		port, valid := parseDockerSummaryPort(key)
		if !valid {
			continue
		}
		for _, binding := range bindings {
			hostPort, err := strconv.ParseUint(binding.HostPort, 10, 16)
			if err != nil || hostPort == 0 {
				continue
			}
			ports = append(ports, dockerSummaryPort{
				IP: binding.HostIP, PrivatePort: port.PrivatePort, PublicPort: uint16(hostPort), Type: port.Type,
			})
		}
		if len(bindings) == 0 {
			ports = append(ports, port)
		}
	}
	slices.SortFunc(ports, func(a, b dockerSummaryPort) int {
		return cmp.Or(cmp.Compare(a.PrivatePort, b.PrivatePort), cmp.Compare(a.Type, b.Type),
			cmp.Compare(a.IP, b.IP), cmp.Compare(a.PublicPort, b.PublicPort))
	})
	return ports
}

func (port dockerSummaryPort) key() string {
	return strconv.Itoa(int(port.PrivatePort)) + "/" + port.Type
}

func parseDockerSummaryPort(key string) (dockerSummaryPort, bool) {
	value, protocol, _ := strings.Cut(key, "/")
	if protocol == "" {
		protocol = "tcp"
	}
	switch protocol {
	case "tcp", "udp", "sctp":
	default:
		return dockerSummaryPort{}, false
	}
	port, err := strconv.ParseUint(value, 10, 16)
	return dockerSummaryPort{PrivatePort: uint16(port), Type: protocol}, err == nil && port != 0
}

// Containerd includes the OCI image config in the verbose CRI status response.
// Runtimes without this optional data retain the ports supplied by the caller.
func mergeImageExposedPorts(exposed map[string]struct{}, info string) map[string]struct{} {
	if info == "" {
		return exposed
	}
	var details struct {
		ImageSpec struct {
			Config struct {
				ExposedPorts map[string]struct{}
			}
		}
	}
	if err := json.Unmarshal([]byte(info), &details); err != nil || len(details.ImageSpec.Config.ExposedPorts) == 0 {
		return exposed
	}
	ports := maps.Clone(exposed)
	if ports == nil {
		ports = make(map[string]struct{}, len(details.ImageSpec.Config.ExposedPorts))
	}
	for key := range details.ImageSpec.Config.ExposedPorts {
		if port, valid := parseDockerSummaryPort(key); valid {
			ports[port.key()] = struct{}{}
		}
	}
	return ports
}

// imageEnv is the environment an image's config sets, from the image
// status's verbose info; nil when it sets none or the info cannot be read.
func imageEnv(info string) []string {
	if info == "" {
		return nil
	}
	var details struct {
		ImageSpec struct {
			Config struct {
				Env []string
			}
		}
	}
	if err := json.Unmarshal([]byte(info), &details); err != nil {
		return nil
	}
	return details.ImageSpec.Config.Env
}
