package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const rootlessRun = "/run/user/1001"

func privateRootless() bool { return os.Getenv("MICROPOD_ENGINE_ROOTLESS") == "1" }
func inAllocationUserNS() bool {
	raw, err := os.ReadFile("/proc/self/uid_map")
	if err != nil {
		return false
	}
	first, _, _ := strings.Cut(strings.TrimSpace(string(raw)), "\n")
	m := strings.Fields(first)
	return len(m) == 3 && m[0] == "0" && m[1] == "1001" && m[2] == "1"
}
func clientSocket(shared, private string) string {
	if privateRootless() {
		return rootlessRun + "/" + private
	}
	return shared
}
func workerUplink() string {
	if privateRootless() {
		return os.Getenv("MICROPOD_ROOTLESS_UPLINK")
	}
	return "eth0"
}

type rootlessPort struct {
	client *http.Client
	id     int
}

func (p *rootlessPort) Close() error {
	defer p.client.CloseIdleConnections()
	req, err := http.NewRequest(http.MethodDelete, "http://unix/v1/ports/"+strconv.Itoa(p.id), nil)
	if err != nil {
		return err
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 && resp.StatusCode != 404 {
		return fmt.Errorf("release private port: %s", resp.Status)
	}
	return nil
}

// RootlessKit owns the allocation's outer loopback listener. Its child dials
// the container IP directly, so published traffic takes one userspace relay.
func publishRootless(ctx context.Context, ip string, guest, requested uint16) (*publishedPort, uint16, error) {
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", rootlessRun+"/rootlesskit/api.sock")
	}}
	client := &http.Client{Transport: tr, Timeout: 4 * time.Second}
	for i := 0; i < 8; i++ {
		parent := requested
		if parent == 0 {
			l, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
			if err != nil {
				return nil, 0, err
			}
			parent = uint16(l.Addr().(*net.TCPAddr).Port)
			l.Close()
		}
		payload, _ := json.Marshal(map[string]any{"proto": "tcp", "parentIP": "127.0.0.1", "parentPort": parent, "childIP": ip, "childPort": guest})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://unix/v1/ports", bytes.NewReader(payload))
		if err != nil {
			return nil, 0, err
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			tr.CloseIdleConnections()
			return nil, 0, err
		}
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		if err != nil {
			tr.CloseIdleConnections()
			return nil, 0, err
		}
		if resp.StatusCode/100 == 2 {
			var state struct{ ID *int }
			if json.Unmarshal(raw, &state) != nil || state.ID == nil {
				return nil, 0, errors.New("private port registration had no identity")
			}
			return &publishedPort{lease: &rootlessPort{client: client, id: *state.ID}}, parent, nil
		}
		if requested != 0 || !strings.Contains(string(raw), "address already in use") {
			tr.CloseIdleConnections()
			return nil, 0, fmt.Errorf("register private port: %s: %.512s", resp.Status, raw)
		}
	}
	tr.CloseIdleConnections()
	return nil, 0, errors.New("no available private loopback port")
}
