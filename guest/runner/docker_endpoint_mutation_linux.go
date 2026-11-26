package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// The BridgeGeneration field records the owned pod before configuring the
// named primary address or publishing ports. Only pod retirement retires it.
type dockerBridgeGeneration struct{ JobID, PodID string }

func (g *dockerBridgeGeneration) valid() bool {
	return jobID.MatchString(g.JobID) && fullContainerID.MatchString(g.PodID)
}

type dockerBridgeOperations interface {
	attach(context.Context, *workerNetwork, string) (string, error)
	detach(*workerNetwork) error
	close() error
	setDNSNetworks([]*workerNetwork)
}

// The catalog protects all fields. bridgeOps fences the data plane and its
// retirement from concurrent network mutations without holding the catalog lock.
type dockerRunningBridge struct {
	sandbox    dockerBridgeOperations
	generation dockerBridgeGeneration
	active     map[string]string // Network ID to live peer MAC.
	pending    *dockerSecondaryEndpoint
	retiring   bool
	uncertain  bool
}

const dockerEndpointTimeout = 10 * time.Second

func unsupportedDockerSecondaryNetwork() error {
	return fail(http.StatusNotImplemented, "secondary attachments require named IPv4 bridge networks on a native worker")
}

func (s *dockerEngine) mutateDockerNetwork(w http.ResponseWriter, r *http.Request, key string, connect bool) error {
	name, options, err := readDockerNetworkMutation(w, r, connect)
	if err != nil {
		return err
	}
	c, err := s.lookupFor(r.Context(), strings.TrimPrefix(name, "/"))
	if err != nil {
		return err
	}
	if viewer := viewerOf(r.Context()); viewer != "" {
		s.mu.Lock()
		n, err := s.findNetwork(key, false)
		visible := err == nil && n != nil && s.seesNetworkLocked(viewer, n)
		s.mu.Unlock()
		if !visible {
			return fail(http.StatusNotFound, "no such network: "+key)
		}
	}
	release, err := s.lockContainerLifecycle(r.Context(), c)
	if err != nil {
		return err
	}
	if release != nil {
		defer release()
	}
	if err := s.changeDockerNetwork(r.Context(), c, c.dir(), key, options, connect); err != nil {
		return err
	}
	w.WriteHeader(http.StatusOK)
	return nil
}

func (s *dockerEngine) changeDockerNetwork(ctx context.Context, c *dockerContainer, dir, key string, options dockerEndpointOptions, connect bool) error {
	c.bridgeOps.Lock()
	defer c.bridgeOps.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if c.removed || c.Phase == "removing" || s.containers[c.ID] != c {
		return fail(http.StatusNotFound, "container removed")
	}
	if c.Phase != "created" && c.Phase != "running" && c.Phase != "exited" {
		return fail(http.StatusConflict, "container network is unavailable during this lifecycle state")
	}
	if builtinDockerNetwork(key) != "" || !s.namedNetworks[c.NetworkID].secondaryBridge() {
		return unsupportedDockerSecondaryNetwork()
	}
	n, err := s.findNetwork(key, false)
	if err != nil {
		return err
	}
	if n == nil {
		return fail(http.StatusNotFound, "no such network: "+key)
	}
	if !n.secondaryBridge() {
		return unsupportedDockerSecondaryNetwork()
	}
	if options.NetworkID != "" && options.NetworkID != n.ID {
		return fail(http.StatusBadRequest, "endpoint network identity differs")
	}
	if n.ID == c.NetworkID {
		if connect {
			return dockerNetworkEndpointConflict(c, n)
		}
		return fail(http.StatusNotImplemented, "disconnecting the primary network is unavailable")
	}
	b := c.bridge
	if c.Phase == "running" && (b == nil || b.retiring || b.uncertain || c.BridgeGeneration == nil || *c.BridgeGeneration != b.generation) {
		return fail(http.StatusConflict, "container network is retiring or needs recovery")
	}
	if c.Phase != "running" && c.BridgeGeneration != nil {
		return fail(http.StatusConflict, "previous named network sandbox needs worker recovery")
	}
	index := c.secondaryEndpoint(n.ID)
	if connect {
		return s.connectDockerSecondaryLocked(ctx, c, b, dir, n, options.Aliases, index)
	}
	if index < 0 {
		return fail(http.StatusConflict, "container is not connected to network "+n.Name)
	}
	return s.disconnectDockerSecondaryLocked(ctx, c, b, dir, n, index)
}

// A late directory sync failure can follow a successful rename. Keep the live
// catalog aligned with whichever state is visible and return the sync error.
func (c *dockerContainer) commitDockerBridge(dir string, generation *dockerBridgeGeneration, endpoints []dockerSecondaryEndpoint) (bool, error) {
	record := c.dockerRecord
	record.BridgeGeneration = generation
	record.SecondaryNetworks = endpoints
	visible, err := record.commitIn(dir)
	if visible {
		c.BridgeGeneration, c.SecondaryNetworks = generation, endpoints
	}
	return visible, err
}

// Called with the catalog locked, before moving the primary interface or
// creating port forwards. A failed teardown still owns the primary address.
func (c *dockerContainer) claimDockerNetworkPod(dir string, pod ownedPod) error {
	generation := dockerBridgeGeneration{JobID: pod.id, PodID: pod.pod}
	if !generation.valid() || c.NetworkID == "" || c.BridgeGeneration != nil {
		return errors.New("cannot record the named network sandbox generation")
	}
	_, err := c.commitDockerBridge(dir, &generation, c.SecondaryNetworks)
	return err
}

func (c *dockerContainer) recoverDockerNetworkPod(ctx context.Context, dir string, remove func(context.Context, string, string) error) error {
	generation := c.BridgeGeneration
	if generation == nil {
		return nil
	}
	if err := remove(ctx, generation.JobID, generation.PodID); err != nil {
		return err
	}
	_, err := c.commitDockerBridge(dir, nil, c.SecondaryNetworks)
	return err
}

func (s *dockerEngine) connectDockerSecondaryLocked(ctx context.Context, c *dockerContainer, bridge *dockerRunningBridge, dir string, n *workerNetwork, aliases []string, index int) error {
	next := slices.Clone(c.SecondaryNetworks)
	if index >= 0 {
		if bridge != nil {
			return dockerNetworkEndpointConflict(c, n)
		}
		// Like Docker, setting stopped endpoint options updates the same logical
		// membership. Keep its allocation and identity until the next start.
		next[index].Aliases = aliases
		_, err := c.commitDockerBridge(dir, nil, next)
		return err
	}
	endpoint, err := s.allocateDockerEndpoint(n, aliases)
	if err != nil {
		return err
	}
	next = append(next, endpoint)
	if bridge == nil {
		_, err := c.commitDockerBridge(dir, nil, next)
		return err
	}
	bridge.pending = &endpoint
	s.mu.Unlock()
	attachCtx, cancel := context.WithTimeout(ctx, dockerEndpointTimeout)
	mac, attachErr := bridge.sandbox.attach(attachCtx, n, endpoint.IP)
	cancel()
	s.mu.Lock()
	if attachErr != nil {
		if errors.Is(attachErr, errDockerBridgeCleanup) {
			s.mu.Unlock()
			rollback := bridge.sandbox.detach(n)
			s.mu.Lock()
			if rollback != nil {
				bridge.uncertain = true
				return errors.Join(attachErr, rollback)
			}
		}
		bridge.pending = nil
		return attachErr
	}
	visible, err := c.commitDockerBridge(dir, c.BridgeGeneration, next)
	if visible {
		bridge.pending = nil
		bridge.active[n.ID] = mac
		n.services.publishEndpoint(c.Name, c.Config.Hostname, endpoint.Aliases, endpoint.IP, true)
		s.updateDockerBridgeDNS(c)
		return err
	}
	s.mu.Unlock()
	rollback := bridge.sandbox.detach(n)
	s.mu.Lock()
	if rollback == nil {
		bridge.pending = nil
	} else {
		bridge.uncertain = true
	}
	return errors.Join(err, rollback)
}

func dockerNetworkEndpointConflict(c *dockerContainer, n *workerNetwork) error {
	return fail(http.StatusForbidden, fmt.Sprintf("endpoint with name %s already exists in network %s", c.Name, n.Name))
}

func (s *dockerEngine) disconnectDockerSecondaryLocked(ctx context.Context, c *dockerContainer, bridge *dockerRunningBridge, dir string, n *workerNetwork, index int) error {
	next := slices.Delete(slices.Clone(c.SecondaryNetworks), index, index+1)
	if bridge == nil {
		_, err := c.commitDockerBridge(dir, nil, next)
		return err
	}
	endpoint := c.SecondaryNetworks[index]
	s.mu.Unlock()
	detachErr := bridge.sandbox.detach(n)
	s.mu.Lock()
	if detachErr != nil {
		if errors.Is(detachErr, errDockerBridgeCleanup) {
			s.unpublishDockerSecondary(c, n, endpoint)
			bridge.uncertain = true
		}
		return detachErr
	}
	visible, err := c.commitDockerBridge(dir, c.BridgeGeneration, next)
	if visible {
		s.unpublishDockerSecondary(c, n, endpoint)
		return err
	}
	s.mu.Unlock()
	rollbackCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), dockerEndpointTimeout)
	mac, rollback := bridge.sandbox.attach(rollbackCtx, n, endpoint.IP)
	cancel()
	s.mu.Lock()
	if rollback == nil {
		bridge.active[n.ID] = mac
	} else {
		s.unpublishDockerSecondary(c, n, endpoint)
		bridge.uncertain = true
	}
	return errors.Join(err, rollback)
}

func (s *dockerEngine) unpublishDockerSecondary(c *dockerContainer, n *workerNetwork, endpoint dockerSecondaryEndpoint) {
	delete(c.bridge.active, n.ID)
	n.services.publishEndpoint(c.Name, c.Config.Hostname, endpoint.Aliases, endpoint.IP, false)
	s.updateDockerBridgeDNS(c)
}

func (s *dockerEngine) updateDockerBridgeDNS(c *dockerContainer) {
	bridge := c.bridge
	networks := []*workerNetwork{s.namedNetworks[c.NetworkID]}
	for _, endpoint := range c.SecondaryNetworks {
		if _, active := bridge.active[endpoint.NetworkID]; active {
			networks = append(networks, s.namedNetworks[endpoint.NetworkID])
		}
	}
	bridge.sandbox.setDNSNetworks(networks)
}

func (s *dockerEngine) configureDockerBridge(ctx context.Context, c *dockerContainer, pod ownedPod) (string, error) {
	if c.NetworkID == "" {
		return "", nil
	}
	s.mu.Lock()
	primary := s.namedNetworks[c.NetworkID]
	eligible := primary.secondaryBridge()
	generation := c.BridgeGeneration
	s.mu.Unlock()
	if primary == nil {
		return "", errors.New("container network no longer exists")
	}
	if !eligible {
		return filepath.Join(primary.dir(), "resolv.conf"), nil
	}
	if generation == nil || generation.JobID != pod.id || generation.PodID != pod.pod {
		return "", errors.New("bridge namespace differs from the recorded sandbox")
	}
	bridge, err := s.openDockerBridgeSandbox(ctx, pod.pod, primary)
	if err != nil {
		return "", err
	}
	active := &dockerRunningBridge{sandbox: bridge, generation: *generation, active: make(map[string]string)}
	s.mu.Lock()
	c.bridge = active
	endpoints := c.SecondaryNetworks
	s.mu.Unlock()
	for _, endpoint := range endpoints {
		s.mu.Lock()
		n := s.namedNetworks[endpoint.NetworkID]
		eligible := n.secondaryBridge()
		s.mu.Unlock()
		if !eligible {
			return "", errors.New("secondary bridge no longer exists")
		}
		mac, err := bridge.attach(ctx, n, endpoint.IP)
		if err != nil {
			return "", fmt.Errorf("attach secondary bridge %s: %w", n.Name, err)
		}
		s.mu.Lock()
		active.active[endpoint.NetworkID] = mac
		s.mu.Unlock()
	}
	s.mu.Lock()
	s.updateDockerBridgeDNS(c)
	s.mu.Unlock()
	return dockerBridgeResolverPath, nil
}

func (s *dockerEngine) publishDockerBridgeNames(c *dockerContainer, add bool) {
	if n := s.namedNetworks[c.NetworkID]; n != nil {
		n.services.publish(c, add)
	}
	if c.bridge == nil {
		return
	}
	for _, endpoint := range c.SecondaryNetworks {
		if _, active := c.bridge.active[endpoint.NetworkID]; active {
			n := s.namedNetworks[endpoint.NetworkID]
			n.services.publishEndpoint(c.Name, c.Config.Hostname, endpoint.Aliases, endpoint.IP, add)
		}
	}
}

func (s *dockerEngine) retireDockerBridge(c *dockerContainer) error {
	c.bridgeOps.Lock()
	defer c.bridgeOps.Unlock()
	s.mu.Lock()
	b := c.bridge
	if b == nil {
		s.mu.Unlock()
		return nil
	}
	b.retiring = true
	s.publishDockerBridgeNames(c, false)
	s.mu.Unlock()
	if err := b.sandbox.close(); err != nil {
		return err
	}
	// The extra veth pairs are gone. The primary still belongs to CRI until
	// both port retirement and pod cleanup are acknowledged.
	s.mu.Lock()
	c.bridge = nil
	s.mu.Unlock()
	return nil
}

// The committed addresses survive stopped pods and are released by logical
// detach or deletion. This acknowledges retirement of their live owner.
func (s *dockerEngine) acknowledgeDockerPodRetirement(c *dockerContainer) {
	s.mu.Lock()
	c.bridge, c.BridgeGeneration = nil, nil
	s.mu.Unlock()
}
