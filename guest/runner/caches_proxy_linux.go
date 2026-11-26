package main

import (
	"io"
	"net/http"
	"sync"
	"time"
)

// The create-time health check of the policy's dependency proxies
// (cacheRequest.proxyUp): a container gets GOPROXY or npm_config_registry
// only while the proxy answers, so a proxy outage leaves installs on their
// own registries instead of failing every one of them.

const (
	// proxyProbeTimeout bounds one check: a create waits at most this long.
	proxyProbeTimeout = 300 * time.Millisecond
	// proxyProbeTTL is how long one check's answer stands, so a burst of
	// creates checks once.
	proxyProbeTTL = 5 * time.Second
)

type proxyProbe struct {
	at time.Time
	up bool
}

// proxyHealth caches one answer per URL for proxyProbeTTL.
type proxyHealth struct {
	mu   sync.Mutex
	seen map[string]proxyProbe
	// probe answers whether url is up now; nil is probeProxy (tests swap it).
	probe func(url string) bool
	now   func() time.Time
}

var dependencyProxies = &proxyHealth{}

// up reports whether url answered a check made within proxyProbeTTL,
// checking it now when no such answer is kept.
func (h *proxyHealth) up(url string) bool {
	now := time.Now
	if h.now != nil {
		now = h.now
	}
	h.mu.Lock()
	if p, ok := h.seen[url]; ok && now().Sub(p.at) < proxyProbeTTL {
		h.mu.Unlock()
		return p.up
	}
	probe := h.probe
	h.mu.Unlock()
	if probe == nil {
		probe = probeProxy
	}
	up := probe(url)
	h.mu.Lock()
	if h.seen == nil {
		h.seen = map[string]proxyProbe{}
	}
	h.seen[url] = proxyProbe{at: now(), up: up}
	h.mu.Unlock()
	return up
}

var proxyProbeClient = &http.Client{
	Timeout: proxyProbeTimeout,
	// Never through a proxy of the engine's own environment, never kept
	// open, never following a redirect: any answer of the URL itself counts.
	Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true, ResponseHeaderTimeout: proxyProbeTimeout},
	CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

// probeProxy is one GET of the proxy URL: any HTTP answer below 500 (a Go
// module proxy's base path may well be a 404) counts as up; no answer within
// proxyProbeTimeout, a refused connection or a 5xx counts as down.
func probeProxy(url string) bool {
	resp, err := proxyProbeClient.Get(url)
	if err != nil {
		return false
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4<<10))
	resp.Body.Close()
	return resp.StatusCode < 500
}
