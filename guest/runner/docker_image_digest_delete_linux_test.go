package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/containerd/containerd/api/types"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestDockerImageDigestRemoveScopesTagsToExactRepositoryAndTarget(t *testing.T) {
	f := imageIDDeletionFixture(t)
	digest := f.manifest.target.GetDigest()
	const repo = "docker.io/team/archive"
	first, second := repo+":a", repo+":b"
	storedDigest := repo + "@" + digest
	keepTags := []string{"docker.io/team/another:keep", repo + ":another-target"}
	for _, name := range []string{first, second, storedDigest, keepTags[0], keepTags[1]} {
		f.addRef(name)
	}
	f.store.refs[keepTags[1]].Target = &types.Descriptor{Digest: "sha256:" + strings.Repeat("b", 64)}
	for _, wrong := range []string{"team/missing@" + digest, "sha256@" + digest} {
		_, err := f.remove(wrong, "")
		var problem apiError
		if !errors.As(err, &problem) || problem.code != http.StatusNotFound || len(f.store.deleted) != 0 {
			t.Fatalf("unassociated digest removal = %v, deletes %v", err, f.store.deleted)
		}
	}
	res, err := f.remove("team/archive@"+digest, "")
	var records []map[string]string
	if err != nil || json.Unmarshal(res.Body.Bytes(), &records) != nil || !slices.Equal(f.store.deleted, []string{first, second, storedDigest}) {
		t.Fatalf("digest removal = %v %s, deletes %v", err, res.Body, f.store.deleted)
	}
	if len(records) != 3 || records[0]["Untagged"] != "team/archive:a" ||
		records[1]["Untagged"] != "team/archive:b" || records[2]["Untagged"] != "team/archive@"+digest {
		t.Fatalf("unexpected untag response %s", res.Body)
	}
	for _, name := range append(keepTags, f.id) {
		if f.store.refs[name] == nil {
			t.Fatalf("removed out-of-scope reference %q", name)
		}
	}
}

func TestDockerImageDigestRemoveLastReferenceHonorsRetention(t *testing.T) {
	for _, tc := range []struct {
		name         string
		state        cri.ContainerState
		used, force  bool
		alternate    bool
		wantConflict bool
		wantConfig   bool
	}{
		{name: "unused"},
		{name: "stopped conflict", used: true, state: cri.ContainerState_CONTAINER_EXITED, wantConflict: true, wantConfig: true},
		{name: "running conflict", used: true, state: cri.ContainerState_CONTAINER_RUNNING, wantConflict: true, wantConfig: true},
		{name: "force untag stopped", used: true, state: cri.ContainerState_CONTAINER_EXITED, force: true, wantConfig: true},
		{name: "force conflict running", used: true, state: cri.ContainerState_CONTAINER_RUNNING, force: true, wantConflict: true, wantConfig: true},
		{name: "shared config for another descriptor", alternate: true, wantConfig: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := imageIDDeletionFixture(t)
			const tag = "docker.io/team/archive:latest"
			f.addRef(tag)
			f.cri.image.RepoTags = []string{tag}
			if tc.alternate {
				const otherTag = "docker.io/team/archive:another"
				f.addRef(otherTag).Target = &types.Descriptor{Digest: "sha256:" + strings.Repeat("d", 64)}
				f.cri.image.RepoTags = append(f.cri.image.RepoTags, otherTag)
			}
			if tc.used {
				f.cri.containers = []*cri.Container{{ImageId: f.id, State: tc.state}}
			}
			var query string
			if tc.force {
				query = "force=1"
			}
			res, err := f.remove("team/archive@"+f.manifest.target.GetDigest(), query)
			var problem apiError
			if tc.wantConflict {
				if !errors.As(err, &problem) || problem.code != http.StatusConflict || len(f.store.deleted) != 0 || f.store.refs[tag] == nil {
					t.Fatalf("retained image removal = %v, deleted %v", err, f.store.deleted)
				}
			} else if err != nil || f.store.refs[tag] != nil || strings.Contains(res.Body.String(), `"Deleted"`) == tc.wantConfig {
				t.Fatalf("digest removal = %v, %s, deleted %v", err, res.Body, f.store.deleted)
			}
			if (f.store.refs[f.id] != nil) != tc.wantConfig {
				t.Fatalf("config retained = %v, wanted %v", f.store.refs[f.id] != nil, tc.wantConfig)
			}
		})
	}
}

func TestDockerImageDigestRemoveStopsWhenAnIndependentWriterRetags(t *testing.T) {
	f := imageIDDeletionFixture(t)
	const first = "docker.io/team/archive:a"
	const second = "docker.io/team/archive:b"
	f.addRef(first)
	f.addRef(second)
	f.cri.image.RepoTags = []string{first, second}
	newTarget := "sha256:" + strings.Repeat("b", 64)
	f.store.onDelete = func(name string) {
		if name == second {
			f.store.refs[name].Target = &types.Descriptor{Digest: newTarget}
		}
	}
	_, err := f.remove("team/archive@"+f.manifest.target.GetDigest(), "")
	var problem apiError
	if !errors.As(err, &problem) || problem.code != http.StatusConflict || !slices.Equal(f.store.deleted, []string{first}) ||
		f.store.refs[second].GetTarget().GetDigest() != newTarget || f.store.refs[f.id] == nil {
		t.Fatalf("partial retag: err = %v, removed = %v, live refs = %v", err, f.store.deleted, f.store.refs)
	}
}
