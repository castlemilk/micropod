package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	if len(os.Args) != 3 {
		panic("url marker dir")
	}
	u, id := os.Args[1], os.Args[2]

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
			tr := &http.Transport{DialContext: (&net.Dialer{Timeout: 5 * time.Second}).DialContext, MaxIdleConnsPerHost: 1}
			defer tr.CloseIdleConnections()
			client := &http.Client{Transport: tr, Timeout: 30 * time.Second}
			if e := identity(client, u, id); e != nil {
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
				req, _ := http.NewRequestWithContext(ctx, "GET", u+"/data", nil)
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
			if e := identity(client, u, id); e != nil {
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
	json.NewEncoder(os.Stdout).Encode(map[string]any{"streams": 32, "arrivals": count, "period_us": gap.Microseconds(), "window_s": elapsed.Seconds(), "bytes": total, "per_stream_bytes": delta, "mib_s": float64(total) / 1048576 / elapsed.Seconds(), "fresh_p95_us": results[227], "fresh_p99_us": results[237], "dispatch_p95_us": delays[227], "dispatch_max_us": delays[239], "errors": problems, "reopened": reopens.Load()})
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
