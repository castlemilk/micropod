// Package micropod is the Go SDK for the Micropod container API.
//
// It wraps the generated connect-go client with resiliency defaults —
// retry with exponential backoff on transient codes, per-call timeouts,
// and optional OpenTelemetry tracing/metrics via otelconnect.
//
//	client := micropod.NewClient("http://localhost:45454",
//	    micropod.WithRetry(micropod.DefaultRetryPolicy()),
//	    micropod.WithOTel(tp, mp),
//	)
//	resp, err := client.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
//
// The API is grouped into per-domain services (ContainerService,
// ImageService, …, CacheService, RigService, TelemetryService); Client embeds
// every one so each RPC is reachable as a promoted method —
// client.ListContainers, client.GetCacheStatus, client.ControlMachine, etc.
// Use the generated per-service clients directly
// (micropodv1connect.New*Client) when you only need one domain.
//
// Order matters: pass WithTimeout before WithRetry so each retry shares one
// deadline (connect-go applies the first interceptor outermost). Reversed,
// every attempt gets a fresh deadline and a call can run MaxAttempts times
// longer than the configured timeout.
//
// The Swift MicropodAPI serves Connect (binary and proto-JSON) over HTTP/1.1
// by default; WithHTTP2 switches the transport to HTTP/2 (h2c) and WithGRPC
// to the gRPC protocol. WithUnixSocket reaches its owner socket.
package micropod

import (
	"context"
	"net"
	"net/http"
	"time"

	"connectrpc.com/connect"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
)

// Client fans the configured interceptor chain out to every domain
// service. Method names are unique across services, so the embedded
// clients promote a flat call surface: client.ListContainers(ctx, req).
type Client struct {
	micropodv1connect.ContainerServiceClient
	micropodv1connect.ImageServiceClient
	micropodv1connect.VolumeServiceClient
	micropodv1connect.NetworkServiceClient
	micropodv1connect.ComposeServiceClient
	micropodv1connect.SystemServiceClient
	micropodv1connect.K8SServiceClient
	micropodv1connect.MachineServiceClient
	micropodv1connect.SandboxServiceClient
	micropodv1connect.CacheServiceClient
	micropodv1connect.RigServiceClient
	micropodv1connect.TelemetryServiceClient
}

type config struct {
	httpClient   *http.Client
	interceptors []connect.Interceptor
	connectOpts  []connect.ClientOption
	http2        bool
	unixSocket   string
	customHTTP   bool
}

// Option customizes the SDK client.
type Option func(*config)

// WithHTTPClient overrides the transport (custom TLS, proxy, vsock dialer…).
func WithHTTPClient(h *http.Client) Option {
	return func(c *config) {
		c.httpClient = h
		c.customHTTP = true
	}
}

// WithHTTP2 speaks HTTP/2 with prior knowledge (h2c) to the Swift
// MicropodAPI, which serves it beside HTTP/1.1 on the same port and socket.
// All calls share one connection, multiplexed. Ignored when WithHTTPClient
// supplies the transport. The default stays HTTP/1.1.
func WithHTTP2() Option {
	return func(c *config) { c.http2 = true }
}

// WithUnixSocket dials the API's Unix socket (~/.micropod/api.sock) for
// every call, whatever host baseURL names (use http://localhost/api).
// Ignored when WithHTTPClient supplies the transport.
func WithUnixSocket(path string) Option {
	return func(c *config) { c.unixSocket = path }
}

// WithGRPC speaks the gRPC protocol (application/grpc) instead of Connect:
// connect.WithGRPC() over HTTP/2 (WithHTTP2). The Swift MicropodAPI serves
// gRPC on /api/micropod.v1.<Service>/<Method> and on the bare
// /micropod.v1.<Service>/<Method> path grpc-go uses.
func WithGRPC() Option {
	return func(c *config) {
		c.http2 = true
		c.connectOpts = append(c.connectOpts, connect.WithGRPC())
	}
}

// Idle connections of the transport WithHTTP2 and WithUnixSocket build.
//
// The MicropodAPI closes an HTTP/1.1 connection that was idle for 120 s. A
// client must drop it first: a Connect call is a POST, which net/http does
// not retry on a connection the server closed under it, so the call fails
// with "unavailable: unexpected EOF". 90 s is http.DefaultTransport's value,
// which the default client has always had. (A zero http.Transport keeps
// idle connections for ever, and only two per host, so concurrent callers
// kept opening new ones.)
const (
	idleConnTimeout     = 90 * time.Second
	maxIdleConnsPerHost = 16
	maxIdleConns        = 64
)

// transport builds the HTTP client WithHTTP2 and WithUnixSocket ask for.
func (c *config) transport() *http.Client {
	if c.customHTTP || (!c.http2 && c.unixSocket == "") {
		return c.httpClient
	}
	tr := &http.Transport{
		IdleConnTimeout:     idleConnTimeout,
		MaxIdleConnsPerHost: maxIdleConnsPerHost,
		MaxIdleConns:        maxIdleConns,
	}
	if c.http2 {
		var protocols http.Protocols
		protocols.SetUnencryptedHTTP2(true)
		tr.Protocols = &protocols
	}
	if path := c.unixSocket; path != "" {
		dialer := &net.Dialer{}
		tr.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, "unix", path)
		}
	}
	return &http.Client{Transport: tr}
}

// WithInterceptors appends custom interceptors after the built-in
// retry/timeout/OTel chain.
func WithInterceptors(interceptors ...connect.Interceptor) Option {
	return func(c *config) { c.interceptors = append(c.interceptors, interceptors...) }
}

// WithConnectOptions forwards connect.ClientOptions (e.g.
// connect.WithProtoJSON(), connect.WithGRPC(), connect.WithSendGzip()) to
// every generated per-service client. They are applied after the SDK's own
// interceptor chain, so a connect.WithInterceptors passed here runs inside it.
func WithConnectOptions(opts ...connect.ClientOption) Option {
	return func(c *config) { c.connectOpts = append(c.connectOpts, opts...) }
}

// WithRetry enables unary retry with the given policy (see RetryPolicy).
// Retries apply only to unary calls on transient codes — server streams
// (StreamContainerLogs) are never retried mid-flight. Set
// RetryPolicy.Idempotent to restrict replay to procedures that are safe to
// repeat; the server cannot observe a client giving up, so a timed-out
// CreateContainer still completes server-side and a replay collides with it.
func WithRetry(policy RetryPolicy) Option {
	return func(c *config) {
		c.interceptors = append(c.interceptors, retryInterceptor{policy: policy})
	}
}

// WithTimeout applies a default per-call deadline to unary calls when the
// caller's context carries none (or a later one). Server streams are not
// bounded by it — a log follow has no sane default — so bound them with the
// caller's own context.
func WithTimeout(d time.Duration) Option {
	return func(c *config) {
		c.interceptors = append(c.interceptors, timeoutInterceptor{timeout: d})
	}
}

// WithOTel enables OpenTelemetry tracing + metrics + trace-context
// propagation (W3C traceparent headers) for every call, via otelconnect.
// Pass nil to use the global providers.
func WithOTel(opts ...OTelOption) Option {
	return func(c *config) {
		c.interceptors = append(c.interceptors, newOTelInterceptor(opts...))
	}
}

// NewClient builds a client for all micropod.v1 services against baseURL
// (e.g. http://localhost:45454 for the Go apiserver, http://localhost:45454/api
// for the Swift MicropodAPI) speaking the Connect protocol over HTTP. The
// wire encoding is connect-go's default (binary proto) unless overridden via
// WithConnectOptions(connect.WithProtoJSON()).
func NewClient(baseURL string, opts ...Option) *Client {
	cfg := &config{httpClient: http.DefaultClient}
	for _, o := range opts {
		o(cfg)
	}
	cfg.httpClient = cfg.transport()
	clientOpts := append([]connect.ClientOption{connect.WithInterceptors(cfg.interceptors...)}, cfg.connectOpts...)
	return &Client{
		ContainerServiceClient: micropodv1connect.NewContainerServiceClient(cfg.httpClient, baseURL, clientOpts...),
		ImageServiceClient:     micropodv1connect.NewImageServiceClient(cfg.httpClient, baseURL, clientOpts...),
		VolumeServiceClient:    micropodv1connect.NewVolumeServiceClient(cfg.httpClient, baseURL, clientOpts...),
		NetworkServiceClient:   micropodv1connect.NewNetworkServiceClient(cfg.httpClient, baseURL, clientOpts...),
		ComposeServiceClient:   micropodv1connect.NewComposeServiceClient(cfg.httpClient, baseURL, clientOpts...),
		SystemServiceClient:    micropodv1connect.NewSystemServiceClient(cfg.httpClient, baseURL, clientOpts...),
		K8SServiceClient:       micropodv1connect.NewK8SServiceClient(cfg.httpClient, baseURL, clientOpts...),
		MachineServiceClient:   micropodv1connect.NewMachineServiceClient(cfg.httpClient, baseURL, clientOpts...),
		SandboxServiceClient:   micropodv1connect.NewSandboxServiceClient(cfg.httpClient, baseURL, clientOpts...),
		CacheServiceClient:     micropodv1connect.NewCacheServiceClient(cfg.httpClient, baseURL, clientOpts...),
		RigServiceClient:       micropodv1connect.NewRigServiceClient(cfg.httpClient, baseURL, clientOpts...),
		TelemetryServiceClient: micropodv1connect.NewTelemetryServiceClient(cfg.httpClient, baseURL, clientOpts...),
	}
}
