package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestNormalizeDockerRoute(t *testing.T) {
	cases := map[string]string{
		"/v1.47/containers/create":              "/containers/create",
		"/v1.47/containers/abcdef123456/start":  "/containers/{id}/start",
		"/v1.44/containers/mp-tc-123/json":      "/containers/{id}/json",
		"/v1.47/containers/abcdef123456":        "/containers/{id}",
		"/v1.47/containers/json":                "/containers/json",
		"/v1.47/networks/create":                "/networks/create",
		"/v1.47/networks/net123/connect":        "/networks/{id}/connect",
		"/v1.47/volumes/my-vol":                 "/volumes/{id}",
		"/v1.47/images/alpine:3.23/json":        "/images/{id}/json",
		"/v1.47/images/ghcr.io/foo/bar:v1/json": "/images/{id}/json",
		"/v1.47/exec/exec123/start":             "/exec/{id}/start",
		"/_ping":                                "/_ping",
		"/v1.47/micropod/metrics":               "/micropod/metrics",
		"/v1.47/micropod/containers/summary":    "/micropod/containers/summary",
		"/micropod/caches/prune":                "/micropod/caches/prune",
		"/micropod/caches/":                     "/micropod/caches",
		"/micropod/containers/abc123":           "/micropod/other",
		"/micropod/made-up":                     "/micropod/other",
	}
	for in, want := range cases {
		if got := normalizeDockerRoute(in); got != want {
			t.Fatalf("normalizeDockerRoute(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAPIMetricsCapturesIssuesAndTracesWithoutPollingNoise(t *testing.T) {
	var m apiMetrics
	now := time.Now()
	// Routine GET 404 polling (e.g. Ryuk wait-for-removal) counts in 4xx but does NOT flood recent_issues.
	m.recordHTTP("docker_api", "GET", "/v1.47/containers/abc123/json", 404, now, 2*time.Millisecond, "no such container")
	// 409 conflict (e.g. concurrent Testcontainers Ryuk create race) IS recorded.
	m.recordHTTP("docker_api", "POST", "/v1.47/containers/create", 409, now, 4*time.Millisecond, `Conflict. The container name "/reaper_abc" is already in use`)
	// 501 unsupported IS recorded.
	m.recordHTTP("docker_api", "POST", "/v1.47/networks/n2/connect", 501, now, 3*time.Millisecond, "unsupported secondary network")
	// Slow non-streaming API call (>50ms) IS recorded.
	m.recordHTTP("docker_api", "POST", "/v1.47/containers/abc123/start", 204, now, 75*time.Millisecond, "")
	// Streaming call (>50ms) is NOT flagged as slow.
	m.recordHTTP("docker_api", "GET", "/v1.47/events", 200, now, 5*time.Second, "")

	snap, issues := m.snapshot()
	if snap["requests_total"].(uint64) != 5 {
		t.Fatalf("requests_total = %v, want 5", snap["requests_total"])
	}
	if snap["errors_4xx"].(uint64) != 2 || snap["conflicts_409"].(uint64) != 1 || snap["not_implemented_501"].(uint64) != 1 {
		t.Fatalf("unexpected error counters: %+v", snap)
	}
	if snap["slow_requests_total"].(uint64) != 1 {
		t.Fatalf("slow_requests_total = %v, want 1", snap["slow_requests_total"])
	}
	if len(issues) != 3 {
		t.Fatalf("len(issues) = %d, want 3: %+v", len(issues), issues)
	}
	if issues[0].Kind != "conflict" || issues[1].Kind != "unsupported" || issues[2].Kind != "slow" {
		t.Fatalf("unexpected issue kinds: %+v", issues)
	}

	otlp := m.renderOTLPTraces()
	raw, err := json.Marshal(otlp)
	if err != nil {
		t.Fatalf("marshal OTLP traces: %v", err)
	}
	var parsed struct {
		ResourceSpans []struct {
			ScopeSpans []struct {
				Spans []struct {
					Name string `json:"name"`
				} `json:"spans"`
			} `json:"scopeSpans"`
		} `json:"resourceSpans"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal OTLP traces: %v", err)
	}
	if len(parsed.ResourceSpans) != 1 || len(parsed.ResourceSpans[0].ScopeSpans[0].Spans) != 3 {
		t.Fatalf("unexpected OTLP trace span count: %s", raw)
	}
	m.clearTraces()
	otlp2 := m.renderOTLPTraces()
	raw2, _ := json.Marshal(otlp2)
	_ = json.Unmarshal(raw2, &parsed)
	if len(parsed.ResourceSpans[0].ScopeSpans[0].Spans) != 0 {
		t.Fatalf("expected 0 spans after clearTraces")
	}
}

// The batched container listing the host's list uses
// (/micropod/containers/summary) is one counted request, so one listing is
// one guest request on the guest's own counter (B24). Reading that counter
// (/micropod/metrics, the traces) does not change it, and made-up /micropod
// paths share one route key.
func TestAPIMetricsCountTheBatchedListingButNotTheirOwnReads(t *testing.T) {
	s := &dockerEngine{}
	serve := func(method, target string) *httptest.ResponseRecorder {
		t.Helper()
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, httptest.NewRequest(method, target, nil))
		return rec
	}
	type apiSnap struct {
		RequestsTotal uint64                `json:"requests_total"`
		Routes        map[string]routeStats `json:"routes"`
	}
	read := func() apiSnap {
		t.Helper()
		rec := serve("GET", "/v1.47/micropod/metrics")
		var v struct{ API apiSnap }
		if err := json.Unmarshal(rec.Body.Bytes(), &v); rec.Code != 200 || err != nil {
			t.Fatalf("metrics: %d %s %v", rec.Code, rec.Body, err)
		}
		return v.API
	}
	before := read()
	if rec := serve("GET", "/v1.47/micropod/containers/summary"); rec.Code != 200 {
		t.Fatalf("summary: %d %s", rec.Code, rec.Body)
	}
	after := read()
	if got := after.RequestsTotal - before.RequestsTotal; got != 1 {
		t.Fatalf("one listing counted as %d requests: %+v", got, after)
	}
	if got := after.Routes["GET /micropod/containers/summary"].Count; got != 1 {
		t.Fatalf("summary route count %d: %v", got, after.Routes)
	}
	serve("GET", "/micropod/traces")
	serve("POST", "/micropod/traces/clear")
	if again := read(); again.RequestsTotal != after.RequestsTotal {
		t.Fatalf("reading the metrics and traces counted: %d then %d", after.RequestsTotal, again.RequestsTotal)
	}
	for _, target := range []string{"/micropod/x1", "/v1.47/micropod/x2/y", "/micropod"} {
		serve("GET", target)
	}
	last := read()
	if got := last.RequestsTotal - after.RequestsTotal; got != 3 {
		t.Fatalf("made-up /micropod paths counted as %d requests", got)
	}
	for route := range last.Routes {
		switch route {
		case "GET /micropod/containers/summary", "GET /micropod/other":
		default:
			t.Fatalf("route key %q (keys %v)", route, last.Routes)
		}
	}
	if got := last.Routes["GET /micropod/other"].Count; got != 3 {
		t.Fatalf("made-up paths under %d keys: %v", got, last.Routes)
	}
}

func TestReaperMetricsAndStatusRecorder(t *testing.T) {
	var r reaperMetrics
	r.sessionsStarted.Add(1)
	r.activeSessions.Add(1)
	r.recordDelete("containers", 12*time.Millisecond, nil)
	r.recordDelete("networks", 5*time.Millisecond, nil)
	r.recordDelete("volumes", 3*time.Millisecond, nil)
	r.recordDelete("containers", 8*time.Millisecond, fail(500, "boom"))
	r.activeSessions.Add(-1)
	r.sessionsClosed.Add(1)

	snap := r.snapshot()
	if snap["containers_reaped"].(uint64) != 1 || snap["networks_reaped"].(uint64) != 1 ||
		snap["volumes_reaped"].(uint64) != 1 || snap["reap_errors"].(uint64) != 1 ||
		snap["active_sessions"].(int64) != 0 || snap["sessions_closed"].(uint64) != 1 {
		t.Fatalf("unexpected reaper snapshot: %+v", snap)
	}

	rr := httptest.NewRecorder()
	sr := &statusRecorder{ResponseWriter: rr}
	sr.WriteHeader(http.StatusCreated)
	_, _ = sr.Write([]byte("ok"))
	if sr.status != http.StatusCreated {
		t.Fatalf("statusRecorder captured %d, want 201", sr.status)
	}
}

func TestStartingPhaseMapsToValidDockerStatus(t *testing.T) {
	c := &dockerContainer{dockerRecord: dockerRecord{ID: "abc", Name: "reaper_test", Phase: "starting"}}
	if got := c.dockerStatus(); got != "created" {
		t.Fatalf("initial starting status = %q, want created", got)
	}
	if state := c.inspect()["State"].(map[string]any); state["Status"] != "created" || state["Running"] != false {
		t.Fatalf("inspect during initial start = %+v", state)
	}
	c.Exits = 1
	if got := c.dockerStatus(); got != "exited" {
		t.Fatalf("restart starting status = %q, want exited", got)
	}
	c.Phase = "running"
	if got := c.dockerStatus(); got != "running" {
		t.Fatalf("running status = %q, want running", got)
	}
}
