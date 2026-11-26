package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestDockerRegistryLogin(t *testing.T) {
	t.Run("HTTPS endpoints and legacy Docker Hub address", func(t *testing.T) {
		for raw, want := range map[string]string{
			"": "registry-1.docker.io", "https://index.docker.io/v1/": "registry-1.docker.io",
			"docker.io": "registry-1.docker.io", "localhost:5443": "localhost:5443", "[::1]:5443": "[::1]:5443",
		} {
			u, err := registryLoginEndpoint(raw)
			if err != nil || u.String() != "https://"+want+"/v2/" {
				t.Fatalf("address %q: %v, %v", raw, u, err)
			}
		}
		for _, raw := range []string{"http://host", "https://user:pass@host", "https://host/a", "host?query", "host#fragment", "https:///v2/"} {
			if _, err := registryLoginEndpoint(raw); err == nil {
				t.Fatalf("accepted %q", raw)
			}
		}
	})

	t.Run("basic challenge", func(t *testing.T) {
		reg := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			u, p, ok := r.BasicAuth()
			if !ok || u != "ci" || p != "allowed" {
				w.Header().Set("WWW-Authenticate", `Basic realm="Private Registry"`)
				http.Error(w, "remote diagnostic with a private value", 401)
			}
		}))
		defer reg.Close()
		endpoint, _ := registryLoginEndpoint(reg.URL)
		for _, password := range []string{"allowed", "rejected"} {
			token, err := verifyRegistryLogin(t.Context(), reg.Client().Transport, endpoint, &dockerRegistryAuth{Username: "ci", Password: password})
			if password == "allowed" {
				if token != "" || err != nil {
					t.Fatalf("basic login: token supplied %v, error %v", token != "", err)
				}
			} else if err == nil || err.(apiError).code != 401 || strings.Contains(err.Error(), "private value") {
				t.Fatalf("wrong denial: %v", err)
			}
		}
	})

	t.Run("bearer and offline refresh", func(t *testing.T) {
		tokenRequests := 0
		issuer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			tokenRequests++
			switch r.Method {
			case http.MethodGet:
				u, p, _ := r.BasicAuth()
				if u != "ci" || p != "valid" || r.URL.Query().Get("offline_token") != "true" {
					t.Error("token request omitted login credentials or offline access")
				}
			case http.MethodPost:
				if r.FormValue("grant_type") != "refresh_token" || r.FormValue("refresh_token") != "previous" {
					t.Error("incorrect refresh grant")
				}
			default:
				t.Errorf("token request method %v", r.Method)
			}
			_, _ = fmt.Fprint(w, `{"access_token":"access","refresh_token":"renewed"}`)
		}))
		defer issuer.Close()
		reg := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer access" {
				w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer realm="%s/token",service="ci"`, issuer.URL))
				w.WriteHeader(401)
			}
		}))
		defer reg.Close()
		endpoint, _ := registryLoginEndpoint(reg.URL)
		for _, config := range []dockerRegistryAuth{{Username: "ci", Password: "valid"}, {IdentityToken: "previous"}, {RegistryToken: "access"}} {
			token, err := verifyRegistryLogin(t.Context(), reg.Client().Transport, endpoint, &config)
			if err != nil || (config.RegistryToken == "" && token != "renewed") {
				t.Fatalf("bearer login: issued refresh %v, error %v", token != "", err)
			}
		}
		if tokenRequests != 2 {
			t.Fatalf("got %d token requests", tokenRequests)
		}
	})

	t.Run("unsafe issuer and redirects", func(t *testing.T) {
		calls := 0
		other := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++ }))
		defer other.Close()
		for _, mode := range []string{"http-realm", "cross-origin"} {
			t.Run(mode, func(t *testing.T) {
				reg := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if mode == "http-realm" {
						w.Header().Set("WWW-Authenticate", `Bearer realm="http://localhost/token"`)
					} else {
						if r.Header.Get("Authorization") != "" {
							http.Redirect(w, r, other.URL+"/v2/", 307)
							return
						}
						w.Header().Set("WWW-Authenticate", `Basic realm="CI"`)
					}
					w.WriteHeader(401)
				}))
				defer reg.Close()
				endpoint, _ := registryLoginEndpoint(reg.URL)
				if _, err := verifyRegistryLogin(t.Context(), reg.Client().Transport, endpoint, &dockerRegistryAuth{Username: "ci", Password: "test"}); err == nil {
					t.Fatal("accepted unsafe authentication exchange")
				}
			})
		}
		if calls != 0 {
			t.Fatal("followed authenticated redirect to another origin")
		}
	})

	t.Run("malformed stock API request", func(t *testing.T) {
		s := new(dockerEngine)
		for _, body := range []string{"null", `{"auth":"invalid","serveraddress":"localhost"}`, `{"serveraddress":"http://localhost"}`} {
			w := httptest.NewRecorder()
			s.ServeHTTP(w, httptest.NewRequest("POST", "/v1.47/auth", strings.NewReader(body)))
			if w.Code != 400 {
				t.Fatalf("received %d for malformed registry login", w.Code)
			}
		}
	})

	t.Run("pull credential scope", func(t *testing.T) {
		r := httptest.NewRequest("POST", "/v1.47/images/create", nil)
		w := httptest.NewRecorder()
		r.Header.Set("X-Registry-Auth", base64.RawURLEncoding.EncodeToString([]byte(`{"username":"ci","password":"valid","serveraddress":"host.test:5443"}`)))
		c, err := registryPullCredentials(w, r, "host.test:5443/team/ci:one")
		if err != nil || c.GetUsername() != "ci" || c.GetPassword() != "valid" || c.GetServerAddress() != "https://host.test:5443" {
			t.Fatal("CRI credential does not match the target")
		}
		if _, err := registryPullCredentials(w, r, "another.test:5443/team/ci:one"); err == nil {
			t.Fatal("accepted credentials for a different registry")
		}
	})

	t.Run("cancelled request", func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		cancel()
		endpoint := &url.URL{Scheme: "https", Host: "unused.invalid", Path: "/v2/"}
		if _, err := verifyRegistryLogin(ctx, http.DefaultTransport, endpoint, &dockerRegistryAuth{}); err == nil {
			t.Fatal("cancelled login succeeded")
		}
	})
}
