package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The delegated engine socket: who may be given one at create, and what a
// request on it is.

func engineForPolicy(t *testing.T, policy string) *dockerEngine {
	t.Helper()
	path := filepath.Join(t.TempDir(), "absent.json")
	if policy != "" {
		path = filepath.Join(t.TempDir(), "cache-policy.json")
		if err := os.WriteFile(path, []byte(policy), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return &dockerEngine{containers: map[string]*dockerContainer{}, cachePolicy: policyLoader{path: path}}
}

func ryukSpec() dockerConfig {
	return dockerConfig{
		Image: "testcontainers/ryuk:0.11.0",
		Labels: map[string]string{
			"org.testcontainers.ryuk": "true", "org.testcontainers.reaper": "true",
			tcSession: "0123456789abcdef0123",
		},
		HostConfig: dockerHost{Binds: []string{"/var/run/docker.sock:/var/run/docker.sock"}},
	}
}

func TestEngineSocketGrant(t *testing.T) {
	host := withCacheOrigin(context.Background(), cacheOrigin{hostFacing: true})
	nested := withCacheOrigin(context.Background(), cacheOrigin{creator: "attempt"})
	sock := func(labels map[string]string, bind string) dockerConfig {
		return dockerConfig{Image: "golang:1", Labels: labels, HostConfig: dockerHost{Binds: []string{bind}}}
	}
	trusted := map[string]string{"io.micropod.cache.trust": "trusted"}
	for _, tc := range []struct {
		name   string
		policy string
		ctx    context.Context
		spec   dockerConfig
		grant  bool
		denied string // substring of the 403, "" for no error
	}{
		{"no docker.sock bind", "", host, dockerConfig{Image: "golang:1"}, false, ""},
		{"shipped default, unlabeled, host", "", host, sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), true, ""},
		{"/run/docker.sock source", "", host, sock(nil, "/run/docker.sock:/var/run/docker.sock"), true, ""},
		{"untrusted default, labelled trusted, host", `{"defaultTrust":"untrusted"}`, host,
			sock(trusted, "/var/run/docker.sock:/var/run/docker.sock"), true, ""},
		{"untrusted default, unlabeled", `{"defaultTrust":"untrusted"}`, host,
			sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), false, "only a trusted container"},
		{"untrusted default, trusted only in env", `{"defaultTrust":"untrusted"}`, host,
			dockerConfig{Image: "golang:1", Env: []string{"MICROPOD_CACHE_TRUST=trusted"},
				HostConfig: dockerHost{Binds: []string{"/var/run/docker.sock:/var/run/docker.sock"}}}, false, "only a trusted container"},
		{"labelled untrusted", "", host, sock(map[string]string{"io.micropod.cache.trust": "untrusted"}, "/var/run/docker.sock:/var/run/docker.sock"),
			false, "only a trusted container"},
		{"read-only", "", host, sock(map[string]string{"io.micropod.cache.readonly": "1"}, "/var/run/docker.sock:/var/run/docker.sock"),
			false, "only a trusted container"},
		{"from inside a container", "", nested, sock(trusted, "/var/run/docker.sock:/var/run/docker.sock"), false, "cannot be given a Docker socket"},
		{"no origin mark is a container's", "", context.Background(), sock(nil, "/var/run/docker.sock:/var/run/docker.sock"), false, "cannot be given"},
		{"the reaper keeps its cleanup socket", `{"defaultTrust":"untrusted"}`, nested, ryukSpec(), false, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := engineForPolicy(t, tc.policy)
			grant, err := s.engineSocketGrant(tc.ctx, tc.spec)
			if grant != tc.grant {
				t.Fatalf("grant = %v, want %v (err %v)", grant, tc.grant, err)
			}
			switch {
			case tc.denied == "" && err != nil:
				t.Fatalf("unexpected error %v", err)
			case tc.denied != "":
				var api apiError
				if !errors.As(err, &api) || api.code != 403 || !strings.Contains(api.message, tc.denied) {
					t.Fatalf("err %v, want 403 containing %q", err, tc.denied)
				}
			}
		})
	}
}

// A start mounts the delegated socket at the bind's target and the reaper's
// cleanup socket at its own; a create validates neither as a workspace bind.
func TestOpenMountsDelegatedEngineSocket(t *testing.T) {
	s := engineForPolicy(t, "")
	spec := dockerConfig{Image: "golang:1", HostConfig: dockerHost{Binds: []string{"/var/run/docker.sock:/var/run/docker.sock"}}}
	rules := cacheVolumeRules{}
	if files, mounts, _, err := s.openMountsWith(spec, rules, true, mountSockets{}, ""); err != nil || len(files) != 0 || len(mounts) != 0 {
		t.Fatalf("create: files %d mounts %d err %v", len(files), len(mounts), err)
	}
	if _, _, _, err := s.openMountsWith(spec, rules, false, mountSockets{}, ""); err == nil || !strings.Contains(err.Error(), "not granted") {
		t.Fatalf("start without a granted socket: %v", err)
	}
	_, mounts, _, err := s.openMountsWith(spec, rules, false, mountSockets{engine: "/run/micropod-oci/engine-1/docker.sock"}, "")
	if err != nil || len(mounts) != 1 || mounts[0].HostPath != "/run/micropod-oci/engine-1/docker.sock" || mounts[0].ContainerPath != "/var/run/docker.sock" {
		t.Fatalf("start: %+v %v", mounts, err)
	}
	_, mounts, _, err = s.openMountsWith(ryukSpec(), rules, false, mountSockets{cleanup: "/run/micropod-oci/reaper-1/api.sock", engine: "/elsewhere"}, "")
	if err != nil || len(mounts) != 1 || mounts[0].HostPath != "/run/micropod-oci/reaper-1/api.sock" || !mounts[0].Readonly {
		t.Fatalf("reaper: %+v %v", mounts, err)
	}
}

// Every request on a container's socket is that container's, never the
// host's, so what it creates is capped at its tier; closing removes it.
func TestServeContainerEngineMarksTheContainersOrigin(t *testing.T) {
	got := make(chan cacheOrigin, 1)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got <- cacheOriginOf(r.Context())
		w.WriteHeader(200)
	})
	path, closeFn, err := serveContainerEngine(handler, t.TempDir(), "c0ffee")
	if err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode()&os.ModeSocket == 0 || st.Mode().Perm() != 0o666 {
		t.Fatalf("socket %s: %v %v", path, st.Mode(), err)
	}
	if dir, _ := os.Stat(filepath.Dir(path)); dir.Mode().Perm() != 0o700 {
		t.Fatalf("socket directory mode %v, want 0700", dir.Mode().Perm())
	}
	client := http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", path)
		}}}
	resp, err := client.Get("http://docker/_ping")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if o := <-got; o.hostFacing || o.creator != "c0ffee" {
		t.Fatalf("origin %+v, want the container's", o)
	}
	closeFn()
	if _, err := os.Stat(filepath.Dir(path)); !os.IsNotExist(err) {
		t.Fatalf("socket directory survives close: %v", err)
	}
}
