// Read the actual CI endpoint type and address from inside its network namespace.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/vishvananda/netlink"
)

func inspect() error {
	link, err := netlink.LinkByName("eth0")
	if err != nil {
		return err
	}
	ips, err := netlink.AddrList(link, netlink.FAMILY_V4)
	if err != nil {
		return err
	}
	routes, err := netlink.RouteList(link, netlink.FAMILY_V4)
	if err != nil {
		return err
	}
	row := struct {
		Kind         string   `json:"kind"`
		Mode         string   `json:"mode,omitempty"`
		MTU          int      `json:"mtu"`
		IPv4         []string `json:"ipv4"`
		DefaultRoute bool     `json:"default_route"`
	}{Kind: link.Type(), MTU: link.Attrs().MTU}
	switch dev := link.(type) {
	case *netlink.IPVlan:
		if dev.Mode != netlink.IPVLAN_MODE_L2 {
			return fmt.Errorf("expected IPvlan L2, got mode %d", dev.Mode)
		}
		row.Mode = "l2"
	case *netlink.Macvlan:
		if dev.Mode != netlink.MACVLAN_MODE_BRIDGE {
			return fmt.Errorf("expected Macvlan bridge, got mode %d", dev.Mode)
		}
		row.Mode = "bridge"
	}
	for _, addr := range ips {
		row.IPv4 = append(row.IPv4, addr.IP.String())
	}
	for _, route := range routes {
		if route.Dst == nil {
			row.DefaultRoute = true
		} else if ones, _ := route.Dst.Mask.Size(); ones == 0 {
			row.DefaultRoute = true
		}
	}
	return json.NewEncoder(os.Stdout).Encode(row)
}

func main() {
	if err := inspect(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
