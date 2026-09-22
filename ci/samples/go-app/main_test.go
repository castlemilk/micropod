package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGreeting(t *testing.T) {
	cases := map[string]string{
		"":      "hello, world",
		"ada":   "hello, ada",
		"cuttle": "hello, cuttle",
	}
	for name, want := range cases {
		if got := greeting(name); got != want {
			t.Errorf("greeting(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestHelloHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/?name=ada", nil)
	rec := httptest.NewRecorder()
	helloHandler(rec, req)
	body, err := io.ReadAll(rec.Result().Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if got, want := strings.TrimSpace(string(body)), "hello, ada"; got != want {
		t.Errorf("handler body = %q, want %q", got, want)
	}
}

func TestHealthHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	healthHandler(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Errorf("health status = %d, want %d", rec.Code, http.StatusNoContent)
	}
}
