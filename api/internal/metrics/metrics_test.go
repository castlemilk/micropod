package metrics

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestServeHTTPReturnsMetrics(t *testing.T) {
	r := NewRegistry()
	mux := http.NewServeMux()
	mux.HandleFunc("/x", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) })
	wrapped := r.Wrap(mux)
	rec := httptest.NewRecorder()
	wrapped.ServeHTTP(rec, httptest.NewRequest("GET", "/x", nil))
	rec2 := httptest.NewRecorder()
	r.ServeHTTP(rec2, httptest.NewRequest("GET", "/metrics", nil))
	body := rec2.Body.String()
	if !strings.Contains(body, "micropod_uptime_seconds") {
		t.Fatalf("missing uptime gauge:\n%s", body)
	}
	if !strings.Contains(body, `route="/x"`) {
		t.Fatalf("missing /x route entry:\n%s", body)
	}
}
