/* eslint-disable @typescript-eslint/no-explicit-any */
import type { ParsedEndpoint } from "./types";
import { requestExampleFor } from "./examples";

export interface Sample {
  label: string;
  lang: string;
  code: string;
  /** Brand icon key — see components/lang-icons.tsx. */
  icon?: string;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

function jsLiteral(value: any, indent: string): string {
  // Pretty JSON with the given base indent — close enough to JS object literal
  // syntax for sample purposes (quoted keys are valid JS).
  return JSON.stringify(value, null, 2)
    .split("\n")
    .map((l, i) => (i === 0 ? l : indent + l))
    .join("\n");
}

// ---------------------------------------------------------------------------
// Language generators — one per call shape (method, url, body)
// ---------------------------------------------------------------------------

function curlSample(method: string, url: string, body: any, extraHeaders: string[] = []): string {
  let out = `curl -X ${method} "${url}"`;
  for (const h of extraHeaders) out += ` \\\n  -H "${h}"`;
  if (body !== undefined) {
    out += ` \\\n  -H "Content-Type: application/json"`;
    out += ` \\\n  -d '${JSON.stringify(body, null, 2)}'`;
  }
  return out;
}

function jsSample(method: string, url: string, body: any): string {
  const lines = [
    `const response = await fetch("${url}", {`,
    `  method: "${method}",`,
  ];
  if (body !== undefined) {
    lines.push(`  headers: { "Content-Type": "application/json" },`);
    lines.push(`  body: JSON.stringify(${jsLiteral(body, "  ")}),`);
  }
  lines.push("});", "", "const data = await response.json();", "console.log(data);");
  return lines.join("\n");
}

function pySample(method: string, url: string, body: any): string {
  const m = method.toLowerCase();
  const lines = ["import requests", "", `url = "${url}"`];
  if (body !== undefined) {
    lines.push("", `payload = ${jsLiteral(body, "")}`, "", `response = requests.${m}(url, json=payload)`);
  } else {
    lines.push("", `response = requests.${m}(url)`);
  }
  lines.push("print(response.status_code, response.json())");
  return lines.join("\n");
}

/** Render a JSON value as a Go composite literal (map[string]any / []any). */
function goLiteral(v: any, indent: string): string {
  if (v === null) return "nil";
  if (typeof v === "string") return JSON.stringify(v);
  if (typeof v === "boolean" || typeof v === "number") return String(v);
  if (Array.isArray(v)) {
    if (v.length === 0) return "[]any{}";
    const items = v.map((x) => `${indent}\t${goLiteral(x, indent + "\t")},`).join("\n");
    return `[]any{\n${items}\n${indent}}`;
  }
  const entries = Object.entries(v).map(
    ([k, x]) => `${indent}\t${JSON.stringify(k)}: ${goLiteral(x, indent + "\t")},`,
  );
  if (entries.length === 0) return "map[string]any{}";
  return `map[string]any{\n${entries.join("\n")}\n${indent}}`;
}

function goSample(method: string, url: string, body: any): string {
  const lines = [
    "import (",
    '\t"bytes"',
    '\t"encoding/json"',
    '\t"fmt"',
    '\t"net/http"',
    ")",
    "",
  ];
  if (body !== undefined) {
    lines.push(
      `payload, _ := json.Marshal(${goLiteral(body, "")})`,
      "",
      `req, _ := http.NewRequest("${method}", "${url}", bytes.NewReader(payload))`,
      '\treq.Header.Set("Content-Type", "application/json")',
    );
  } else {
    lines.push(`req, _ := http.NewRequest("${method}", "${url}", nil)`);
  }
  lines.push(
    "",
    "resp, err := http.DefaultClient.Do(req)",
    "if err != nil { panic(err) }",
    "defer resp.Body.Close()",
    "",
    "var result map[string]any",
    "json.NewDecoder(resp.Body).Decode(&result)",
    "fmt.Println(result)",
  );
  return lines.join("\n");
}

function swiftSample(method: string, url: string, body: any): string {
  const lines = [
    "import Foundation",
    "",
    `var request = URLRequest(url: URL(string: "${url}")!)`,
    `request.httpMethod = "${method}"`,
  ];
  if (body !== undefined) {
    lines.push(
      'request.setValue("application/json", forHTTPHeaderField: "Content-Type")',
      `request.httpBody = try JSONSerialization.data(withJSONObject: ${jsLiteral(body, "\t")})`,
    );
  }
  lines.push(
    "",
    "let (data, _) = try await URLSession.shared.data(for: request)",
    "print(String(decoding: data, as: UTF8.self))",
  );
  return lines.join("\n");
}

function samplesForCall(method: string, url: string, body: any): Sample[] {
  // Raw-HTTP samples are labeled by mechanism (fetch, requests, …) so they
  // don't collide with the typed SDK tabs (TypeScript, Go, Swift) when the
  // panel flattens everything into one strip.
  return [
    { label: "cURL", lang: "bash", icon: "bash", code: curlSample(method, url, body) },
    { label: "fetch", lang: "javascript", icon: "javascript", code: jsSample(method, url, body) },
    { label: "requests", lang: "python", icon: "python", code: pySample(method, url, body) },
    { label: "net/http", lang: "go", icon: "go", code: goSample(method, url, body) },
    { label: "URLSession", lang: "swift", icon: "swift", code: swiftSample(method, url, body) },
  ];
}

// ---------------------------------------------------------------------------
// Connect endpoints — raw HTTP samples.
// ---------------------------------------------------------------------------

export function connectSamples(endpoint: ParsedEndpoint, baseUrl: string): Sample[] {
  const body = requestExampleFor(endpoint);
  const url = `${baseUrl}${endpoint.path}`;
  // Typed-client snippets for MicropodService live in lib/sdk-samples.ts;
  // the request panel flattens both sets into one tab strip.
  return samplesForCall(endpoint.method, url, body);
}

// ---------------------------------------------------------------------------
// MCP — tools/call JSON-RPC payload.
// ---------------------------------------------------------------------------

export function mcpCallPayload(toolName: string, args: any): string {
  return JSON.stringify(
    {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: toolName, arguments: args },
    },
    null,
    2,
  );
}

export function mcpSamples(toolName: string, args: any): Sample[] {
  const payload = mcpCallPayload(toolName, args);
  return [
    {
      label: "JSON-RPC",
      lang: "json",
      code: payload,
    },
    {
      label: "stdio",
      lang: "bash",
      code: `# MicropodMCP speaks JSON-RPC over stdin/stdout\necho '${JSON.stringify(JSON.parse(payload))}' | micropod-mcp`,
    },
    {
      label: "Python",
      lang: "python",
      code: `import json, subprocess

proc = subprocess.run(
    ["micropod-mcp"],
    input=${JSON.stringify(JSON.stringify(JSON.parse(payload)))},
    capture_output=True, text=True,
)
print(json.loads(proc.stdout.strip().splitlines()[-1]))`,
    },
  ];
}
