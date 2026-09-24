# MicropodSDK (Swift)

Swift client for the Micropod container API — SwiftProtobuf messages
generated from `proto/micropod/v1`, a dependency-light Connect-RPC
transport over URLSession, and an interceptor chain for retry, timeouts,
and tracing.

```swift
import MicropodSDK

let client = MicropodClient(baseURL: URL(string: "http://localhost:45454")!)
let snapshot = try await client.system()
let ref = try await client.run(.with { $0.image = "alpine:3.20" })

for try await chunk in client.streamLogs(.with { $0.id = ref.id }) {
    print(String(data: chunk.data, encoding: .utf8) ?? "")
}
```

## Resiliency

`ConnectClient.standard` installs the chain **tracing → retry → timeout**:

- **`RetryInterceptor`** — exponential backoff + jitter on `unavailable`,
  `deadlineExceeded`, `resourceExhausted`, `aborted`. Unary only; streams
  are never replayed.
- **`TimeoutInterceptor`** — races the whole call (including retries)
  against a `Duration` deadline.
- **`ClientInterceptor`** protocol — compose your own auth, logging, or
  metrics middleware; interceptors can mutate `RPCContext.headers` before
  the wire.

## Instrumentation

- **`TracingInterceptor`** injects a W3C `traceparent` header and records
  an `OSSignposter` interval per RPC (`com.micropod.sdk` / `rpc`) —
  visible in Instruments. Provide your own `TraceContextProvider` to
  bridge an OpenTelemetry span's context so server-side spans join the
  same distributed trace.
- `ConnectError` carries the Connect `code` + HTTP status for typed
  handling.

## Streaming

`streamLogs` and `pullImage` return `AsyncThrowingStream` — decode is
Connect-envelope framed; a trailer `error` surfaces as `ConnectError`, and
`onTermination` cancels the in-flight request.

## Package

Add `https://github.com/castlemilk/micropod` and depend on the
`MicropodSDK` product, or use the standalone package at `sdk/swift/` as a
local dependency. Platforms: macOS 15+ / iOS 18+.
