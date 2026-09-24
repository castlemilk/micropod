import React from "react";
import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { getMcpTool, loadMcpTools } from "@/lib/data";
import {
  mcpArgumentsExample,
  mcpDescription,
  mcpInputSchema,
} from "@/lib/examples";
import { mcpSamples } from "@/lib/code-samples";
import { toolMarkdown } from "@/lib/markdown";
import { PageActions } from "@/components/page-actions";
import { PayloadExplorer } from "@/components/payload-explorer";
import { RequestPanel } from "@/components/request-panel";
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

  const schema = mcpInputSchema(tool);
  const args = mcpArgumentsExample(tool);
  const samples = mcpSamples(tool.name, args);
  const description = mcpDescription(tool.description);

  const panel = <RequestPanel samples={samples} heading={`tools/call · ${tool.name}`} />;

  return (
    <div className="xl:grid xl:grid-cols-[1fr_420px]">
      <div className="space-y-8 px-6 py-8 pb-16 md:px-8">
        <div className="space-y-3">
          <p className="flex items-center gap-1.5 text-[13px] font-medium text-primary">
            <TerminalSquare className="h-3.5 w-3.5" /> MCP · tools/call
          </p>
          <h1 className="font-mono text-3xl font-bold tracking-tight">{tool.name}</h1>
          <PageActions
            markdown={toolMarkdown({ name: tool.name, description, argsExample: args })}
          />
          <div className="flex items-center gap-3 rounded-lg border border-border bg-card/60 px-3.5 py-2.5">
            <code className="min-w-0 flex-1 truncate font-mono text-[13px] text-muted">
              micropod-mcp · stdio JSON-RPC 2.0
            </code>
          </div>
          <p className="text-muted">{description}</p>
        </div>

        {schema ? (
          <section className="space-y-3">
            <h2 className="border-b border-border pb-2 text-xl font-semibold">Arguments</h2>
            <PayloadExplorer schema={schema} example={args} />
          </section>
        ) : (
          <p className="rounded-md border border-border bg-card px-4 py-3 text-sm text-muted">
            Takes no arguments — call it with an empty{" "}
            <code className="font-mono text-xs">arguments</code> object.
          </p>
        )}

        <section className="space-y-3">
          <h2 className="border-b border-border pb-2 text-xl font-semibold">Result</h2>
          <p className="text-sm text-muted">
            Returns a standard MCP <code className="font-mono text-xs">CallToolResult</code>{" "}
            — text content on success, or <code className="font-mono text-xs">isError: true</code>{" "}
            with a diagnostic message on failure.
          </p>
        </section>
      </div>

      <div className="hidden xl:block">
        <div className="sticky top-14 h-[calc(100vh-3.5rem)]">{panel}</div>
      </div>
      <div className="border-t border-border px-6 py-8 md:px-8 xl:hidden">
        <div className="h-96 overflow-hidden rounded-lg border border-border">{panel}</div>
      </div>
    </div>
  );
}
