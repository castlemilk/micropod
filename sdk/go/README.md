# micropod Go SDK

Generated Connect-RPC client for the Micropod API, with resiliency and
OpenTelemetry instrumentation built in.

```go
import (
    "github.com/castlemilk/micropod/sdk/go"
    micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
)

client := micropod.NewClient("http://localhost:45454",
    micropod.WithRetry(micropod.DefaultRetryPolicy()), // unary retry, transient codes
    micropod.WithTimeout(30*time.Second),              // default per-call deadline
    micropod.WithOTel(),                               // spans, metrics, traceparent
)

resp, err := client.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
```

## Resiliency

- **`WithRetry(RetryPolicy)`** — exponential backoff + ±25% jitter on
  `unavailable` / `deadline_exceeded` / `resource_exhausted` / `aborted`.
  Unary only; server streams are never replayed mid-flight.
- **`WithTimeout(d)`** — applies a deadline when the caller's context has
  none or a later one. Never widens an earlier deadline.
- **`WithInterceptors(...)`** — append your own `connect.Interceptor`s.

## OpenTelemetry

`WithOTel()` wraps every call with `connectrpc.com/otelconnect`: a client
span per RPC (`rpc.system=connect_rpc`, `rpc.service`, `rpc.method`), a
duration histogram + request counter, and W3C `traceparent` propagation.
Override providers with `WithTracerProvider` / `WithMeterProvider`;
`WithOTel()` alone uses the globals (`otel.GetTracerProvider()`).

## Custom transports

`WithHTTPClient` accepts any `*http.Client` — point the dialer at a Unix
socket, vsock bridge, or instrumented `http.RoundTripper`.

## Versioning

`go get github.com/castlemilk/micropod/sdk/go@sdk/go/v0.7.0` — the SDK is
tagged `sdk/go/v*` from the release workflow. Generated sources live under
`gen/`; do not hand-edit.
