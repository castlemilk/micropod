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
// ImageService, …); Client embeds all seven so every RPC is reachable as a
// promoted method — client.ListContainers, client.ComposeUp, etc. Use the
// generated per-service clients directly (micropodv1connect.New*Client)
// when you only need one domain.
//
// Order matters: pass WithTimeout before WithRetry so each retry shares one
// deadline (connect-go applies the first interceptor outermost). Reversed,
// every attempt gets a fresh deadline and a call can run MaxAttempts times
// longer than the configured timeout.
//
// The Swift MicropodAPI server speaks proto-JSON only; pass
// WithConnectOptions(connect.WithProtoJSON()) when talking to it.
package micropod

import (
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
}

type config struct {
	httpClient   *http.Client
	interceptors []connect.Interceptor
	connectOpts  []connect.ClientOption
}

// Option customizes the SDK client.
type Option func(*config)

// WithHTTPClient overrides the transport (custom TLS, proxy, vsock dialer…).
func WithHTTPClient(h *http.Client) Option {
	return func(c *config) { c.httpClient = h }
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
	clientOpts := append([]connect.ClientOption{connect.WithInterceptors(cfg.interceptors...)}, cfg.connectOpts...)
	return &Client{
		ContainerServiceClient: micropodv1connect.NewContainerServiceClient(cfg.httpClient, baseURL, clientOpts...),
		ImageServiceClient:     micropodv1connect.NewImageServiceClient(cfg.httpClient, baseURL, clientOpts...),
		VolumeServiceClient:    micropodv1connect.NewVolumeServiceClient(cfg.httpClient, baseURL, clientOpts...),
		NetworkServiceClient:   micropodv1connect.NewNetworkServiceClient(cfg.httpClient, baseURL, clientOpts...),
		ComposeServiceClient:   micropodv1connect.NewComposeServiceClient(cfg.httpClient, baseURL, clientOpts...),
		SystemServiceClient:    micropodv1connect.NewSystemServiceClient(cfg.httpClient, baseURL, clientOpts...),
		K8SServiceClient:       micropodv1connect.NewK8SServiceClient(cfg.httpClient, baseURL, clientOpts...),
	}
}
