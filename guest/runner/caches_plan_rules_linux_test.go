package main

import (
	"path/filepath"
	"testing"
)

// Plans an older engine or an older table made, brought to the rules this
// engine applies at start.

// A plan the untrusted default demoted (an older engine's) is trusted again
// once the policy trusts by default, with the table's exclusive kinds; every
// start takes the table's exclusive kinds, so a plan made before maven was
// exclusive asks for its writer slot, and a reader's never does.
func TestCachePlansFollowTheCurrentRulesAtStart(t *testing.T) {
	legacy := cachePlan{Scope: "default", Stores: []cacheStoreRef{{Kind: "maven", Unit: "maven"}, {Kind: "gomod", Unit: "gomod"}}}
	legacy.applyCurrentRules(untrustedPolicy())
	if !legacy.ReadOnly || legacy.TrustFrom != trustFromLegacy || legacy.Stores[0].Exclusive {
		t.Fatalf("demoted %+v", legacy)
	}
	legacy.applyCurrentRules(defaultCachePolicy())
	if legacy.ReadOnly || legacy.Trust != "" || legacy.TrustFrom != "" || !legacy.Stores[0].Exclusive || legacy.Stores[1].Exclusive {
		t.Fatalf("switched back to trusted: %+v", legacy)
	}
	// Demoted again by the next untrusted start, never stuck.
	legacy.applyCurrentRules(untrustedPolicy())
	if !legacy.ReadOnly {
		t.Fatal("not demoted again")
	}
	// A plan this engine made keeps its tier; only Exclusive follows the table.
	made := cachePlan{Scope: "default", TrustFrom: trustFromPolicy, Stores: []cacheStoreRef{{Kind: "maven", Unit: "maven"}}}
	shared := made.Stores
	made.applyCurrentRules(untrustedPolicy())
	if made.ReadOnly || !made.Stores[0].Exclusive || shared[0].Exclusive {
		t.Fatalf("trusted plan %+v (shared slice %+v)", made, shared)
	}
	reader := cachePlan{Scope: "default", Trust: trustUntrusted, TrustFrom: trustFromLabel, ReadOnly: true, Stores: []cacheStoreRef{{Kind: "maven", Unit: "maven", Exclusive: true}}}
	reader.applyCurrentRules(defaultCachePolicy())
	if !reader.ReadOnly || reader.Stores[0].Exclusive {
		t.Fatalf("reader %+v", reader)
	}
}

// A plan an engine before the sharing rule made keeps a tool that does not
// verify its store in scope "global"; a start leaves that tool out instead of
// sharing its store across projects, and keeps the verified ones.
func TestCacheRetiredGlobalShareIsLeftOut(t *testing.T) {
	useFence(t, "boot-a")
	plan := cachePlan{Scope: "proj-a", TrustFrom: trustFromPolicy, Tools: map[string]cacheToolState{
		"gomod": {Mode: "env", Path: cacheMountL0Root + "/gomod", Scope: cacheL0GlobalScope},
		"pip":   {Mode: "env", Path: cacheMountL0Root + "/pip/u0", Scope: cacheL0GlobalScope},
	},
		Stores:  []cacheStoreRef{{Scope: cacheL0GlobalScope, Kind: "gomod", Unit: "gomod"}, {Scope: cacheL0GlobalScope, Kind: "pip", Unit: "pip.u0", UID: new(uint32)}},
		Mounts:  []cacheMount{{Scope: cacheL0GlobalScope, Target: cacheMountL0Root}},
		ToolEnv: map[string][]string{"gomod": {"GOMODCACHE=" + cacheMountL0Root + "/gomod"}, "pip": {"PIP_CACHE_DIR=" + cacheMountL0Root + "/pip/u0"}},
		Env:     []string{"GOMODCACHE=" + cacheMountL0Root + "/gomod", "PIP_CACHE_DIR=" + cacheMountL0Root + "/pip/u0"},
	}
	a := openCacheMounts(&plan, "")
	defer a.close()
	if a.skipped["pip"] != skipRetiredShare || a.skipped["gomod"] != "" {
		t.Fatalf("skipped %v", a.skipped)
	}
	if _, set := envLookup(a.env, "PIP_CACHE_DIR", false); set {
		t.Fatalf("PIP_CACHE_DIR kept: %v", a.env)
	}
	if exists(filepath.Join(cacheRoot, "scopes/global/pip")) || !exists(filepath.Join(cacheRoot, "scopes/global/gomod")) {
		t.Fatal("stores")
	}
}
