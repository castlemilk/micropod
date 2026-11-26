package main

import (
	"context"
	"errors"
	"slices"
	"testing"

	"google.golang.org/grpc/metadata"
)

type fakeProbeKeys struct {
	leases, snaps     []string
	leaseErr, snapErr error
	namespaces        []string
}

func (f *fakeProbeKeys) seen(ctx context.Context) {
	md, _ := metadata.FromOutgoingContext(ctx)
	f.namespaces = append(f.namespaces, md.Get("containerd-namespace")...)
}

func (f *fakeProbeKeys) leaseIDs(ctx context.Context) ([]string, error) {
	f.seen(ctx)
	return f.leases, f.leaseErr
}

func (f *fakeProbeKeys) snapshotNames(ctx context.Context) ([]string, error) {
	f.seen(ctx)
	return f.snaps, f.snapErr
}

func TestSweepProbesRemovesOnlyStaleProbeKeysFromContainerdsLists(t *testing.T) {
	keys := &fakeProbeKeys{
		leases: []string{probeRoot + "/p1", "k8s.io/1/abc", probeRoot + "-not-a-probe"},
		snaps:  []string{probeRoot + "/p1", probeRoot + "/p2", "sha256:0123", "mp-rootfs-" + probeRoot},
	}
	var removed []string
	sweepProbes(context.Background(), keys, func(_ context.Context, key string) error {
		removed = append(removed, key)
		return nil
	})
	if want := []string{probeRoot + "/p1", probeRoot + "/p2"}; !slices.Equal(removed, want) {
		t.Fatalf("removed %v, want %v (once each)", removed, want)
	}
	if !slices.Equal(keys.namespaces, []string{"k8s.io", "k8s.io"}) {
		t.Fatalf("listed in namespaces %v, want the runtime's (k8s.io) for both lists", keys.namespaces)
	}
}

func TestSweepProbesStillSweepsWhatOneListFinds(t *testing.T) {
	keys := &fakeProbeKeys{
		leases:  []string{probeRoot + "/p3"},
		snapErr: errors.New("snapshotter unavailable"),
	}
	var removed []string
	failing := func(_ context.Context, key string) error {
		removed = append(removed, key)
		return errors.New("busy")
	}
	sweepProbes(context.Background(), keys, failing)
	if !slices.Equal(removed, []string{probeRoot + "/p3"}) {
		t.Fatalf("removed %v", removed)
	}
}
