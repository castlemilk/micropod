package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httputil"
	"net/http/pprof"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// The engine's own Go profiles, and containerd's, for tuning the machine
// under load. Host only: these are /micropod/* routes, which a delegated
// socket never reaches (engineOwnRoute).
//
//	GET  /micropod/debug/pprof/                 the profile index (net/http/pprof)
//	GET  /micropod/debug/pprof/profile?seconds=N  CPU profile
//	GET  /micropod/debug/pprof/{goroutine,heap,mutex,block,allocs,threadcreate}[?debug=1|2]
//	GET  /micropod/debug/pprof/trace?seconds=N    execution trace
//	POST /micropod/debug/pprof/rates?mutex=N&block=NS
//	                                            runtime.SetMutexProfileFraction(N) and
//	                                            runtime.SetBlockProfileRate(NS); 0 turns
//	                                            each off again (the default)
//	GET  /micropod/debug/containerd/pprof/...   the same, from containerd's debug
//	                                            socket (containerd.toml [debug] address)
//
// Nothing here runs unless asked: the rates are 0 until set, and a profile
// costs only while it is being taken.
const containerdDebugSocket = "/run/containerd/debug.sock"

func init() { extraRoutes = append(extraRoutes, debugRoutes) }

func debugRoutes(_ *dockerEngine, w http.ResponseWriter, r *http.Request, method, path string) (bool, error) {
	if rest, ok := strings.CutPrefix(path, "micropod/debug/pprof"); ok {
		return true, servePprof(w, r, method, rest)
	}
	if rest, ok := strings.CutPrefix(path, "micropod/debug/containerd/pprof"); ok && method == http.MethodGet {
		return true, proxyContainerdPprof(w, r, rest)
	}
	return false, nil
}

func servePprof(w http.ResponseWriter, r *http.Request, method, rest string) error {
	rest = strings.TrimPrefix(rest, "/")
	if rest == "rates" {
		if method != http.MethodPost {
			return fail(405, "POST /micropod/debug/pprof/rates?mutex=N&block=NS")
		}
		q := r.URL.Query()
		out := map[string]int{}
		for name, set := range map[string]func(int){
			"mutex": func(n int) { runtime.SetMutexProfileFraction(n) },
			"block": runtime.SetBlockProfileRate,
		} {
			raw := q.Get(name)
			if raw == "" {
				continue
			}
			n, err := strconv.Atoi(raw)
			if err != nil || n < 0 {
				return fail(400, name+": expected a number of 0 or more")
			}
			set(n)
			out[name] = n
		}
		writeJSON(w, 200, out)
		return nil
	}
	if method != http.MethodGet {
		return fail(405, "profiles are read with GET")
	}
	// net/http/pprof finds the profile's name under /debug/pprof/.
	r2 := r.Clone(r.Context())
	r2.URL.Path = "/debug/pprof/" + rest
	switch rest {
	case "profile":
		pprof.Profile(w, r2)
	case "trace":
		pprof.Trace(w, r2)
	case "symbol":
		pprof.Symbol(w, r2)
	case "cmdline":
		pprof.Cmdline(w, r2)
	default:
		pprof.Index(w, r2)
	}
	return nil
}

func proxyContainerdPprof(w http.ResponseWriter, r *http.Request, rest string) error {
	if _, err := os.Stat(containerdDebugSocket); err != nil {
		return fail(503, "containerd has no debug socket (containerd.toml [debug] address)")
	}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(p *httputil.ProxyRequest) {
			p.Out.URL.Scheme = "http"
			p.Out.URL.Host = "containerd"
			p.Out.URL.Path = "/debug/pprof" + rest
			p.Out.Host = "containerd"
		},
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", containerdDebugSocket)
			},
			ResponseHeaderTimeout: 5 * time.Minute,
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			if errors.Is(err, context.Canceled) {
				return
			}
			writeJSON(w, 502, map[string]string{"message": "containerd debug socket: " + err.Error()})
		},
	}
	proxy.ServeHTTP(w, r)
	return nil
}
