package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// familyFixture is delegatedFixture with every container stopped and given a
// record directory, a network and a volume for each family, and one of the
// host's each.
func familyFixture(t *testing.T) (s *dockerEngine, owner, child, other, otherChild *dockerContainer) {
	t.Helper()
	needRoot(t)
	useVolumeStore(t)
	s, owner, child, other, otherChild = delegatedFixture(t)
	owner.EngineSocket, other.EngineSocket = true, true
	// The fixture's networks have no links or firewall rules: a stand-in
	// iptables finds no rule to remove, so removing them needs neither the
	// machine's firewall nor NET_ADMIN (a container on a machine has neither).
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "iptables"), []byte("#!/bin/sh\nexit 1\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	for _, d := range []string{"containers", "retired", "networks"} {
		if err := os.MkdirAll(filepath.Join(engineRoot, d), 0700); err != nil {
			t.Fatal(err)
		}
	}
	dir := func(p string) {
		if err := os.MkdirAll(p, 0700); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.RemoveAll(p) })
	}
	for _, c := range []*dockerContainer{owner, child, other, otherChild} {
		c.Phase = "exited"
		dir(c.dir())
		t.Cleanup(func() { os.RemoveAll(filepath.Join(engineRoot, "retired", c.ID)) })
	}
	for i, n := range []*workerNetwork{
		{Name: "app_default", CreatedBy: owner.ID},
		{Name: "b_default", CreatedBy: other.ID},
		{Name: "host-net"},
	} {
		n.ID, n.Driver = strings.Repeat(string(rune('1'+i)), 64), "bridge"
		n.Subnet = netip.MustParsePrefix("10.90." + string(rune('1'+i)) + ".0/24")
		s.namedNetworks[n.ID] = n
		dir(n.dir())
	}
	for _, v := range []struct{ name, by string }{{"app_pgdata", owner.ID}, {"b_data", other.ID}, {"host_data", ""}} {
		if err := ensureVolumeBy(v.name, nil, v.by); err != nil {
			t.Fatal(err)
		}
	}
	return s, owner, child, other, otherChild
}

func (s *dockerEngine) hasNetworkNamed(name string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	n, _ := s.findNetwork(name, true)
	return n != nil
}

func hasVolume(name string) bool { _, err := inspectVolume(name); return err == nil }

// Removing a delegated socket's owner removes what its socket created, and
// nothing of another job's or the host's: a later job of the same compose
// project then finds its names free.
func TestRemovingAnOwnerReapsItsFamily(t *testing.T) {
	s, owner, child, other, otherChild := familyFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := s.remove(ctx, owner, true); err != nil {
		t.Fatal(err)
	}
	// remove answers once the family is gone.
	s.mu.Lock()
	_, childLeft := s.containers[child.ID]
	_, otherLeft := s.containers[other.ID]
	_, otherChildLeft := s.containers[otherChild.ID]
	s.mu.Unlock()
	if childLeft || !otherLeft || !otherChildLeft {
		t.Fatalf("after its owner's removal: its child left %v, another job's %v and %v", childLeft, otherLeft, otherChildLeft)
	}
	if s.hasNetworkNamed("app_default") || !s.hasNetworkNamed("b_default") || !s.hasNetworkNamed("host-net") {
		t.Fatal("the owner's network outlived it, or another's went with it")
	}
	if hasVolume("app_pgdata") || !hasVolume("b_data") || !hasVolume("host_data") {
		t.Fatal("the owner's volume outlived it, or another's went with it")
	}

	// Its socket, still answering a request, creates nothing more.
	gone := withViewer(context.Background(), owner.ID)
	rec := httptest.NewRecorder()
	err := s.volumes(rec, httptest.NewRequest("POST", "/volumes/create", strings.NewReader(`{"Name":"late"}`)).WithContext(gone), "/create")
	var api apiError
	if !errors.As(err, &api) || api.code != http.StatusForbidden || hasVolume("late") {
		t.Errorf("a volume created through a removed owner's socket: %v", err)
	}
	err = s.createNetwork(httptest.NewRecorder(), httptest.NewRequest("POST", "/networks/create", strings.NewReader(`{"Name":"late"}`)).WithContext(gone))
	if !errors.As(err, &api) || api.code != http.StatusForbidden || s.hasNetworkNamed("late") {
		t.Errorf("a network created through a removed owner's socket: %v", err)
	}
}

// Every answer that a job's container is removed waits for its family, not
// only a remove that removes it itself: `docker run --rm` (a wait for
// removal, answered by the removal on its exit) and a `docker rm -f` or a
// second remove that finds it already removed answer once its children,
// networks and volumes are gone, so the next job of the project finds the
// names free.
func TestEveryAnswerThatAnOwnerIsRemovedWaitsForItsFamily(t *testing.T) {
	s, owner, child, _, _ := familyFixture(t)
	owner.Config.HostConfig.AutoRemove = true
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// A host's docker cp of the child holds its lifecycle, so the reaping
	// waits for it.
	held, err := s.lockContainerLifecycle(ctx, child)
	if err != nil || held == nil {
		t.Fatalf("hold the child's lifecycle: %v", err)
	}
	var once sync.Once
	release := func() { once.Do(held) }
	t.Cleanup(release)

	waited := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("POST", "/containers/"+owner.ID+"/wait?condition=removed", nil).WithContext(ctx)
		if err := s.wait(rec, req, owner); err != nil {
			t.Error(err)
		}
		waited <- rec
	}()
	// The container exits and is removed on exit, as AutoRemove does.
	s.mu.Lock()
	err = s.removeLocked(owner)
	s.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	removed := make(chan error, 1)
	go func() { removed <- s.remove(ctx, owner, true) }()
	select {
	case <-waited:
		t.Fatal("the wait for removal answered while the family was still there")
	case err := <-removed:
		t.Fatalf("a remove of the removed owner answered (%v) while the family was still there", err)
	case <-time.After(300 * time.Millisecond):
	}

	release()
	var rec *httptest.ResponseRecorder
	for range 2 {
		select {
		case rec = <-waited:
		case err := <-removed:
			if err != nil {
				t.Fatal(err)
			}
		case <-ctx.Done():
			t.Fatal("the reaping did not finish")
		}
		s.mu.Lock()
		_, childLeft := s.containers[child.ID]
		s.mu.Unlock()
		if childLeft || s.hasNetworkNamed("app_default") || hasVolume("app_pgdata") {
			t.Fatal("an answer that the owner is removed came before its family was gone")
		}
	}
	if !strings.Contains(rec.Body.String(), `"StatusCode"`) {
		t.Errorf("the wait answered %q", rec.Body)
	}
}

// A removed volume's data is deleted without the engine's lock, whether a
// family's reaping or a `docker volume rm` removes it: while its tree is
// still being deleted every other request is answered, and its name is free
// for a new, empty volume.
func TestAVolumesDataIsDeletedWithoutTheEngineLock(t *testing.T) {
	s, owner, _, _, _ := familyFixture(t)
	for _, name := range []string{"app_pgdata", "host_data"} {
		if err := os.WriteFile(filepath.Join(volumePath(name), "PG_VERSION"), []byte("17"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	deleting := make(chan string)
	proceed := make(chan struct{})
	deleteVolumeData = func(p string) error {
		deleting <- p
		<-proceed
		return os.RemoveAll(p)
	}
	t.Cleanup(func() { deleteVolumeData = os.RemoveAll })
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	for _, c := range []struct {
		name   string
		remove func() error
	}{
		{"app_pgdata", func() error { return s.remove(ctx, owner, true) }},
		{"host_data", func() error {
			rec := httptest.NewRecorder()
			err := s.volumes(rec, httptest.NewRequest("DELETE", "/volumes/host_data", nil).WithContext(ctx), "/host_data")
			if err == nil && rec.Code != http.StatusNoContent {
				err = errors.New(rec.Result().Status)
			}
			return err
		}},
	} {
		done := make(chan error, 1)
		go func() { done <- c.remove() }()
		var data string
		select {
		case data = <-deleting:
		case err := <-done:
			t.Fatalf("%s: removed (%v) without deleting its data", c.name, err)
		case <-ctx.Done():
			t.Fatalf("%s: its data was never deleted", c.name)
		}
		if !s.mu.TryLock() {
			close(proceed)
			t.Fatalf("%s: the engine's lock is held while the volume's data is deleted", c.name)
		}
		s.mu.Unlock()
		if _, err := os.Stat(filepath.Join(data, "PG_VERSION")); err != nil {
			t.Errorf("%s: the data being deleted: %v", c.name, err)
		}
		if hasVolume(c.name) {
			t.Errorf("%s: the name is still taken while its old data is deleted", c.name)
		}
		if err := ensureVolume(c.name, nil); err != nil {
			t.Fatal(err)
		}
		if entries, err := os.ReadDir(volumePath(c.name)); err != nil || len(entries) != 0 {
			t.Errorf("%s: a new volume of the name holds %v (%v)", c.name, entries, err)
		}
		proceed <- struct{}{}
		if err := <-done; err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if _, err := os.Stat(data); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s: its old data is left: %v", c.name, err)
		}
	}
}

// addChild gives owner's family another stopped child.
func addChild(t *testing.T, s *dockerEngine, owner *dockerContainer, id byte, name string) *dockerContainer {
	t.Helper()
	c := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat(string(id), 64), Name: name, Phase: "exited", CreatedBy: owner.ID,
		Config: dockerConfig{Image: "alpine"}}, changed: make(chan struct{})}
	if err := os.MkdirAll(c.dir(), 0700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		os.RemoveAll(c.dir())
		os.RemoveAll(filepath.Join(engineRoot, "retired", c.ID))
	})
	s.mu.Lock()
	s.containers[c.ID] = c
	s.mu.Unlock()
	return c
}

// holdLifecycle holds c's lifecycle, as a host's docker cp of it does, until
// the returned release (also called at the test's end).
func holdLifecycle(t *testing.T, ctx context.Context, s *dockerEngine, c *dockerContainer) (release func()) {
	t.Helper()
	held, err := s.lockContainerLifecycle(ctx, c)
	if err != nil || held == nil {
		t.Fatalf("hold %s's lifecycle: %v", c.Name, err)
	}
	var once sync.Once
	release = func() { once.Do(held) }
	t.Cleanup(release)
	return release
}

// left counts those of cs the engine still has.
func (s *dockerEngine) left(cs ...*dockerContainer) (n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range cs {
		if s.containers[c.ID] != nil {
			n++
		}
	}
	return n
}

// A child that cannot be reaped in time does not use up the others' time,
// and what a reaping leaves is reaped again later, not only at the next
// engine start: here a host's docker cp of one stopped child holds its
// lifecycle for longer than its deadline, and one of another for less.
func TestAReapingThatLeavesPartOfAFamilyLeavesTheRestTheirTimeAndTriesAgain(t *testing.T) {
	s, owner, child, _, _ := familyFixture(t)
	second := addChild(t, s, owner, 'e', "job-a-redis")
	oldTimeout, oldDelay := reapChildTimeout, reapRetryDelay
	reapChildTimeout, reapRetryDelay = time.Second, time.Second
	t.Cleanup(func() { reapChildTimeout, reapRetryDelay = oldTimeout, oldDelay })
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	time.AfterFunc(2500*time.Millisecond, holdLifecycle(t, ctx, s, child))
	time.AfterFunc(500*time.Millisecond, holdLifecycle(t, ctx, s, second))
	// remove answers when the first reaping is over.
	if err := s.remove(ctx, owner, true); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	childLeft, secondLeft := s.containers[child.ID] != nil, s.containers[second.ID] != nil
	s.mu.Unlock()
	if !childLeft || secondLeft {
		t.Fatalf("after the first reaping: the child held past its deadline left %v, the one held for less %v; want only the first", childLeft, secondLeft)
	}
	for s.left(child, second) != 0 {
		select {
		case <-ctx.Done():
			t.Fatal("what the first reaping left was never reaped again")
		case <-time.After(50 * time.Millisecond):
		}
	}
	if s.hasNetworkNamed("app_default") || hasVolume("app_pgdata") {
		t.Error("the family's network or volume outlived it")
	}
}

// Children of one family that cannot be reaped in time cost one child's
// deadline in all, not one each: an owner's removal, which answers once the
// first reaping is over, waits no longer for four of them than for one.
func TestStuckChildrenOfAFamilyCostOneDeadlineInAll(t *testing.T) {
	s, owner, child, _, _ := familyFixture(t)
	children := []*dockerContainer{child, addChild(t, s, owner, 'e', "job-a-redis"), addChild(t, s, owner, 'f', "job-a-kafka"),
		addChild(t, s, owner, '9', "job-a-minio")}
	oldTimeout, oldDelay := reapChildTimeout, reapRetryDelay
	reapChildTimeout, reapRetryDelay = time.Second, time.Second
	t.Cleanup(func() { reapChildTimeout, reapRetryDelay = oldTimeout, oldDelay })
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var releases []func()
	for _, c := range children {
		releases = append(releases, holdLifecycle(t, ctx, s, c))
	}

	start := time.Now()
	if err := s.remove(ctx, owner, true); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(start); took > 2*reapChildTimeout {
		t.Fatalf("the removal of an owner with %d stuck children answered after %v, want about one child's deadline (%v)", len(children), took, reapChildTimeout)
	}
	if n := s.left(children...); n != len(children) {
		t.Fatalf("the first reaping removed %d held children", len(children)-n)
	}
	for _, release := range releases {
		release()
	}
	for s.left(children...) != 0 {
		select {
		case <-ctx.Done():
			t.Fatal("what the first reaping left was never reaped again")
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// An engine start reaps a family whose owner it does not find, removed by an
// engine that stopped before it reaped, and leaves every other alone.
func TestEngineStartReapsAFamilyWithoutItsOwner(t *testing.T) {
	s, owner, child, other, otherChild := familyFixture(t)
	s.mu.Lock()
	delete(s.containers, owner.ID)
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	s.reapOrphanFamilies(ctx)
	s.mu.Lock()
	_, childLeft := s.containers[child.ID]
	_, otherLeft := s.containers[other.ID]
	_, otherChildLeft := s.containers[otherChild.ID]
	s.mu.Unlock()
	if childLeft || !otherLeft || !otherChildLeft {
		t.Fatalf("an orphaned child left %v; another job's %v and %v", childLeft, otherLeft, otherChildLeft)
	}
	if s.hasNetworkNamed("app_default") || hasVolume("app_pgdata") {
		t.Fatal("an orphaned family's network or volume outlived the engine start")
	}
	if !s.hasNetworkNamed("b_default") || !hasVolume("b_data") || !s.hasNetworkNamed("host-net") || !hasVolume("host_data") {
		t.Fatal("an engine start removed a live family's or the host's network or volume")
	}
}

// An engine start waits for the reaping of a family without its owner only
// orphanReapWait at most before it opens its socket: a child that cannot be
// reaped would take its whole deadline, longer than the start-up may take.
// The reaping goes on meanwhile and finishes once the child can go.
func TestEngineStartWaitsForAnOrphanedFamilyOnlySoLong(t *testing.T) {
	s, owner, child, other, _ := familyFixture(t)
	s.mu.Lock()
	delete(s.containers, owner.ID)
	s.mu.Unlock()
	oldTimeout, oldWait := reapChildTimeout, orphanReapWait
	reapChildTimeout, orphanReapWait = 20*time.Second, 300*time.Millisecond
	t.Cleanup(func() { reapChildTimeout, orphanReapWait = oldTimeout, oldWait })
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	time.AfterFunc(3*time.Second, holdLifecycle(t, ctx, s, child))

	start := time.Now()
	s.reapOrphanFamilies(ctx)
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("the engine start waited %v for an orphaned family whose child is held, want about %v", took, orphanReapWait)
	}
	if s.left(child) != 1 {
		t.Fatal("the held child was reaped while it was held")
	}
	for s.left(child) != 0 || s.hasNetworkNamed("app_default") || hasVolume("app_pgdata") {
		select {
		case <-ctx.Done():
			t.Fatal("the orphaned family was not reaped once its child could go")
		case <-time.After(50 * time.Millisecond):
		}
	}
	if s.left(other) != 1 || !s.hasNetworkNamed("b_default") || !hasVolume("b_data") {
		t.Fatal("the engine start removed a live family")
	}
}
