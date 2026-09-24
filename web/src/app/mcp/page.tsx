import React from "react";
import Link from "next/link";
import type { Metadata } from "next";
import { loadMcpTools, mcpGroups } from "@/lib/data";

export const metadata: Metadata = {
  title: "MCP tools",
  description: "Model Context Protocol tools exposed by the MicropodMCP server.",
};

export default function McpIndexPage() {
  const tools = loadMcpTools();
  const groups = mcpGroups(tools);

  return (
    <div className="mx-auto max-w-4xl space-y-10 px-6 py-10 md:px-10">
      <div className="space-y-3">
        <h1 className="text-3xl font-bold tracking-tight">MCP tools</h1>
        <p className="text-muted">
          {tools.length} tools exposed by the <code className="font-mono text-xs">MicropodMCP</code>{" "}
          server over stdio JSON-RPC. Captured from a live{" "}
          <code className="font-mono text-xs">tools/list</code> — argument details are in
          each tool&apos;s description.
        </p>
      </div>

      {groups.map((g) => (
        <section key={g.title} className="space-y-3">
          <h2 className="text-xl font-semibold">{g.title}</h2>
          <div className="divide-y divide-border overflow-hidden rounded-lg border border-border">
            {g.tools.map((t) => (
              <Link
                key={t.name}
                href={`/mcp/${t.name}/`}
                className="flex items-center gap-3 bg-card px-4 py-2.5 transition-colors hover:bg-secondary/50"
              >
                <code className="shrink-0 font-mono text-sm font-semibold text-primary">
                  {t.name}
                </code>
                <span className="truncate text-xs text-muted">
                  {t.description.split(".")[0]}
                </span>
              </Link>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
