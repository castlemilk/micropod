package micropod

import (
	"context"
	"math/rand/v2"
	"time"

	"connectrpc.com/connect"
	"connectrpc.com/otelconnect"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"
)

// RetryPolicy controls unary-call retry behavior.
type RetryPolicy struct {
	// MaxAttempts is the total number of tries including the first (default 3).
	MaxAttempts int
	// InitialBackoff before the first retry (default 100ms).
	InitialBackoff time.Duration
	// MaxBackoff caps the exponential growth (default 2s).
	MaxBackoff time.Duration
	// Multiplier applied per retry (default 2.0).
	Multiplier float64
	// RetryableCodes — Connect codes worth retrying (default: unavailable,
	// deadline_exceeded, resource_exhausted, aborted).
	RetryableCodes []connect.Code
	// Idempotent reports whether a procedure (e.g.
	// "/micropod.v1.ContainerService/GetContainer") may be replayed. nil
	// means every unary procedure is retried (previous behaviour). Return
	// false for procedures whose replay is unsafe — CreateContainer,
	// RunContainer, CommitVolumeClone — because the server cannot observe a
	// client that gave up: a timed-out attempt still completes server-side.
	Idempotent func(procedure string) bool
}

// DefaultRetryPolicy: 3 attempts, 100ms → ~2s backoff with ±25% jitter.
func DefaultRetryPolicy() RetryPolicy {
	return RetryPolicy{
		MaxAttempts:    3,
		InitialBackoff: 100 * time.Millisecond,
		MaxBackoff:     2 * time.Second,
		Multiplier:     2.0,
		RetryableCodes: []connect.Code{
			connect.CodeUnavailable,
			connect.CodeDeadlineExceeded,
			connect.CodeResourceExhausted,
			connect.CodeAborted,
		},
	}
}

func (p RetryPolicy) retryable(code connect.Code) bool {
	for _, c := range p.RetryableCodes {
		if c == code {
			return true
		}
	}
	return false
}

// retryInterceptor retries unary calls on transient Connect codes with
// exponential backoff + jitter. Unary request bodies are buffered by
// connect-go, so replaying next() is safe.
type retryInterceptor struct {
	policy RetryPolicy
}

func (r retryInterceptor) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
		if r.policy.Idempotent != nil && !r.policy.Idempotent(req.Spec().Procedure) {
			return next(ctx, req)
		}
		attempts := r.policy.MaxAttempts
		if attempts < 1 {
			attempts = 1
		}
		backoff := r.policy.InitialBackoff
		var lastErr error
		for i := 0; i < attempts; i++ {
			resp, err := next(ctx, req)
			if err == nil {
				return resp, nil
			}
			lastErr = err
			code := connect.CodeOf(err)
			if !r.policy.retryable(code) || i == attempts-1 {
				return nil, err
			}
			// ±25% jitter
			jitter := time.Duration(rand.Int64N(int64(backoff/2) + 1))
			delay := backoff - backoff/4 + jitter
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return nil, ctx.Err()
			case <-timer.C:
			}
			backoff = time.Duration(float64(backoff) * r.policy.Multiplier)
			if backoff > r.policy.MaxBackoff {
				backoff = r.policy.MaxBackoff
			}
		}
		return nil, lastErr
	}
}

func (r retryInterceptor) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	// Streams are not retried — partial progress can't be replayed safely.
	return next
}

func (r retryInterceptor) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return next
}

// timeoutInterceptor applies a default deadline to unary calls when the
// incoming context has none or a later one. Streams are passed through
// untouched.
type timeoutInterceptor struct {
	timeout time.Duration
}

func (t timeoutInterceptor) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
		if t.timeout > 0 {
			if deadline, ok := ctx.Deadline(); !ok || time.Until(deadline) > t.timeout {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, t.timeout)
				defer cancel()
			}
		}
		return next(ctx, req)
	}
}

// WrapStreamingClient is a pass-through. Streams never receive a default
// deadline — a log follow has no sane default; callers bound streams with
// their own context. (An earlier version wrapped the stream context in
// WithTimeout and cancelled it from CloseRequest, which connect-go calls
// before the first Receive on a server stream — every stream died with
// "context canceled" before delivering a frame.)
func (t timeoutInterceptor) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (t timeoutInterceptor) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return next
}

// OTelOption customizes the OpenTelemetry interceptor.
type OTelOption func(*otelConfig)

type otelConfig struct {
	tracerProvider trace.TracerProvider
	meterProvider  metric.MeterProvider
}

// WithTracerProvider sets the OTel tracer provider (default: global).
func WithTracerProvider(tp trace.TracerProvider) OTelOption {
	return func(c *otelConfig) { c.tracerProvider = tp }
}

// WithMeterProvider sets the OTel meter provider (default: global).
func WithMeterProvider(mp metric.MeterProvider) OTelOption {
	return func(c *otelConfig) { c.meterProvider = mp }
}

// newOTelInterceptor builds the otelconnect interceptor — spans per call
// with rpc.system/rpc.service/rpc.method attributes, duration/request
// metrics, and W3C traceparent propagation into request headers.
func newOTelInterceptor(opts ...OTelOption) connect.Interceptor {
	cfg := &otelConfig{
		tracerProvider: otel.GetTracerProvider(),
		meterProvider:  otel.GetMeterProvider(),
	}
	for _, o := range opts {
		o(cfg)
	}
	otelOpts := []otelconnect.Option{
		otelconnect.WithTracerProvider(cfg.tracerProvider),
		otelconnect.WithMeterProvider(cfg.meterProvider),
		otelconnect.WithPropagator(otel.GetTextMapPropagator()),
	}
	i, err := otelconnect.NewInterceptor(otelOpts...)
	if err != nil {
		// NewInterceptor only errors on nil options misuse; degrade to a
		// no-op rather than panic a client constructor.
		return connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
			return next
		})
	}
	return i
}
