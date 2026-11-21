// Fixed-arrival Gamma workload. Each fresh request is timed from its scheduled dispatch.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type service struct{ url, marker string }

func readServices(args []string) ([]service, error) {
	if len(args) != 2 {
		return nil, fmt.Errorf("usage: offered URL MARKER | offered --targets 32-port.tsv")
	}
	if args[0] != "--targets" {
		return []service{{args[0], args[1]}}, nil
	}
	file, err := os.Open(args[1])
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var services []service
	hosts, markers := map[string]bool{}, map[string]bool{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		address, marker, ok := strings.Cut(scanner.Text(), "\t")
		target, err := url.Parse(address)
		if !ok || err != nil || target.Scheme != "http" || target.Host == "" || target.Port() == "" ||
			target.Path != "" || target.RawQuery != "" || target.Fragment != "" || target.User != nil ||
			marker == "" || strings.ContainsRune(marker, '\t') || hosts[target.Host] || markers[marker] {
			return nil, fmt.Errorf("invalid or duplicate published endpoint on line %d", len(services)+1)
		}
		hosts[target.Host], markers[marker] = true, true
		services = append(services, service{address, marker})
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(services) != 32 {
		return nil, fmt.Errorf("expected 32 distinct published ports, found %d", len(services))
	}
	return services, nil
}

func main() {
	services, err := readServices(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	var bytes [32]atomic.Int64
	var reopens atomic.Int64
	var jobs, ready sync.WaitGroup
	var mu sync.Mutex
	var problems []string

	report := func(e error) { mu.Lock(); problems = append(problems, e.Error()); mu.Unlock() }
	stop := make(chan struct{})
	ready.Add(32)
	for i := range 32 {
		jobs.Add(1)
		go func(i int) {
			defer jobs.Done()
			target := services[i%len(services)]
			tr := &http.Transport{DialContext: (&net.Dialer{Timeout: 5 * time.Second}).DialContext, MaxIdleConnsPerHost: 1}
			defer tr.CloseIdleConnections()
			client := &http.Client{Transport: tr, Timeout: 30 * time.Second}
			if e := identity(client, target.url, target.marker); e != nil {
				report(e)
				ready.Done()
				return
			}
			ctx := httptrace.WithClientTrace(context.Background(), &httptrace.ClientTrace{GotConn: func(c httptrace.GotConnInfo) {
				if !c.Reused {
					reopens.Add(1)
				}
			}})
			first := true
			defer func() {
				if first {
					ready.Done()
				}
			}()
			for {
				req, _ := http.NewRequestWithContext(ctx, "GET", target.url+"/data", nil)
				r, e := client.Do(req)
				if e != nil {
					report(e)
					return
				}
				n, e := io.Copy(counter{&bytes[i]}, r.Body)
				r.Body.Close()
				if e != nil || r.StatusCode != 200 || n != 8<<20 {
					report(fmt.Errorf("stream %d HTTP %d bytes %d error %v", i, r.StatusCode, n, e))
					return
				}

				if first {
					first = false
					ready.Done()
				}
				select {
				case <-stop:
					return
				default:
				}
			}
		}(i)
	}
	ready.Wait()
	const count = 240
	const gap = 25 * time.Millisecond
	client := &http.Client{Transport: &http.Transport{DisableKeepAlives: true, DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext}, Timeout: 15 * time.Second}
	var results [count]int64
	var delays [count]int64
	var fresh sync.WaitGroup
	var before, delta [32]int64
	for i := range bytes {
		before[i] = bytes[i].Load()
	}
	begin := time.Now()
	for i := range count {
		target := begin.Add(time.Duration(i) * gap)
		if wait := time.Until(target); wait > 0 {
			time.Sleep(wait)
		}
		fresh.Add(1)
		go func(i int) {
			defer fresh.Done()
			delays[i] = time.Since(target).Microseconds()
			service := services[i%len(services)]
			if e := identity(client, service.url, service.marker); e != nil {
				report(e)
				return
			}
			results[i] = time.Since(target).Microseconds()
		}(i)
	}
	if wait := time.Until(begin.Add(count * gap)); wait > 0 {
		time.Sleep(wait)
	}
	elapsed := time.Since(begin)
	var total int64
	for i := range bytes {
		delta[i] = bytes[i].Load() - before[i]
		total += delta[i]
	}
	fresh.Wait()
	close(stop)
	jobs.Wait()
	slices.Sort(results[:])
	slices.Sort(delays[:])
	for stream, n := range delta {
		if n <= 0 {
			report(fmt.Errorf("no bytes on stream %d in the offered window", stream))
		}
	}
	err = json.NewEncoder(os.Stdout).Encode(map[string]any{
		"published_ports": len(services),
		"streams":         32, "arrivals": count, "period_us": gap.Microseconds(), "window_s": elapsed.Seconds(),
		"bytes": total, "per_stream_bytes": delta, "mib_s": float64(total) / (1 << 20) / elapsed.Seconds(),
		"fresh_p95_us": results[227], "fresh_p99_us": results[237],
		"dispatch_p95_us": delays[227], "dispatch_max_us": delays[239],
		"errors": problems, "reopened": reopens.Load(),
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if len(problems) > 0 || reopens.Load() != 0 {
		os.Exit(1)
	}
}

type counter struct{ n *atomic.Int64 }

func (c counter) Write(p []byte) (int, error) { c.n.Add(int64(len(p))); return len(p), nil }

func identity(c *http.Client, u, id string) error {
	r, e := c.Get(u + "/id")
	if e != nil {
		return e
	}
	defer r.Body.Close()
	b, e := io.ReadAll(io.LimitReader(r.Body, 1024))
	if e != nil {
		return e
	}
	if r.StatusCode != 200 || string(b) != id {
		return fmt.Errorf("wrong service identity")
	}
	return nil
}
