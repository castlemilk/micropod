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
	profile := flag.String("profile", "", "profile fresh requests, sustained bulk streams, or fresh requests during continuous downloads (fresh, bulk, or mixed)")
	freshURL := flag.String("fresh-url", "", "mixed profile only: send fresh requests to a second URL serving the same marker")
	cgroupInfo := flag.Bool("cgroup-info", false, "print the actual cgroup v2 limits seen inside this Linux container")
	dns := flag.Int("lookups", 0, "number of single-family service DNS lookups")
	dnsClients := flag.Int("dns-clients", 1, "independent resolvers issuing parallel service lookups")
	flag.Parse()
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
	if *target == "" || *rounds < 2 || *streams < 0 || *streams > 128 || *bursts < 1 || *bursts > 100 || *dns < 0 || *dns > 10000 || *dnsClients < 1 || *dnsClients > 128 {
		flag.Usage()
		os.Exit(2)
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
			result = profileFresh(client, id, *rounds)
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
			result = profileMixed(*target, *freshURL, *marker, *streams, *rounds)
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

func requestBody(client *http.Client, target string, ctx context.Context, path string, w io.Writer) int64 {
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, target+path, nil)
	if e != nil {
		log.Fatal(e)
	}
	r, e := client.Do(req)
	if e != nil {
		log.Fatal(e)
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		log.Fatal(r.Status)
	}
	n, e := io.Copy(w, r.Body)
	if e != nil {
		log.Fatal(e)
	}
	return n
}

func verifyID(client *http.Client, target, marker string, ctx context.Context) {
	var b bytes.Buffer
	requestBody(client, target, ctx, "/id", &b)
	if b.String() != marker {
		log.Fatalf("unexpected service identity %q", b.String())
	}
}

func profileFresh(client *http.Client, verify func(context.Context), requests int) map[string]any {
	result := map[string]any{"mode": "fresh", "iterations": requests}
	phases := make(map[string][]int64)
	incomplete := 0
	begin := time.Now()
	for range requests {
		client.CloseIdleConnections()
		var connected, written, first atomic.Int64
		start := time.Now()
		ctx := httptrace.WithClientTrace(context.Background(), &httptrace.ClientTrace{
			GotConn: func(c httptrace.GotConnInfo) {
				if c.Reused {
					log.Fatal("fresh request reused a connection")
				}
				connected.Store(time.Since(start).Nanoseconds())
			},
			WroteRequest: func(w httptrace.WroteRequestInfo) {
				if w.Err == nil {
					written.Store(time.Since(start).Nanoseconds())
				}
			},
			GotFirstResponseByte: func() { first.Store(time.Since(start).Nanoseconds()) },
		})
		verify(ctx)
		phases["complete_ns"] = append(phases["complete_ns"], time.Since(start).Nanoseconds())
		c, w, f := connected.Load(), written.Load(), first.Load()
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

func profileMixed(bulkURL, freshURL, marker string, streams, requests int) map[string]any {
	var ready, done sync.WaitGroup
	var reopened atomic.Int64
	counters := make([]downloadCounter, streams)
	stop := make(chan struct{})
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
	var total int64
	remaining := requests
	fresh := profileFresh(client, func(ctx context.Context) {
		verifyID(client, freshURL, marker, ctx)
		remaining--
		if remaining == 0 {
			elapsed = time.Since(begin)
			for i := range counters {
				perStream[i] = counters[i].bytes.Load() - before[i]
				total += perStream[i]
			}
			close(stop)
		}
	}, requests)
	done.Wait()
	return map[string]any{"mode": "mixed", "fresh": fresh, "streams": streams,
		"overlap_s": elapsed.Seconds(), "overlap_bytes": total, "overlap_bytes_per_stream": perStream,
		"overlap_mib_s": float64(total) / (1 << 20) / elapsed.Seconds(), "reopened_connections": reopened.Load()}
}
