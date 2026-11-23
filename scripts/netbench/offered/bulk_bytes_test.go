package main

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestBulkAccountingIncludesLateFreshDrain(t *testing.T) {
	const responseBytes = 8 << 20
	body := make([]byte, responseBytes)
	var arms [2]bulkPhases
	for arm, late := range []bool{false, true} {
		synctest.Test(t, func(t *testing.T) {
			response := func(body io.Reader) *http.Response {
				return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(body)}
			}
			newBulk := func() *http.Client {
				return &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
					if req.URL.Path == "/id" {
						return response(strings.NewReader("marker")), nil
					}
					time.Sleep(710 * time.Millisecond)
					return response(bytes.NewReader(body)), nil
				})}
			}
			var arrivals atomic.Int32
			fresh := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				if arrivals.Add(1) == 240 && late {
					time.Sleep(3 * time.Second)
				}
				time.Sleep(time.Millisecond)
				return response(strings.NewReader("marker")), nil
			})}
			var output bytes.Buffer
			if err := run([]service{{"http://fixture.invalid", "marker"}}, newBulk, fresh, &output); err != nil {
				t.Fatal(err)
			}
			var got struct {
				Phases   bulkPhases `json:"bulk_body_bytes"`
				Bytes    int64      `json:"bytes"`
				Streams  [32]int64  `json:"per_stream_bytes"`
				Window   float64    `json:"window_s"`
				Rate     float64    `json:"mib_s"`
				Arrivals int        `json:"arrivals"`
			}
			if err := json.Unmarshal(output.Bytes(), &got); err != nil {
				t.Fatal(err)
			}
			if arrivals.Load() != 240 || got.Arrivals != 240 || got.Window != 6 ||
				got.Rate != float64(got.Bytes)/(1<<20)/6 ||
				got.Phases.Scored != (phaseBytes{Bytes: got.Bytes, Streams: got.Streams}) {
				t.Fatalf("unexpected scored workload: %s", &output)
			}
			// Virtual time delivers one warmup response, eight in the scoring window,
			// and one in flight when normal fresh requests finish. A three-second delay
			// on the final fresh completion permits four additional bulk responses.
			drain := int64(1)
			if late {
				drain = 5
			}
			for phase, want := range map[*phaseBytes]int64{&got.Phases.Warmup: 1, &got.Phases.Scored: 8,
				&got.Phases.Drain: drain, &got.Phases.Invocation: 9 + drain} {
				if phase.Bytes != 32*want*responseBytes {
					t.Fatalf("phase total %d, want %d", phase.Bytes, 32*want*responseBytes)
				}
				for i, n := range phase.Streams {
					if n != want*responseBytes {
						t.Fatalf("stream %d has %d bytes, want %d", i, n, want*responseBytes)
					}
				}
			}
			arms[arm] = got.Phases
		})
	}
	if arms[0].Warmup != arms[1].Warmup || arms[0].Scored != arms[1].Scored || arms[0].Drain.Bytes >= arms[1].Drain.Bytes {
		t.Fatal("delaying only the final fresh response must increase only post-window work")
	}
}

func TestBulkAccountingRejectsInvalidSnapshots(t *testing.T) {
	for _, test := range []struct {
		name               string
		before, end, final [32]int64
	}{
		{"negative", [32]int64{-1}, [32]int64{}, [32]int64{}},
		{"scored regression", [32]int64{2}, [32]int64{1}, [32]int64{3}},
		{"drain regression", [32]int64{1}, [32]int64{3}, [32]int64{2}},
		{"total overflow", [32]int64{}, [32]int64{}, [32]int64{math.MaxInt64, 1}},
	} {
		if _, err := bulkBodyBytes(&test.before, &test.end, &test.final); err == nil {
			t.Errorf("%s: accepted invalid snapshots", test.name)
		}
	}
}
