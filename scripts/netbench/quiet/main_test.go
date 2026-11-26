package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
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
			r := measure(context.Background(), client, "http://backend/id", "expected", 3, schedule{})
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

func TestScheduledGate(t *testing.T) {
	dir := t.TempDir()
	ready, start := filepath.Join(dir, "ready"), filepath.Join(dir, "start")
	deadline := time.Now().Add(40 * time.Millisecond)
	if err := os.WriteFile(start, []byte(strconv.FormatInt(deadline.UnixNano(), 10)), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	var w window
	if err := w.await(ctx, ready, start); err != nil {
		t.Fatal(err)
	}
	if time.Now().Before(deadline) || w.ReadyNS >= w.Scheduled || w.Scheduled != deadline.UnixNano() {
		t.Fatal("client did not wait for the scheduled deadline", w)
	}
	if err := w.await(ctx, ready, start); !os.IsExist(err) {
		t.Fatalf("reused participant marker returned %v", err)
	}
	cancel()
	if err := w.await(ctx, ready+"-new", start+"-absent"); err != context.Canceled {
		t.Fatalf("missing release after cancellation returned %v", err)
	}
}

func TestPacedSchedule(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct{ rate, perClient int }{{32000, 1500}, {64000, 3000}, {96000, 4500}, {128000, 6000}, {160000, 7500}} {
		t.Run(strconv.Itoa(tc.rate), func(t *testing.T) {
			var previous time.Duration
			for index := range tc.perClient {
				for slot := range pacedClients {
					p := pacing{rate: tc.rate, slot: slot}
					due := p.due(index)
					ordinal := index*pacedClients + slot
					if !p.valid() || p.count() != tc.perClient || due >= pacedDuration || (ordinal > 0 && due <= previous) {
						t.Fatalf("slot %d call %d due %v, count %d", slot, index, due, p.count())
					}
					if product, ideal := due.Nanoseconds()*int64(tc.rate), int64(ordinal)*int64(time.Second); product > ideal || ideal-product >= int64(tc.rate) {
						t.Fatalf("slot %d call %d did not round the absolute rational offset down", slot, index)
					}
					previous = due
				}
			}
			for slot := range pacedClients {
				if p := (pacing{rate: tc.rate, slot: slot}); p.due(tc.perClient) < pacedDuration {
					t.Fatalf("slot %d omitted a scheduled arrival", slot)
				}
			}
		})
	}
	if (pacing{rate: 150000, slot: 0}).valid() || (pacing{rate: 32000, slot: 32}).valid() {
		t.Fatal("unplanned rate or slot was accepted")
	}
}

func testPacedClient(conn net.Conn, badCall int) *http.Client {
	index := 0
	return &http.Client{Transport: roundTrip(func(req *http.Request) (*http.Response, error) {
		trace := httptrace.ContextClientTrace(req.Context())
		trace.GotConn(httptrace.GotConnInfo{Conn: conn, Reused: true})
		trace.WroteRequest(httptrace.WroteRequestInfo{})
		trace.GotFirstResponseByte()
		body := "expected"
		if index == badCall {
			body = "wrong"
		}
		index++
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
}

func TestPacedDrainsLateArrivals(t *testing.T) {
	t.Parallel()
	p := pacing{rate: 32000, slot: 31}
	conn := &fakeConn{}
	r := receipt{URL: "http://backend/id", Marker: "expected", Requested: p.count(),
		Window: &window{Scheduled: time.Now().Add(-2 * pacedDuration).UnixNano()}, Pace: &paceLog{Rate: p.rate, Slot: p.slot}}
	measurePaced(context.Background(), &r, testPacedClient(conn, -1), conn, p)
	if !r.Complete || len(r.Samples) != p.count() || len(r.Pace.Arrivals) != p.count() {
		t.Fatalf("lost late arrivals, completed %d of %d, error %q", len(r.Samples), p.count(), r.Window.Error)
	}
	var previous int64
	for i, arrival := range r.Pace.Arrivals {
		if arrival.DueNS != p.due(i).Nanoseconds() || arrival.DispatchNS < max(previous, pacedDuration.Nanoseconds()) ||
			arrival.CompletionNS-arrival.DispatchNS != r.Samples[i].TotalNS || arrival.LatencyNS != arrival.CompletionNS-arrival.DueNS {
			t.Fatalf("wrong timing for call %d: %+v", i, arrival)
		}
		previous = arrival.CompletionNS
	}
	if r.Window.StartedNS != r.Window.Scheduled+r.Pace.Arrivals[0].DispatchNS || r.Window.FinishedNS != r.Window.Scheduled+previous {
		t.Fatal("window does not use the paced monotonic clock translation", r.Window)
	}
}

func TestPacedRecordsPartialFailure(t *testing.T) {
	t.Parallel()
	p := pacing{rate: 32000, slot: 0}
	conn := &fakeConn{}
	for _, tc := range []struct {
		name     string
		cancel   bool
		attempts int
	}{
		{"invalid response", false, 2},
		{"canceled", true, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if tc.cancel {
				cancel()
			}
			r := receipt{URL: "http://backend/id", Marker: "expected", Requested: p.count(),
				Window: &window{Scheduled: time.Now().Add(-pacedDuration).UnixNano()}, Pace: &paceLog{Rate: p.rate, Slot: p.slot}}
			measurePaced(ctx, &r, testPacedClient(conn, 1), conn, p)
			if r.Complete || r.Window.Error == "" || r.Requested != p.count() || len(r.Samples) != tc.attempts || len(r.Pace.Arrivals) != tc.attempts {
				t.Fatalf("wrong partial receipt, attempted %d of %d, error %q", len(r.Samples), r.Requested, r.Window.Error)
			}
		})
	}
}

func TestWaitPacedRespectsSubmillisecondDeadline(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if runtime.GOOS == "linux" {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
	}
	scheduled := time.Now().UnixNano()
	var log paceLog
	clock, err := newPaceClock(scheduled, &log)
	if err != nil || clock.origin.UnixNano() != scheduled {
		t.Fatalf("could not preserve the scheduled clock origin: %v", err)
	}
	if runtime.GOOS == "linux" && (log.ClockCalibrationNS <= 0 || log.TimerSlackNS <= 0 || log.WaitClock != "linux-clock-monotonic-absolute") {
		t.Fatalf("missing Linux timing evidence: %+v", log)
	}
	offset := 250 * time.Microsecond
	if err := clock.wait(ctx, offset); err != nil || time.Now().Before(clock.origin.Add(offset)) {
		t.Fatalf("paced arrival returned before its deadline or failed: %v", err)
	}
}
