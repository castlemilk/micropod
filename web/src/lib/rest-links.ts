/* eslint-disable @typescript-eslint/no-explicit-any */

// REST routes are thin handlers in APIHandlers.swift, not OpenAPI-described —
// this table gives each route its real request/response shape so the explorer
// can show payloads instead of `{}`. Where a route delegates to a Connect RPC
// verbatim we reuse that schema; REST-specific projections are curated here
// (kept in sync with the `projection`/`policyBody` helpers in APIHandlers.swift).

import type { RestRoute } from "./types";

export interface RouteResponse {
  status: string;
  description: string;
  example?: any;
  stream?: string; // e.g. "text/event-stream of LogChunk lines"
}

export interface RouteShape {
  /** JSON Schema for the request body (drives the field explorer). */
  requestSchema?: any;
  /** Literal example body (used when no schema applies). */
  requestExample?: any;
  query?: { name: string; description: string; required?: boolean }[];
  responses: RouteResponse[];
}

const CONTAINER_PROJECTION = {
  id: "9f2e4a1b3c7d",
  state: "running",
  image: "alpine:3.20",
  createdAt: "2026-09-24T04:02:11.044Z",
  ipv4Address: "192.168.64.3",
  networks: ["micropod0"],
  env: ["NGINX_PORT=80"],
  labels: { "com.micropod.workload": "demo" },
  platform: "linux/arm64",
  readOnly: false,
  useInit: true,
};

const RUN_CONTAINER_SCHEMA = {
  type: "object",
  title: "RunContainerRequest",
  properties: {
    image: { type: "string", description: "Image reference to run (docker pull if absent)." },
    name: { type: ["string", "null"], description: "Optional container name." },
    detach: { type: "boolean", description: "Return immediately instead of streaming." },
    cpus: { type: ["number", "null"], format: "double", description: "CPU limit, e.g. 0.5." },
    memory: { type: ["string", "null"], description: "Memory limit, e.g. \"512m\"." },
    env: { type: "array", items: { type: "string" }, description: "KEY=value pairs." },
    ports: {
      type: "array",
      items: {
        type: "object",
        title: "PortSpec",
        properties: {
          hostPort: { type: "integer" },
          containerPort: { type: "integer" },
          protocol: { type: "string" },
          hostIP: { type: ["string", "null"] },
        },
      },
      description: "Published port mappings.",
    },
    volumes: { type: "array", items: { type: "string" }, description: "name-or-path:/mount specs." },
    labels: {
      type: "object",
      additionalProperties: { type: "string" },
      description: "Arbitrary metadata labels.",
    },
    init: { type: "boolean", description: "Run an init process as PID 1." },
    arguments: { type: "array", items: { type: "string" }, description: "Command + args override." },
  },
  required: ["image"],
};

const RUN_REQUEST_EXAMPLE = {
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
};

const IMAGE_PROJECTION = {
  id: "sha256:1d34ff…",
  names: ["alpine:3.20", "alpine:latest"],
  createdAt: "2026-09-20T11:40:02Z",
  digest: "sha256:1d34ffeaf190be23c96c9f3d4c2a1e8c1e2b8f6d4a3c2e1b0f9e8d7c6b5a4938",
  sizeBytes: "7834211",
};

const VOLUME_PROJECTION = {
  id: "web-data",
  driver: "local",
  format: "ext4",
  sizeBytes: "10737418240",
  source: "web-data",
  createdAt: "2026-09-22T09:15:00Z",
  labels: { "com.micropod.cache.clone": "true" },
};

const NETWORK_PROJECTION = {
  id: "frontend",
  plugin: "vmnet",
  mode: "nat",
  ipv4Gateway: "192.168.64.1",
  ipv4Subnet: "192.168.64.0/24",
  ipv6Subnet: "fd64:a1b2:c3d4::/64",
  createdAt: "2026-09-21T08:00:00Z",
  builtin: false,
  labels: {},
};

const POLICY_BODY = {
  cloneMode: "labels",
  goldenVolumes: ["xcode-cache"],
  jobsOnly: false,
  cache: "auto",
  labels: {
    clone: "com.micropod.cache.clone",
    sync: "com.micropod.volume.sync",
    cache: "com.micropod.volume.cache",
  },
  sync: "fsync",
};

const POLICY_SCHEMA = {
  type: "object",
  title: "VolumePolicy",
  properties: {
    cloneMode: {
      type: "string",
      enum: ["labels", "goldens", "all"],
      description: "Which volumes get copy-on-write clones.",
    },
    goldenVolumes: {
      type: "array",
      items: { type: "string" },
      description: "Named volumes always cloned (with cloneMode=goldens|all).",
    },
    jobsOnly: { type: "boolean", description: "Restrict sharing to job workloads." },
    sync: {
      type: ["string", "null"],
      enum: ["full", "fsync", "nosync", null],
      description: "Sync mode for shared volumes (null = default).",
    },
    cache: {
      type: "string",
      enum: ["on", "off", "auto"],
      description: "Mount-cache behavior for shared volumes.",
    },
  },
};

const SHAPES: Record<string, RouteShape> = {
  "get-health": {
    responses: [{ status: "200", description: "Liveness probe", example: { status: "ok" } }],
  },
  "get-metrics": {
    responses: [
      {
        status: "200",
        description: "Prometheus metrics",
        stream: "text/plain; version=0.0.4 — Prometheus exposition format",
      },
    ],
  },
  "get-v1-usage": {
    responses: [
      {
        status: "200",
        description: "Disk usage report",
        example: {
          images: [
            {
              id: "sha256:1d34ff…",
              names: ["alpine:3.20"],
              sizeBytes: "7834211",
              createdAt: "2026-09-20T11:40:02Z",
              usedByContainerIDs: ["9f2e4a1b3c7d"],
              inUse: true,
            },
          ],
          volumes: [
            {
              id: "web-data",
              sizeBytes: "10737418240",
              createdAt: "2026-09-22T09:15:00Z",
              usedByContainerIDs: ["9f2e4a1b3c7d"],
              inUse: true,
            },
          ],
          reclaimableImageBytes: "536870912",
          reclaimableVolumeBytes: "0",
          stoppedContainerCount: 2,
        },
      },
    ],
  },
  "get-v1-system": {
    responses: [
      {
        status: "200",
        description: "Runtime + disk status",
        example: {
          status: "running",
          cliVersion: "1.3.1",
          apiServerVersion: "1.3.1",
          appRoot: "/Applications/Micropod.app",
          backend: "native",
          runtimeVersion: "1.3.1",
          runtimeCommit: "e9a62e2",
          diskUsage: {
            containers: { total: "7834211", active: "7834211", sizeBytes: "7834211", reclaimableBytes: "0" },
            images: { total: "21474836480", active: "16106127360", sizeBytes: "21474836480", reclaimableBytes: "5368709120" },
            volumes: { total: "10737418240", active: "10737418240", sizeBytes: "10737418240", reclaimableBytes: "0" },
            totalReclaimableBytes: "5368709120",
          },
        },
      },
    ],
  },
  "post-v1-system-update": {
    responses: [
      {
        status: "202",
        description: "Update check started",
        example: { state: "checking", version: "0.7.0" },
      },
      { status: "503", description: "App not running", example: { error: "Micropod app is not running (no control socket)" } },
    ],
  },
  "get-v1-system-update": {
    responses: [
      {
        status: "200",
        description: "Update status",
        example: { state: "idle", lastChecked: "2026-09-24T04:00:00Z" },
      },
      { status: "503", description: "App not running", example: { error: "Micropod app is not running (no control socket)" } },
    ],
  },
  "post-v1-system-update-apply": {
    responses: [
      { status: "202", description: "Update applied", example: { state: "installing", version: "0.7.0" } },
      { status: "409", description: "Update refused", example: { error: "no update available" } },
      { status: "503", description: "App not running", example: { error: "Micropod app is not running (no control socket)" } },
    ],
  },
  "get-v1-containers": {
    responses: [
      { status: "200", description: "Container list", example: { containers: [CONTAINER_PROJECTION] } },
    ],
  },
  "post-v1-containers": {
    requestSchema: RUN_CONTAINER_SCHEMA,
    requestExample: RUN_REQUEST_EXAMPLE,
    responses: [
      { status: "201", description: "Created and started", example: { id: "9f2e4a1b3c7d" } },
      { status: "500", description: "Runtime error", example: { error: "image not found: alpine:3.20" } },
    ],
  },
  "post-v1-containers-create": {
    requestSchema: RUN_CONTAINER_SCHEMA,
    requestExample: RUN_REQUEST_EXAMPLE,
    responses: [
      { status: "201", description: "Created (not started)", example: { id: "9f2e4a1b3c7d" } },
    ],
  },
  "post-v1-containers-id-start": actionShape("start"),
  "post-v1-containers-id-stop": actionShape("stop"),
  "post-v1-containers-id-restart": actionShape("restart"),
  "post-v1-containers-id-kill": actionShape("kill"),
  "delete-v1-containers-id": {
    query: [{ name: "force", description: "Force-remove a running container" }],
    responses: [{ status: "200", description: "Deleted", example: { deleted: "9f2e4a1b3c7d" } }],
  },
  "get-v1-containers-id-logs": {
    query: [
      { name: "tail", description: "Lines from the end of the log (default 100)" },
      { name: "boot", description: "Include vminitd boot log" },
    ],
    responses: [
      {
        status: "200",
        description: "Log stream",
        stream: "text/event-stream — one SSE `data:` event per log line",
        example: "data: server listening on :8080\\n\n\ndata: GET /health 200\\n\n\n",
      },
    ],
  },
  "get-v1-containers-id-vsock-port": {
    responses: [
      {
        status: "200",
        description: "Duplex byte stream",
        stream: "raw bytes — speak gRPC to vminitd on :1024 after the 200 head",
      },
      { status: "501", description: "Native backend required", example: { error: "vsock bridge requires the native runtime backend" } },
      { status: "400", description: "Bad port", example: { error: "invalid vsock port 'x'" } },
    ],
  },
  "get-v1-images": {
    responses: [{ status: "200", description: "Image list", example: { images: [IMAGE_PROJECTION] } }],
  },
  "post-v1-images-pull": {
    requestSchema: {
      type: "object",
      properties: { reference: { type: "string", description: "Image reference to pull." } },
      required: ["reference"],
    },
    requestExample: { reference: "alpine:3.20" },
    responses: [
      { status: "200", description: "Pulled", example: { pulled: "alpine:3.20", lastLine: "done" } },
      { status: "400", description: "Missing reference", example: { error: "reference is required" } },
    ],
  },
  "delete-v1-images-ref": {
    query: [{ name: "force", description: "Remove even if in use" }],
    responses: [{ status: "200", description: "Deleted", example: { deleted: "alpine:3.20" } }],
  },
  "get-v1-volumes": {
    responses: [{ status: "200", description: "Volume list", example: { volumes: [VOLUME_PROJECTION] } }],
  },
  "post-v1-volumes": {
    requestSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Volume name." },
        size: { type: ["string", "null"], description: "Optional size, e.g. \"10g\"." },
      },
      required: ["name"],
    },
    requestExample: { name: "web-data", size: "10g" },
    responses: [
      { status: "201", description: "Created", example: { name: "web-data" } },
      { status: "400", description: "Missing name", example: { error: "name is required" } },
    ],
  },
  "delete-v1-volumes-name": {
    responses: [{ status: "200", description: "Deleted", example: { deleted: "web-data" } }],
  },
  "get-v1-config-volumes": {
    responses: [{ status: "200", description: "Current volume policy", example: POLICY_BODY }],
  },
  "put-v1-config-volumes": {
    requestSchema: POLICY_SCHEMA,
    requestExample: { cloneMode: "goldens", goldenVolumes: ["xcode-cache", "node-modules"], jobsOnly: false, cache: "auto" },
    responses: [
      { status: "200", description: "Saved policy", example: POLICY_BODY },
      { status: "400", description: "Invalid policy", example: { error: "invalid policy — expected {cloneMode: labels|goldens|all, …}" } },
    ],
  },
  "get-v1-networks": {
    responses: [{ status: "200", description: "Network list", example: { networks: [NETWORK_PROJECTION] } }],
  },
  "post-v1-networks": {
    requestSchema: {
      type: "object",
      properties: {
        name: { type: "string" },
        internal: { type: "boolean" },
        subnet: { type: ["string", "null"], description: "IPv4 CIDR, e.g. 192.168.100.0/24" },
      },
      required: ["name"],
    },
    requestExample: { name: "frontend", internal: false, subnet: "192.168.100.0/24" },
    responses: [
      { status: "201", description: "Created", example: { name: "frontend" } },
      { status: "400", description: "Missing name", example: { error: "name is required" } },
    ],
  },
  "delete-v1-networks-name": {
    responses: [{ status: "200", description: "Deleted", example: { deleted: "frontend" } }],
  },
  "get-v1-stats": {
    responses: [
      {
        status: "200",
        description: "Resource snapshot",
        example: {
          containers: [
            {
              id: "9f2e4a1b3c7d",
              cpuPercent: 0.8,
              memoryUsedBytes: "71303168",
              memoryLimitBytes: "4294967296",
              networkRxBytes: "1887436",
              networkTxBytes: "917504",
              blockReadBytes: "4096",
              blockWriteBytes: "1048576",
              pids: "14",
            },
          ],
          sampledAt: "2026-09-24T04:12:37.201Z",
        },
      },
    ],
  },
  "post-v1-compose-up": {
    requestSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to a docker-compose.yml on the host." },
        profiles: { type: ["string", "null"], description: "Comma-separated profiles to enable." },
      },
      required: ["path"],
    },
    requestExample: { path: "/tmp/docker-compose.yml", profiles: "debug" },
    responses: [
      {
        status: "200",
        description: "Stack started",
        example: { name: "demo", progress: ["pulled alpine:3.20", "created web", "started web"] },
      },
      { status: "400", description: "Missing path", example: { error: "path is required" } },
    ],
  },
  "post-v1-compose-down": {
    requestSchema: {
      type: "object",
      properties: { name: { type: "string", description: "Compose project name." } },
      required: ["name"],
    },
    requestExample: { name: "demo" },
    responses: [
      { status: "200", description: "Stack torn down", example: { toreDown: "demo" } },
      { status: "400", description: "Missing name", example: { error: "name is required" } },
    ],
  },
  "post-v1-exec": {
    requestSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Container ID." },
        command: { type: "string", description: "Command to run inside the container." },
        workdir: { type: ["string", "null"], description: "Working directory." },
      },
      required: ["id", "command"],
    },
    requestExample: { id: "9f2e4a1b3c7d", command: "cat /etc/os-release", workdir: "/" },
    responses: [
      {
        status: "200",
        description: "Command result",
        example: { output: "NAME=\"Alpine Linux\"\nID=alpine\nVERSION_ID=3.20.3\n", error: "", exitCode: 0 },
      },
      { status: "400", description: "Missing fields", example: { error: "id and command are required" } },
    ],
  },
};

function actionShape(action: string): RouteShape {
  return {
    responses: [
      { status: "200", description: `Container ${action}ed`, example: { id: "9f2e4a1b3c7d", action } },
      { status: "500", description: "Runtime error", example: { error: "container not running" } },
    ],
  };
}

export function restShape(route: RestRoute): RouteShape | undefined {
  return SHAPES[route.id];
}
