// cpbench drives the MicropodAPI control plane for the B25 gate
// (scripts/gates/control-plane.sh) and reports what it measured as one JSON
// document on stdout. It is a client only: every number comes from calls to
// the real MicropodAPI binary over its Unix socket or loopback TCP, through
// the generated connect-go clients of sdk/go (binary protobuf or proto-JSON)
// or plain HTTP for the REST routes.
//
//	cpbench unary     -target unix:/p|tcp:127.0.0.1:N -codec proto|json|rest|auto -rpc NAME [-id X]
//	                  -n 200 -warmup 20 -concurrency 1 [-samples FILE] [-expect-prefix P -expect-count K]
//	cpbench roundtrip -target T -codec proto|json -n 30 -image alpine:3.20 -prefix NAME
//	cpbench logs      -target T -codec proto|json|sse -id X -n 50 -expect LINE
//	cpbench exec      -target T -codec proto|json -id X -n 50
//	cpbench probe     -target T   (gRPC over h2c, AttachContainer, codec advertisement)
//
// Connections are counted on the client: every dial the transport makes is
// counted, and httptrace reports whether a request rode a reused connection.
// The transport keeps idle connections (keep-alive on, 64 per host), so a
// server that allowed reuse would get it; a "dials == requests" result is
// the server closing every connection.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptrace"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"connectrpc.com/connect"
	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
	"golang.org/x/net/http2"
)

// --- transport --------------------------------------------------------------

type target struct {
	spec    string
	network string // unix | tcp
	address string
}

func parseTarget(spec string) (target, error) {
	switch {
	case strings.HasPrefix(spec, "unix:"):
		return target{spec, "unix", strings.TrimPrefix(spec, "unix:")}, nil
	case strings.HasPrefix(spec, "tcp:"):
		return target{spec, "tcp", strings.TrimPrefix(spec, "tcp:")}, nil
	}
	return target{}, fmt.Errorf("target %q: want unix:/path or tcp:host:port", spec)
}

// baseURL is what the generated clients prefix to /micropod.v1.<Svc>/<Method>.
// Loopback TCP is guarded by the API's Host check, so it names the real
// address; the owner socket ignores Host.
func (t target) baseURL() string {
	if t.network == "tcp" {
		return "http://" + t.address
	}
	return "http://localhost"
}

// counted is an http.Client whose dials and connection reuse are counted.
type counted struct {
	client *http.Client
	dials  atomic.Int64
	reused atomic.Int64
	fresh  atomic.Int64
}

func newCounted(t target, timeout time.Duration) *counted {
	c := &counted{}
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	tr := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			c.dials.Add(1)
			return dialer.DialContext(ctx, t.network, t.address)
		},
		MaxIdleConns:        256,
		MaxIdleConnsPerHost: 64,
		IdleConnTimeout:     90 * time.Second,
		DisableCompression:  true,
	}
	c.client = &http.Client{Transport: tr, Timeout: timeout}
	return c
}

// traced returns ctx with a trace that records whether the request's
// connection was reused, into *reused (set once the connection is got).
func (c *counted) traced(ctx context.Context, reused *bool) context.Context {
	return httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			if info.Reused {
				c.reused.Add(1)
			} else {
				c.fresh.Add(1)
			}
			if reused != nil {
				*reused = info.Reused
			}
		},
	})
}

func connectOpts(codec string) []connect.ClientOption {
	if codec == "json" {
		return []connect.ClientOption{connect.WithProtoJSON()}
	}
	return nil
}

// micropodUnaryBinaryProto mirrors cuttlefish/internal/runner/micropod_detect.go
// (commit 1fd58d6f): MICROPOD_BINARY_PROTO=0/false/off/no keeps unary calls
// on proto-JSON, =1/true/on/yes forces binary, unset follows the server's
// X-Micropod-Codecs advertisement on Ping.
func micropodUnaryBinaryProto(advertised string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("MICROPOD_BINARY_PROTO"))) {
	case "0", "false", "off", "no":
		return false
	case "1", "true", "on", "yes":
		return true
	}
	return strings.Contains(strings.ToLower(advertised), "proto")
}

// --- statistics ---------------------------------------------------------------

type stats struct {
	N      int     `json:"n"`
	P50    float64 `json:"p50Us"`
	P95    float64 `json:"p95Us"`
	P99    float64 `json:"p99Us"`
	Min    float64 `json:"minUs"`
	Max    float64 `json:"maxUs"`
	Mean   float64 `json:"meanUs"`
	Stddev float64 `json:"stddevUs"`
}

// quantile is the nearest-rank quantile (no interpolation): p95 of 200
// samples is the 190th smallest.
func quantile(sorted []float64, q float64) float64 {
	if len(sorted) == 0 {
		return math.NaN()
	}
	rank := int(math.Ceil(q*float64(len(sorted)))) - 1
	if rank < 0 {
		rank = 0
	}
	if rank >= len(sorted) {
		rank = len(sorted) - 1
	}
	return sorted[rank]
}

func summarize(us []float64) *stats {
	if len(us) == 0 {
		return nil
	}
	s := append([]float64(nil), us...)
	sort.Float64s(s)
	var sum float64
	for _, v := range s {
		sum += v
	}
	mean := sum / float64(len(s))
	var sq float64
	for _, v := range s {
		sq += (v - mean) * (v - mean)
	}
	r := func(v float64) float64 { return math.Round(v*10) / 10 }
	return &stats{N: len(s), P50: r(quantile(s, .50)), P95: r(quantile(s, .95)), P99: r(quantile(s, .99)),
		Min: r(s[0]), Max: r(s[len(s)-1]), Mean: r(mean), Stddev: r(math.Sqrt(sq / float64(len(s))))}
}

func us(d time.Duration) float64 { return float64(d.Nanoseconds()) / 1e3 }

// --- one call -----------------------------------------------------------------

// outcome is what one request returned, for verification by the gate.
type outcome struct {
	contentType string
	bytes       int
	containers  []string // ListContainers: ids
	detail      string   // a short description of the answer
}

type caller func(ctx context.Context) (outcome, error)

type rpcSpec struct {
	rpc, codec, id string
}

// newCaller builds the function one sample calls: a generated connect client
// for proto/json, a plain GET for REST.
func newCaller(c *counted, t target, spec rpcSpec) (caller, error) {
	base := t.baseURL()
	if spec.codec == "rest" || spec.rpc == "CacheSummary" || spec.rpc == "CacheExplain" || spec.rpc == "Health" {
		if spec.codec != "rest" {
			return nil, fmt.Errorf("%s has no Connect RPC (codec %s unsupported): no CacheService in proto/micropod/v1", spec.rpc, spec.codec)
		}
		var path string
		switch spec.rpc {
		case "Health":
			path = "/health"
		case "GetSystem":
			path = "/v1/system"
		case "ListContainers":
			path = "/v1/containers"
		case "CacheSummary":
			path = "/v1/caches"
		case "CacheExplain":
			path = "/v1/caches/explain/" + spec.id
		case "Runtimes":
			path = "/v1/runtimes"
		default:
			return nil, fmt.Errorf("%s has no REST route", spec.rpc)
		}
		return func(ctx context.Context) (outcome, error) {
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+path, nil)
			if err != nil {
				return outcome{}, err
			}
			resp, err := c.client.Do(req)
			if err != nil {
				return outcome{}, err
			}
			body, err := io.ReadAll(resp.Body)
			resp.Body.Close()
			if err != nil {
				return outcome{}, err
			}
			o := outcome{contentType: resp.Header.Get("Content-Type"), bytes: len(body)}
			if resp.StatusCode != 200 {
				return o, fmt.Errorf("HTTP %d: %s", resp.StatusCode, trim(string(body), 200))
			}
			if spec.rpc == "ListContainers" {
				var doc struct {
					Containers []struct {
						ID string `json:"id"`
					} `json:"containers"`
				}
				if err := json.Unmarshal(body, &doc); err != nil {
					return o, fmt.Errorf("decoding the listing: %w", err)
				}
				for _, ct := range doc.Containers {
					o.containers = append(o.containers, ct.ID)
				}
			}
			return o, nil
		}, nil
	}
	opts := connectOpts(spec.codec)
	sys := micropodv1connect.NewSystemServiceClient(c.client, base+"/api", opts...)
	ctr := micropodv1connect.NewContainerServiceClient(c.client, base+"/api", opts...)
	ct := func(h http.Header) string { return h.Get("Content-Type") }
	switch spec.rpc {
	case "Ping":
		return func(ctx context.Context) (outcome, error) {
			r, err := sys.Ping(ctx, connect.NewRequest(&micropodv1.Empty{}))
			if err != nil {
				return outcome{}, err
			}
			return outcome{contentType: ct(r.Header()), detail: r.Msg.GetStatus() + "/" + r.Msg.GetRuntimeBackend()}, nil
		}, nil
	case "GetSystem":
		return func(ctx context.Context) (outcome, error) {
			r, err := sys.GetSystem(ctx, connect.NewRequest(&micropodv1.Empty{}))
			if err != nil {
				return outcome{}, err
			}
			return outcome{contentType: ct(r.Header()), detail: r.Msg.GetStatus().GetStatus()}, nil
		}, nil
	case "ListContainers":
		return func(ctx context.Context) (outcome, error) {
			r, err := ctr.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
			if err != nil {
				return outcome{}, err
			}
			o := outcome{contentType: ct(r.Header())}
			for _, x := range r.Msg.GetContainers() {
				o.containers = append(o.containers, x.GetId())
			}
			return o, nil
		}, nil
	case "GetContainer":
		return func(ctx context.Context) (outcome, error) {
			r, err := ctr.GetContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: spec.id}))
			if err != nil {
				return outcome{}, err
			}
			return outcome{contentType: ct(r.Header()), detail: r.Msg.GetId() + "/" + r.Msg.GetState()}, nil
		}, nil
	}
	return nil, fmt.Errorf("unknown rpc %q", spec.rpc)
}

func trim(s string, n int) string {
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}

// --- unary ----------------------------------------------------------------------

type sample struct {
	Index   int     `json:"i"`
	Worker  int     `json:"w"`
	StartUs float64 `json:"t"`
	Us      float64 `json:"us"`
	OK      bool    `json:"ok"`
	Reused  bool    `json:"reused"`
	Error   string  `json:"err,omitempty"`
}

type unaryResult struct {
	Mode          string         `json:"mode"`
	Target        string         `json:"target"`
	Transport     string         `json:"transport"`
	RPC           string         `json:"rpc"`
	Codec         string         `json:"codec"`
	CodecUsed     string         `json:"codecUsed"`
	Advertised    string         `json:"advertisedCodecs,omitempty"`
	BinaryProtoEn string         `json:"binaryProtoEnv"`
	ID            string         `json:"id,omitempty"`
	Concurrency   int            `json:"concurrency"`
	Requested     int            `json:"requested"`
	Warmup        int            `json:"warmup"`
	FirstCallUs   float64        `json:"firstCallUs"`
	FirstCallErr  string         `json:"firstCallError,omitempty"`
	Stats         *stats         `json:"stats"`
	OK            int            `json:"ok"`
	Errors        int            `json:"errors"`
	ErrorSamples  []string       `json:"errorSamples"`
	Requests      int64          `json:"requests"`
	Dials         int64          `json:"dials"`
	Reused        int64          `json:"reusedConnections"`
	Fresh         int64          `json:"freshConnections"`
	WallUs        float64        `json:"wallUs"`
	Throughput    float64        `json:"callsPerSecond"`
	ContentTypes  map[string]int `json:"contentTypes"`
	Bytes         int            `json:"responseBytes"`
	Containers    []string       `json:"containers,omitempty"`
	Detail        string         `json:"detail,omitempty"`
	ExpectPrefix  string         `json:"expectPrefix,omitempty"`
	Matching      int            `json:"matchingContainers"`
	MatchAll      bool           `json:"everySampleMatched"`
	SamplesFile   string         `json:"samplesFile,omitempty"`
}

func runUnary(args []string) (any, error) {
	fs := flag.NewFlagSet("unary", flag.ExitOnError)
	tspec := fs.String("target", "", "unix:/path or tcp:host:port")
	codec := fs.String("codec", "proto", "proto | json | rest | auto (Cuttlefish's negotiation)")
	rpc := fs.String("rpc", "Ping", "Ping | GetSystem | ListContainers | GetContainer | CacheSummary | CacheExplain | Health")
	id := fs.String("id", "", "container id for GetContainer / CacheExplain")
	n := fs.Int("n", 200, "measured calls")
	warmup := fs.Int("warmup", 20, "unmeasured calls before measuring")
	conc := fs.Int("concurrency", 1, "parallel clients sharing one transport")
	samplesOut := fs.String("samples", "", "write every sample here (JSON lines)")
	timeout := fs.Duration("timeout", 60*time.Second, "per-call timeout")
	prefix := fs.String("expect-prefix", "", "ListContainers: count listed ids with this prefix")
	count := fs.Int("expect-count", -1, "ListContainers: every sample must list exactly this many prefixed ids")
	_ = fs.Parse(args)
	t, err := parseTarget(*tspec)
	if err != nil {
		return nil, err
	}
	res := &unaryResult{Mode: "unary", Target: t.spec, Transport: t.network, RPC: *rpc, Codec: *codec, ID: *id,
		Concurrency: *conc, Requested: *n, Warmup: *warmup, ContentTypes: map[string]int{}, ErrorSamples: []string{},
		BinaryProtoEn: os.Getenv("MICROPOD_BINARY_PROTO"), ExpectPrefix: *prefix, MatchAll: true}
	c := newCounted(t, *timeout)
	used := *codec
	if used == "auto" {
		// Cuttlefish's detection: a proto-JSON Ping, then its X-Micropod-Codecs.
		probe := micropodv1connect.NewSystemServiceClient(c.client, t.baseURL()+"/api", connect.WithProtoJSON())
		r, err := probe.Ping(context.Background(), connect.NewRequest(&micropodv1.Empty{}))
		if err != nil {
			return nil, fmt.Errorf("codec negotiation Ping: %w", err)
		}
		res.Advertised = r.Header().Get("X-Micropod-Codecs")
		if micropodUnaryBinaryProto(res.Advertised) {
			used = "proto"
		} else {
			used = "json"
		}
		c.dials.Store(0)
		c.reused.Store(0)
		c.fresh.Store(0)
	}
	res.CodecUsed = used
	call, err := newCaller(c, t, rpcSpec{*rpc, used, *id})
	if err != nil {
		return nil, err
	}
	var mu sync.Mutex
	record := func(o outcome) {
		mu.Lock()
		defer mu.Unlock()
		res.ContentTypes[o.contentType]++
		res.Bytes = o.bytes
		if o.detail != "" {
			res.Detail = o.detail
		}
		if *rpc == "ListContainers" {
			res.Containers = o.containers
			if *prefix != "" {
				m := 0
				for _, id := range o.containers {
					if strings.HasPrefix(id, *prefix) {
						m++
					}
				}
				res.Matching = m
				if *count >= 0 && m != *count {
					res.MatchAll = false
				}
			}
		}
	}
	// The first call of this process: a new connection, cold client.
	t0 := time.Now()
	o, err := call(c.traced(context.Background(), nil))
	res.FirstCallUs = math.Round(us(time.Since(t0))*10) / 10
	if err != nil {
		res.FirstCallErr = err.Error()
	} else {
		record(o)
	}
	for i := 1; i < *warmup; i++ {
		if o, err := call(c.traced(context.Background(), nil)); err == nil {
			record(o)
		}
	}
	dials0, reused0, fresh0 := c.dials.Load(), c.reused.Load(), c.fresh.Load()
	samples := make([]sample, *n)
	var next atomic.Int64
	var wg sync.WaitGroup
	start := time.Now()
	for w := 0; w < *conc; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for {
				i := int(next.Add(1)) - 1
				if i >= *n {
					return
				}
				var reused bool
				ctx := c.traced(context.Background(), &reused)
				s := time.Now()
				o, err := call(ctx)
				d := time.Since(s)
				smp := sample{Index: i, Worker: w, StartUs: us(s.Sub(start)), Us: us(d), OK: err == nil, Reused: reused}
				if err != nil {
					smp.Error = trim(err.Error(), 300)
				} else {
					record(o)
				}
				samples[i] = smp
			}
		}(w)
	}
	wg.Wait()
	wall := time.Since(start)
	res.WallUs = math.Round(us(wall))
	res.Requests = int64(*n)
	res.Dials = c.dials.Load() - dials0
	res.Reused = c.reused.Load() - reused0
	res.Fresh = c.fresh.Load() - fresh0
	var lat []float64
	for _, s := range samples {
		if s.OK {
			res.OK++
			lat = append(lat, s.Us)
		} else {
			res.Errors++
			if len(res.ErrorSamples) < 5 {
				res.ErrorSamples = append(res.ErrorSamples, s.Error)
			}
		}
	}
	res.Stats = summarize(lat)
	if wall > 0 {
		res.Throughput = math.Round(float64(res.OK)/wall.Seconds()*10) / 10
	}
	if *samplesOut != "" {
		if err := writeSamples(*samplesOut, samples); err != nil {
			return nil, err
		}
		res.SamplesFile = *samplesOut
	}
	return res, nil
}

func writeSamples(path string, samples []sample) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	enc := json.NewEncoder(w)
	for _, s := range samples {
		if err := enc.Encode(s); err != nil {
			return err
		}
	}
	return w.Flush()
}

// --- create → start → wait → remove ---------------------------------------------

type roundtripResult struct {
	Mode        string            `json:"mode"`
	Target      string            `json:"target"`
	Transport   string            `json:"transport"`
	Codec       string            `json:"codec"`
	Requested   int               `json:"requested"`
	OK          int               `json:"ok"`
	Errors      []string          `json:"errors"`
	Steps       map[string]*stats `json:"steps"`
	Total       *stats            `json:"total"`
	ExitCodes   map[string]int    `json:"exitCodes"`
	Dials       int64             `json:"dials"`
	Requests    int64             `json:"requests"`
	Names       []string          `json:"names"`
	SamplesFile string            `json:"samplesFile,omitempty"`
}

func runRoundtrip(args []string) (any, error) {
	fs := flag.NewFlagSet("roundtrip", flag.ExitOnError)
	tspec := fs.String("target", "", "unix:/path or tcp:host:port")
	codec := fs.String("codec", "proto", "proto | json")
	n := fs.Int("n", 30, "round trips")
	image := fs.String("image", "alpine:3.20", "image")
	prefix := fs.String("prefix", "b25-rt", "container name prefix")
	samplesOut := fs.String("samples", "", "write every round trip here (JSON lines)")
	_ = fs.Parse(args)
	t, err := parseTarget(*tspec)
	if err != nil {
		return nil, err
	}
	c := newCounted(t, 120*time.Second)
	ctr := micropodv1connect.NewContainerServiceClient(c.client, t.baseURL()+"/api", connectOpts(*codec)...)
	res := &roundtripResult{Mode: "roundtrip", Target: t.spec, Transport: t.network, Codec: *codec, Requested: *n,
		Errors: []string{}, Steps: map[string]*stats{}, ExitCodes: map[string]int{}}
	steps := map[string][]float64{}
	var total []float64
	type rt struct {
		Name    string             `json:"name"`
		StepsUs map[string]float64 `json:"stepsUs"`
		TotalUs float64            `json:"totalUs"`
		Exit    int32              `json:"exitCode"`
		Error   string             `json:"err,omitempty"`
	}
	var rows []rt
	runtime := "hvf"
	ctx := context.Background()
	for i := 0; i < *n; i++ {
		name := fmt.Sprintf("%s-%03d", *prefix, i)
		row := rt{Name: name, StepsUs: map[string]float64{}}
		res.Names = append(res.Names, name)
		begin := time.Now()
		fail := func(step string, err error) {
			row.Error = step + ": " + trim(err.Error(), 300)
			res.Errors = append(res.Errors, name+" "+row.Error)
		}
		s := time.Now()
		cr, err := ctr.CreateContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{
			Image: *image, Name: &name, Arguments: []string{"true"}, Runtime: &runtime,
			Labels: map[string]string{"b25.roundtrip": *prefix}}))
		res.Requests++
		row.StepsUs["create"] = us(time.Since(s))
		if err != nil {
			fail("create", err)
			rows = append(rows, row)
			continue
		}
		id := cr.Msg.GetId()
		s = time.Now()
		_, err = ctr.StartContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: id}))
		res.Requests++
		row.StepsUs["start"] = us(time.Since(s))
		if err == nil {
			s = time.Now()
			var w *connect.Response[micropodv1.WaitContainerResponse]
			w, err = ctr.WaitContainer(ctx, connect.NewRequest(&micropodv1.WaitContainerRequest{Id: id, TimeoutSeconds: 60}))
			res.Requests++
			row.StepsUs["wait"] = us(time.Since(s))
			if err == nil {
				row.Exit = w.Msg.GetExitCode()
				if !w.Msg.GetExited() {
					err = fmt.Errorf("wait returned without an exit (state %q)", w.Msg.GetState())
				}
			}
			if err != nil {
				fail("wait", err)
			}
		} else {
			fail("start", err)
		}
		s = time.Now()
		_, derr := ctr.DeleteContainer(ctx, connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: id, Force: true}))
		res.Requests++
		row.StepsUs["remove"] = us(time.Since(s))
		row.TotalUs = us(time.Since(begin))
		if derr != nil && err == nil {
			fail("remove", derr)
			err = derr
		}
		if err == nil {
			res.OK++
			total = append(total, row.TotalUs)
			for k, v := range row.StepsUs {
				steps[k] = append(steps[k], v)
			}
			res.ExitCodes[fmt.Sprint(row.Exit)]++
		}
		rows = append(rows, row)
	}
	for k, v := range steps {
		res.Steps[k] = summarize(v)
	}
	res.Total = summarize(total)
	res.Dials = c.dials.Load()
	if *samplesOut != "" {
		f, err := os.Create(*samplesOut)
		if err != nil {
			return nil, err
		}
		enc := json.NewEncoder(f)
		for _, r := range rows {
			_ = enc.Encode(r)
		}
		f.Close()
		res.SamplesFile = *samplesOut
	}
	return res, nil
}

// --- streams: logs (Connect server stream or SSE) and exec ---------------------------

type ttfbResult struct {
	Mode        string   `json:"mode"`
	Target      string   `json:"target"`
	Transport   string   `json:"transport"`
	Codec       string   `json:"codec"`
	ID          string   `json:"id"`
	Requested   int      `json:"requested"`
	OK          int      `json:"ok"`
	Errors      []string `json:"errors"`
	TTFB        *stats   `json:"ttfb"`
	Total       *stats   `json:"total"`
	FirstChunk  string   `json:"firstChunk"`
	Matched     int      `json:"matchedExpected"`
	ContentType string   `json:"contentType"`
	Dials       int64    `json:"dials"`
	SamplesFile string   `json:"samplesFile,omitempty"`
}

func runLogs(args []string) (any, error) {
	fs := flag.NewFlagSet("logs", flag.ExitOnError)
	tspec := fs.String("target", "", "unix:/path or tcp:host:port")
	codec := fs.String("codec", "proto", "proto | json | sse")
	id := fs.String("id", "", "container")
	n := fs.Int("n", 50, "streams opened")
	tail := fs.Int("tail", 5, "tail lines requested")
	expect := fs.String("expect", "", "the first line every stream must deliver")
	samplesOut := fs.String("samples", "", "write every sample here (JSON lines)")
	_ = fs.Parse(args)
	t, err := parseTarget(*tspec)
	if err != nil {
		return nil, err
	}
	c := newCounted(t, 0)
	res := &ttfbResult{Mode: "logs", Target: t.spec, Transport: t.network, Codec: *codec, ID: *id, Requested: *n, Errors: []string{}}
	var first, totals []float64
	var rows []sample
	ctr := micropodv1connect.NewContainerServiceClient(c.client, t.baseURL()+"/api", connectOpts(*codec)...)
	for i := 0; i < *n; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		s := time.Now()
		var line string
		var ttfb time.Duration
		var err error
		if *codec == "sse" {
			var req *http.Request
			req, err = http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/v1/containers/%s/logs?tail=%d", t.baseURL(), *id, *tail), nil)
			if err == nil {
				var resp *http.Response
				resp, err = c.client.Do(req)
				if err == nil {
					res.ContentType = resp.Header.Get("Content-Type")
					br := bufio.NewReader(resp.Body)
					for {
						var l string
						l, err = br.ReadString('\n')
						if err != nil {
							break
						}
						if strings.HasPrefix(l, "data: ") {
							ttfb = time.Since(s)
							line = strings.TrimRight(strings.TrimPrefix(l, "data: "), "\r\n")
							break
						}
					}
					resp.Body.Close()
				}
			}
		} else {
			var stream *connect.ServerStreamForClient[micropodv1.LogChunk]
			stream, err = ctr.StreamContainerLogs(ctx, connect.NewRequest(&micropodv1.StreamLogsRequest{Id: *id, Tail: int32(*tail)}))
			if err == nil {
				if stream.Receive() {
					ttfb = time.Since(s)
					line = strings.TrimRight(stream.Msg().GetText(), "\r\n")
					res.ContentType = stream.ResponseHeader().Get("Content-Type")
				} else if stream.Err() != nil {
					err = stream.Err()
				} else {
					err = errors.New("the stream ended before any chunk")
				}
				stream.Close()
			}
		}
		total := time.Since(s)
		cancel()
		smp := sample{Index: i, Us: us(ttfb), OK: err == nil && ttfb > 0}
		if err != nil {
			smp.Error = trim(err.Error(), 300)
			res.Errors = append(res.Errors, smp.Error)
		} else if ttfb > 0 {
			res.OK++
			first = append(first, us(ttfb))
			totals = append(totals, us(total))
			if i == 0 {
				res.FirstChunk = line
			}
			if *expect != "" && line == *expect {
				res.Matched++
			}
		}
		rows = append(rows, smp)
	}
	res.TTFB = summarize(first)
	res.Total = summarize(totals)
	res.Dials = c.dials.Load()
	if *samplesOut != "" {
		if err := writeSamples(*samplesOut, rows); err != nil {
			return nil, err
		}
		res.SamplesFile = *samplesOut
	}
	return res, nil
}

func runExec(args []string) (any, error) {
	fs := flag.NewFlagSet("exec", flag.ExitOnError)
	tspec := fs.String("target", "", "unix:/path or tcp:host:port")
	codec := fs.String("codec", "proto", "proto | json")
	id := fs.String("id", "", "container")
	n := fs.Int("n", 50, "execs")
	samplesOut := fs.String("samples", "", "write every sample here (JSON lines)")
	_ = fs.Parse(args)
	t, err := parseTarget(*tspec)
	if err != nil {
		return nil, err
	}
	c := newCounted(t, 120*time.Second)
	ctr := micropodv1connect.NewContainerServiceClient(c.client, t.baseURL()+"/api", connectOpts(*codec)...)
	res := &ttfbResult{Mode: "exec", Target: t.spec, Transport: t.network, Codec: *codec, ID: *id, Requested: *n, Errors: []string{}}
	var lat []float64
	var rows []sample
	for i := 0; i < *n; i++ {
		want := fmt.Sprintf("b25-exec-%d", i)
		s := time.Now()
		r, err := ctr.Exec(context.Background(), connect.NewRequest(&micropodv1.ExecRequest{Id: *id, Arguments: []string{"echo", want}}))
		d := time.Since(s)
		smp := sample{Index: i, Us: us(d), OK: err == nil}
		if err != nil {
			smp.Error = trim(err.Error(), 300)
			res.Errors = append(res.Errors, smp.Error)
		} else {
			res.ContentType = r.Header().Get("Content-Type")
			got := strings.TrimSpace(r.Msg.GetOutput())
			if got == want && r.Msg.GetExitCode() == 0 {
				res.Matched++
				res.OK++
				lat = append(lat, us(d))
			} else {
				smp.OK = false
				smp.Error = fmt.Sprintf("output %q exit %d, want %q exit 0", got, r.Msg.GetExitCode(), want)
				res.Errors = append(res.Errors, smp.Error)
			}
			if i == 0 {
				res.FirstChunk = got
			}
		}
		rows = append(rows, smp)
	}
	// Exec is unary: its first byte is its whole reply.
	res.TTFB = summarize(lat)
	res.Total = res.TTFB
	res.Dials = c.dials.Load()
	if *samplesOut != "" {
		if err := writeSamples(*samplesOut, rows); err != nil {
			return nil, err
		}
		res.SamplesFile = *samplesOut
	}
	return res, nil
}

// --- probes: HTTP/2 gRPC, attach, codec advertisement ---------------------------------

type probeResult struct {
	Mode            string            `json:"mode"`
	Target          string            `json:"target"`
	GRPC            map[string]string `json:"grpcH2c"`
	ConnectH2C      map[string]string `json:"connectH2c"`
	Attach          map[string]string `json:"attach"`
	Advertised      string            `json:"advertisedCodecs"`
	ConnectionClose string            `json:"connectionHeader"`
	HTTPVersion     string            `json:"httpVersion"`
}

func h2cClient(t target) *http.Client {
	return &http.Client{Timeout: 10 * time.Second, Transport: &http2.Transport{
		AllowHTTP: true,
		DialTLSContext: func(ctx context.Context, _, _ string, _ *tls.Config) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, t.network, t.address)
		},
	}}
}

func runProbe(args []string) (any, error) {
	fs := flag.NewFlagSet("probe", flag.ExitOnError)
	tspec := fs.String("target", "", "unix:/path or tcp:host:port")
	id := fs.String("id", "", "a running container, for the attach probe")
	_ = fs.Parse(args)
	t, err := parseTarget(*tspec)
	if err != nil {
		return nil, err
	}
	res := &probeResult{Mode: "probe", Target: t.spec, GRPC: map[string]string{}, ConnectH2C: map[string]string{}, Attach: map[string]string{}}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// gRPC (application/grpc) over HTTP/2 with prior knowledge.
	g := micropodv1connect.NewSystemServiceClient(h2cClient(t), t.baseURL()+"/api", connect.WithGRPC())
	if r, err := g.Ping(ctx, connect.NewRequest(&micropodv1.Empty{})); err != nil {
		res.GRPC["error"] = trim(err.Error(), 400)
	} else {
		res.GRPC["status"] = r.Msg.GetStatus()
	}
	// Connect binary over HTTP/2 with prior knowledge.
	h := micropodv1connect.NewSystemServiceClient(h2cClient(t), t.baseURL()+"/api")
	if r, err := h.Ping(ctx, connect.NewRequest(&micropodv1.Empty{})); err != nil {
		res.ConnectH2C["error"] = trim(err.Error(), 400)
	} else {
		res.ConnectH2C["status"] = r.Msg.GetStatus()
	}
	// The HTTP/1.1 answer: its protocol, Connection header and codec advertisement.
	c := newCounted(t, 10*time.Second)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, t.baseURL()+"/api/micropod.v1.SystemService/Ping", bytes.NewReader([]byte("{}")))
	req.Header.Set("Content-Type", "application/json")
	if resp, err := c.client.Do(req); err == nil {
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		res.Advertised = resp.Header.Get("X-Micropod-Codecs")
		// net/http consumes the Connection header; resp.Close is what it said.
		res.ConnectionClose = resp.Header.Get("Connection")
		if resp.Close && res.ConnectionClose == "" {
			res.ConnectionClose = "close"
		}
		res.HTTPVersion = resp.Proto
	}
	// AttachContainer: a bidi RPC the plan asks for (B39); probe whether it exists.
	body := []byte(fmt.Sprintf(`{"id":%q}`, *id))
	areq, _ := http.NewRequestWithContext(ctx, http.MethodPost, t.baseURL()+"/api/micropod.v1.ContainerService/AttachContainer", bytes.NewReader(body))
	areq.Header.Set("Content-Type", "application/connect+json")
	if resp, err := c.client.Do(areq); err != nil {
		res.Attach["error"] = trim(err.Error(), 300)
	} else {
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		res.Attach["status"] = fmt.Sprint(resp.StatusCode)
		res.Attach["body"] = trim(string(b), 300)
	}
	return res, nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: cpbench unary|roundtrip|logs|exec|probe [flags]")
		os.Exit(2)
	}
	var out any
	var err error
	switch os.Args[1] {
	case "unary":
		out, err = runUnary(os.Args[2:])
	case "roundtrip":
		out, err = runRoundtrip(os.Args[2:])
	case "logs":
		out, err = runLogs(os.Args[2:])
	case "exec":
		out, err = runExec(os.Args[2:])
	case "probe":
		out, err = runProbe(os.Args[2:])
	default:
		err = fmt.Errorf("unknown mode %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "cpbench:", err)
		os.Exit(1)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(out)
}
