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
	"net/url"
	"os"
	"slices"
	"sync"
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
	dns := flag.Int("lookups", 0, "number of single-family service DNS lookups")
	dnsClients := flag.Int("dns-clients", 1, "independent resolvers issuing parallel service lookups")
	flag.Parse()
	if *listen != "" {
		mux := http.NewServeMux()
		mux.HandleFunc("/id", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, *marker) })
		mux.HandleFunc("/data", func(w http.ResponseWriter, r *http.Request) {
			http.ServeContent(w, r, "data", time.Time{}, bytes.NewReader(payload))
		})
		log.Fatal((&http.Server{Addr: *listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second}).ListenAndServe())
	}
	if *target == "" || *rounds < 2 || *streams < 0 || *streams > 128 || *dns < 0 || *dns > 10000 || *dnsClients < 1 || *dnsClients > 128 {
		flag.Usage()
		os.Exit(2)
	}
	tr := &http.Transport{DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext}
	client := &http.Client{Transport: tr, Timeout: 15 * time.Second}
	get := func(path string, w io.Writer) int64 {
		r, e := client.Get(*target + path)
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
	id := func() {
		var b bytes.Buffer
		get("/id", &b)
		if b.String() != *marker {
			log.Fatalf("unexpected service identity %q", b.String())
		}
	}
	id()
	sum := sha256.New()
	if get("/data", sum) != size || !bytes.Equal(sum.Sum(nil), hashPayload()) {
		log.Fatal("bulk response integrity")
	}
	result := map[string]any{"requests": *rounds, "bulk_bytes": 8 * size}
	for _, mode := range []string{"keepalive", "fresh"} {
		samples := make([]int64, *rounds)
		for i := range samples {
			if mode == "fresh" {
				tr.CloseIdleConnections()
			}
			start := time.Now()
			id()
			samples[i] = time.Since(start).Microseconds()
		}
		slices.Sort(samples)
		result[mode+"_p50_us"] = samples[len(samples)/2]
		result[mode+"_p95_us"] = samples[(len(samples)*95-1)/100]
	}
	start := time.Now()
	for range 8 {
		if get("/data", io.Discard) != size {
			log.Fatal("short bulk response")
		}
	}
	result["bulk_mib_s"] = float64(8*size) / (1 << 20) / time.Since(start).Seconds()
	if *streams > 0 {
		var group sync.WaitGroup
		gate := make(chan struct{})
		tr.CloseIdleConnections()
		for range *streams {
			group.Go(func() {
				<-gate
				if get("/data", io.Discard) != size {
					log.Fatal("short parallel response")
				}
			})
		}
		start = time.Now()
		close(gate)
		group.Wait()
		result["parallel_streams"] = *streams
		result["parallel_mib_s"] = float64(*streams*size) / (1 << 20) / time.Since(start).Seconds()
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
