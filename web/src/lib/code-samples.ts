/* eslint-disable @typescript-eslint/no-explicit-any */
import type { ParsedEndpoint, RestRoute } from "./types";

function exampleFromSchema(schema: any): any {
  if (!schema || typeof schema !== "object") return {};
  if (schema.example !== undefined) return schema.example;
  if (schema.enum?.length) return schema.enum[0];
  if (schema.type === "array") return [exampleFromSchema(schema.items)];
  if (schema.type === "object" || schema.properties) {
    const out: Record<string, any> = {};
    const required: string[] = schema.required ?? [];
    for (const [k, v] of Object.entries<any>(schema.properties ?? {})) {
      // Only populate required fields so samples stay minimal.
      if (required.includes(k)) out[k] = exampleFromSchema(v);
    }
    if (Object.keys(out).length === 0 && schema.properties) {
      for (const [k, v] of Object.entries<any>(schema.properties).slice(0, 2)) {
        out[k] = exampleFromSchema(v);
      }
    }
    return out;
  }
  switch (schema.type) {
    case "string":
      return schema.format === "date-time" ? "2025-01-01T00:00:00Z" : "string";
    case "integer":
    case "number":
      return 0;
    case "boolean":
      return true;
    default:
      return {};
  }
}

function requestExample(endpoint: ParsedEndpoint): any | undefined {
  const schema = endpoint.requestBody?.content?.["application/json"]?.schema as any;
  return schema ? exampleFromSchema(schema) : undefined;
}

export function generateCurl(endpoint: ParsedEndpoint, baseUrl: string): string {
  let curl = `curl -X ${endpoint.method} "${baseUrl}${endpoint.path}"`;
  curl += ` \\\n  -H "Content-Type: application/json"`;
  const body = requestExample(endpoint);
  if (endpoint.method !== "GET") {
    curl += ` \\\n  -d '${JSON.stringify(body ?? {}, null, 2)}'`;
  }
  return curl;
}

export function generateJavascript(endpoint: ParsedEndpoint, baseUrl: string): string {
  const body = requestExample(endpoint);
  const lines = [
    `const response = await fetch("${baseUrl}${endpoint.path}", {`,
    `  method: "${endpoint.method}",`,
    `  headers: { "Content-Type": "application/json" },`,
  ];
  if (endpoint.method !== "GET") {
    lines.push(`  body: JSON.stringify(${JSON.stringify(body ?? {})}),`);
  }
  lines.push("});", "const data = await response.json();");
  return lines.join("\n");
}

export function generatePython(endpoint: ParsedEndpoint, baseUrl: string): string {
  const body = requestExample(endpoint);
  const m = endpoint.method.toLowerCase();
  let py = `import requests\n\nurl = "${baseUrl}${endpoint.path}"\n`;
  if (endpoint.method !== "GET") {
    py += `\ndata = ${JSON.stringify(body ?? {}, null, 4)}\n`;
    py += `response = requests.${m}(url, json=data)\n`;
  } else {
    py += `response = requests.${m}(url)\n`;
  }
  return py + `print(response.json())`;
}

export function generateGo(endpoint: ParsedEndpoint, baseUrl: string): string {
  const op = endpoint.operationId ?? endpoint.summary ?? "Call";
  const reqType = `${op.split(".").pop()}Request`;
  return `import (
  "net/http"

  "connectrpc.com/connect"
  micropodv1 "github.com/castlemilk/micropod/api/gen/micropod/v1"
  "github.com/castlemilk/micropod/api/gen/micropod/v1/micropodv1connect"
)

client := micropodv1connect.NewMicropodServiceClient(
  http.DefaultClient, "${baseUrl}",
)
resp, err := client.${endpoint.summary}(
  ctx, connect.NewRequest(&micropodv1.${reqType}{/* ... */}),
)`;
}

export function generateRestCurl(route: RestRoute, baseUrl: string): string {
  const path = route.pathParams.reduce(
    (p, name) => p.replace(`{${name}}`, `<${name}>`),
    route.path,
  );
  let curl = `curl -X ${route.method} "${baseUrl}${path}"`;
  if (route.method === "POST" || route.method === "PUT") {
    curl += ` \\\n  -H "Content-Type: application/json" \\\n  -d '{}'`;
  }
  return curl;
}
