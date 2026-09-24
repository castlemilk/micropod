import React from "react";
import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { getMcpTool, loadMcpTools } from "@/lib/data";
import { SchemaViewer } from "@/components/schema-viewer";
import { CodeBlock } from "@/components/code-block";
import { TerminalSquare } from "lucide-react";

export function generateStaticParams() {
  return loadMcpTools().map((t) => ({ tool: t.name }));
}

export function generateMetadata({ params }: { params: { tool: string } }): Metadata {
  const tool = getMcpTool(params.tool);
  if (!tool) return {};
  return { title: tool.name, description: tool.description };
}

export default function McpToolPage({ params }: { params: { tool: string } }) {
  const tool = getMcpTool(params.tool);
  if (!tool) return notFound();

  const hasProperties =
    tool.inputSchema &&
    typeof tool.inputSchema === "object" &&
    Object.keys((tool.inputSchema as Record<string, unknown>).properties ?? {}).length > 0;

  const call = JSON.stringify(
    {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: tool.name, arguments: {} },
    },
    null,
    2,
  );

  return (
    <div className="mx-auto max-w-3xl space-y-8 px-6 py-10 md:px-10">
      <div className="space-y-3">
        <div className="flex items-center gap-3">
          <TerminalSquare className="h-5 w-5 text-warn" />
          <code className="font-mono text-sm text-muted">tools/call</code>
        </div>
        <h1 className="font-mono text-3xl font-bold tracking-tight">{tool.name}</h1>
        <p className="text-muted">{tool.description}</p>
      </div>

      {hasProperties ? (
        <section className="space-y-3">
          <h2 className="border-b border-border pb-2 text-xl font-semibold">Arguments</h2>
          <SchemaViewer schema={tool.inputSchema} />
        </section>
      ) : (
        <p className="rounded-md border border-border bg-card px-4 py-3 text-sm text-muted">
          No declared input schema — argument details are described in the tool
          description above.
        </p>
      )}

      <section className="space-y-3">
        <h2 className="border-b border-border pb-2 text-xl font-semibold">JSON-RPC call</h2>
        <div className="overflow-hidden rounded-lg border border-border bg-card">
          <CodeBlock code={call} language="json" />
        </div>
      </section>
    </div>
  );
}
