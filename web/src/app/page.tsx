import React from "react";
import Link from "next/link";
import { ArrowRight, Plug, TerminalSquare, FileCode2, Package } from "lucide-react";
import { loadConnectServices, loadMcpTools, REST_BASE_URL } from "@/lib/data";

export default function OverviewPage() {
  const services = loadConnectServices();
  const tools = loadMcpTools();
  const daemonServices = services.filter((s) => s.service.startsWith("micropod."));
  const rpcCount = daemonServices.reduce((n, s) => n + s.spec.endpoints.length, 0);
  const guest = services.filter((s) => !s.service.startsWith("micropod."));
  const version = services.find((s) => s.spec.info.version)?.spec.info.version;

  const surfaces = [
    {
      href: "/grpc/",
      icon: Plug,
      title: "Micropod API",
      count: `${rpcCount} RPCs · ${daemonServices.length} services`,
      blurb: `The daemon's Connect-RPC service on ${REST_BASE_URL} — unary JSON over plain POST, so curl, fetch, and the typed SDKs all speak the same contract.`,
    },
    {
      href: "/sdk/",
      icon: Package,
      title: "Client SDKs",
      count: "Go · TS · Swift",
      blurb:
        "Generated clients with retry, timeouts, client-side validation, and OpenTelemetry instrumentation built in — one contract, three languages.",
    },
    {
      href: "/mcp/",
      icon: TerminalSquare,
      title: "MCP tools",
      count: `${tools.length} tools`,
      blurb:
        "Model Context Protocol server (MicropodMCP) exposing container, image, volume, and compose operations to agents — installable as a Claude Code plugin from the repo.",
    },
    {
      href: "/proto/",
      icon: FileCode2,
      title: "Protobuf",
      count: "source of truth",
      blurb:
        "Generated message and service reference for proto/micropod/v1 plus the vendored Apple sandbox contract.",
    },
  ];

  return (
    <div className="mx-auto max-w-4xl space-y-12 px-6 py-10 md:px-10">
      <div className="space-y-4">
        <div className="flex items-center gap-3">
          <h1 className="text-4xl font-extrabold tracking-tight">Micropod API</h1>
          {version && (
            <span className="rounded-md border border-border bg-card px-2 py-1 font-mono text-xs font-semibold text-muted">
              v{version}
            </span>
          )}
        </div>
        <p className="max-w-2xl text-lg text-muted">
          One API, three client styles. The daemon exposes a single Connect-RPC
          service — proto-JSON over plain HTTP POST — so curl, browsers, and the
          typed SDKs all call the same endpoints. The MCP server wraps the same
          operations for agents, and the vminitd guest contract rides the vsock
          bridge. Everything is generated from the protos.
        </p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        {surfaces.map((s) => (
          <Link
            key={s.href}
            href={s.href}
            className="group rounded-lg border border-border bg-card p-5 transition-colors hover:border-primary/50"
          >
            <div className="mb-3 flex items-center justify-between">
              <s.icon className="h-5 w-5 text-primary" />
              <span className="font-mono text-xs text-muted">{s.count}</span>
            </div>
            <h2 className="mb-1 font-semibold">{s.title}</h2>
            <p className="text-sm leading-relaxed text-muted">{s.blurb}</p>
            <span className="mt-3 flex items-center text-sm font-medium text-primary">
              Browse
              <ArrowRight className="ml-1 h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5" />
            </span>
          </Link>
        ))}
      </div>

      <section className="space-y-4">
        <h2 className="text-xl font-semibold">Quick start</h2>
        <div className="rounded-lg border border-border bg-card p-4 font-mono text-[13px] leading-relaxed">
          <p className="text-muted"># Connect unary — plain POST + JSON</p>
          <p>
            curl -X POST {REST_BASE_URL}/api/micropod.v1.ContainerService/ListContainers \
          </p>
          <p>{'  -H "Content-Type: application/json" -d \'{}\''}</p>
          <p className="mt-3 text-muted"># TypeScript SDK — same call, typed</p>
          <p>{`const res = await client.listContainers({});`}</p>
          <p className="mt-3 text-muted"># MCP — stdio JSON-RPC (MicropodMCP binary)</p>
          <p>{`echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | MicropodMCP`}</p>
        </div>
        <p className="text-xs text-muted">
          Infra endpoints outside the Connect mount:{" "}
          <code className="font-mono">GET /health</code>,{" "}
          <code className="font-mono">GET /metrics</code>, and{" "}
          <code className="font-mono">GET /v1/containers/{"{id}"}/vsock/{"{port}"}</code>{" "}
          (raw duplex bridge into guest vminitd — not Connect-expressible).
        </p>
      </section>

      {guest.length > 0 && (
        <section className="space-y-3">
          <h2 className="text-xl font-semibold">Guest API</h2>
          <p className="text-sm text-muted">
            <code className="font-mono text-xs">SandboxContext</code> ({guest[0].spec.endpoints.length} RPCs)
            is vminitd's contract inside each container VM — served over vsock port 1024,
            reachable from the host via the bridge above, not via {REST_BASE_URL}.
          </p>
        </section>
      )}

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">Generated artifacts</h2>
        <p className="text-sm text-muted">
          Everything on this site is produced by <code className="font-mono text-xs">scripts/gen-api-docs.py</code> +
          buf remote plugins. Raw outputs:
        </p>
        <ul className="grid gap-1 font-mono text-xs text-primary sm:grid-cols-2">
          {[
            "rest-routes.json",
            "mcp-tools.json",
            "proto-reference.html",
            "openapi.html",
            "micropod/v1/container.openapi.json",
            "micropod/v1/image.openapi.json",
            "micropod/v1/volume.openapi.json",
            "micropod/v1/network.openapi.json",
            "micropod/v1/compose.openapi.json",
            "micropod/v1/system.openapi.json",
            "com/apple/containerization/sandbox/v3/sandbox_context.openapi.json",
          ].map((f) => (
            <li key={f}>
              <a href={`specs/${f}`} className="hover:underline">
                {f}
              </a>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}
