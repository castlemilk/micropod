package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"strings"
	"testing"
)

type fakeConn struct{ net.Conn }
type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

func TestQuietHTTPTrace(t *testing.T) {
	for _, variant := range []string{"clean", "replaced", "redial", "retry", "wrong-marker", "no-first-byte", "bad-warmup"} {
		t.Run(variant, func(t *testing.T) {
			first, other := &fakeConn{}, &fakeConn{}
			call := 0
			client := &http.Client{Transport: roundTrip(func(req *http.Request) (*http.Response, error) {
				trace := httptrace.ContextClientTrace(req.Context())
				conn := first
				body := "expected"
				if call == 0 && variant == "bad-warmup" {
					body = "wrong"
				}
				if call > 0 {
					switch variant {
					case "replaced":
						conn = other
					case "redial":
						trace.ConnectStart("tcp", "service")
					case "retry":
						trace.GotConn(httptrace.GotConnInfo{Conn: first, Reused: true})
					case "wrong-marker":
						body = "unexpected"
					}
				}
				trace.GotConn(httptrace.GotConnInfo{Conn: conn, Reused: call > 0})
				trace.WroteRequest(httptrace.WroteRequestInfo{})
				if variant != "no-first-byte" || call == 0 {
					trace.GotFirstResponseByte()
				}
				call++
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
			})}
			r := measure(context.Background(), client, "http://backend/id", "expected", 3)
			if variant == "bad-warmup" {
				if r.Complete || r.Warmup.Error == "" || len(r.Samples) != 0 {
					t.Fatal(r)
				}
				return
			}
			if len(r.Samples) != 3 || r.Complete != (variant == "clean") {
				t.Fatal(r)
			}
			for _, row := range r.Samples {
				if (row.Error == "") != r.Complete || row.TotalNS <= 0 {
					t.Fatal(row)
				}
			}
		})
	}
}
