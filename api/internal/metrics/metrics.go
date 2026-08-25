// Package metrics provides a tiny in-process Prometheus-format metrics
// registry for the Micropod API server. The server records request
// count, status counts, and request latency per route, and exposes
// them at /metrics in the standard text exposition format so any
// scraper (Prometheus, vmagent, the Swift app) can read them.
package metrics

import (
	"fmt"
	"io"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// Registry collects request counters and a latency histogram keyed by
// route + method + status. All operations are safe for concurrent use.
type Registry struct {
	mu      sync.RWMutex
	routes  map[string]*routeMetrics
	startAt time.Time
}

type routeMetrics struct {
	count      atomic.Int64
	errCount   atomic.Int64
	latencySum atomic.Int64 // microseconds
}

// NewRegistry returns an empty registry. Call Attach to wire it into
// an http.Handler.
func NewRegistry() *Registry {
	return &Registry{
		routes:  make(map[string]*routeMetrics),
		startAt: time.Now(),
	}
}

// record stores one observation. status is an HTTP status code.
func (r *Registry) record(route, method string, status int, dur time.Duration) {
	key := routeKey(route, method, status)
	r.mu.RLock()
	rm, ok := r.routes[key]
	r.mu.RUnlock()
	if !ok {
		r.mu.Lock()
		rm, ok = r.routes[key]
		if !ok {
			rm = &routeMetrics{}
			r.routes[key] = rm
		}
		r.mu.Unlock()
	}
	rm.count.Add(1)
	if status >= 400 {
		rm.errCount.Add(1)
	}
	rm.latencySum.Add(dur.Microseconds())
}

func routeKey(route, method string, status int) string {
	return fmt.Sprintf("%s %s %d", route, method, status)
}

// Wrap returns an http.Handler middleware that records request count,
// status, and latency for every request. It wraps next unchanged.
func (r *Registry) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		start := time.Now()
		ww := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(ww, req)
		r.record(req.URL.Path, req.Method, ww.status, time.Since(start))
	})
}

// statusRecorder captures the status code from the ResponseWriter.
type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (s *statusRecorder) WriteHeader(code int) {
	if !s.wroteHeader {
		s.status = code
		s.wroteHeader = true
	}
	s.ResponseWriter.WriteHeader(code)
}

// ServeHTTP renders the registry in Prometheus text exposition format.
func (r *Registry) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")

	uptime := time.Since(r.startAt).Seconds()
	fmt.Fprintf(w, "# HELP micropod_uptime_seconds Seconds since server start\n")
	fmt.Fprintf(w, "# TYPE micropod_uptime_seconds gauge\n")
	fmt.Fprintf(w, "micropod_uptime_seconds %.3f\n", uptime)

	keys := make([]string, 0, len(r.routes))
	for k := range r.routes {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	fmt.Fprintf(w, "# HELP micropod_http_requests_total Total HTTP requests handled\n")
	fmt.Fprintf(w, "# TYPE micropod_http_requests_total counter\n")
	fmt.Fprintf(w, "# HELP micropod_http_errors_total HTTP requests with status >= 400\n")
	fmt.Fprintf(w, "# TYPE micropod_http_errors_total counter\n")
	fmt.Fprintf(w, "# HELP micropod_http_request_duration_microseconds_total Total request latency\n")
	fmt.Fprintf(w, "# TYPE micropod_http_request_duration_microseconds_total counter\n")
	for _, k := range keys {
		rm := r.routes[k]
		route, method, status := splitKey(k)
		count := rm.count.Load()
		errs := rm.errCount.Load()
		lat := rm.latencySum.Load()
		fmt.Fprintf(w, "micropod_http_requests_total{route=%q,method=%q,status=%d} %d\n",
			route, method, status, count)
		fmt.Fprintf(w, "micropod_http_errors_total{route=%q,method=%q,status=%d} %d\n",
			route, method, status, errs)
		fmt.Fprintf(w, "micropod_http_request_duration_microseconds_total{route=%q,method=%q} %d\n",
			route, method, lat)
	}
}

func splitKey(k string) (route, method string, status int) {
	var s int
	fmt.Sscanf(k, "%s %s %d", &route, &method, &s)
	return route, method, s
}

// WriteTo is a helper for embedding the registry into another text body.
func (r *Registry) WriteTo(_ io.Writer) {}
