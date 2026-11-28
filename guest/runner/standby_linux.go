// A standby pod holds only a pause process and private namespaces. The scheduler
// may prepare these during idle time. Removing a ready entry consumes it once.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const primeWorkers = 4
const readyDir = "/run/micropod-oci/standby"

type ownedPod struct{ id, pod string }

func (n node) cleanup(id string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	if err := n.remove(ctx, id); err != nil {
		return fmt.Errorf("cleanup of job %s: %w", id, err)
	}
	return nil
}

func (n node) attest(ctx context.Context, p ownedPod, handler string) error {
	resp, err := n.runtime.PodSandboxStatus(ctx, &cri.PodSandboxStatusRequest{PodSandboxId: p.pod})
	if err != nil {
		return err
	}
	st := resp.GetStatus()
	if st.GetId() != p.pod || st.GetRuntimeHandler() != handler || st.GetState() != cri.PodSandboxState_SANDBOX_READY ||
		st.GetLabels()[owner] != p.id || st.GetMetadata().GetUid() != p.id || st.GetMetadata().GetNamespace() != "micropod-ci" {
		return errors.New("pod ownership, readiness or runtime differs from scheduler policy")
	}
	return nil
}

func (n node) newPod(ctx context.Context, handler string) (p ownedPod, err error) {
	var nonce [16]byte
	if _, err = rand.Read(nonce[:]); err != nil {
		return p, err
	}
	p.id = hex.EncodeToString(nonce[:])
	dir := filepath.Join(dataRoot, "jobs", p.id)
	if err = os.MkdirAll(dir, 0700); err != nil {
		return p, err
	}
	// Record ownership before making any CRI calls, including calls that can lose their reply.
	defer func() {
		if err != nil {
			err = errors.Join(err, n.cleanup(p.id))
		}
	}()
	if err = syscall.Mount("tmpfs", dir, "tmpfs", syscall.MS_NODEV|syscall.MS_NOSUID|syscall.MS_NOEXEC, "size=8m,mode=0700"); err != nil {
		return p, err
	}
	result, err := n.runPodSandbox(ctx, &cri.RunPodSandboxRequest{Config: sandboxConfig(p.id, dir, handler), RuntimeHandler: handler})
	if err != nil {
		return p, fmt.Errorf("start %s pod: %w", handler, err)
	}
	p.pod = result.PodSandboxId
	return p, n.attest(ctx, p, handler)
}

// sandboxConfig is a new pod's configuration. A crun pod's pause rootfs goes
// with the pod, so it asks for a volatile layer (rootfs_volatile_linux.go),
// and its sandbox for CPU shares above CRI's minimum
// (sandbox_shares_linux.go); an untrusted Kata job's pod carries no
// annotation at all.
func sandboxConfig(id, dir, handler string) *cri.PodSandboxConfig {
	pod := podConfig(id, dir)
	if handler == "crun" {
		pod.Annotations = withVolatileRootFS(pod.Annotations)
		pod.Annotations = withSandboxCPUShares(pod.Annotations, startBoostWindow > 0)
	}
	return pod
}

// runPodSandbox names the engine's sandbox lease (runtime_lease_linux.go),
// and goes again without it if CRI finds no such lease.
func (n node) runPodSandbox(ctx context.Context, request *cri.RunPodSandboxRequest) (*cri.RunPodSandboxResponse, error) {
	result, err := n.runtime.RunPodSandbox(n.sandboxLeaseContext(ctx), request)
	if missingRuntimeLease(err) {
		return n.runtime.RunPodSandbox(ctx, request)
	}
	return result, err
}

func readyPods() ([]os.DirEntry, error) {
	entries, err := os.ReadDir(readyDir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	return entries, err
}
func (n node) acquire(ctx context.Context, handler string) (ownedPod, bool, error) {
	if handler == "crun" {
		entries, err := readyPods()
		if err != nil {
			return ownedPod{}, false, err
		}
		for _, ent := range entries {
			id, pod, ok := strings.Cut(ent.Name(), ".")
			if !ok || !jobID.MatchString(id) || len(pod) != 64 {
				continue
			}
			if err := os.Remove(filepath.Join(readyDir, ent.Name())); errors.Is(err, os.ErrNotExist) {
				continue
			} else if err != nil {
				return ownedPod{}, false, err
			}
			p := ownedPod{id, pod}
			if err := n.attest(ctx, p, handler); err == nil {
				return p, true, nil
			}
			if err := n.cleanup(id); err != nil {
				return ownedPod{}, false, err
			}
			if ctx.Err() != nil {
				return ownedPod{}, false, ctx.Err()
			}
		}
	}
	p, err := n.newPod(ctx, handler)
	return p, false, err
}

func (n node) prime(ctx context.Context, target int) (int, error) {
	if target < 1 || target > 32 {
		return 0, errors.New("expected 1 through 32 single-use trusted pods")
	}
	if err := os.MkdirAll(readyDir, 0700); err != nil {
		return 0, err
	}
	lock, err := os.Open(readyDir)
	if err != nil {
		return 0, err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return 0, fmt.Errorf("another preparation is active: %w", err)
	}
	entries, err := readyPods()
	if err != nil {
		return 0, err
	}
	needed := max(0, target-len(entries))
	work := make(chan struct{}, needed)
	for range needed {
		work <- struct{}{}
	}
	close(work)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var workers sync.WaitGroup
	var created atomic.Int32
	var first sync.Once
	var failure error
	for range min(primeWorkers, needed) {
		workers.Go(func() {
			for range work {
				if ctx.Err() != nil {
					return
				}
				if err := n.prepareOne(ctx); err != nil {
					first.Do(func() { failure = err; cancel() })
					return
				}
				created.Add(1)
			}
		})
	}
	workers.Wait()
	return int(created.Load()), errors.Join(failure, ctx.Err())
}

func (n node) prepareOne(ctx context.Context) error {
	p, err := n.newPod(ctx, "crun")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(readyDir, p.id+"."+p.pod), nil, 0600); err != nil {
		return errors.Join(err, n.cleanup(p.id))
	}
	return nil
}
