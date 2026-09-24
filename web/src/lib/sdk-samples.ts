/* eslint-disable @typescript-eslint/no-explicit-any */
// SDK call samples — typed client invocations for the Go, TypeScript, and
// Swift SDKs. Generated from the endpoint's proto contract (operationId,
// request/response message types, streaming flag) plus the shared request
// example, so field names stay proto-accurate even when the REST projection
// differs.
import type { ParsedEndpoint, RestRoute } from "./types";
import { requestExampleFor } from "./examples";
import { loadConnectServices, REST_BASE_URL } from "./data";
import type { Sample } from "./code-samples";

// ---------------------------------------------------------------------------
// Field-name + literal helpers
// ---------------------------------------------------------------------------

const lowerFirst = (s: string) => s[0].toLowerCase() + s.slice(1);
const upperFirst = (s: string) => s[0].toUpperCase() + s.slice(1);

const rpcName = (e: ParsedEndpoint) =>
  (e.operationId ?? e.path).split(".").pop() ?? "Call";

const shortType = (t?: string) => t?.split(".").pop() ?? "Empty";

/** Scalar/array/map literal in each language; nested messages get a comment. */
function tsLiteral(v: any): string {
  return JSON.stringify(v);
}

function goLiteral(v: any): string {
  if (typeof v === "string") return JSON.stringify(v);
  if (typeof v === "boolean" || typeof v === "number") return String(v);
  if (Array.isArray(v)) return `[]string{${v.map(goLiteral).join(", ")}}`;
  if (v && typeof v === "object")
    return `map[string]string{${Object.entries(v)
      .map(([k, x]) => `${JSON.stringify(k)}: ${JSON.stringify(x)}`)
      .join(", ")}}`;
  return "nil";
}

function swiftLiteral(v: any): string {
  if (typeof v === "string") return JSON.stringify(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return String(v);
  if (Array.isArray(v)) return `[${v.map(swiftLiteral).join(", ")}]`;
  if (v && typeof v === "object")
    return `[${Object.entries(v)
      .map(([k, x]) => `${JSON.stringify(k)}: ${swiftLiteral(x)}`)
      .join(", ")}]`;
  return "nil";
}

/** Fields worth inlining — skip nested-message values that need builders. */
function scalarFields(body: any): [string, any][] {
  return Object.entries<any>(body ?? {}).filter(
    ([, v]) =>
      v === null ||
      ["string", "boolean", "number"].includes(typeof v) ||
      (Array.isArray(v) && v.every((x) => typeof x !== "object" || x === null)) ||
      (v && typeof v === "object" && !Array.isArray(v) &&
        Object.values(v).every((x) => ["string", "boolean", "number"].includes(typeof x))),
  );
}

// ---------------------------------------------------------------------------
// Swift facade — MicropodClient method names differ from RPC names.
// arg: "none" = no request value, "msg" = .with { } message, "ref" = ContainerRef.
// ---------------------------------------------------------------------------

const SWIFT_FACADE: Record<string, { m: string; arg: "none" | "msg" | "ref" }> = {
  GetSystem: { m: "system", arg: "none" },
  GetStats: { m: "stats", arg: "none" },
  ListContainers: { m: "listContainers", arg: "none" },
  RunContainer: { m: "run", arg: "msg" },
  CreateContainer: { m: "create", arg: "msg" },
  StartContainer: { m: "start", arg: "ref" },
  StopContainer: { m: "stop", arg: "ref" },
  RestartContainer: { m: "restart", arg: "ref" },
  KillContainer: { m: "kill", arg: "ref" },
  DeleteContainer: { m: "delete", arg: "msg" },
  StreamContainerLogs: { m: "streamLogs", arg: "msg" },
  Exec: { m: "exec", arg: "msg" },
  ListImages: { m: "listImages", arg: "none" },
  PullImage: { m: "pullImage", arg: "msg" },
  DeleteImage: { m: "deleteImage", arg: "msg" },
  ListVolumes: { m: "listVolumes", arg: "none" },
  CreateVolume: { m: "createVolume", arg: "msg" },
  DeleteVolume: { m: "deleteVolume", arg: "msg" },
  ListNetworks: { m: "listNetworks", arg: "none" },
  CreateNetwork: { m: "createNetwork", arg: "msg" },
  DeleteNetwork: { m: "deleteNetwork", arg: "msg" },
  GetUsage: { m: "usage", arg: "none" },
  GetVolumePolicy: { m: "volumePolicy", arg: "none" },
  SetVolumePolicy: { m: "setVolumePolicy", arg: "msg" },
  CheckForUpdates: { m: "checkForUpdates", arg: "none" },
  GetUpdateStatus: { m: "updateStatus", arg: "none" },
  ApplyUpdate: { m: "applyUpdate", arg: "none" },
  ComposeUp: { m: "composeUp", arg: "msg" },
  ComposeDown: { m: "composeDown", arg: "msg" },
};

// ---------------------------------------------------------------------------
// Per-language sample builders
// ---------------------------------------------------------------------------

function tsSdkSample(endpoint: ParsedEndpoint, body: any): string {
  const op = lowerFirst(rpcName(endpoint));
  const fields = scalarFields(body)
    .map(([k, v]) => `${k}: ${tsLiteral(v)}`)
    .join(", ");
  const arg = fields ? `{ ${fields} }` : "{}";
  const head = `import { createMicropodClient } from "@micropod/sdk";

const client = createMicropodClient("${REST_BASE_URL}", {
  retry: { maxAttempts: 3 },
  timeoutMs: 10_000,
  otel: true,
});
`;
  if (endpoint.serverStreaming) {
    return `${head}
for await (const event of client.${op}(${arg})) {
  console.log(event);
}`;
  }
  return `${head}
const res = await client.${op}(${arg});`;
}

function goSdkSample(endpoint: ParsedEndpoint, body: any): string {
  const op = rpcName(endpoint);
  const reqType = shortType(endpoint.requestType);
  const fields = scalarFields(body)
    .map(([k, v]) => `\t\t${upperFirst(k)}: ${goLiteral(v)},`)
    .join("\n");
  const req = fields
    ? `&micropodv1.${reqType}{\n${fields}\n\t}`
    : `&micropodv1.${reqType}{}`;
  const head = `import (
	"context"
	"fmt"
	"time"

	"connectrpc.com/connect"
	micropod "github.com/castlemilk/micropod/sdk/go"
	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"log"
)

client := micropod.NewClient("${REST_BASE_URL}",
	micropod.WithRetry(micropod.DefaultRetryPolicy()),
	micropod.WithTimeout(30*time.Second),
	micropod.WithOTel(), // global OTel providers
)
ctx := context.Background()`;
  if (endpoint.serverStreaming) {
    return `${head}

stream, err := client.${op}(ctx, connect.NewRequest(${req}))
if err != nil {
	log.Fatal(err)
}
for stream.Receive() {
	fmt.Println(stream.Msg())
}
if err := stream.Err(); err != nil {
	log.Fatal(err)
}`;
  }
  const ret = endpoint.responseType === "micropod.v1.Empty" ? "_" : "resp";
  return `${head}

${ret}, err := client.${op}(ctx, connect.NewRequest(${req}))
if err != nil {
	log.Fatal(err)
}${ret === "resp" ? "\nfmt.Println(resp.Msg)" : ""}`;
}

function swiftSdkSample(endpoint: ParsedEndpoint, body: any): string {
  const op = rpcName(endpoint);
  const facade = SWIFT_FACADE[op];
  if (!facade) return "";
  const reqType = `Micropod_V1_${shortType(endpoint.requestType)}`;
  const head = `import MicropodSDK

let client = MicropodClient(baseURL: URL(string: "${REST_BASE_URL}")!)`;

  let call: string;
  if (facade.arg === "none") {
    call = `client.${facade.m}()`;
  } else {
    const fields = scalarFields(body)
      .map(([k, v]) => `$0.${k} = ${swiftLiteral(v)}`)
      .join("; ");
    call = fields
      ? `client.${facade.m}(.with { ${fields} })`
      : `client.${facade.m}(${reqType}())`;
  }

  if (endpoint.serverStreaming) {
    return `${head}

for try await event in ${call} {
    print(event)
}`;
  }
  const returns = endpoint.responseType !== "micropod.v1.Empty";
  return `${head}

${returns ? `let res = try await ${call}` : `try await ${call}`}`;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * SDK samples for a Connect endpoint — TypeScript, Go, Swift typed clients.
 * Empty for SandboxContext (the SDKs only cover MicropodService).
 */
export function connectSdkSamples(endpoint: ParsedEndpoint): Sample[] {
  if (!endpoint.service.startsWith("micropod.")) return [];
  const body = requestExampleFor(endpoint);
  return [
    { label: "TypeScript", lang: "typescript", icon: "typescript", code: tsSdkSample(endpoint, body) },
    { label: "Go", lang: "go", icon: "go", code: goSdkSample(endpoint, body) },
    { label: "Swift", lang: "swift", icon: "swift", code: swiftSdkSample(endpoint, body) },
  ].filter((s) => s.code);
}

/** Per-RPC call spellings across the three SDKs — drives the /sdk call map. */
export function sdkCallMap(): {
  rpc: string;
  ts: string;
  go: string;
  swift: string;
  streaming: boolean;
}[] {
  const svc = loadConnectServices().find((s) => s.service.startsWith("micropod."));
  if (!svc) return [];
  return svc.spec.endpoints.map((e) => {
    const rpc = rpcName(e);
    const facade = SWIFT_FACADE[rpc];
    return {
      rpc,
      ts: `client.${lowerFirst(rpc)}(…)`,
      go: `client.${rpc}(ctx, req)`,
      swift: facade ? `client.${facade.m}(…)` : `—`,
      streaming: e.serverStreaming ?? false,
    };
  });
}

/** REST route → the Connect RPC it delegates to (empty = REST-only surface). */
const REST_TO_RPC: Record<string, string> = {
  "get-v1-containers": "ListContainers",
  "post-v1-containers": "RunContainer",
  "post-v1-containers-create": "CreateContainer",
  "post-v1-containers-id-start": "StartContainer",
  "post-v1-containers-id-stop": "StopContainer",
  "post-v1-containers-id-restart": "RestartContainer",
  "post-v1-containers-id-kill": "KillContainer",
  "delete-v1-containers-id": "DeleteContainer",
  "get-v1-containers-id-logs": "StreamContainerLogs",
  "post-v1-exec": "Exec",
  "get-v1-images": "ListImages",
  "post-v1-images-pull": "PullImage",
  "delete-v1-images-ref": "DeleteImage",
  "get-v1-volumes": "ListVolumes",
  "post-v1-volumes": "CreateVolume",
  "delete-v1-volumes-name": "DeleteVolume",
  "get-v1-networks": "ListNetworks",
  "post-v1-networks": "CreateNetwork",
  "delete-v1-networks-name": "DeleteNetwork",
  "get-v1-system": "GetSystem",
  "get-v1-stats": "GetStats",
  "get-v1-usage": "GetUsage",
  "get-v1-config-volumes": "GetVolumePolicy",
  "put-v1-config-volumes": "SetVolumePolicy",
  "post-v1-system-update": "CheckForUpdates",
  "get-v1-system-update": "GetUpdateStatus",
  "post-v1-system-update-apply": "ApplyUpdate",
  "post-v1-compose-up": "ComposeUp",
  "post-v1-compose-down": "ComposeDown",
};

/** The Connect endpoint backing a legacy REST route; undefined for
 * REST-only infra routes (health, metrics, vsock bridge). Used by the
 * /rest/* redirect stubs. */
export function restRpcEndpoint(route: RestRoute): ParsedEndpoint | undefined {
  const rpc = REST_TO_RPC[route.id];
  if (!rpc) return undefined;
  return loadConnectServices()
    .flatMap((s) => s.spec.endpoints)
    .find((e) => e.operationId?.endsWith(`.${rpc}`));
}
