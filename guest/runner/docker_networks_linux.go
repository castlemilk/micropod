package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"strings"
)

// These are the two network modes the worker actually implements. Obtain
// bridge settings from the same CNI configuration that containerd loads.
func networkID(name string) string {
	hash := sha256.Sum256([]byte(os.Getenv("MICROPOD_CI_WORKER_ID") + "/" + name))
	return hex.EncodeToString(hash[:])
}

func (s *dockerEngine) networks(w http.ResponseWriter, r *http.Request, path string) error {
	filters, err := dockerFilters(r.URL.Query().Get("filters"), "name", "id", "driver")
	if err != nil {
		return err
	}
	var cni struct {
		Plugins []struct {
			Bridge string
			IPAM   struct{ Ranges [][]struct{ Subnet string } }
		}
	}
	b, err := os.ReadFile("/etc/cni/net.d/10-micropod.conflist")
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, &cni); err != nil {
		return err
	}
	key := strings.TrimPrefix(path, "/")
	var list []map[string]any
	for _, name := range []string{"bridge", "none"} {
		id := networkID(name)
		driver := "bridge"
		options := map[string]string{}
		var ranges []map[string]string
		if name == "none" {
			driver = "null"
		} else {
			for _, plugin := range cni.Plugins {
				if plugin.Bridge == "" {
					continue
				}
				options["com.docker.network.bridge.name"] = plugin.Bridge
				for _, group := range plugin.IPAM.Ranges {
					for _, subnet := range group {
						ranges = append(ranges, map[string]string{"Subnet": subnet.Subnet})
					}
				}
			}
		}
		details := map[string]any{"Name": name, "Id": id, "Driver": driver, "Scope": "local", "EnableIPv4": true, "Options": options, "IPAM": map[string]any{"Driver": "default", "Config": ranges}}
		if key != "" && (key == name || key == id) {
			members := map[string]any{}
			s.mu.Lock()
			for _, c := range s.containers {
				if c.Phase == "running" && (c.Config.HostConfig.NetworkMode == "none") == (name == "none") {
					members[c.ID] = map[string]string{"Name": c.Name, "IPv4Address": c.IP}
				}
			}
			s.mu.Unlock()
			details["Containers"] = members
			writeJSON(w, 200, details)
			return nil
		}
		match := true
		for field, values := range filters {
			ok := len(values) == 0
			for _, v := range values {
				ok = ok || field == "name" && strings.Contains(name, v) || field == "id" && strings.HasPrefix(id, v) || field == "driver" && driver == v
			}
			match = match && ok
		}
		if match {
			list = append(list, details)
		}
	}
	if key != "" {
		return fail(404, "no such network")
	}
	if list == nil {
		list = []map[string]any{}
	}
	writeJSON(w, 200, list)
	return nil
}
