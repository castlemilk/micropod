/* eslint-disable @typescript-eslint/no-explicit-any */

// Renders an endpoint/tool page as a Markdown document — used by the
// "Copy page" / "View as Markdown" actions (Fern parity for AI-assisted
// workflows: agents and chat tools ingest markdown cleanly).

export function endpointMarkdown(opts: {
  title: string;
  method: string;
  url: string;
  description?: string;
  requestExample?: any;
  responses?: { status: string; description?: string; example?: any }[];
  notes?: string;
}): string {
  const parts: string[] = [
    `# ${opts.method} ${opts.title}`,
    "",
    `\`${opts.method} ${opts.url}\``,
  ];
  if (opts.description) parts.push("", opts.description);
  if (opts.requestExample !== undefined) {
    parts.push("", "## Request", "", "```json", JSON.stringify(opts.requestExample, null, 2), "```");
  }
  if (opts.responses?.length) {
    parts.push("", "## Responses");
    for (const r of opts.responses) {
      parts.push("", `### ${r.status}${r.description ? ` — ${r.description}` : ""}`);
      if (r.example !== undefined) {
        const body = typeof r.example === "string" ? r.example : JSON.stringify(r.example, null, 2);
        parts.push("", "```json", body, "```");
      }
    }
  }
  if (opts.notes) parts.push("", opts.notes);
  parts.push("", "---", "_Micropod API reference — https://castlemilk.github.io/micropod/api/_");
  return parts.join("\n");
}

export function toolMarkdown(opts: {
  name: string;
  description?: string;
  argsExample?: any;
}): string {
  const parts: string[] = [`# MCP tool: ${opts.name}`];
  if (opts.description) parts.push("", opts.description);
  parts.push(
    "",
    "## Invocation",
    "",
    "```json",
    JSON.stringify(
      {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: opts.name, arguments: opts.argsExample ?? {} },
      },
      null,
      2,
    ),
    "```",
    "",
    "Serve over stdio: `micropod-mcp` — register via",
    "`claude mcp add micropod -- ~/.local/bin/micropod-mcp`.",
    "",
    "---",
    "_Micropod API reference — https://castlemilk.github.io/micropod/api/_",
  );
  return parts.join("\n");
}
