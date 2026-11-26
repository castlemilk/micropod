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
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
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
	Window    *window  `json:"window,omitempty"`
	Pace      *paceLog `json:"pace,omitempty"`
}

type window struct {
	ReadyNS    int64           `json:"ready_unix_ns"`
	Scheduled  int64           `json:"scheduled_unix_ns"`
	StartedNS  int64           `json:"started_unix_ns"`
	FinishedNS int64           `json:"finished_unix_ns"`
	DurationNS int64           `json:"duration_ns,omitempty"`
	Local      string          `json:"local"`
	Remote     string          `json:"remote"`
	PageBytes  int             `json:"page_bytes"`
	PID        int             `json:"pid,omitempty"`
	Threads    json.RawMessage `json:"threads,omitempty"`
	Error      string          `json:"error,omitempty"`
}

// Each sibling client signals only after verifying its private warm connection.
// The coordinator publishes a common deadline on the guest's realtime clock.
func (w *window) readGate(ctx context.Context, readyFile, startFile string) error {
	w.ReadyNS = time.Now().UnixNano()
	f, err := os.OpenFile(readyFile, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(f, w.ReadyNS)
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	data, err := waitFile(ctx, startFile)
	if err != nil {
		return err
	}
	w.Scheduled, err = strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil || w.Scheduled <= w.ReadyNS {
		return fmt.Errorf("invalid start time %q", data)
	}
	return nil
}

func (w *window) await(ctx context.Context, readyFile, startFile string) error {
	if err := w.readGate(ctx, readyFile, startFile); err != nil {
		return err
	}
	wait := time.NewTimer(time.Until(time.Unix(0, w.Scheduled)))
	defer wait.Stop()
	select {
	case <-wait.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func waitFile(ctx context.Context, path string) ([]byte, error) {
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		data, err := os.ReadFile(path)
		if !os.IsNotExist(err) {
			return data, err
		}
		select {
		case <-tick.C:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}

func request(ctx context.Context, client *http.Client, endpoint, marker string, expected net.Conn) (sample, net.Conn) {
	return requestAt(ctx, client, endpoint, marker, expected, time.Now())
}

func requestAt(ctx context.Context, client *http.Client, endpoint, marker string, expected net.Conn, start time.Time) (sample, net.Conn) {
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

type schedule struct {
	ready, start, threadProbe string
	duration                  time.Duration
	pace                      pacing
}

const (
	pacedClients  = 32
	pacedDuration = 1500 * time.Millisecond
)

type pacing struct {
	rate int
	slot int
}

func (p pacing) valid() bool {
	switch p.rate {
	case 32000, 64000, 96000, 128000, 160000:
		return 0 <= p.slot && p.slot < pacedClients
	default:
		return false
	}
}

func (p pacing) count() int {
	// Include every ordinal with floor(ordinal * 1 s / rate) < duration.
	total := (int64(p.rate)*pacedDuration.Nanoseconds() + int64(time.Second) - 1) / int64(time.Second)
	return (int(total) - p.slot + pacedClients - 1) / pacedClients
}

func (p pacing) due(index int) time.Duration {
	return time.Duration(int64(p.slot+index*pacedClients) * int64(time.Second) / int64(p.rate))
}

type pacedArrival struct {
	DueNS        int64 `json:"due_offset_ns"`
	DispatchNS   int64 `json:"dispatch_offset_ns"`
	CompletionNS int64 `json:"completion_offset_ns"`
	LatencyNS    int64 `json:"latency_ns"`
}

type paceLog struct {
	Rate               int            `json:"offered_rps"`
	Slot               int            `json:"slot"`
	WaitClock          string         `json:"wait_clock,omitempty"`
	ClockCalibrationNS int64          `json:"clock_calibration_ns,omitempty"`
	TimerSlackNS       int64          `json:"timer_slack_ns,omitempty"`
	Arrivals           []pacedArrival `json:"arrivals"`
}

type paceClock struct {
	origin       time.Time
	kernelOrigin int64
	sleepTrap    uintptr
}

const (
	clockMonotonic  = 1
	timerAbsolute   = 1
	prGetTimerSlack = 30
)

func newPaceClock(scheduled int64, log *paceLog) (paceClock, error) {
	now := time.Now()
	// Translate the shared wall-clock gate once. All offered slots and
	// request timestamps then use this monotonic origin.
	c := paceClock{origin: now.Add(time.Duration(scheduled - now.UnixNano()))}
	if runtime.GOOS != "linux" {
		log.WaitClock = "go-monotonic"
		return c, nil
	}
	// The probe is built from this one file. Use Linux's 64-bit syscall
	// numbers and timespec layout while keeping host-side Go tests portable.
	var clockGettime, prctl uintptr
	switch runtime.GOARCH {
	case "arm64":
		clockGettime, c.sleepTrap, prctl = 113, 115, 167
	case "amd64":
		clockGettime, c.sleepTrap, prctl = 228, 230, 157
	default:
		return paceClock{}, fmt.Errorf("paced clock is unavailable on linux/%s", runtime.GOARCH)
	}
	slack, _, errno := syscall.Syscall6(prctl, prGetTimerSlack, 0, 0, 0, 0, 0)
	if errno != 0 {
		return paceClock{}, fmt.Errorf("reading Linux timer slack: %w", errno)
	}
	log.WaitClock = "linux-clock-monotonic-absolute"
	log.TimerSlackNS = int64(slack)
	for i := range 3 {
		var clock [2]int64
		before := time.Now()
		_, _, errno := syscall.Syscall(clockGettime, clockMonotonic, uintptr(unsafe.Pointer(&clock)), 0)
		span := time.Since(before).Nanoseconds()
		if errno != 0 {
			return paceClock{}, fmt.Errorf("reading Linux monotonic clock: %w", errno)
		}
		if i == 0 || span < log.ClockCalibrationNS {
			// The kernel sample falls inside this bracket. Pair it with
			// the lower Go endpoint so the sleep lands at the due time
			// or at most one bracket width after it, before timer slack.
			c.kernelOrigin = clock[0]*int64(time.Second) + clock[1] + c.origin.Sub(before).Nanoseconds()
			log.ClockCalibrationNS = span
		}
	}
	return c, nil
}

func (c paceClock) wait(ctx context.Context, offset time.Duration) error {
	deadline := c.origin.Add(offset)
	when := c.kernelOrigin + offset.Nanoseconds()
	stamp := [2]int64{when / int64(time.Second), when % int64(time.Second)}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		delay := time.Until(deadline)
		if delay <= 0 {
			return nil
		}
		if delay > 2*time.Millisecond {
			// Long initial waits use a cancelable timer. Reserve the last
			// interval for the kernel sleep because Go's Linux epoll wait
			// rounds sub-millisecond timers up to a whole millisecond.
			timer := time.NewTimer(delay - time.Millisecond)
			select {
			case <-timer.C:
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			}
			continue
		}
		if c.sleepTrap == 0 {
			time.Sleep(delay)
			continue
		}
		_, _, errno := syscall.Syscall6(c.sleepTrap, clockMonotonic, timerAbsolute, uintptr(unsafe.Pointer(&stamp)), 0, 0, 0)
		if errno != 0 && errno != syscall.EINTR {
			return fmt.Errorf("waiting for paced arrival: %w", errno)
		}
		// An interruption or preemption does not move the kernel deadline.
	}
}

func measurePaced(ctx context.Context, result *receipt, client *http.Client, conn net.Conn, p pacing) {
	w := result.Window
	w.DurationNS = pacedDuration.Nanoseconds()
	if runtime.GOOS == "linux" {
		// PR_GET_TIMERSLACK is per thread. Keep the paced goroutine on the
		// issuing thread so its observed slack applies to every sleep.
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
	}
	clock, err := newPaceClock(w.Scheduled, result.Pace)
	if err != nil {
		w.Error = err.Error()
		return
	}
	for i := range result.Requested {
		due := p.due(i)
		if err := clock.wait(ctx, due); err != nil {
			w.Error = fmt.Sprintf("paced request %d of %d: %v", i+1, result.Requested, err)
			break
		}
		start := time.Now()
		dispatch := start.Sub(clock.origin).Nanoseconds()
		row, _ := requestAt(ctx, client, result.URL, result.Marker, conn, start)
		completion := dispatch + row.TotalNS
		result.Samples = append(result.Samples, row)
		result.Pace.Arrivals = append(result.Pace.Arrivals, pacedArrival{
			DueNS: due.Nanoseconds(), DispatchNS: dispatch, CompletionNS: completion, LatencyNS: completion - due.Nanoseconds(),
		})
		if i == 0 {
			w.StartedNS = w.Scheduled + dispatch
		}
		w.FinishedNS = w.Scheduled + completion
		if row.Error != "" {
			w.Error = fmt.Sprintf("paced request %d of %d: %s", i+1, result.Requested, row.Error)
			break
		}
	}
	if ctx.Err() != nil && w.Error == "" {
		w.Error = ctx.Err().Error()
	}
	result.Complete = w.Error == "" && len(result.Samples) == result.Requested
}

func waitDrain(ctx context.Context, gate schedule) error {
	// Keep JSON encoding and Docker output off the CPUs while siblings are still measuring.
	if err := os.WriteFile(gate.ready+".done", []byte("done"), 0600); err != nil {
		return err
	}
	_, err := waitFile(ctx, gate.start+".drain")
	return err
}

func measure(ctx context.Context, client *http.Client, endpoint, marker string, count int, gate schedule) receipt {
	if gate.pace.rate != 0 {
		count = gate.pace.count()
	}
	result := receipt{URL: endpoint, Marker: marker, Requested: count, Samples: make([]sample, 0, count)}
	if gate.pace.rate != 0 {
		result.Pace = &paceLog{Rate: gate.pace.rate, Slot: gate.pace.slot, Arrivals: make([]pacedArrival, 0, count)}
	}
	warmup, expected := request(ctx, client, endpoint, marker, nil)
	result.Warmup = warmup
	if warmup.Error != "" {
		return result
	}
	var end time.Time
	if gate.start != "" {
		w := &window{Local: expected.LocalAddr().String(), Remote: expected.RemoteAddr().String(), PageBytes: os.Getpagesize()}
		result.Window = w
		if gate.threadProbe != "" {
			w.PID = os.Getpid()
			out, err := exec.CommandContext(ctx, gate.threadProbe, "-inspect", strconv.Itoa(w.PID)).Output()
			if err != nil || !json.Valid(out) {
				w.Error = fmt.Sprintf("could not read scheduler attributes: %v", err)
				return result
			}
			w.Threads = out
		}
		if result.Pace != nil {
			if err := w.readGate(ctx, gate.ready, gate.start); err != nil {
				w.Error = err.Error()
				return result
			}
			measurePaced(ctx, &result, client, expected, gate.pace)
			if err := waitDrain(ctx, gate); err != nil {
				if w.Error == "" {
					w.Error = err.Error()
				}
				result.Complete = false
			}
			return result
		}
		if err := w.await(ctx, gate.ready, gate.start); err != nil {
			w.Error = err.Error()
			return result
		}
		if gate.duration > 0 {
			w.DurationNS = gate.duration.Nanoseconds()
			end = time.Unix(0, w.Scheduled).Add(gate.duration)
		}
		w.StartedNS = time.Now().UnixNano()
	}
	clean := true
	for i := 0; ctx.Err() == nil; i++ {
		if end.IsZero() && i >= count || !end.IsZero() && !time.Now().Before(end) {
			break
		}
		row, _ := request(ctx, client, endpoint, marker, expected)
		result.Samples = append(result.Samples, row)
		clean = clean && row.Error == ""
	}
	if result.Window != nil {
		result.Window.FinishedNS = time.Now().UnixNano()
	}
	result.Complete = clean && ctx.Err() == nil && (len(result.Samples) == count || !end.IsZero()) && len(result.Samples) > 0
	if !end.IsZero() {
		if err := waitDrain(ctx, gate); err != nil {
			result.Window.Error = err.Error()
			result.Complete = false
		}
	}
	return result
}

func main() {
	base := flag.String("url", "", "base HTTP URL of the sibling service")
	marker := flag.String("marker", "", "expected /id response body")
	count := flag.Int("requests", 100, "number of serial requests after the warmup (1 to 200)")
	ready := flag.String("ready-file", "", "exclusive marker file for this warmed client")
	start := flag.String("start-file", "", "file containing the common start time in Unix nanoseconds")
	threadProbe := flag.String("thread-probe", "", "inspect the warmed client's Linux scheduling attributes before signaling ready")
	duration := flag.Int("duration-ms", 0, "sustained synchronized window (1 to 1500 ms, requires -requests 0)")
	offered := flag.Int("offered-rps", 0, "aggregate paced requests per second across 32 clients")
	slot := flag.Int("client-slot", -1, "phase index (0 to 31) in a paced wave")
	flag.Parse()
	pace := pacing{rate: *offered, slot: *slot}
	target, err := url.Parse(*base)
	if err != nil || target.Scheme != "http" || target.Hostname() == "" || target.User != nil ||
		target.RawQuery != "" || target.Fragment != "" || strings.Trim(target.Path, "/") != "" ||
		*marker == "" || len(*marker) > 256 || flag.NArg() != 0 ||
		(*duration == 0 && (*count < 1 || *count > 200)) || (*duration != 0 && (*duration < 1 || *duration > 1500 || *count != 0 || *start == "")) ||
		(*offered == 0 && *slot != -1) || (*offered != 0 && (!pace.valid() || time.Duration(*duration)*time.Millisecond != pacedDuration)) ||
		(*ready == "") != (*start == "") || (*ready != "" && *ready == *start) || (*threadProbe != "" && *start == "") {
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
	result := measure(ctx, client, target.String(), *marker, *count, schedule{
		ready: *ready, start: *start, threadProbe: *threadProbe, duration: time.Duration(*duration) * time.Millisecond, pace: pace,
	})
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil || !result.Complete {
		os.Exit(1)
	}
}
