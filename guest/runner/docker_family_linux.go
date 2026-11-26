package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// What a delegated socket's owner leaves behind.
//
// What a container created through its delegated socket (its family:
// containers, networks, volumes; docker_delegated_linux.go) is on no other
// container's socket, and no other family joins or mounts it through the
// host's. With its owner gone it is nobody's: the names it holds (a compose
// project's app_default, app_pgdata, app-db-1) fail every later job of that
// project (409, or 403 for a volume), no other job's socket can remove them,
// and a child still running keeps its binds below the owner's workspace. So
// a family goes with its owner: when the owner is removed its containers are
// stopped and removed, then the networks and volumes it created that nothing
// uses any more. An engine start does the same for every family whose owner
// it does not find (removed by an engine that stopped before it reaped).
// What a reaping cannot remove yet (a child a host's long docker cp holds, a
// stop or rootfs reclaim that failed, a network or volume such a child still
// uses) is reaped again a while later (retryReap).

// reapChildTimeout bounds the reaping of one child of a family, so that one
// that cannot be stopped or removed in time leaves every other child its own
// time. A family's children are reaped at once, so however many of them run
// out of time, they cost one reapChildTimeout in all: an owner's removal,
// which answers once its family's first reaping is over (awaitFamily), waits
// that long at most for them, as it did when one deadline bounded the whole
// family. A variable for tests.
var reapChildTimeout = 2 * time.Minute

// reapRetryDelay is how long after a reaping that left part of a family the
// engine reaps it again, doubling for each of reapRetries tries; what is left
// after them the next engine start reaps. A variable for tests.
var reapRetryDelay = 30 * time.Second

const reapRetries = 5

// orphanReapWait is how long an engine start waits, before it opens its
// socket, for the first reaping of the families whose owner is gone; what is
// still being reaped then goes on in the background, and is reaped again as
// any other (retryReap). A child that cannot be reaped takes a whole
// reapChildTimeout, longer than the engine's start-up may take
// (startupBudget). A variable for tests.
var orphanReapWait = 15 * time.Second

// ownsFamily reports whether c's removal reaps a family: a container the
// host created and granted a delegated socket.
func (c *dockerContainer) ownsFamily() bool { return c.CreatedBy == "" && c.EngineSocket }

// reapFamily removes what owner's delegated socket created, owner being gone.
func (s *dockerEngine) reapFamily(ctx context.Context, owner string) error {
	s.mu.Lock()
	var children []*dockerContainer
	for _, c := range s.containers {
		if c.CreatedBy == owner {
			children = append(children, c)
		}
	}
	s.mu.Unlock()
	errs := make([]error, len(children))
	var reaping sync.WaitGroup
	for i, c := range children {
		reaping.Go(func() {
			child, cancel := context.WithTimeout(ctx, reapChildTimeout)
			defer cancel()
			if err := s.reapChild(child, c); err != nil {
				errs[i] = fmt.Errorf("container %.12s: %w", c.ID, err)
			}
		})
	}
	reaping.Wait()
	s.mu.Lock()
	var networks []string
	for id, n := range s.namedNetworks {
		if n.CreatedBy == owner {
			networks = append(networks, id)
		}
	}
	s.mu.Unlock()
	for _, id := range networks {
		err := s.removeNetwork(id, func(n *workerNetwork) bool { return n.ID == id && n.CreatedBy == owner })
		var api apiError
		if err != nil && !(errors.As(err, &api) && api.code == 404) {
			errs = append(errs, fmt.Errorf("network %.12s: %w", id, err))
		}
	}
	s.mu.Lock()
	volumes, err := s.familyVolumesLocked(func(createdBy string) bool { return createdBy == owner })
	errs = append(errs, err)
	data := map[string]string{}
	for _, name := range volumes {
		var err error
		if data[name], err = s.removeVolumeLocked(name); err != nil {
			errs = append(errs, fmt.Errorf("volume %s: %w", name, err))
		}
	}
	s.mu.Unlock()
	// The names are free; their data goes without the engine's lock.
	for name, d := range data {
		if err := discardVolumeData(d); err != nil {
			errs = append(errs, fmt.Errorf("volume %s: %w", name, err))
		}
	}
	return errors.Join(errs...)
}

// retryReap reaps owner's family again while its last reaping failed with
// err (nil: nothing to do), reapRetryDelay after it and then twice as long
// each time, until it succeeds, ctx ends or reapRetries tries are spent.
func (s *dockerEngine) retryReap(ctx context.Context, owner string, err error) {
	delay := reapRetryDelay
	for try := 0; err != nil && try < reapRetries; try++ {
		log.Printf("remove what the Docker socket of %.12s created: %v (again in %v)", owner, err, delay)
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
		delay *= 2
		err = s.reapFamily(ctx, owner)
	}
	if err != nil {
		log.Printf("remove what the Docker socket of %.12s created: %v (left to the next engine start)", owner, err)
	}
}

// reapChild stops and removes c, a child of a family being reaped. A kill
// comes first: a request through the owner's socket, still in flight, may
// hold c's lifecycle for as long as c runs (a stop with a long timeout).
func (s *dockerEngine) reapChild(ctx context.Context, c *dockerContainer) error {
	if err := s.stop(ctx, c, 0, ""); err != nil {
		return err
	}
	release, err := s.lockContainerLifecycle(ctx, c)
	var api apiError
	if errors.As(err, &api) && api.code == 404 {
		return nil // removed meanwhile
	}
	if err != nil {
		return err
	}
	if release != nil {
		defer release()
	}
	return s.remove(ctx, c, true)
}

// familyVolumesLocked are the named volumes whose creator is one of those
// created reports. Call with s.mu held.
func (s *dockerEngine) familyVolumesLocked(created func(createdBy string) bool) ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(volumeStore, "volumes"))
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if _, shared := sharedCachePath(e.Name()); !e.IsDir() || shared || !dockerName.MatchString(e.Name()) {
			continue
		}
		if v, err := inspectVolume(e.Name()); err == nil && v.createdBy != "" && created(v.createdBy) {
			names = append(names, e.Name())
		}
	}
	return names, nil
}

// reapOrphanFamilies reaps every family whose owner the engine does not have:
// one removed by an engine that stopped before it reaped. Call once recovery
// has loaded every container, before the socket opens. It reaps the families
// at once and returns when their first reapings are over, or after
// orphanReapWait with those still running left to go on.
func (s *dockerEngine) reapOrphanFamilies(ctx context.Context) {
	s.mu.Lock()
	orphans := map[string]bool{}
	gone := func(owner string) bool { return owner != "" && s.containers[owner] == nil }
	for _, c := range s.containers {
		if gone(c.CreatedBy) {
			orphans[c.CreatedBy] = true
		}
	}
	for _, n := range s.namedNetworks {
		if gone(n.CreatedBy) {
			orphans[n.CreatedBy] = true
		}
	}
	volumes, err := s.familyVolumesLocked(gone)
	for _, name := range volumes {
		if v, err := inspectVolume(name); err == nil {
			orphans[v.createdBy] = true
		}
	}
	s.mu.Unlock()
	if err != nil {
		log.Printf("find the volumes of removed Docker sockets: %v", err)
	}
	var first sync.WaitGroup
	for owner := range orphans {
		first.Add(1)
		go func() {
			err := s.reapFamily(ctx, owner)
			first.Done()
			s.retryReap(ctx, owner, err)
		}()
	}
	reaped := make(chan struct{})
	go func() {
		first.Wait()
		close(reaped)
	}()
	select {
	case <-reaped:
	case <-ctx.Done():
	case <-time.After(orphanReapWait):
		log.Printf("what the Docker sockets of removed containers created is still being removed after %v; the engine opens its socket meanwhile", orphanReapWait)
	}
}
