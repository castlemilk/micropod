# @micropod/sdk

TypeScript SDK for the Micropod container API — protobuf-es v2 generated
messages + Connect client with retry, timeouts, and OpenTelemetry
instrumentation. Works on Node 18+ and browsers (fetch transport).

```ts
import { createMicropodClient } from "@micropod/sdk";

const client = createMicropodClient("http://localhost:45454", {
  retry: { maxAttempts: 3 },
  timeoutMs: 10_000,
  otel: true,
});

const { containers } = await client.listContainers({});
```

## Resiliency

- **`retry`** — exponential backoff + jitter on `unavailable`,
  `deadline_exceeded`, `resource_exhausted`, `aborted`. Unary only; server
  streams pass through untouched. `retry: false` disables.
- **`timeoutMs`** — default per-call deadline composed with the caller's
  `AbortSignal` (portable across Node/browsers).
- **`interceptors`** — append connect-es `Interceptor`s of your own.

## OpenTelemetry

`otel: true` wraps every call in a `CLIENT` span
(`micropod.v1.MicropodService/RunContainer`), injects the W3C
`traceparent` header, and records `micropod.client.duration` +
`micropod.client.calls` on the global meter. Streaming calls keep the span
open until the stream terminates. Pass `{ tracer, meter }` to bypass the
global providers.

## Custom transports

```ts
import { createConnectTransport } from "@connectrpc/connect-node"; // HTTP/2
createMicropodClient("http://localhost:45454", { transport: createConnectTransport({ baseUrl }) });
```

## Generated surface

`@micropod/sdk/gen/*` exposes the raw protobuf-es modules
(`micropod/v1/api_pb`, `container_pb`, …) plus the `MicropodService`
descriptor if you want to compose your own client.
