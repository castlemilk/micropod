package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// CRI needs an IP to admit its pod. Before creating any workload process,
// detach the disposable pod's veth. CNI still owns and releases its IP lease.
func (n node) disconnectPod(ctx context.Context, id string) error {
	r, err := n.runtime.PodSandboxStatus(ctx, &cri.PodSandboxStatusRequest{PodSandboxId: id, Verbose: true})
	if err != nil {
		return err
	}
	st := r.GetStatus()
	if st.GetId() != id || st.GetMetadata().GetNamespace() != "micropod-ci" || st.GetMetadata().GetUid() != st.GetLabels()[owner] || !jobID.MatchString(st.GetLabels()[owner]) || st.GetRuntimeHandler() != "crun" {
		return errors.New("offline network requires an owned crun pod")
	}
	var info struct{ Pid int }
	if json.Unmarshal([]byte(r.Info["info"]), &info) != nil || info.Pid <= 1 {
		return errors.New("missing owned pod namespace")
	}
	f, err := os.Open(fmt.Sprintf("/proc/%d/ns/net", info.Pid))
	if err != nil {
		return err
	}
	defer f.Close()
	ours, err := os.Stat("/proc/self/ns/net")
	if err != nil {
		return err
	}
	theirs, err := f.Stat()
	if err != nil {
		return err
	}
	if os.SameFile(ours, theirs) {
		return errors.New("offline target is the worker namespace")
	}
	cmd := exec.CommandContext(ctx, "/bin/busybox", "nsenter", "--net=/proc/self/fd/3", "/bin/busybox", "ip", "link", "delete", "eth0")
	cmd.ExtraFiles = []*os.File{f}
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
	if b, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("disconnect pod network: %w: %.256s", err, b)
	}
	return nil
}
