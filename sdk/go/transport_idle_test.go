package micropod

import (
	"net/http"
	"testing"
	"time"
)

// serverKeepAliveIdle is the MicropodAPI's default idle close of an HTTP/1.1
// connection (HTTPConnectionPolicy.swift, keepAliveIdle).
const serverKeepAliveIdle = 120 * time.Second

// The transport WithUnixSocket and WithHTTP2 build must drop an idle
// connection before the server closes it, and keep enough idle connections
// for concurrent callers.
func TestTheBuiltTransportDropsIdleConnectionsBeforeTheServerDoes(t *testing.T) {
	for name, cfg := range map[string]*config{
		"WithUnixSocket":             {httpClient: http.DefaultClient, unixSocket: "/tmp/none.sock"},
		"WithHTTP2":                  {httpClient: http.DefaultClient, http2: true},
		"WithHTTP2 + WithUnixSocket": {httpClient: http.DefaultClient, http2: true, unixSocket: "/tmp/none.sock"},
	} {
		tr, ok := cfg.transport().Transport.(*http.Transport)
		if !ok {
			t.Fatalf("%s: transport is %T", name, cfg.transport().Transport)
		}
		if tr.IdleConnTimeout <= 0 || tr.IdleConnTimeout >= serverKeepAliveIdle {
			t.Errorf("%s: IdleConnTimeout %v, want above 0 and below the server's %v", name, tr.IdleConnTimeout, serverKeepAliveIdle)
		}
		if tr.MaxIdleConnsPerHost < 8 {
			t.Errorf("%s: MaxIdleConnsPerHost %d, want at least 8", name, tr.MaxIdleConnsPerHost)
		}
		if tr.Proxy != nil {
			t.Errorf("%s: a proxy is set; the API is local", name)
		}
	}
}
