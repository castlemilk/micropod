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
package micropod

import (
	"net/http"
	"time"

	"connectrpc.com/connect"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
)

// Client is the MicropodService client with the configured interceptor
// chain applied. It satisfies micropodv1connect.MicropodServiceClient.
type Client struct {
	micropodv1connect.MicropodServiceClient
}

type config struct {
	httpClient   *http.Client
	interceptors []connect.Interceptor
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

// WithRetry enables unary retry with the given policy (see RetryPolicy).
// Retries apply only to unary calls on transient codes — server streams
// (StreamContainerLogs) are never retried mid-flight.
func WithRetry(policy RetryPolicy) Option {
	return func(c *config) {
		c.interceptors = append(c.interceptors, retryInterceptor{policy: policy})
	}
}

// WithTimeout applies a default per-call deadline when the caller's
// context carries none (or a later one).
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

// NewClient builds a MicropodService client against baseURL
// (e.g. http://localhost:45454) speaking Connect JSON over HTTP.
func NewClient(baseURL string, opts ...Option) *Client {
	cfg := &config{httpClient: http.DefaultClient}
	for _, o := range opts {
		o(cfg)
	}
	return &Client{
		MicropodServiceClient: micropodv1connect.NewMicropodServiceClient(
			cfg.httpClient,
			baseURL,
			connect.WithInterceptors(cfg.interceptors...),
		),
	}
}
