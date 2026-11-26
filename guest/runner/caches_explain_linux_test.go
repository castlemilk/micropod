package main

import (
	"encoding/json"
	"testing"
)

// docker inspect's MicropodCache names the policy digest the plan was decided
// under, which the host's `cache explain` (REST, CLI and MCP) reports: the
// digest at create, kept across an engine restart (the record's JSON) and not
// rewritten by a policy hot-applied later.
func TestInspectNamesThePolicyDigestThePlanWasDecidedUnder(t *testing.T) {
	pol := defaultCachePolicy()
	pol.DefaultTrust = trustUntrusted
	plan := decide(t, pol, dockerConfig{}, testFacts(golangEnv, nil, "go"))
	if plan.PolicyDigest == "" || plan.PolicyDigest != pol.digest() {
		t.Fatalf("plan digest %q, policy digest %q", plan.PolicyDigest, pol.digest())
	}
	inspectCache := func(c *dockerContainer) map[string]any {
		t.Helper()
		// Through JSON, as the host reads it off the socket.
		b, err := json.Marshal(c.inspect())
		if err != nil {
			t.Fatal(err)
		}
		var v struct {
			MicropodCache map[string]any
		}
		if err := json.Unmarshal(b, &v); err != nil || v.MicropodCache == nil {
			t.Fatalf("inspect %s: %v", b, err)
		}
		return v.MicropodCache
	}
	c := &dockerContainer{dockerRecord: dockerRecord{ID: "x", Name: "h-untrusted", Cache: &plan}}
	if mc := inspectCache(c); mc["policyDigest"] != pol.digest() || mc["trust"] != trustUntrusted || mc["trustFrom"] != "policy-default" {
		t.Fatalf("inspect MicropodCache %v, want policyDigest %s", mc, pol.digest())
	}

	// An engine restart reads the record back with the same digest.
	b, err := json.Marshal(c.dockerRecord)
	if err != nil {
		t.Fatal(err)
	}
	var back dockerRecord
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	c = &dockerContainer{dockerRecord: back}
	// A policy applied after the create is the next container's, not this one's.
	later := defaultCachePolicy()
	if later.digest() == pol.digest() {
		t.Fatal("the two policies must differ")
	}
	c.Cache.applyCurrentRules(later)
	if mc := inspectCache(c); mc["policyDigest"] != pol.digest() {
		t.Fatalf("after a restart and a later policy: policyDigest %v, want %s", mc["policyDigest"], pol.digest())
	}

	// A plan an engine before digests recorded has none: the key is absent, never "".
	old := &dockerContainer{dockerRecord: dockerRecord{ID: "y", Cache: &cachePlan{Scope: "default", Tools: map[string]cacheToolState{}}}}
	if mc := inspectCache(old); mc["policyDigest"] != nil {
		t.Fatalf("a plan without a digest: %v", mc)
	}
}
