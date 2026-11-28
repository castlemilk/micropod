package main

import (
	"context"
	"strings"
	"sync"

	leases "github.com/containerd/containerd/api/services/leases/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// Fewer metadata commits per container: the leases CRI's client would make.
//
// containerd's client wraps every container it creates in a lease of its own
// unless the request already names one: one bbolt commit to create the
// lease, one to delete it, for the pod's pause container (RunPodSandbox) and
// again for the workload (CreateContainer). Each commit is two fdatasyncs
// under containerd's single metadata write lock, the limit of start
// throughput (profiling CONFIRMED.md §6: 22.8 metadata commits per
// `docker run --rm`, 4 of them these leases). A lease in the request's
// "containerd-lease" header takes their place, as the client documents:
//
//   - CreateContainer names its pod's own lease. CRI creates a lease with
//     the sandbox's ID in RunPodSandbox and deletes it in RemovePodSandbox,
//     so the workload's snapshot is held exactly as long as its pod.
//   - RunPodSandbox cannot name its pod's lease (CRI picks the ID inside the
//     call), so it names runtimeSandboxLease, one lease of this engine that
//     holds each pod's pause snapshot from its creation. RemovePodSandbox
//     names it too, which drops that hold as the snapshot goes. Recovery
//     deletes it once every pod is gone (resetSandboxLease), so a hold an
//     interrupted call left behind lasts one boot at most.
//
// Nothing changes for durability: each commit that remains is synced as
// before, and what a lease held is held by another until the same point.
const (
	runtimeLeaseHeader  = "containerd-lease"
	runtimeSandboxLease = "micropod-runtime-sandboxes"
)

func withRuntimeLease(ctx context.Context, id string) context.Context {
	return metadata.AppendToOutgoingContext(ctx, runtimeLeaseHeader, id)
}

// runtimeLeaseNamespace is the namespace CRI's leases live in.
func runtimeLeaseNamespace(ctx context.Context) context.Context {
	return metadata.AppendToOutgoingContext(ctx, "containerd-namespace", dockerRuntimeNamespace)
}

// sandboxLease is whether this process has made sure runtimeSandboxLease
// exists. A failed attempt is retried by the next pod.
var sandboxLease struct {
	sync.Mutex
	ready bool
}

// sandboxLeaseContext names runtimeSandboxLease on a RunPodSandbox or
// RemovePodSandbox request, once it exists. Without it (no lease service, or
// the lease could not be made) the request goes as before: CRI's client
// makes its own lease.
func (n node) sandboxLeaseContext(ctx context.Context) context.Context {
	if n.leases == nil {
		return ctx
	}
	sandboxLease.Lock()
	defer sandboxLease.Unlock()
	if !sandboxLease.ready {
		_, err := n.leases.Create(runtimeLeaseNamespace(ctx), &leases.CreateRequest{ID: runtimeSandboxLease,
			Labels: map[string]string{"io.micropod.lease": "pause snapshots of the engine's pods"}})
		if err != nil && status.Code(err) != codes.AlreadyExists {
			return ctx
		}
		sandboxLease.ready = true
	}
	return withRuntimeLease(ctx, runtimeSandboxLease)
}

// resetSandboxLease deletes runtimeSandboxLease once recovery has removed
// every pod of the scheduler and the engine: what it still holds is a pause
// snapshot an interrupted RunPodSandbox left, which containerd's garbage
// collection then takes. The next pod makes the lease again.
func (n node) resetSandboxLease(ctx context.Context) error {
	if n.leases == nil {
		return nil
	}
	sandboxLease.Lock()
	defer sandboxLease.Unlock()
	sandboxLease.ready = false
	_, err := n.leases.Delete(runtimeLeaseNamespace(ctx), &leases.DeleteRequest{ID: runtimeSandboxLease})
	if status.Code(err) == codes.NotFound {
		return nil
	}
	return err
}

// missingRuntimeLease is CRI's answer to a request whose named lease does not
// exist (a pod made before its lease, or a lease deleted under it): the
// request is repeated without one.
func missingRuntimeLease(err error) bool {
	return status.Code(err) == codes.NotFound && strings.Contains(status.Convert(err).Message(), "lease does not exist")
}
