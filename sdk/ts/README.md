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

## Sandboxes

`Sandbox` drives a micro-VM that stays up between calls. It uses the same
method names as shuru's SDK, so porting is a find-and-replace.

```ts
import { Sandbox } from "@micropod/sdk";

const sb = await Sandbox.start({ image: "python:3.12", mounts: { "./src": "/workspace" } });

const r = await sb.exec("python3 -c 'print(1+1)'");          // { stdout: "2\n", stderr: "", exitCode: 0 }

const proc = await sb.spawn("python3 -u server.py", { cwd: "/workspace" });
proc.on("stdout", (chunk) => process.stdout.write(chunk));   // Uint8Array chunks, live
proc.on("exit", (code) => console.log("exited", code));
await proc.write("input\n");                                 // stdin
await proc.kill();                                           // SIGTERM (or kill("KILL"))

await sb.watch("/workspace", (e) => console.log(e.event, e.path));   // inside the guest
await sb.writeFile("/workspace/data.bin", bytes, { createParents: true });
const back = await sb.readFile("/workspace/data.bin");       // Uint8Array
await sb.readDir("/workspace"); await sb.stat("/workspace/data.bin");
await sb.mkdir("/a/b"); await sb.rename("/a", "/c"); await sb.copy("/c", "/d", { recursive: true });
await sb.chmod("/d/b", 0o755); await sb.remove("/d", { recursive: true }); await sb.exists("/d");

await sb.checkpoint("after-setup");                         // saves the disk, stops the VM
const next = await Sandbox.start({ from: "after-setup" });
await next.stop();                                          // discards it
```

**`Sandbox.start` options:**

| option | what it does |
|---|---|
| `image` | image to boot (default `alpine:latest`) |
| `from` | boot from a checkpoint instead of an image |
| `cpus`, `memory`, `diskSize` | CPU count; memory and disk in MiB |
| `allowNet` | turn on networking (default off) |
| `ports` | forward host ports: `["8080:80"]` |
| `mounts` | share host directories: `{ host: "/guest[:ro\|rw]" }`. Guest writes stay in the sandbox unless `:rw` |
| `exposeHost` | host loopback ports, reachable from the guest as `host.micropod.internal` |
| `network: { allow }` | allowlist of hosts the guest can reach |
| `secrets` | per variable name: `{ from \| value \| command, hosts, ttl?, cwd? }` |
| `dnsResolvers` | DNS servers for the guest |
| `env`, `cwd`, `labels`, `name` | environment variables, working directory, labels, sandbox name |

- **Secrets:** the guest only sees a placeholder. The daemon's proxy
  substitutes the real value on HTTPS requests to the listed `hosts`. A
  `command` secret runs on the host and is re-run before it expires.
- **Connecting:** by default the SDK talks to the daemon at
  `http://localhost:45454` (its `/api` mount), or `$MICROPOD_API` if set.
  Use `Sandbox.attach(id)` to reconnect to a running sandbox.
- **Checkpoints:** `Sandbox.listCheckpoints()` and
  `Sandbox.deleteCheckpoint(name)` manage them.
- **Low-level access:** the underlying RPCs are on `createMicropodClient`
  (`startSandbox`, `startProcess`, `streamProcess`, `readFile`, …).

## Resiliency

- **`retry`** — exponential backoff + jitter on `unavailable`,
  `deadline_exceeded`, `resource_exhausted`, `aborted`. Unary only; server
  streams pass through untouched. `retry: false` disables.
- **`timeoutMs`** — default per-call deadline composed with the caller's
  `AbortSignal` (portable across Node/browsers).
- **`interceptors`** — append connect-es `Interceptor`s of your own.

## OpenTelemetry

`otel: true` wraps every call in a `CLIENT` span
(`micropod.v1.ContainerService/RunContainer`), injects the W3C
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
(`micropod/v1/api_pb`, `container_pb`, …) plus the per-service
descriptors (`ContainerService`, `ImageService`, …) if you want to compose
your own client.
