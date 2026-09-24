import React from "react";
import type { Metadata } from "next";
import { Braces, Package, Repeat2, Timer, Activity } from "lucide-react";
import { CodeBlock } from "@/components/code-block";
import { GoIcon, SwiftIcon, TypeScriptIcon } from "@/components/lang-icons";
import { REST_BASE_URL } from "@/lib/data";
import { sdkCallMap } from "@/lib/sdk-samples";

export const metadata: Metadata = {
  title: "Client SDKs",
  description:
    "Generated Go, TypeScript, and Swift clients for the Micropod API — with retry, timeouts, and OpenTelemetry instrumentation.",
};

const sdks = [
  {
    id: "go",
    name: "Go",
    Icon: GoIcon,
    package: "github.com/castlemilk/micropod/sdk/go",
    install: "go get github.com/castlemilk/micropod/sdk/go@sdk/go/v0.8.0",
    source: "sdk/go",
    blurb:
      "connect-go generated stubs plus a configured client: unary retry on transient codes, per-call deadlines, and otelconnect instrumentation.",
    quickstart: `import (
    "connectrpc.com/connect"
    micropod "github.com/castlemilk/micropod/sdk/go"
    micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
)

client := micropod.NewClient("${REST_BASE_URL}",
    micropod.WithRetry(micropod.DefaultRetryPolicy()),
    micropod.WithTimeout(30*time.Second),
    micropod.WithOTel(), // global providers, or WithTracerProvider(...)
)

resp, err := client.ListContainers(ctx,
    connect.NewRequest(&micropodv1.Empty{}))`,
    otel: "WithOTel() wraps every call in connectrpc.com/otelconnect — a CLIENT span per RPC (rpc.system, rpc.service, rpc.method), duration histogram + call counter, and W3C traceparent propagation. Pass WithTracerProvider/WithMeterProvider to bypass the globals.",
  },
  {
    id: "ts",
    name: "TypeScript",
    Icon: TypeScriptIcon,
    package: "@micropod/sdk",
    install: "npm install @micropod/sdk",
    source: "sdk/ts",
    blurb:
      "protobuf-es v2 messages + connect-es client. Fetch transport — runs on Node 18+, browsers, and edge runtimes. Requests are checked against the buf.validate constraints before they hit the wire.",
    quickstart: `import { createMicropodClient } from "@micropod/sdk";

const client = createMicropodClient("${REST_BASE_URL}", {
  retry: { maxAttempts: 3 },
  timeoutMs: 10_000,
  otel: true, // or { tracer, meter }
  // validate: false disables client-side buf.validate checks
  // (on by default — bad requests fail fast with invalid_argument)
});

const { containers } = await client.listContainers({});

// Streaming is an AsyncIterable — retry never replays it.
for await (const line of client.pullImage({ image: "alpine:3.20" })) {
  console.log(line.status);
}`,
    otel: "otel: true emits a CLIENT span per call, injects the W3C traceparent header, and records micropod.client.duration + micropod.client.calls on the global meter. Streaming calls hold the span open until the stream terminates.",
  },
  {
    id: "swift",
    name: "Swift",
    Icon: SwiftIcon,
    package: "MicropodSDK",
    install: `.package(url: "https://github.com/castlemilk/micropod", from: "0.8.0")`,
    source: "sdk/swift",
    blurb:
      "SwiftProtobuf messages + a dependency-light Connect transport over URLSession. The MicropodClient facade covers all 29 RPCs across the six micropod.v1 services.",
    quickstart: `import MicropodSDK

let client = MicropodClient(baseURL: URL(string: "${REST_BASE_URL}")!)
let snapshot = try await client.system()

let ref = try await client.run(.with { $0.image = "alpine:3.20" })

// Server-streaming endpoints return AsyncThrowingStream.
for try await chunk in client.streamLogs(.with { $0.id = ref.id }) {
    print(String(data: chunk.data, encoding: .utf8) ?? "")
}`,
    otel: "TracingInterceptor injects a W3C traceparent header and records an OSSignposter interval per RPC (com.micropod.sdk / rpc) — visible in Instruments. Supply a TraceContextProvider bridging your OTel span to join a real distributed trace.",
  },
];

const retryableCodes = [
  ["unavailable", "transient transport state — safe to retry"],
  ["deadline_exceeded", "server missed its deadline — retry with care"],
  ["resource_exhausted", "rate limit / quota — back off and retry"],
  ["aborted", "concurrency conflict — safe to retry"],
];

export default function SdkPage() {
  return (
    <div className="mx-auto max-w-4xl space-y-14 px-6 py-10 md:px-10">
      <div className="space-y-4">
        <p className="font-mono text-xs uppercase tracking-wider text-muted">
          Generated clients
        </p>
        <h1 className="text-4xl font-extrabold tracking-tight">Client SDKs</h1>
        <p className="max-w-2xl text-lg text-muted">
          Three languages, one contract. Each SDK is generated from{" "}
          <code className="font-mono text-sm">proto/micropod/v1</code> and wraps
          the raw stubs with a resiliency + instrumentation chain: retry on
          transient codes, per-call deadlines, W3C trace propagation, and
          OpenTelemetry metrics.
        </p>
      </div>

      <section className="grid gap-3 sm:grid-cols-3">
        {[
          {
            icon: Repeat2,
            title: "Retry",
            body: "Unary calls retry on transient codes with exponential backoff and jitter. Streams are never replayed mid-flight.",
          },
          {
            icon: Timer,
            title: "Timeouts",
            body: "A default per-call deadline applies when the caller set none — it never widens an earlier deadline.",
          },
          {
            icon: Activity,
            title: "Tracing",
            body: "W3C traceparent propagation on every call. Go + TS emit OpenTelemetry spans and metrics; Swift emits signpost intervals.",
          },
        ].map((f) => (
          <div key={f.title} className="rounded-lg border border-border bg-card p-4">
            <f.icon className="mb-2 h-4 w-4 text-primary" />
            <h3 className="mb-1 text-sm font-semibold">{f.title}</h3>
            <p className="text-[13px] leading-relaxed text-muted">{f.body}</p>
          </div>
        ))}
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">Retryable codes</h2>
        <p className="text-sm text-muted">
          The default policy retries these Connect codes — everything else
          fails fast. Override via each SDK&apos;s policy type.
        </p>
        <div className="overflow-hidden rounded-lg border border-border">
          <table className="w-full text-left text-sm">
            <tbody>
              {retryableCodes.map(([code, why]) => (
                <tr key={code} className="border-b border-border last:border-0">
                  <td className="px-4 py-2 font-mono text-xs text-primary">{code}</td>
                  <td className="px-4 py-2 text-muted">{why}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">Call map</h2>
        <p className="text-sm text-muted">
          Every RPC across the six micropod.v1 services, spelled in each SDK —
          endpoint pages embed the matching snippet in the request panel.
        </p>
        <div className="overflow-hidden rounded-lg border border-border">
          <table className="w-full text-left text-[12px]">
            <thead>
              <tr className="border-b border-border bg-secondary/40 font-mono text-[10px] uppercase tracking-wide text-muted">
                <th className="px-4 py-2 font-semibold">RPC</th>
                <th className="px-4 py-2 font-semibold">
                  <span className="inline-flex items-center gap-1.5">
                    <TypeScriptIcon className="h-3 w-3" /> TypeScript
                  </span>
                </th>
                <th className="px-4 py-2 font-semibold">
                  <span className="inline-flex items-center gap-1.5">
                    <GoIcon className="h-3 w-3" /> Go
                  </span>
                </th>
                <th className="px-4 py-2 font-semibold">
                  <span className="inline-flex items-center gap-1.5">
                    <SwiftIcon className="h-3 w-3" /> Swift
                  </span>
                </th>
              </tr>
            </thead>
            <tbody>
              {sdkCallMap().map((row, i, rows) => (
                <React.Fragment key={row.rpc}>
                  {(i === 0 || rows[i - 1].service !== row.service) && (
                    <tr className="border-b border-border bg-secondary/25">
                      <td
                        colSpan={4}
                        className="px-4 py-1.5 font-mono text-[10px] font-semibold uppercase tracking-wide text-muted"
                      >
                        {row.service}
                      </td>
                    </tr>
                  )}
                  <tr className="border-b border-border last:border-0">
                    <td className="px-4 py-1.5 font-mono text-foreground">
                      {row.rpc}
                      {row.streaming && (
                        <span className="ml-1.5 rounded-sm bg-primary/10 px-1 font-mono text-[9px] uppercase text-primary">
                          stream
                        </span>
                      )}
                    </td>
                    <td className="px-4 py-1.5 font-mono text-muted">{row.ts}</td>
                    <td className="px-4 py-1.5 font-mono text-muted">{row.go}</td>
                    <td className="px-4 py-1.5 font-mono text-muted">{row.swift}</td>
                  </tr>
                </React.Fragment>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {sdks.map((sdk) => (
        <section key={sdk.id} id={sdk.id} className="space-y-5 border-t border-border pt-10">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <h2 className="flex items-center gap-2.5 text-2xl font-bold tracking-tight">
              <sdk.Icon className="h-6 w-6" />
              {sdk.name}
            </h2>
            <code className="font-mono text-xs text-muted">{sdk.package}</code>
          </div>
          <p className="text-sm leading-relaxed text-muted">{sdk.blurb}</p>

          <div className="space-y-1.5">
            <h3 className="flex items-center gap-2 text-sm font-semibold">
              <Package className="h-3.5 w-3.5 text-muted" />
              Install
            </h3>
            <div className="rounded-lg border border-border bg-card">
              <CodeBlock code={sdk.install} language="bash" />
            </div>
          </div>

          <div className="space-y-1.5">
            <h3 className="flex items-center gap-2 text-sm font-semibold">
              <Braces className="h-3.5 w-3.5 text-muted" />
              Quickstart
            </h3>
            <div className="rounded-lg border border-border bg-card">
              <CodeBlock code={sdk.quickstart} language={sdk.id} />
            </div>
          </div>

          <p className="rounded-lg border border-border bg-secondary/40 px-4 py-3 text-[13px] leading-relaxed text-muted">
            <span className="font-medium text-foreground">Instrumentation — </span>
            {sdk.otel}
          </p>
        </section>
      ))}

      <section className="space-y-3 border-t border-border pt-10">
        <h2 className="text-xl font-semibold">Versioning &amp; regeneration</h2>
        <p className="text-sm leading-relaxed text-muted">
          SDKs track the daemon version. Go is tagged{" "}
          <code className="font-mono text-xs">sdk/go/v*</code>, the TypeScript
          package ships as a tarball asset on each GitHub release, and Swift
          consumers pin the repo tag. Generated code refreshes via{" "}
          <code className="font-mono text-xs">scripts/gen-sdk.sh</code> —
          CI fails if <code className="font-mono text-xs">proto/</code> and{" "}
          <code className="font-mono text-xs">sdk/</code> drift.
        </p>
      </section>
    </div>
  );
}
