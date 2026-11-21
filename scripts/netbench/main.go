// Command netbench measures the same in-guest service path with each runtime.
// Build once for linux/arm64 and put the same binary in every image.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const size = 8 << 20

var payload = bytes.Repeat([]byte("micropod"), size/8)

func main() {
	listen := flag.String("listen", "", "listen address for server mode")
	target := flag.String("url", "", "service URL for client mode")
	marker := flag.String("marker", "ok", "expected server identity")
	rounds := flag.Int("requests", 200, "number of small requests")
	streams := flag.Int("streams", 0, "simultaneous bulk TCP transfers")
	bursts := flag.Int("bursts", 1, "number of parallel transfer batches")
	barrier := flag.Bool("stream-barrier", false, "wait for every response to begin before draining the parallel streams")
	profile := flag.String("profile", "", "profile fresh requests, sustained bulk streams, or fresh requests during continuous downloads (fresh, bulk, mixed, burst-fresh, or burst-warm)")
	traceMixed := flag.Bool("trace-mixed", false, "sample per-stream bytes and fresh HTTP phase timestamps around the mixed interval")
	freshURL := flag.String("fresh-url", "", "mixed profile only: send fresh requests to a second URL serving the same marker")
	netInfo := flag.Bool("net-info", false, "snapshot Linux network-namespace and cgroup counters")
	cgroupInfo := flag.Bool("cgroup-info", false, "print the actual cgroup v2 limits seen inside this Linux container")
	dns := flag.Int("lookups", 0, "number of single-family service DNS lookups")
	dnsClients := flag.Int("dns-clients", 1, "independent resolvers issuing parallel service lookups")
	flag.Parse()
	if *netInfo {
		files := []string{"/proc/net/snmp", "/proc/net/netstat", "/proc/net/sockstat", "/proc/net/dev", "/proc/net/stat/nf_conntrack",
			"/proc/sys/net/netfilter/nf_conntrack_count", "/proc/sys/net/netfilter/nf_conntrack_max",
			"/sys/fs/cgroup/cpu.stat", "/sys/fs/cgroup/cpu.pressure", "/sys/fs/cgroup/memory.events"}
		values := map[string]string{}
		for _, path := range files {
			if b, err := os.ReadFile(path); err == nil {
				values[path] = strings.TrimSpace(string(b))
			}
		}
		if _, ok := values["/proc/net/netstat"]; !ok {
			log.Fatal("missing Linux network counters")
		}
		if err := json.NewEncoder(os.Stdout).Encode(values); err != nil {
			log.Fatal(err)
		}
		return
	}
	if *cgroupInfo {
		limits := map[string]any{"visible_cpus": runtime.NumCPU(), "gomaxprocs": runtime.GOMAXPROCS(0)}
		for _, name := range []string{"cpu.max", "cpuset.cpus.effective", "memory.max", "pids.max", "cpu.stat"} {
			value, err := os.ReadFile("/sys/fs/cgroup/" + name)
			if err != nil {
				log.Fatal(err)
			}
			limits[name] = strings.TrimSpace(string(value))
		}
		if err := json.NewEncoder(os.Stdout).Encode(limits); err != nil {
			log.Fatal(err)
		}
		return
	}
	if *listen != "" {
		mux := http.NewServeMux()
		mux.HandleFunc("/id", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, *marker) })
		mux.HandleFunc("/data", func(w http.ResponseWriter, r *http.Request) {
			http.ServeContent(w, r, "data", time.Time{}, bytes.NewReader(payload))
		})
		log.Fatal((&http.Server{Addr: *listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second}).ListenAndServe())
	}
	maxBursts := 100
	if *profile == "bulk" {
		// Keep established streams alive across the worker's network health interval.
		maxBursts = 1024
	}
	if *target == "" || *rounds < 2 || *streams < 0 || *streams > 128 || *bursts < 1 || *bursts > maxBursts || *dns < 0 || *dns > 10000 || *dnsClients < 1 || *dnsClients > 128 {
		flag.Usage()
		os.Exit(2)
	}
	if *traceMixed && *profile != "mixed" {
		log.Fatal("-trace-mixed requires -profile mixed")
	}
	if *freshURL != "" && *profile != "mixed" {
		log.Fatal("-fresh-url is only used with -profile mixed")
	}
	tr := &http.Transport{DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext}
	client := &http.Client{Transport: tr, Timeout: 15 * time.Second}
	ctx := context.Background()
	get := func(ctx context.Context, path string, w io.Writer) int64 {
		return requestBody(client, *target, ctx, path, w)
	}
	id := func(ctx context.Context) { verifyID(client, *target, *marker, ctx) }
	if *profile != "" {
		var result map[string]any
		switch *profile {
		case "fresh":
			result = profileFresh(client, *target, *marker, *rounds, time.Now(), nil)
		case "burst-fresh", "burst-warm":
			if *streams == 0 {
				log.Fatal("burst profiling needs at least one stream")
			}
			result = profileBurst(*target, *marker, *streams, *bursts, *profile == "burst-warm", *barrier)
		case "bulk":
			if *streams == 0 {
				log.Fatal("bulk profiling needs at least one stream")
			}
			result = profileBulk(*target, *marker, *streams, *bursts)
		case "mixed":
			if *streams == 0 {
				log.Fatal("mixed profiling needs at least one stream")
			}
			if *freshURL == "" {
				*freshURL = *target
			}
			result = profileMixed(*target, *freshURL, *marker, *streams, *rounds, *traceMixed)
		default:
			log.Fatalf("unknown profile %q", *profile)
		}
		if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
			log.Fatal(err)
		}
		return
	}
	id(ctx)
	sum := sha256.New()
	if get(ctx, "/data", sum) != size || !bytes.Equal(sum.Sum(nil), hashPayload()) {
		log.Fatal("bulk response integrity")
	}
	result := map[string]any{"requests": *rounds, "bulk_bytes": 8 * size}
	for _, mode := range []string{"keepalive", "fresh"} {
		samples := make([]int64, *rounds)
		connect, response := make([]int64, *rounds), make([]int64, *rounds)
		for i := range samples {
			reqCtx := ctx
			var connected, firstByte time.Time
			if mode == "fresh" {
				tr.CloseIdleConnections()
				reqCtx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
					GotConn: func(c httptrace.GotConnInfo) {
						if c.Reused {
							log.Fatal("fresh request reused a connection")
						}
						connected = time.Now()
					},
					GotFirstResponseByte: func() { firstByte = time.Now() },
				})
			}
			start := time.Now()
			id(reqCtx)
			samples[i] = time.Since(start).Microseconds()
			if mode == "fresh" {
				connect[i] = connected.Sub(start).Microseconds()
				response[i] = firstByte.Sub(connected).Microseconds()
			}
		}
		slices.Sort(samples)
		result[mode+"_p50_us"] = samples[len(samples)/2]
		result[mode+"_p95_us"] = samples[(len(samples)*95-1)/100]
		result[mode+"_p99_us"] = samples[(len(samples)*99-1)/100]
		if mode == "fresh" {
			slices.Sort(connect)
			slices.Sort(response)
			result["fresh_connect_p50_us"] = connect[len(connect)/2]
			result["fresh_connected_to_first_byte_p50_us"] = response[len(response)/2]
		}
	}
	start := time.Now()
	for range 8 {
		if get(ctx, "/data", io.Discard) != size {
			log.Fatal("short bulk response")
		}
	}
	result["bulk_mib_s"] = float64(8*size) / (1 << 20) / time.Since(start).Seconds()
	if *streams > 0 {
		rates := make([]float64, *bursts)
		for i := range rates {
			tr.CloseIdleConnections()
			batch, cancel := context.WithTimeout(ctx, client.Timeout)
			if *barrier {
				var arrivals atomic.Int32
				ready := make(chan struct{})
				batch = httptrace.WithClientTrace(batch, &httptrace.ClientTrace{GotFirstResponseByte: func() {
					if arrivals.Add(1) == int32(*streams) {
						close(ready)
					}
					select {
					case <-ready:
					case <-batch.Done():
						log.Fatal("parallel response barrier timed out")
					}
				}})
			}
			var group sync.WaitGroup
			gate := make(chan struct{})
			for range *streams {
				group.Go(func() {
					<-gate
					if get(batch, "/data", io.Discard) != size {
						log.Fatal("short parallel response")
					}
				})
			}
			start = time.Now()
			close(gate)
			group.Wait()
			rates[i] = float64(*streams*size) / (1 << 20) / time.Since(start).Seconds()
			cancel()
		}
		result["parallel_streams"] = *streams
		result["parallel_bursts_mib_s"] = rates
		result["parallel_barrier"] = *barrier
		ordered := slices.Clone(rates)
		slices.Sort(ordered)
		result["parallel_mib_s"] = ordered[len(ordered)/2]
	}
	if *dns > 0 {
		address, err := url.Parse(*target)
		if err != nil {
			log.Fatal(err)
		}
		samples := make([]int64, *dns**dnsClients)
		var group sync.WaitGroup
		gate := make(chan struct{})
		for i := range *dnsClients {
			group.Go(func() {
				resolver := &net.Resolver{PreferGo: true}
				local := samples[i**dns : (i+1)**dns]
				<-gate
				for j := range local {
					ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
					start := time.Now()
					ips, err := resolver.LookupNetIP(ctx, "ip4", address.Hostname())
					local[j] = time.Since(start).Microseconds()
					cancel()
					if err != nil || len(ips) == 0 {
						log.Fatalf("service DNS: %v", err)
					}
				}
			})
		}
		begin := time.Now()
		close(gate)
		group.Wait()
		result["dns_clients"] = *dnsClients
		result["dns_queries"] = len(samples)
		result["dns_queries_s"] = float64(len(samples)) / time.Since(begin).Seconds()
		slices.Sort(samples)
		result["dns_p50_us"] = samples[len(samples)/2]
		result["dns_p95_us"] = samples[(len(samples)*95-1)/100]
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		log.Fatal(err)
	}
}
func hashPayload() []byte { h := sha256.Sum256(payload); return h[:] }

func readBody(client *http.Client, target string, ctx context.Context, path string, w io.Writer) (int64, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target+path, nil)
	if err != nil {
		return 0, err
	}
	r, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer r.Body.Close()
	if r.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("GET %s returned %s", path, r.Status)
	}
	return io.Copy(w, r.Body)
}

func requestBody(client *http.Client, target string, ctx context.Context, path string, w io.Writer) int64 {
	n, err := readBody(client, target, ctx, path, w)
	if err != nil {
		log.Fatalf("GET %s after %d bytes: %v", path, n, err)
	}
	return n
}

func checkID(client *http.Client, target, marker string, ctx context.Context) error {
	var b bytes.Buffer
	if _, err := readBody(client, target, ctx, "/id", &b); err != nil {
		return err
	}
	if b.String() != marker {
		return fmt.Errorf("unexpected service identity %q", b.String())
	}
	return nil
}

func verifyID(client *http.Client, target, marker string, ctx context.Context) {
	if err := checkID(client, target, marker, ctx); err != nil {
		log.Fatal(err)
	}
}

func profileFresh(client *http.Client, target, marker string, requests int, origin time.Time, completed func(freshArrival)) map[string]any {
	result := map[string]any{"mode": "fresh", "iterations": requests}
	phases := make(map[string][]int64)
	incomplete := 0
	begin := time.Now()
	for i := range requests {
		client.CloseIdleConnections()
		var connected, written, first atomic.Int64
		var local atomic.Pointer[net.TCPAddr]
		start := time.Now()
		ctx := httptrace.WithClientTrace(context.Background(), &httptrace.ClientTrace{
			GotConn: func(c httptrace.GotConnInfo) {
				if c.Reused {
					log.Fatal("fresh request reused a connection")
				}
				connected.Store(time.Since(start).Nanoseconds())
				addr, _ := c.Conn.LocalAddr().(*net.TCPAddr)
				local.Store(addr)
			},
			WroteRequest: func(w httptrace.WroteRequestInfo) {
				if w.Err == nil {
					written.Store(time.Since(start).Nanoseconds())
				}
			},
			GotFirstResponseByte: func() { first.Store(time.Since(start).Nanoseconds()) },
		})
		err := checkID(client, target, marker, ctx)
		end := time.Now()
		c, w, f := connected.Load(), written.Load(), first.Load()
		if completed != nil || err != nil {
			offset := start.Sub(origin)
			arrival := freshArrival{Start: offset.Microseconds(), Done: end.Sub(origin).Microseconds()}
			if w > 0 {
				arrival.Written = (offset + time.Duration(w)).Microseconds()
			}
			if f > 0 {
				arrival.First = (offset + time.Duration(f)).Microseconds()
			}
			if err != nil {
				log.Fatalf("fresh request %d/%d local=%v origin_unix_us=%d start_us=%d written_us=%d first_byte_us=%d failed_us=%d: %v",
					i+1, requests, local.Load(), origin.UnixMicro(), arrival.Start, arrival.Written, arrival.First, arrival.Done, err)
			}
			completed(arrival)
		}
		phases["complete_ns"] = append(phases["complete_ns"], end.Sub(start).Nanoseconds())
		// HTTP trace callbacks can run on different goroutines. Count an
		// overlapped or missing callback instead of reporting a negative phase.
		if c <= 0 || w < c || f < w {
			incomplete++
			continue
		}
		phases["connect_ns"] = append(phases["connect_ns"], c)
		phases["write_ns"] = append(phases["write_ns"], w-c)
		phases["written_to_first_byte_ns"] = append(phases["written_to_first_byte_ns"], f-w)
	}
	result["elapsed_s"] = time.Since(begin).Seconds()
	result["incomplete_phase_samples"] = incomplete
	for name, samples := range phases {
		slices.Sort(samples)
		result[name] = map[string]int64{"p50": samples[(len(samples)-1)/2], "p95": samples[(len(samples)*95-1)/100], "p99": samples[(len(samples)*99-1)/100]}
	}
	return result
}

func downloadClient(target, marker string, reopened *atomic.Int64) (*http.Client, context.Context) {
	tr := &http.Transport{DialContext: (&net.Dialer{Timeout: 5 * time.Second}).DialContext, MaxIdleConnsPerHost: 1}
	client := &http.Client{Transport: tr, Timeout: 30 * time.Second}
	verifyID(client, target, marker, context.Background())
	ctx := httptrace.WithClientTrace(context.Background(), &httptrace.ClientTrace{
		GotConn: func(c httptrace.GotConnInfo) {
			if !c.Reused {
				reopened.Add(1)
			}
		},
	})
	return client, ctx
}

// Keep body bytes, stream count and start gate identical. The optional header
// barrier releases every first response together. Each stream owns its verified
// connection so net/http cannot silently share or pool sockets between streams.
func profileBurst(target, marker string, streams, transfers int, warm, barrier bool) map[string]any {
	type sample struct {
		Connected int64 `json:"connected_us"`
		Written   int64 `json:"request_written_us"`
		First     int64 `json:"first_header_us"`
		FirstDone int64 `json:"first_body_complete_us"`
		Done      int64 `json:"complete_us"`
	}
	phases := make([]sample, streams)
	var ready, done sync.WaitGroup
	var mismatch, arrivals, reopened atomic.Int64
	startGate, headerGate := make(chan struct{}), make(chan struct{})
	var begin time.Time
	ready.Add(streams)
	for i := range streams {
		done.Go(func() {
			client, next := downloadClient(target, marker, &reopened)
			defer client.CloseIdleConnections()
			if !warm {
				client.CloseIdleConnections()
			}
			ready.Done()
			<-startGate
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			var connected, written, first atomic.Int64
			ctx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
				GotConn: func(info httptrace.GotConnInfo) {
					if info.Reused != warm {
						mismatch.Add(1)
					}
					connected.Store(time.Since(begin).Microseconds())
				},
				WroteRequest: func(info httptrace.WroteRequestInfo) {
					if info.Err == nil {
						written.Store(time.Since(begin).Microseconds())
					}
				},
				GotFirstResponseByte: func() {
					first.Store(time.Since(begin).Microseconds())
					if barrier {
						if arrivals.Add(1) == int64(streams) {
							close(headerGate)
						}
						select {
						case <-headerGate:
						case <-ctx.Done():
							log.Fatal("first-response barrier timed out")
						}
					}
				},
			})
			if requestBody(client, target, ctx, "/data", io.Discard) != size {
				log.Fatal("short first transfer")
			}
			firstDone := time.Since(begin).Microseconds()
			for j := 1; j < transfers; j++ {
				if requestBody(client, target, next, "/data", io.Discard) != size {
					log.Fatal("short subsequent transfer")
				}
			}
			phases[i] = sample{connected.Load(), written.Load(), first.Load(), firstDone, time.Since(begin).Microseconds()}
		})
	}
	ready.Wait()
	begin = time.Now()
	close(startGate)
	done.Wait()
	// End the transfer at the last complete body, excluding transport cleanup.
	var elapsed int64
	for _, phase := range phases {
		elapsed = max(elapsed, phase.Done)
	}
	total := int64(streams) * int64(transfers) * size
	return map[string]any{"warm": warm, "first_response_barrier": barrier, "streams": streams, "transfers_per_stream": transfers,
		"bytes": total, "elapsed_us": elapsed, "mib_s": float64(total) / (1 << 20) / (float64(elapsed) / 1e6), "initial_connection_mismatches": mismatch.Load(),
		"unexpected_reconnects": reopened.Load(), "stream_phases": phases}
}

func profileBulk(target, marker string, streams, transfers int) map[string]any {
	var ready, done sync.WaitGroup
	var newConnections atomic.Int64
	gate := make(chan struct{})
	ready.Add(streams)
	for range streams {
		done.Go(func() {
			client, ctx := downloadClient(target, marker, &newConnections)
			defer client.CloseIdleConnections()
			ready.Done()
			<-gate
			for range transfers {
				if requestBody(client, target, ctx, "/data", io.Discard) != size {
					log.Fatal("short bulk response")
				}
			}
		})
	}
	ready.Wait()
	start := time.Now()
	close(gate)
	done.Wait()
	elapsed := time.Since(start).Seconds()
	total := int64(streams) * int64(transfers) * size
	return map[string]any{"mode": "bulk", "iterations": transfers, "streams": streams, "bytes": total,
		"elapsed_s": elapsed, "mib_s": float64(total) / (1 << 20) / elapsed, "reopened_connections": newConnections.Load()}
}

// Each downloader uses one verified connection. Counters are per stream so
// measuring the offered load does not add a shared lock to every socket read.
type downloadCounter struct {
	bytes atomic.Int64
}

func (c *downloadCounter) Write(p []byte) (int, error) {
	c.bytes.Add(int64(len(p)))
	return len(p), nil
}

func profileMixed(bulkURL, freshURL, marker string, streams, requests int, trace bool) map[string]any {
	var ready, done sync.WaitGroup
	var reopened atomic.Int64
	counters := make([]downloadCounter, streams)
	stop := make(chan struct{})
	warmup := time.Now()
	ready.Add(streams)
	for i := range counters {
		done.Go(func() {
			client, ctx := downloadClient(bulkURL, marker, &reopened)
			defer client.CloseIdleConnections()
			// Finish one complete transfer before counting this stream as warm.
			for first := true; ; first = false {
				if requestBody(client, bulkURL, ctx, "/data", &counters[i]) != size {
					log.Fatal("short mixed-load transfer")
				}
				if first {
					ready.Done()
				}
				select {
				case <-stop:
					return
				default:
				}
			}
		})
	}
	ready.Wait()
	warmupTime := time.Since(warmup)
	// Trace runs include equal bulk-only windows on either side. Leave the
	// qualification workload and hot read path identical when tracing is off.
	var samples []mixedSample
	var arrivals []freshArrival
	var omitted int
	traceDone := make(chan struct{})
	stopTrace := make(chan struct{})
	origin := time.Now()
	if trace {
		go func() {
			defer close(traceDone)
			timer := time.NewTicker(5 * time.Millisecond)
			defer timer.Stop()
			for {
				if len(samples) < 24000 {
					row := mixedSample{AtUS: time.Since(origin).Microseconds(), Bytes: make([]int64, streams)}
					for i := range counters {
						row.Bytes[i] = counters[i].bytes.Load()
					}
					samples = append(samples, row)
				} else {
					omitted++
				}
				select {
				case <-timer.C:
				case <-stopTrace:
					return
				}
			}
		}()
		time.Sleep(400 * time.Millisecond)
	}
	warmupReopens := reopened.Load()
	tr := &http.Transport{DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 15 * time.Second}
	before := make([]int64, streams)
	perStream := make([]int64, streams)
	for i := range counters {
		before[i] = counters[i].bytes.Load()
	}
	begin := time.Now()
	var elapsed time.Duration
	var total, endReopens int64
	remaining := requests
	fresh := profileFresh(client, freshURL, marker, requests, origin, func(arrival freshArrival) {
		if trace {
			arrivals = append(arrivals, arrival)
		}
		remaining--
		if remaining == 0 {
			elapsed = time.Since(begin)
			endReopens = reopened.Load()
			for i := range counters {
				perStream[i] = counters[i].bytes.Load() - before[i]
				total += perStream[i]
			}
			if !trace {
				close(stop)
			}
		}
	})
	if trace {
		time.Sleep(400 * time.Millisecond)
		close(stopTrace)
		<-traceDone
		close(stop)
	}
	done.Wait()
	result := map[string]any{"mode": "mixed", "fresh": fresh, "streams": streams,
		"warmup_s": warmupTime.Seconds(), "warmup_reopens": warmupReopens,
		"overlap_reopens": endReopens - warmupReopens, "drain_reopens": reopened.Load() - endReopens,
		"overlap_s": elapsed.Seconds(), "overlap_bytes": total, "overlap_bytes_per_stream": perStream,
		"overlap_mib_s": float64(total) / (1 << 20) / elapsed.Seconds(), "reopened_connections": reopened.Load()}
	if trace {
		result["trace"] = map[string]any{"origin_unix_us": origin.UnixMicro(), "sample_period_us": 5000,
			"samples": samples, "omitted_samples": omitted,
			"fresh": arrivals, "overlap_start_us": begin.Sub(origin).Microseconds(), "overlap_end_us": begin.Add(elapsed).Sub(origin).Microseconds()}
	}
	return result
}

type mixedSample struct {
	AtUS  int64   `json:"at_us"`
	Bytes []int64 `json:"cumulative_bytes"`
}

type freshArrival struct {
	Start   int64 `json:"start_us"`
	Written int64 `json:"written_us"`
	First   int64 `json:"first_byte_us"`
	Done    int64 `json:"done_us"`
}
