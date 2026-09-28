package localguard

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const port = 45454

func serve(t *testing.T, r *http.Request) int {
	t.Helper()
	rec := httptest.NewRecorder()
	Wrap(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }), port).ServeHTTP(rec, r)
	return rec.Code
}

func req(method, host, contentType, origin, body string) *http.Request {
	r := httptest.NewRequest(method, "http://"+host+"/micropod.v1.SystemService/Ping", strings.NewReader(body))
	r.Host = host
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	if body == "" {
		r.ContentLength = 0
	}
	return r
}

func TestHostCheck(t *testing.T) {
	for host, want := range map[string]int{
		"127.0.0.1:45454":    200,
		"localhost:45454":    200,
		"LOCALHOST:45454":    200,
		"[::1]:45454":        200,
		"evil.example":       403,
		"evil.example:45454": 403,
		"127.0.0.1:1234":     403,
		"127.0.0.1":          403,
		"192.168.1.10:45454": 403,
		"":                   403,
	} {
		if got := serve(t, req(http.MethodPost, host, "application/json", "", "{}")); got != want {
			t.Errorf("Host %q: got %d, want %d", host, got, want)
		}
	}
}

func TestContentTypeCheck(t *testing.T) {
	cases := []struct {
		method, ct, body string
		want             int
	}{
		{"POST", "application/json", "{}", 200},
		{"POST", "application/json; charset=utf-8", "{}", 200},
		{"POST", "application/connect+json", "{}", 200},
		{"POST", "application/proto", "x", 200},
		{"POST", "application/grpc", "x", 200},
		{"POST", "application/grpc+proto", "x", 200},
		{"POST", "application/grpc-web+proto", "x", 200},
		{"POST", "text/plain", "{}", 415},
		{"POST", "text/plain;charset=UTF-8", "{}", 415},
		{"POST", "application/x-www-form-urlencoded", "a=b", 415},
		{"POST", "multipart/form-data; boundary=x", "x", 415},
		{"POST", "", "", 415}, // body-less POST is still a simple request
		{"DELETE", "", "", 200},
		{"DELETE", "text/plain", "x", 415},
		{"PUT", "text/plain", "x", 415},
		{"GET", "", "", 200},
	}
	for _, c := range cases {
		if got := serve(t, req(c.method, "127.0.0.1:45454", c.ct, "", c.body)); got != c.want {
			t.Errorf("%s %q: got %d, want %d", c.method, c.ct, got, c.want)
		}
	}
}

func TestOriginCheck(t *testing.T) {
	t.Setenv("MICROPOD_API_CORS_ORIGINS", "")
	for origin, want := range map[string]int{
		"http://evil.example":          403,
		"https://castlemilk.github.io": 200,
		"http://localhost:3000":        200,
		"http://127.0.0.1:5173":        200,
		"http://[::1]:3000":            200,
		"null":                         403,
	} {
		if got := serve(t, req(http.MethodPost, "127.0.0.1:45454", "application/json", origin, "{}")); got != want {
			t.Errorf("Origin %q: got %d, want %d", origin, got, want)
		}
	}
	t.Setenv("MICROPOD_API_CORS_ORIGINS", "https://docs.internal")
	if got := serve(t, req(http.MethodPost, "127.0.0.1:45454", "application/json", "https://docs.internal", "{}")); got != 200 {
		t.Errorf("configured origin: got %d", got)
	}
	if got := serve(t, req(http.MethodPost, "127.0.0.1:45454", "application/json", "https://castlemilk.github.io", "{}")); got != 403 {
		t.Errorf("override replaces the default list: got %d", got)
	}
}

// The live exposure from the security review: a no-preflight text/plain
// cross-site Ping, with and without a rebinding Host.
func TestCrossSiteSimpleRequestIsRefused(t *testing.T) {
	if got := serve(t, req(http.MethodPost, "evil.example", "text/plain", "http://evil.example", "{}")); got != 403 {
		t.Fatalf("rebinding Host: got %d", got)
	}
	if got := serve(t, req(http.MethodPost, "127.0.0.1:45454", "text/plain", "http://evil.example", "{}")); got != 403 {
		t.Fatalf("foreign Origin: got %d", got)
	}
	if got := serve(t, req(http.MethodPost, "127.0.0.1:45454", "text/plain", "", "{}")); got != 415 {
		t.Fatalf("text/plain without Origin: got %d", got)
	}
}
