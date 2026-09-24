/* eslint-disable @typescript-eslint/no-explicit-any */

// Schema → realistic example values. The connect-openapi specs carry no
// examples or field docs (protobuf-flavored: `type: ["string","null"]` for
// optionals, `["integer","string"]` for int64), so the explorer leans on
// field-name heuristics plus a small set of curated per-message overrides.

const MAX_DEPTH = 5;

// Normalized (lowercase, separators stripped) field name → example value.
// Order matters: first match wins, more specific names first.
const FIELD_HINTS: [RegExp, () => any][] = [
  [/^image$|^reference$/, () => "alpine:3.20"],
  [/containerid|^id$/, () => "9f2e4a1b3c7d"],
  [/^name$/, () => "web"],
  [/^names$/, () => ["alpine:3.20", "alpine:latest"]],
  [/createdat|sampledat|timestamp/, () => "2026-09-24T04:12:37.201Z"],
  [/^cpus$/, () => 0.5],
  [/^memory$/, () => "512m"],
  [/memoryusedbytes/, () => "71303168"],
  [/memorylimitbytes/, () => "4294967296"],
  [/networkrxbytes/, () => "1887436"],
  [/networktxbytes/, () => "917504"],
  [/blockreadbytes/, () => "4096"],
  [/blockwritebytes/, () => "1048576"],
  [/reclaimableimagebytes/, () => "536870912"],
  [/reclaimablevolumebytes/, () => "0"],
  [/totalreclaimablebytes|reclaimablebytes/, () => "1610612736"],
  [/sizebytes/, () => "2147483648"],
  [/bytes$|^total$|^active$/, () => "1073741824"],
  [/^state$|^status$/, () => "running"],
  [/^env$|^environment$/, () => ["NODE_ENV=production", "PORT=8080"]],
  [/^command$/, () => "uname -a"],
  [/^arguments$|^args$/, () => ["cat", "/etc/os-release"]],
  [/^workdir$|^workingdir/, () => "/app"],
  [/^hostport$/, () => 8080],
  [/^containerport$/, () => 80],
  [/^protocol$/, () => "tcp"],
  [/hostip/, () => "0.0.0.0"],
  [/^ports$/, () => [{ hostPort: 8080, containerPort: 80, protocol: "tcp" }]],
  [/^volumes$/, () => ["web-data:/usr/share/nginx/html"]],
  [/^mounts$/, () => [{ type: "volume", source: "web-data", destination: "/data", readOnly: false }]],
  [/^options$/, () => []],
  [/^key$/, () => "com.example.tier"],
  [/^value$/, () => "web"],
  [/^init$|^detach$|^inuse$/, () => true],
  [/^force$|^readonly$|^boot$|^internal$|^builtin$|^rosetta$|^jobsonly$/, () => false],
  [/^tail$/, () => 200],
  [/^exitcode$/, () => 0],
  [/^output$/, () => "Linux 9f2e4a1b3c7d 6.8.0 aarch64 GNU/Linux\n"],
  [/^error$/, () => ""],
  [/^code$/, () => "not_found"],
  [/^message$/, () => "container not found"],
  [/ipv4address/, () => "192.168.64.3"],
  [/ipv4gateway/, () => "192.168.64.1"],
  [/ipv4subnet/, () => "192.168.64.0/24"],
  [/ipv6subnet|subnetv6/, () => "fd64:a1b2:c3d4::/64"],
  [/^subnet$/, () => "192.168.100.0/24"],
  [/^digest$|^sha/, () => "sha256:1d34ffeaf190be23c96c9f3d4c2a1e8c1e2b8f6d4a3c2e1b0f9e8d7c6b5a4938"],
  [/^driver$/, () => "local"],
  [/^plugin$/, () => "vmnet"],
  [/^mode$/, () => "nat"],
  [/^platform$/, () => "linux/arm64"],
  [/^os$/, () => "linux"],
  [/^architecture$/, () => "arm64"],
  [/^variant$/, () => "v8"],
  [/^type$/, () => "volume"],
  [/^source$/, () => "web-data"],
  [/^destination$/, () => "/data"],
  [/^approot$/, () => "/Applications/Micropod.app"],
  [/^installroot$/, () => "/usr/local/micropod"],
  [/apiserverversion|cliversion|runtimeversion/, () => "1.3.1"],
  [/commit$/, () => "e9a62e2"],
  [/^format$/, () => "ext4"],
  [/^text$/, () => "server listening on :8080\n"],
  [/^line$/, () => "alpine:3.20 — pulling layer 2/5"],
  [/^stage$/, () => 2],
  [/totalstages/, () => 5],
  [/^path$|^file$/, () => "/tmp/docker-compose.yml"],
  [/^port$/, () => 1024],
  [/^pids$/, () => 14],
  [/^networks$/, () => ["micropod0"]],
  [/usedbycontainerids/, () => ["9f2e4a1b3c7d"]],
  [/stoppedcontainercount/, () => 2],
  [/^profiles$/, () => ["debug", "test"]],
  [/goldenvolumes|^goldens$/, () => ["xcode-cache"]],
  [/^clonemode$/, () => "labels"],
  [/^sync$/, () => "fsync"],
  [/^cache$/, () => "auto"],
  [/backend/, () => "native"],
];

export function fieldHint(name: string): any {
  const key = name.toLowerCase().replace(/[_\-.]/g, "");
  for (const [re, fn] of FIELD_HINTS) {
    if (re.test(key)) return fn();
  }
  return undefined;
}

/** The concrete (non-null) member of a proto JSON union type. */
export function primaryType(schema: any): string | undefined {
  const t = schema?.type;
  if (Array.isArray(t)) return t.find((x: string) => x !== "null");
  return t;
}

export function isNullable(schema: any): boolean {
  return Array.isArray(schema?.type) && schema.type.includes("null");
}

/** Compact, honest type names for protobuf-flavored OpenAPI schemas. */
export function typeLabel(schema: any): string {
  if (!schema || typeof schema !== "object") return "any";
  if (schema.title && schema.type === "object" && schema.properties && !schema.additionalProperties) {
    // Named message type keeps its proto name.
    return schema.title;
  }
  if (isInt64(schema)) return "int64";
  const type = primaryType(schema);
  const nullable = isNullable(schema) ? "?" : "";
  if (type === "array" || schema.items) {
    return `${typeLabel(schema.items ?? {})}[]${nullable}`;
  }
  if (type === "object" || schema.properties || schema.additionalProperties) {
    if (schema.additionalProperties) {
      const v =
        typeof schema.additionalProperties === "object"
          ? typeLabel(schema.additionalProperties)
          : "any";
      return `map<string, ${v}>${nullable}`;
    }
    return `object${nullable}`;
  }
  if (schema.allOf) return `allOf${nullable}`;
  if (schema.oneOf) return `oneOf${nullable}`;
  if (schema.anyOf) return `anyOf${nullable}`;
  return `${type ?? "any"}${nullable}`;
}

/** proto3 JSON emits int64/uint64 as a string-or-number union. */
export function isInt64(schema: any): boolean {
  const t = schema?.type;
  return Array.isArray(t) && t.includes("integer") && t.includes("string");
}

function hinted(name: string | undefined, schema: any): any {
  if (!name) return undefined;
  const v = fieldHint(name);
  if (v === undefined) return undefined;
  // Skip hints whose shape mismatches the schema (e.g. a string hint on a
  // repeated field) — the type dispatch below produces a saner value.
  const t = primaryType(schema);
  if (t === "array" && !Array.isArray(v)) return undefined;
  if (t === "string" && typeof v !== "string") return undefined;
  return v;
}

function fallbackScalar(schema: any): any {
  switch (primaryType(schema)) {
    case "string":
      if (schema.format === "date-time") return "2026-09-24T04:12:37.201Z";
      if (schema.format === "byte" || schema.format === "bytes") return "AAEC";
      return "string";
    case "integer":
      return 1;
    case "number":
      return 1.0;
    case "boolean":
      return true;
    default:
      return {};
  }
}

export function exampleForSchema(schema: any, name?: string, depth = 0): any {
  if (!schema || typeof schema !== "object") return null;
  // gnostic (openapi.v3.property).example annotations land as `examples: []`.
  if (schema.example !== undefined) return schema.example;
  if (schema.examples?.[0] !== undefined) return schema.examples[0];
  if (schema.default !== undefined) return schema.default;
  if (schema.enum?.length) {
    // Proto enums lead with a *_UNSPECIFIED zero value — examples should
    // show a real variant.
    return (
      schema.enum.find((v: any) => typeof v !== "string" || !/unspecified/i.test(v)) ??
      schema.enum[0]
    );
  }
  if (depth > MAX_DEPTH) return fallbackScalar(schema);

  const h = hinted(name, schema);
  if (h !== undefined) return h;

  if (schema.allOf?.length) return exampleForSchema(schema.allOf[0], name, depth + 1);
  if (schema.oneOf?.length) return exampleForSchema(schema.oneOf[0], name, depth + 1);
  if (schema.anyOf?.length) return exampleForSchema(schema.anyOf[0], name, depth + 1);

  if (isInt64(schema)) {
    // proto3 JSON: 64-bit ints travel as strings.
    const numeric = { int64: "1073741824" };
    return numeric.int64;
  }

  const type = primaryType(schema);
  if (type === "array" || schema.items) {
    return [exampleForSchema(schema.items ?? { type: "string" }, singular(name), depth + 1)];
  }

  if (type === "object" || schema.properties || schema.additionalProperties) {
    if (schema.properties && Object.keys(schema.properties).length > 0) {
      const out: Record<string, any> = {};
      for (const [k, v] of Object.entries<any>(schema.properties)) {
        out[k] = exampleForSchema(v, k, depth + 1);
      }
      return out;
    }
    if (schema.additionalProperties) {
      const val = exampleForSchema(
        typeof schema.additionalProperties === "object" ? schema.additionalProperties : { type: "string" },
        "value",
        depth + 1,
      );
      return { "com.example.key": val };
    }
    return {};
  }

  return fallbackScalar(schema);
}

function singular(name?: string): string | undefined {
  if (!name) return name;
  if (name.endsWith("ies")) return name.slice(0, -3) + "y";
  if (name.endsWith("s")) return name.slice(0, -1);
  return name;
}

// ---------------------------------------------------------------------------
// Curated request/response overrides for flagship operations — the generator
// gets close, but these tell the story better.
// ---------------------------------------------------------------------------

export const REQUEST_OVERRIDES: Record<string, any> = {
  "micropod.v1.ContainerService.CreateContainer": {
    image: "alpine:3.20",
    name: "web",
    detach: true,
    cpus: 0.5,
    memory: "512m",
    env: ["NGINX_PORT=80"],
    ports: [{ hostPort: 8080, containerPort: 80, protocol: "tcp" }],
    volumes: ["web-data:/usr/share/nginx/html"],
    labels: { "com.micropod.workload": "demo" },
    init: true,
    arguments: [],
  },
  "micropod.v1.ContainerService.Exec": {
    id: "9f2e4a1b3c7d",
    command: "cat /etc/os-release",
    workdir: "/",
    env: [],
  },
  "micropod.v1.ImageService.PullImage": { reference: "alpine:3.20", platform: "linux/arm64" },
  "micropod.v1.ContainerService.StreamContainerLogs": { id: "9f2e4a1b3c7d", tail: 200, boot: false },
  "micropod.v1.NetworkService.CreateNetwork": {
    name: "frontend",
    internal: false,
    subnet: "192.168.100.0/24",
    driver: "bridge",
    options: [],
    labels: [{ key: "com.example.tier", value: "edge" }],
  },
  "micropod.v1.VolumeService.CreateVolume": {
    name: "web-data",
    size: "10g",
    labels: [{ key: "com.micropod.cache.clone", value: "true" }],
    options: [],
  },
  "micropod.v1.ComposeService.ComposeUp": {
    path: "/tmp/docker-compose.yml",
    profiles: ["debug"],
  },
  "micropod.v1.ComposeService.ComposeDown": { name: "web" },
  "micropod.v1.VolumeService.SetVolumePolicy": {
    cloneMode: "CLONE_MODE_GOLDENS",
    goldenVolumes: ["xcode-cache"],
    jobsOnly: true,
    sync: "SYNC_MODE_FSYNC",
    cache: "CACHE_MODE_AUTO",
  },
};

export function requestExampleFor(endpoint: { operationId?: string; requestBody?: any }): any {
  if (endpoint.operationId && REQUEST_OVERRIDES[endpoint.operationId]) {
    return REQUEST_OVERRIDES[endpoint.operationId];
  }
  const schema = endpoint.requestBody?.content?.["application/json"]?.schema;
  return schema ? exampleForSchema(schema) : {};
}

export function responseExampleFor(endpoint: { responses?: Record<string, any> }): {
  status: string;
  body: any;
} | undefined {
  const entries = Object.entries(endpoint.responses ?? {});
  const ok = entries.find(([code]) => code.startsWith("2")) ?? entries[0];
  if (!ok) return undefined;
  const schema = ok[1]?.content?.["application/json"]?.schema;
  return { status: ok[0], body: exampleForSchema(schema ?? {}) };
}

// ---------------------------------------------------------------------------
// MCP — tools ship empty inputSchema; their descriptions end with
// "Arguments: name, other (optional note)." Parse that into a synthetic
// schema so tools get the same explorer treatment.
// ---------------------------------------------------------------------------

const MCP_ARG_TYPES: Record<string, any> = {
  tail: { type: "integer" },
  lines: { type: "integer" },
  timeout: { type: "integer" },
  detach: { type: "boolean" },
  init: { type: "boolean" },
  force: { type: "boolean" },
  boot: { type: "boolean" },
  internal: { type: "boolean" },
  jobsOnly: { type: "boolean" },
  env: { type: "array", items: { type: "string" } },
  ports: { type: "array", items: { type: "string" } },
  volumes: { type: "array", items: { type: "string" } },
  goldens: { type: "string", description: "Comma-separated volume names" },
  profiles: { type: "string", description: "Comma-separated compose profiles" },
};

export interface ParsedMcpArg {
  name: string;
  required: boolean;
  note?: string;
  schema: any;
}

export function mcpArgsFromDescription(description: string): ParsedMcpArg[] {
  const start = /Arguments?:\s*/i.exec(description ?? "");
  if (!start) return [];
  // The arg list ends at the first sentence-ending period at paren depth 0
  // ("cache (on|off|auto). Only provided fields change." → stops after `)`).
  const tail = description!.slice(start.index + start[0].length);
  let depth = 0;
  let end = tail.length;
  for (let i = 0; i < tail.length; i++) {
    const c = tail[i];
    if (c === "(") depth++;
    else if (c === ")") depth = Math.max(0, depth - 1);
    else if (c === "." && depth === 0) {
      end = i;
      break;
    }
  }
  const list = tail.slice(0, end).replace(/\.$/, "");
  // Split on commas at paren depth 0 so "(a, b)" stays one token.
  const parts: string[] = [];
  let cur = "";
  depth = 0;
  for (const c of list) {
    if (c === "(") depth++;
    else if (c === ")") depth = Math.max(0, depth - 1);
    if (c === "," && depth === 0) {
      parts.push(cur);
      cur = "";
    } else {
      cur += c;
    }
  }
  parts.push(cur);
  return parts
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const paren = /\(([^)]*)\)/.exec(part);
      const name = part.replace(/\s*\([^)]*\)\s*/, "").trim();
      const note = paren?.[1]?.trim();
      const optional = /optional/i.test(note ?? "") || /optional/i.test(part);
      return {
        name,
        required: !optional,
        note: note && !/optional/i.test(note) ? note : undefined,
        schema: MCP_ARG_TYPES[name] ?? { type: "string" },
      };
    });
}

/** Synthetic JSON Schema for an MCP tool, derived from its description. */
export function mcpInputSchema(tool: { description?: string; inputSchema?: any }): any | undefined {
  const existing = tool.inputSchema;
  if (existing && typeof existing === "object" && Object.keys(existing.properties ?? {}).length > 0) {
    return existing;
  }
  const args = mcpArgsFromDescription(tool.description ?? "");
  if (args.length === 0) return undefined;
  return {
    type: "object",
    title: "arguments",
    properties: Object.fromEntries(
      args.map((a) => [
        a.name,
        {
          ...a.schema,
          ...(a.note ? { description: a.note } : {}),
        },
      ]),
    ),
    required: args.filter((a) => a.required).map((a) => a.name),
  };
}

export function mcpArgumentsExample(tool: { description?: string; inputSchema?: any }): any {
  const schema = mcpInputSchema(tool);
  if (!schema) return {};
  return exampleForSchema(schema);
}

/** Description with just the "Arguments: …" list removed — trailing
 *  sentences like "Only provided fields change." are kept. */
export function mcpDescription(description: string): string {
  const text = description ?? "";
  const start = /Arguments?:\s*/i.exec(text);
  if (!start) return text.trim();
  const tail = text.slice(start.index + start[0].length);
  let depth = 0;
  let end = tail.length;
  for (let i = 0; i < tail.length; i++) {
    const c = tail[i];
    if (c === "(") depth++;
    else if (c === ")") depth = Math.max(0, depth - 1);
    else if (c === "." && depth === 0) {
      end = i;
      break;
    }
  }
  const after = tail.slice(end);
  return (text.slice(0, start.index) + after).replace(/\s+/g, " ").trim();
}
