package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// Open the pause process's namespace before it can be reused. Never modify the
// worker network namespace, even if CRI returns an unexpected process.
func (n node) podNetwork(ctx context.Context, id string) (*os.File, error) {
	r, err := n.runtime.PodSandboxStatus(ctx, &cri.PodSandboxStatusRequest{PodSandboxId: id, Verbose: true})
	if err != nil {
		return nil, err
	}
	st := r.GetStatus()
	if st.GetId() != id || st.GetMetadata().GetNamespace() != "micropod-ci" || st.GetMetadata().GetUid() != st.GetLabels()[owner] || !jobID.MatchString(st.GetLabels()[owner]) || st.GetRuntimeHandler() != "crun" {
		return nil, errors.New("network setup requires an owned crun pod")
	}
	var info struct{ Pid int }
	if json.Unmarshal([]byte(r.Info["info"]), &info) != nil || info.Pid <= 1 {
		return nil, errors.New("missing pod namespace")
	}
	process, err := os.Open(fmt.Sprintf("/proc/%d", info.Pid))
	if err != nil {
		return nil, err
	}
	defer process.Close()
	pinned := filepath.Join("/proc/self/fd", strconv.Itoa(int(process.Fd())))
	membership, err := os.ReadFile(filepath.Join(pinned, "cgroup"))
	if err != nil {
		return nil, err
	}
	cgroup, ok := strings.CutPrefix(strings.TrimSpace(string(membership)), "0::")
	if !ok || !filepath.IsAbs(cgroup) || filepath.Clean(cgroup) != cgroup || filepath.Base(cgroup) != id {
		return nil, errors.New("pause process no longer belongs to the requested pod")
	}
	f, err := os.Open(filepath.Join(pinned, "ns/net"))
	if err != nil {
		return nil, err
	}
	ours, err := os.Stat("/proc/self/ns/net")
	if err == nil {
		var theirs os.FileInfo
		theirs, err = f.Stat()
		if err == nil && os.SameFile(ours, theirs) {
			err = errors.New("pod is in the worker namespace")
		}
	}
	if err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

func configurePodNetwork(ctx context.Context, n node, id string, network *workerNetwork, ip string) error {
	ns, err := n.podNetwork(ctx, id)
	if err != nil {
		return err
	}
	defer ns.Close()
	pod, err := netlink.NewHandleAt(netns.NsHandle(ns.Fd()), unix.NETLINK_ROUTE)
	if err != nil {
		return err
	}
	defer pod.Close()
	link, err := pod.LinkByName("eth0")
	if err != nil {
		return err
	}
	if network != nil && network.Driver == "bridge" {
		return network.moveBridgeEndpoint(pod, link, ip)
	}
	if err := pod.LinkDel(link); err != nil {
		return err
	}
	if network == nil {
		return nil
	} // Preserve only loopback for offline jobs.
	return network.attach(pod, int(ns.Fd()), id, ip)
}
