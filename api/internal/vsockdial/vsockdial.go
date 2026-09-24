// Package vsockdial opens raw byte streams to guest vsock ports through
// MicropodAPI's bridge endpoint:
//
//	GET /v1/containers/{id}/vsock/{port}
//
// The apiserver (Swift side) resolves the container's `containerDial` XPC
// route, receives a host fd wired to the guest socket, then pumps bytes
// between it and this HTTP connection. After the 200 response head the
// stream is fully duplex — effectively a net.Conn into the guest. gRPC
// (vminitd on port 1024) runs cleanly over it.
package vsockdial

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"
)

// BridgeURL returns the MicropodAPI base URL, honoring MICROPOD_API_URL.
func BridgeURL() string {
	if env := os.Getenv("MICROPOD_API_URL"); env != "" {
		return env
	}
	return "http://127.0.0.1:45454"
}

// Dial opens a stream to the given container's vsock port via the MicropodAPI
// bridge at baseURL (see BridgeURL).
func Dial(ctx context.Context, baseURL, containerID string, port uint32) (net.Conn, error) {
	u, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("vsockdial: bad base URL %q: %w", baseURL, err)
	}
	host := u.Host
	if _, _, err := net.SplitHostPort(host); err != nil {
		host = net.JoinHostPort(host, "45454")
	}

	d := net.Dialer{Timeout: 10 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", host)
	if err != nil {
		return nil, fmt.Errorf("vsockdial: connect %s: %w", host, err)
	}

	path := fmt.Sprintf("/v1/containers/%s/vsock/%d", url.PathEscape(containerID), port)
	req := "GET " + path + " HTTP/1.1\r\n" +
		"Host: " + host + "\r\n" +
		"Connection: close\r\n\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		conn.Close()
		return nil, fmt.Errorf("vsockdial: write request: %w", err)
	}

	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodGet})
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("vsockdial: read response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		conn.Close()
		return nil, fmt.Errorf("vsockdial: bridge returned %s", resp.Status)
	}
	return &bridgeConn{Conn: conn, r: br}, nil
}

// bridgeConn preserves bytes the response parser buffered past the headers.
type bridgeConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bridgeConn) Read(b []byte) (int, error) {
	if c.r.Buffered() > 0 {
		return c.r.Read(b)
	}
	return c.Conn.Read(b)
}
