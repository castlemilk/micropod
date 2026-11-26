package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	slowAPIThreshold      = 50 * time.Millisecond
	maxRecentIssues       = 64
	maxRecentTraceSpans   = 256
	maxTrackedRoutes      = 64
	maxIssueMessageLength = 180
)

type apiIssue struct {
	TSUnixNS   int64   `json:"ts_unix_ns"`
	Kind       string  `json:"kind"`   // "error", "conflict", "unsupported", "slow", "reaper_error"
	Source     string  `json:"source"` // "docker_api", "ryuk_reaper"
	Method     string  `json:"method"`
	Route      string  `json:"route"`
	Status     int     `json:"status"`
	DurationMS float64 `json:"duration_ms"`
	Message    string  `json:"message,omitempty"`
}

type routeStats struct {
	Count           uint64 `json:"count"`
	Errors          uint64 `json:"errors"`
	DurationUSTotal int64  `json:"duration_usec_total"`
	MaxDurationUS   int64  `json:"max_duration_usec"`
}

type guestTraceSpan struct {
	SpanID      string            `json:"span_id"`
	Name        string            `json:"name"`
	StartUnixNS int64             `json:"start_unix_ns"`
	EndUnixNS   int64             `json:"end_unix_ns"`
	StatusOK    bool              `json:"status_ok"`
	Attrs       map[string]string `json:"attrs"`
}

type apiMetrics struct {
	requestsTotal     atomic.Uint64
	errors4xx         atomic.Uint64
	errors5xx         atomic.Uint64
	conflicts409      atomic.Uint64
	notImplemented501 atomic.Uint64
	slowRequests      atomic.Uint64
	durationUSTotal   atomic.Int64
	maxDurationUS     atomic.Int64
	spanSeq           atomic.Uint64
	traceID           string

	mu     sync.Mutex
	routes map[string]*routeStats
	issues []apiIssue
	spans  []guestTraceSpan
}

type reaperMetrics struct {
	activeSessions   atomic.Int64
	sessionsStarted  atomic.Uint64
	sessionsClosed   atomic.Uint64
	requestsTotal    atomic.Uint64
	containersReaped atomic.Uint64
	networksReaped   atomic.Uint64
	volumesReaped    atomic.Uint64
	reapErrors       atomic.Uint64
	reapDenied       atomic.Uint64
	durationUSTotal  atomic.Int64
	maxDurationUS    atomic.Int64
	lastReapUnixSecs atomic.Int64
}

func (m *apiMetrics) ensureInitLocked() {
	if m.routes == nil {
		m.routes = make(map[string]*routeStats, 32)
	}
	if m.traceID == "" {
		now := uint64(time.Now().UnixNano())
		hi := (now ^ 0x9e3779b97f4a7c15) | 1
		lo := ((now << 17) | (now >> 47)) ^ 0xbf58476d1ce4e5b9 | 1
		m.traceID = fmt.Sprintf("%016x%016x", hi, lo)
	}
}

func updateAtomicMax(target *atomic.Int64, val int64) {
	for {
		cur := target.Load()
		if val <= cur {
			return
		}
		if target.CompareAndSwap(cur, val) {
			return
		}
	}
}

func sanitizeMessage(msg string) string {
	msg = strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(msg, "\r", " "), "\n", " "))
	if len(msg) > maxIssueMessageLength {
		return msg[:maxIssueMessageLength] + "..."
	}
	return msg
}

func isStreamingRoute(method, route string) bool {
	if route == "/events" || route == "/grpc" || route == "/session" {
		return true
	}
	if method == http.MethodPost && (route == "/containers/{id}/wait" || route == "/containers/{id}/attach" || route == "/exec/{id}/start") {
		return true
	}
	if method == http.MethodGet && (route == "/containers/{id}/logs" || route == "/containers/{id}/stats") {
		return true
	}
	return false
}

// normalizeDockerRoute strips Docker API version prefixes and collapses dynamic IDs/names
// into bounded-cardinality route templates for safe Prometheus/OTLP aggregation.
func normalizeDockerRoute(rawPath string) string {
	path := strings.TrimPrefix(rawPath, "/")
	if strings.HasPrefix(path, "v1.") {
		if _, rest, ok := strings.Cut(path, "/"); ok {
			path = rest
		}
	}
	path = strings.TrimSuffix(path, "/")
	if path == "" {
		return "/"
	}
	parts := strings.Split(path, "/")
	switch parts[0] {
	case "_ping", "version", "info", "events", "auth", "grpc", "session":
		return "/" + parts[0]
	case "micropod":
		if len(parts) >= 2 {
			return "/micropod/" + parts[1]
		}
		return "/micropod"
	case "containers":
		if len(parts) == 1 {
			return "/containers"
		}
		switch parts[1] {
		case "create", "json", "prune":
			return "/containers/" + parts[1]
		default:
			if len(parts) >= 3 {
				return "/containers/{id}/" + parts[2]
			}
			return "/containers/{id}"
		}
	case "exec":
		if len(parts) >= 3 {
			return "/exec/{id}/" + parts[2]
		}
		return "/exec/{id}"
	case "networks":
		if len(parts) == 1 {
			return "/networks"
		}
		switch parts[1] {
		case "create", "prune":
			return "/networks/" + parts[1]
		default:
			if len(parts) >= 3 {
				return "/networks/{id}/" + parts[2]
			}
			return "/networks/{id}"
		}
	case "volumes":
		if len(parts) == 1 {
			return "/volumes"
		}
		switch parts[1] {
		case "create", "prune":
			return "/volumes/" + parts[1]
		default:
			return "/volumes/{id}"
		}
	case "images":
		if len(parts) == 1 {
			return "/images"
		}
		switch parts[1] {
		case "json", "create", "load", "get", "prune", "search":
			return "/images/" + parts[1]
		default:
			last := parts[len(parts)-1]
			switch last {
			case "json", "history", "tag", "push", "get":
				return "/images/{id}/" + last
			default:
				return "/images/{id}"
			}
		}
	default:
		return "/other"
	}
}

func (m *apiMetrics) recordHTTP(source, method, rawPath string, status int, start time.Time, dur time.Duration, errMsg string) {
	if status == 0 {
		status = 200
	}
	route := normalizeDockerRoute(rawPath)
	// Skip self-observation endpoints from polluting API request/error totals.
	if source == "docker_api" && strings.HasPrefix(route, "/micropod/") {
		return
	}
	us := dur.Microseconds()
	if us < 0 {
		us = 0
	}
	streaming := isStreamingRoute(method, route)
	isErr := status >= 400
	isSlow := !streaming && dur >= slowAPIThreshold

	if source == "docker_api" {
		m.requestsTotal.Add(1)
		if !streaming {
			m.durationUSTotal.Add(us)
			updateAtomicMax(&m.maxDurationUS, us)
		}
		if status >= 400 && status < 500 {
			m.errors4xx.Add(1)
		} else if status >= 500 {
			m.errors5xx.Add(1)
		}
		if status == http.StatusConflict {
			m.conflicts409.Add(1)
		}
		if status == http.StatusNotImplemented {
			m.notImplemented501.Add(1)
		}
		if isSlow {
			m.slowRequests.Add(1)
		}
	}

	routeKey := method + " " + route
	m.mu.Lock()
	m.ensureInitLocked()
	if source == "docker_api" {
		rs := m.routes[routeKey]
		if rs == nil && len(m.routes) < maxTrackedRoutes {
			rs = &routeStats{}
			m.routes[routeKey] = rs
		}
		if rs != nil {
			rs.Count++
			if isErr {
				rs.Errors++
			}
			if !streaming {
				rs.DurationUSTotal += us
				if us > rs.MaxDurationUS {
					rs.MaxDurationUS = us
				}
			}
		}
	}

	// Record non-routine issues (skip routine GET 404 existence probes like Ryuk cleanup polling).
	routineProbe404 := source == "docker_api" && method == http.MethodGet && status == http.StatusNotFound
	recordIssue := (isErr && !routineProbe404) || isSlow || (source == "ryuk_reaper" && isErr)
	if recordIssue {
		kind := "slow"
		switch {
		case source == "ryuk_reaper" && isErr:
			kind = "reaper_error"
		case status == http.StatusConflict:
			kind = "conflict"
		case status == http.StatusNotImplemented:
			kind = "unsupported"
		case isErr:
			kind = "error"
		}
		msg := sanitizeMessage(errMsg)
		issue := apiIssue{
			TSUnixNS:   start.UnixNano(),
			Kind:       kind,
			Source:     source,
			Method:     method,
			Route:      route,
			Status:     status,
			DurationMS: float64(us) / 1000.0,
			Message:    msg,
		}
		if len(m.issues) >= maxRecentIssues {
			copy(m.issues, m.issues[1:])
			m.issues[len(m.issues)-1] = issue
		} else {
			m.issues = append(m.issues, issue)
		}

		seq := m.spanSeq.Add(1)
		spanID := fmt.Sprintf("%016x", (seq*0x9e3779b97f4a7c15)|1)
		attrs := map[string]string{
			"http.method":      method,
			"http.route":       route,
			"http.status_code": strconv.Itoa(status),
			"micropod.source":  source,
			"micropod.kind":    kind,
		}
		if msg != "" {
			attrs["error.message"] = msg
		}
		span := guestTraceSpan{
			SpanID:      spanID,
			Name:        source + "." + method + " " + route,
			StartUnixNS: start.UnixNano(),
			EndUnixNS:   start.Add(dur).UnixNano(),
			StatusOK:    !isErr,
			Attrs:       attrs,
		}
		if len(m.spans) >= maxRecentTraceSpans {
			copy(m.spans, m.spans[1:])
			m.spans[len(m.spans)-1] = span
		} else {
			m.spans = append(m.spans, span)
		}
	}
	m.mu.Unlock()
}

func (m *apiMetrics) snapshot() (map[string]any, []apiIssue) {
	m.mu.Lock()
	routesCopy := make(map[string]routeStats, len(m.routes))
	for k, v := range m.routes {
		routesCopy[k] = *v
	}
	issuesCopy := make([]apiIssue, len(m.issues))
	copy(issuesCopy, m.issues)
	m.mu.Unlock()

	summary := map[string]any{
		"requests_total":      m.requestsTotal.Load(),
		"errors_4xx":          m.errors4xx.Load(),
		"errors_5xx":          m.errors5xx.Load(),
		"conflicts_409":       m.conflicts409.Load(),
		"not_implemented_501": m.notImplemented501.Load(),
		"slow_requests_total": m.slowRequests.Load(),
		"duration_usec_total": m.durationUSTotal.Load(),
		"max_duration_usec":   m.maxDurationUS.Load(),
		"routes":              routesCopy,
	}
	return summary, issuesCopy
}

func (m *apiMetrics) clearTraces() {
	m.mu.Lock()
	m.spans = nil
	m.mu.Unlock()
}

func (m *apiMetrics) renderOTLPTraces() map[string]any {
	m.mu.Lock()
	m.ensureInitLocked()
	traceID := m.traceID
	spans := make([]guestTraceSpan, len(m.spans))
	copy(spans, m.spans)
	m.mu.Unlock()

	otlpSpans := make([]map[string]any, 0, len(spans))
	for _, sp := range spans {
		attrs := make([]map[string]any, 0, len(sp.Attrs))
		for k, v := range sp.Attrs {
			attrs = append(attrs, map[string]any{
				"key":   k,
				"value": map[string]string{"stringValue": v},
			})
		}
		code := 1
		if !sp.StatusOK {
			code = 2
		}
		otlpSpans = append(otlpSpans, map[string]any{
			"traceId":           traceID,
			"spanId":            sp.SpanID,
			"name":              sp.Name,
			"kind":              2, // SPAN_KIND_SERVER
			"startTimeUnixNano": strconv.FormatInt(sp.StartUnixNS, 10),
			"endTimeUnixNano":   strconv.FormatInt(sp.EndUnixNS, 10),
			"attributes":        attrs,
			"status":            map[string]int{"code": code},
		})
	}
	return map[string]any{
		"resourceSpans": []map[string]any{
			{
				"resource": map[string]any{
					"attributes": []map[string]any{
						{"key": "service.name", "value": map[string]string{"stringValue": "micropod-guest-runner"}},
					},
				},
				"scopeSpans": []map[string]any{
					{
						"scope": map[string]string{"name": "micropod.docker.api", "version": "1.0.0"},
						"spans": otlpSpans,
					},
				},
			},
		},
	}
}

func (r *reaperMetrics) recordDelete(kind string, dur time.Duration, err error) {
	us := dur.Microseconds()
	if us < 0 {
		us = 0
	}
	r.durationUSTotal.Add(us)
	updateAtomicMax(&r.maxDurationUS, us)
	if err != nil {
		r.reapErrors.Add(1)
		return
	}
	r.lastReapUnixSecs.Store(time.Now().Unix())
	switch kind {
	case "containers":
		r.containersReaped.Add(1)
	case "networks":
		r.networksReaped.Add(1)
	case "volumes":
		r.volumesReaped.Add(1)
	}
}

func (r *reaperMetrics) snapshot() map[string]any {
	return map[string]any{
		"active_sessions":          r.activeSessions.Load(),
		"sessions_started":         r.sessionsStarted.Load(),
		"sessions_closed":          r.sessionsClosed.Load(),
		"requests_total":           r.requestsTotal.Load(),
		"containers_reaped":        r.containersReaped.Load(),
		"networks_reaped":          r.networksReaped.Load(),
		"volumes_reaped":           r.volumesReaped.Load(),
		"reap_errors":              r.reapErrors.Load(),
		"reap_denied":              r.reapDenied.Load(),
		"reap_duration_usec_total": r.durationUSTotal.Load(),
		"max_reap_duration_usec":   r.maxDurationUS.Load(),
		"last_reap_unix_secs":      r.lastReapUnixSecs.Load(),
	}
}

// statusRecorder captures HTTP response status while preserving Hijacker and Flusher interfaces
// required by Docker exec/attach/events/BuildKit upgrade streams.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	if r.status == 0 {
		r.status = code
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(p []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(p)
}

func (r *statusRecorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, http.ErrNotSupported
	}
	return h.Hijack()
}

func (r *statusRecorder) Unwrap() http.ResponseWriter {
	return r.ResponseWriter
}

func (s *dockerEngine) serveObservabilityTraces(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		s.metrics.api.clearTraces()
		writeJSON(w, 200, map[string]any{"cleared": true})
		return
	}
	writeJSON(w, 200, s.metrics.api.renderOTLPTraces())
}

// Keep json import explicitly referenced for staticcheck/build hygiene across versions.
var _ = json.Marshal
