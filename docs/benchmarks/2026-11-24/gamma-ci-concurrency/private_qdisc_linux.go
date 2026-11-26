// Inspect or replace the root queue on the disposable worker's private virtio NIC.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/vishvananda/netlink"
)

func run(action string) error {
	driver, err := filepath.EvalSymlinks("/sys/class/net/eth1/device/driver")
	if err != nil || filepath.Base(driver) != "virtio_net" {
		return fmt.Errorf("unexpected private NIC driver %q", driver)
	}
	link, err := netlink.LinkByName("eth1")
	if err != nil {
		return err
	}
	switch action {
	case "qdisc-fq-codel":
		root := netlink.QdiscAttrs{LinkIndex: link.Attrs().Index, Parent: netlink.HANDLE_ROOT}
		if err := netlink.QdiscReplace(netlink.NewFqCodel(root)); err != nil {
			return err
		}
	case "qdisc-read":
	default:
		return fmt.Errorf("unknown action %q", action)
	}
	queues, err := netlink.QdiscList(link)
	if err != nil {
		return err
	}
	var roots []map[string]any
	for _, queue := range queues {
		a := queue.Attrs()
		if a.Parent != netlink.HANDLE_ROOT {
			continue
		}
		row := map[string]any{"root": true, "kind": queue.Type(), "handle": netlink.HandleStr(a.Handle),
			"ifindex": a.LinkIndex, "gso_ipv4_bytes": link.Attrs().GSOIPv4MaxSize}
		if s := a.Statistics; s != nil && s.Basic != nil && s.Queue != nil {
			row["bytes"], row["packets"] = s.Basic.Bytes, s.Basic.Packets
			row["drops"], row["requeues"], row["overlimits"] = s.Queue.Drops, s.Queue.Requeues, s.Queue.Overlimits
		}
		if fq, ok := queue.(*netlink.FqCodel); ok {
			row["ecn"], row["limit"], row["flows"] = fq.ECN, fq.Limit, fq.Flows
			row["target_us"], row["interval_us"], row["quantum"] = fq.Target, fq.Interval, fq.Quantum
		}
		roots = append(roots, row)
	}
	return json.NewEncoder(os.Stdout).Encode(roots)
}

func main() {
	if len(os.Args) != 2 {
		log.Fatal("one queue action is required")
	}
	if err := run(os.Args[1]); err != nil {
		log.Fatal(err)
	}
}
