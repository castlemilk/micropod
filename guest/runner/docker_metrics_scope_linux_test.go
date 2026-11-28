package main

import (
	"fmt"
	"reflect"
	"testing"
)

// Skips are counted per reason and, where the store left out has a scope,
// per scope too: a tool's own store scope wins over the plan's, a skip with
// no scope is only in the total, and past maxSkipScopes scopes the rest share
// otherSkipScope.
func TestCacheSkipsAreCountedByScope(t *testing.T) {
	var m cacheMetrics
	m.recordPlan(&cachePlan{Scope: "cf-a", Tools: map[string]cacheToolState{
		"gobuild": {Mode: "skipped", Reason: skipNoStore},
		"gomod":   {Mode: "skipped", Reason: skipNoStore, Scope: cacheL0GlobalScope},
		"pip":     {Mode: "skipped", Reason: skipNotSelected},
		"npm":     {Mode: "env"},
	}})
	m.recordPlan(&cachePlan{Reason: planNoScope})
	m.recordPlan(&cachePlan{Scope: "cf-b", Reason: planPolicyOff})
	plan := &cachePlan{Scope: "cf-a", Stores: []cacheStoreRef{{Kind: "gobuild"}, {Kind: "gomod", Scope: cacheL0GlobalScope}}}
	m.skip(plan.storeScope("gobuild"), skipBusyExclusive)
	m.skip(plan.storeScope("gomod"), skipStoreFailed)
	m.skip(plan.storeScope("cargo"), skipStoreFailed)
	m.skip("", skipNoCacheDisk)

	snap := m.snapshot()
	wantTotal := map[string]uint64{skipNoStore: 2, planNoScope: 1, planPolicyOff: 1, skipBusyExclusive: 1, skipStoreFailed: 2, skipNoCacheDisk: 1}
	if got := snap["cache_skip"]; !reflect.DeepEqual(got, wantTotal) {
		t.Fatalf("cache_skip %v, want %v", got, wantTotal)
	}
	wantScope := map[string]map[string]uint64{
		"cf-a":             {skipNoStore: 1, skipBusyExclusive: 1, skipStoreFailed: 1},
		cacheL0GlobalScope: {skipNoStore: 1, skipStoreFailed: 1},
		"cf-b":             {planPolicyOff: 1},
	}
	if got := snap["cache_skip_by_scope"]; !reflect.DeepEqual(got, wantScope) {
		t.Fatalf("cache_skip_by_scope %v, want %v", got, wantScope)
	}
	if got := snap["cache_attach"]; !reflect.DeepEqual(got, map[string]uint64{"npm": 1}) {
		t.Fatalf("cache_attach %v", got)
	}

	// The snapshot is a copy.
	snap["cache_skip_by_scope"].(map[string]map[string]uint64)["cf-a"][skipNoStore] = 99
	if m.skipsByScope["cf-a"][skipNoStore] != 1 {
		t.Fatal("the snapshot shares its maps with the counters")
	}

	var many cacheMetrics
	for i := range maxSkipScopes + 5 {
		many.skip(fmt.Sprintf("s%d", i), skipNoStore)
	}
	many.skip("s0", skipNoStore)
	byScope := many.snapshot()["cache_skip_by_scope"].(map[string]map[string]uint64)
	if len(byScope) != maxSkipScopes+1 || byScope[otherSkipScope][skipNoStore] != 5 || byScope["s0"][skipNoStore] != 2 {
		t.Fatalf("%d scopes, other %v, s0 %v", len(byScope), byScope[otherSkipScope], byScope["s0"])
	}
}
