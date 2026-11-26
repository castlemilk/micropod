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
