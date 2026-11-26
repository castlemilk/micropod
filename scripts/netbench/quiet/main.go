// Measure sequential HTTP/1.1 requests on one verified, warmed service connection.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

type sample struct {
	TotalNS     int64  `json:"total_ns"`
	GotConnNS   int64  `json:"got_conn_ns"`
	WroteNS     int64  `json:"wrote_request_ns"`
	FirstByteNS int64  `json:"first_response_byte_ns"`
	Connections int    `json:"got_conn_count"`
	Dials       int    `json:"dial_starts"`
	Reused      bool   `json:"reused"`
	SameConn    bool   `json:"same_as_warmup"`
	Error       string `json:"error,omitempty"`
}

type receipt struct {
	URL       string   `json:"url"`
	Marker    string   `json:"marker"`
	Requested int      `json:"requested"`
	Warmup    sample   `json:"warmup"`
	Samples   []sample `json:"samples"`
	Complete  bool     `json:"complete"`
}

func request(ctx context.Context, client *http.Client, endpoint, marker string, expected net.Conn) (sample, net.Conn) {
	start := time.Now()
	var sample sample
	var used net.Conn
	var mu sync.Mutex
	// net/http can issue trace callbacks on different goroutines, including a
	// second acquisition after an internal retry on a broken idle connection.
	trace := &httptrace.ClientTrace{
		ConnectStart: func(_, _ string) { mu.Lock(); sample.Dials++; mu.Unlock() },
		GotConn: func(info httptrace.GotConnInfo) {
			mu.Lock()
			defer mu.Unlock()
			sample.Connections++
			used = info.Conn
			sample.Reused = info.Reused
			sample.SameConn = expected != nil && used == expected
			sample.GotConnNS = time.Since(start).Nanoseconds()
		},
		WroteRequest: func(info httptrace.WroteRequestInfo) {
			mu.Lock()
			defer mu.Unlock()
			if info.Err == nil {
				sample.WroteNS = time.Since(start).Nanoseconds()
			}
		},
		GotFirstResponseByte: func() { mu.Lock(); sample.FirstByteNS = time.Since(start).Nanoseconds(); mu.Unlock() },
	}
	req, err := http.NewRequestWithContext(httptrace.WithClientTrace(ctx, trace), http.MethodGet, endpoint, nil)
	if err == nil {
		var response *http.Response
		response, err = client.Do(req)
		if err == nil {
			var body []byte
			body, err = io.ReadAll(io.LimitReader(response.Body, int64(len(marker)+1)))
			response.Body.Close()
			if err == nil && (response.StatusCode != http.StatusOK || string(body) != marker) {
				err = fmt.Errorf("unexpected status or service marker (HTTP %d)", response.StatusCode)
			}
		}
	}
	mu.Lock()
	defer mu.Unlock()
	sample.TotalNS = time.Since(start).Nanoseconds()
	switch {
	case err != nil:
		sample.Error = err.Error()
	case used == nil || sample.Connections != 1:
		sample.Error = "missing or repeated connection acquisition"
	case expected != nil && (!sample.SameConn || !sample.Reused || sample.Dials != 0):
		sample.Error = "request did not stay on the warmed connection"
	case sample.GotConnNS <= 0 || sample.WroteNS < sample.GotConnNS ||
		sample.FirstByteNS < sample.WroteNS || sample.TotalNS < sample.FirstByteNS:
		sample.Error = "missing or overlapping trace phase"
	}
	return sample, used
}

func measure(ctx context.Context, client *http.Client, endpoint, marker string, count int) receipt {
	result := receipt{URL: endpoint, Marker: marker, Requested: count, Samples: make([]sample, 0, count)}
	warmup, expected := request(ctx, client, endpoint, marker, nil)
	result.Warmup = warmup
	if warmup.Error != "" {
		return result
	}
	clean := true
	for range count {
		if ctx.Err() != nil {
			break
		}
		row, _ := request(ctx, client, endpoint, marker, expected)
		result.Samples = append(result.Samples, row)
		clean = clean && row.Error == ""
	}
	result.Complete = clean && len(result.Samples) == count
	return result
}

func main() {
	base := flag.String("url", "", "base HTTP URL of the sibling service")
	marker := flag.String("marker", "", "expected /id response body")
	count := flag.Int("requests", 100, "number of serial requests after the warmup (1 to 200)")
	flag.Parse()
	target, err := url.Parse(*base)
	if err != nil || target.Scheme != "http" || target.Hostname() == "" || target.User != nil ||
		target.RawQuery != "" || target.Fragment != "" || strings.Trim(target.Path, "/") != "" ||
		*marker == "" || len(*marker) > 256 || *count < 1 || *count > 200 || flag.NArg() != 0 {
		flag.Usage()
		os.Exit(2)
	}
	target.Path = "/id"
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	transport := &http.Transport{MaxConnsPerHost: 1}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	result := measure(ctx, client, target.String(), *marker, *count)
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil || !result.Complete {
		os.Exit(1)
	}
}
