package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// What the request's environment may decide, the scope a reader reads,
// and what the policy is where the host config share cannot be read.

// The request's environment is the job's own (an orchestrator passes a job's
// env: block through to the containers it creates): MICROPOD_CACHE_TRUST
// there lowers a tier but never raises one, and under an untrusted default
// MICROPOD_CACHE_SCOPE names no scope. Labels, the host's statement on the
// host-facing socket, still do both.
func TestCacheEnvironmentNeverRaisesTrustOrPicksAReadersScope(t *testing.T) {
	facts := testFacts(golangEnv, nil)
	envClaim := dockerConfig{Env: []string{"MICROPOD_CACHE_TRUST=trusted"}}
	p := decide(t, untrustedPolicy(), envClaim, facts)
	requireReader(t, p, trustUntrusted, trustFromRefused)
	// The label claim on the host-facing socket is the scheduler's.
	requireWriter(t, decide(t, untrustedPolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache.trust": "trusted"}}, facts), trustFromLabel)
	// An empty label falls back to the environment, which still cannot raise.
	emptyLabel := dockerConfig{Labels: map[string]string{"io.micropod.cache.trust": ""}, Env: envClaim.Env}
	requireReader(t, decide(t, untrustedPolicy(), emptyLabel, facts), trustUntrusted, trustFromRefused)
	// Under the shipped default the claim changes nothing; lowering works.
	requireWriter(t, decide(t, defaultCachePolicy(), envClaim, facts), trustFromLabel)
	requireReader(t, decide(t, defaultCachePolicy(), dockerConfig{Env: []string{"MICROPOD_CACHE_TRUST=untrusted"}}, facts), trustUntrusted, trustFromLabel)
	requireReader(t, decide(t, defaultCachePolicy(), dockerConfig{Env: []string{"MICROPOD_CACHE_READONLY=1"}}, facts), trustReadOnly, trustFromLabel)

	other := dockerConfig{Env: []string{"MICROPOD_CACHE_SCOPE=proj-b"}}
	if p := decide(t, untrustedPolicy(), other, facts); p.Scope != "default" {
		t.Fatalf("an unlabeled reader picked scope %q from its environment", p.Scope)
	}
	if p := decide(t, untrustedPolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": "proj-b"}}, facts); p.Scope != "proj-b" {
		t.Fatalf("the scope label: %q", p.Scope)
	}
	if p := decide(t, defaultCachePolicy(), other, facts); p.Scope != "proj-b" {
		t.Fatalf("env-only clients under the shipped default: %q", p.Scope)
	}
	if containerScope(untrustedPolicy(), other) != "default" || containerScope(defaultCachePolicy(), other) != "proj-b" {
		t.Fatal("containerScope")
	}
}

// A reader mounts no alias volume of another scope than its own (the one its
// label names, else the policy default), whatever the allow-list admits;
// sharedL0's global store of a verified kind stays readable to it.
func TestCacheReaderAliasVolumesStayInItsScope(t *testing.T) {
	pol := untrustedPolicy()
	facts := testFacts(golangEnv, nil)
	eng := &dockerEngine{workspace: t.TempDir()}
	reader := dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": "team-a"}}
	plan := decide(t, pol, reader, facts)
	for _, bind := range []string{
		"micropod-ci-scoped-team-b-gomod:/go/pkg/mod:ro",
		"micropod-ci-scoped-default-gomod:/go/pkg/mod:ro",
		"micropod-ci-scoped-global-gomod:/go/pkg/mod:ro",
	} {
		spec := reader
		spec.HostConfig = dockerHost{Binds: []string{bind}}
		for _, create := range []bool{true, false} {
			_, _, _, err := eng.openMounts(spec, volumeRules(pol, spec, &plan), create, "", t.TempDir())
			var api apiError
			if !errors.As(err, &api) || api.code != 400 || !strings.Contains(err.Error(), "its own scope") {
				t.Fatalf("%s (create %v): %v", bind, create, err)
			}
		}
	}
	rules := volumeRules(pol, reader, &plan)
	if !rules.readOnly || rules.scope != "team-a" || !rules.readerMay("team-a", "gobuild") || rules.readerMay("team-b", "gomod") {
		t.Fatalf("rules %+v", rules)
	}
	shared := pol
	shared.SharedL0 = true
	rules = volumeRules(shared, reader, &plan)
	if !rules.readerMay(cacheL0GlobalScope, "gomod") || rules.readerMay(cacheL0GlobalScope, "maven") {
		t.Fatal("sharedL0's global stores")
	}
	// An unlabeled reader's own scope is the policy default; a writer's
	// alias volumes follow the allow-list alone.
	if r := volumeRules(pol, dockerConfig{}, &cachePlan{Trust: trustUntrusted, TrustFrom: trustFromPolicy, ReadOnly: true}); r.scope != "default" || !r.readOnly {
		t.Fatalf("unlabeled reader %+v", r)
	}
	writer := decide(t, defaultCachePolicy(), dockerConfig{}, facts)
	if r := volumeRules(defaultCachePolicy(), dockerConfig{}, &writer); r.readOnly {
		t.Fatalf("writer %+v", r)
	}
}

// Where the host asked for its config share, the policy fails closed when the
// share did not mount or the file is missing, and an error reading a file
// that was there keeps the last policy read. Without a share the file is
// optional, as before.
func TestCachePolicyFailsClosedOnTheHostConfigShare(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good")
	if err := os.Mkdir(good, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(good, "cache-policy.json"), []byte(`{"defaultTrust":"untrusted","defaultScope":"rig"}`), 0644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "share")
	if err := os.Symlink(good, link); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(link, "cache-policy.json")
	missing := filepath.Join(dir, "absent.json")

	if (&policyLoader{path: missing}).get().untrustedByDefault() {
		t.Fatal("no share asked for: a missing file is the shipped default")
	}
	if !(&policyLoader{path: missing, share: hostConfigMounted}).get().untrustedByDefault() {
		t.Fatal("a missing file on the mounted share trusts unlabeled containers")
	}
	if !(&policyLoader{path: file, share: hostConfigUnavailable}).get().untrustedByDefault() {
		t.Fatal("a share that did not mount trusts unlabeled containers")
	}
	l := &policyLoader{path: file, share: hostConfigMounted}
	if pol := l.get(); !pol.untrustedByDefault() || pol.DefaultScope != "rig" {
		t.Fatalf("read %+v", pol)
	}
	// The share's directory now resolves to a file: ENOTDIR, not a policy.
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(good, "cache-policy.json"), link); err != nil {
		t.Fatal(err)
	}
	l.checked = time.Time{}
	if pol := l.get(); !pol.untrustedByDefault() || pol.DefaultScope != "rig" {
		t.Fatalf("an unreadable policy replaced the last one read: %+v", pol)
	}
	// Gone for good: fail closed, not the defaults.
	l.path, l.checked = missing, time.Time{}
	if pol := l.get(); !pol.untrustedByDefault() || pol.DefaultScope != "default" {
		t.Fatalf("missing after a good read: %+v", pol)
	}
	// Without a share an unreadable path is still the shipped default.
	if (&policyLoader{path: filepath.Join(good, "cache-policy.json", "x")}).get().untrustedByDefault() {
		t.Fatal("no share: an unreadable path")
	}
}

// A child of a delegated socket is in its creator's cache scope: naming
// another is refused, naming none is the creator's, and its alias volumes
// follow it even with caches off.
func TestDelegatedChildStaysInItsCreatorsScope(t *testing.T) {
	facts := testFacts(golangEnv, nil)
	req := cacheRequest{origin: cacheOrigin{creator: "c0ffee", creatorTier: trustTrusted, creatorScope: "proj-a"}}
	named := func(scope string, extra ...string) dockerConfig {
		labels := map[string]string{"io.micropod.cache.scope": scope}
		for i := 0; i+1 < len(extra); i += 2 {
			labels[extra[i]] = extra[i+1]
		}
		return dockerConfig{Image: "golang:1", Labels: labels}
	}
	for _, spec := range []dockerConfig{named("proj-b"), named("proj-b", "io.micropod.cache", "off"),
		{Image: "golang:1", Env: []string{"MICROPOD_CACHE_SCOPE=proj-b"}}} {
		_, err := decideCachesFor(defaultCachePolicy(), spec, facts, req)
		var api apiError
		if !errors.As(err, &api) || api.code != 403 {
			t.Errorf("%v %v: %v, want 403", spec.Labels, spec.Env, err)
		}
	}
	for _, spec := range []dockerConfig{{Image: "golang:1"}, named("proj-a")} {
		p, err := decideCachesFor(defaultCachePolicy(), spec, facts, req)
		if err != nil || p.Scope != "proj-a" {
			t.Errorf("%v: scope %q %v, want the creator's", spec.Labels, p.Scope, err)
		}
	}
	// Off, the plan still names the creator's scope, which alias volumes follow.
	off := dockerConfig{Image: "golang:1", Labels: map[string]string{"io.micropod.cache": "off"},
		HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-proj-b-gomod:/go/pkg/mod:ro"}}}
	p, err := decideCachesFor(defaultCachePolicy(), off, facts, req)
	if err != nil || p.Scope != "proj-a" {
		t.Fatalf("off: %q %v", p.Scope, err)
	}
	if rules := volumeRules(defaultCachePolicy(), off, &p); rules.readerMay("proj-b", "gomod") || !rules.readerMay("proj-a", "gomod") {
		t.Fatalf("alias volume rules %+v: want the creator's scope only", rules)
	}
	// An unknown creator's child is in no scope.
	if p, err := decideCachesFor(defaultCachePolicy(), dockerConfig{Image: "golang:1"}, facts, cacheRequest{}); err != nil || p.Scope != "" || p.attached() {
		t.Fatalf("unknown creator: %+v %v", p, err)
	}
	// The engine reads the creator's scope from its plan, else its request.
	s := &dockerEngine{containers: map[string]*dockerContainer{}, cachePolicy: policyLoader{path: filepath.Join(t.TempDir(), "absent.json")}}
	s.containers["a"] = &dockerContainer{dockerRecord: dockerRecord{ID: "a", Cache: &cachePlan{Scope: "proj-a"}}}
	s.containers["b"] = &dockerContainer{dockerRecord: dockerRecord{ID: "b", Cache: &cachePlan{}, Config: dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": "proj-b"}}}}
	for creator, want := range map[string]string{"a": "proj-a", "b": "proj-b"} {
		plan, _, err := s.cacheDecision(withCacheOrigin(context.Background(), cacheOrigin{creator: creator}), dockerConfig{Image: "qa", Labels: map[string]string{"io.micropod.cache": "off"}}, "sha256:x")
		if err != nil || plan.Scope != want {
			t.Errorf("creator %s: scope %q %v, want %s", creator, plan.Scope, err, want)
		}
	}
}
