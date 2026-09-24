import React from "react";
import Link from "next/link";
import { ArrowRight, Globe, Plug, TerminalSquare, FileCode2, Package } from "lucide-react";
import { loadConnectServices, loadMcpTools, loadRestRoutes, REST_BASE_URL } from "@/lib/data";

export default function OverviewPage() {
  const routes = loadRestRoutes();
  const services = loadConnectServices();
  const tools = loadMcpTools();
  const rpcCount = services.reduce((n, s) => n + s.spec.endpoints.length, 0);

  const surfaces = [
    {
      href: "/rest/",
      icon: Globe,
      title: "REST API",
      count: `${routes.length} routes`,
      blurb: `HTTP API served by the Micropod daemon on ${REST_BASE_URL}. Powers the app, CLI, and Docker shim.`,
    },
    {
      href: "/grpc/",
      icon: Plug,
      title: "Connect / gRPC",
      count: `${rpcCount} RPCs`,
      blurb:
        "Protobuf-defined Connect services: MicropodService for the daemon, SandboxContext for the vminitd guest agent over vsock.",
    },
    {
      href: "/mcp/",
      icon: TerminalSquare,
      title: "MCP tools",
      count: `${tools.length} tools`,
      blurb:
        "Model Context Protocol server (MicropodMCP) exposing container, image, volume, and compose operations to agents.",
    },
    {
      href: "/proto/",
      icon: FileCode2,
      title: "Protobuf",
      count: "source of truth",
      blurb:
        "Generated message and service reference for proto/micropod/v1 plus the vendored Apple sandbox contract.",
    },
    {
      href: "/sdk/",
      icon: Package,
      title: "Client SDKs",
      count: "Go · TS · Swift",
      blurb:
        "Generated clients with retry, timeouts, and OpenTelemetry instrumentation built in — one contract, three languages.",
    },
  ];

  return (
    <div className="mx-auto max-w-4xl space-y-12 px-6 py-10 md:px-10">
      <div className="space-y-4">
        <h1 className="text-4xl font-extrabold tracking-tight">Micropod API</h1>
        <p className="max-w-2xl text-lg text-muted">
          Three surfaces, one engine. The REST API serves the app and CLI locally,
          Connect-RPC serves programmatic clients, and the MCP server exposes the
          same operations to agents. Everything here is generated from the source
          of truth — proto definitions, route handlers, and a live tools/list.
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
          <p className="text-muted"># REST — served by the daemon</p>
          <p>curl {REST_BASE_URL}/v1/containers</p>
          <p className="mt-3 text-muted"># Connect-RPC — unary JSON</p>
          <p>
            curl -X POST {REST_BASE_URL}/api/micropod.v1.MicropodService/ListContainers \
          </p>
          <p>{'  -H "Content-Type: application/json" -d \'{}\''}</p>
          <p className="mt-3 text-muted"># MCP — stdio JSON-RPC (MicropodMCP binary)</p>
          <p>{`echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | MicropodMCP`}</p>
        </div>
      </section>

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
            "micropod/v1/api.openapi.json",
            "micropod/v1/container.openapi.json",
            "micropod/v1/image.openapi.json",
            "micropod/v1/system.openapi.json",
            "micropod/v1/compose.openapi.json",
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
