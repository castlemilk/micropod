/* eslint-disable @typescript-eslint/no-explicit-any */

// Playground plumbing — schema → form model, request building, and the
// fetch layer (unary JSON, Connect envelope streams, SSE).

import { primaryType, isNullable, isInt64, exampleForSchema } from "./examples";

// ---------------------------------------------------------------------------
// Field model — one editable row per schema property
// ---------------------------------------------------------------------------

export type FieldKind = "string" | "number" | "boolean" | "enum" | "json";

export interface FieldDef {
  name: string;
  kind: FieldKind;
  required: boolean;
  nullable: boolean;
  description?: string;
  typeLabel: string;
  enumValues?: string[];
  /** Seed value — exampleForSchema output, JSON-stringified for json kind. */
  seed: any;
}

export function fieldsForSchema(schema: any): FieldDef[] {
  const props = schema?.properties;
  if (!props || typeof props !== "object") return [];
  const required = new Set<string>(schema.required ?? []);
  return Object.entries<any>(props).map(([name, prop]) => {
    const seed = exampleForSchema(prop, name);
    const type = primaryType(prop);
    let kind: FieldKind = "string";
    let enumValues: string[] | undefined;
    if (prop.enum?.length) {
      kind = "enum";
      enumValues = prop.enum.filter((v: any) => v !== null).map(String);
    } else if (type === "boolean") {
      kind = "boolean";
    } else if (type === "integer" || type === "number") {
      kind = "number";
    } else if (type === "array" || type === "object" || prop.items || prop.additionalProperties) {
      kind = "json";
    }
    return {
      name,
      kind,
      required: required.has(name),
      nullable: isNullable(prop),
      description: prop.description,
      typeLabel: labelFor(prop),
      enumValues,
      seed,
    };
  });
}

function labelFor(prop: any): string {
  if (isInt64(prop)) return "int64";
  const t = primaryType(prop);
  if (t === "array" || prop.items) return "array";
  if (prop.additionalProperties) return "map";
  if (t === "object") return "object";
  return t ?? "any";
}

// ---------------------------------------------------------------------------
// Request assembly
// ---------------------------------------------------------------------------

export interface FieldState {
  /** Included in the request. Required fields are always on. */
  on: boolean;
  /** Raw editor value — string for text/enum/json, boolean for checkbox. */
  value: string | boolean;
}

export function initialState(fields: FieldDef[]): Record<string, FieldState> {
  const out: Record<string, FieldState> = {};
  for (const f of fields) {
    const seeded = f.seed !== undefined && f.seed !== null;
    out[f.name] = {
      on: f.required || seeded,
      value:
        f.kind === "boolean"
          ? Boolean(f.seed)
          : f.kind === "json"
            ? JSON.stringify(f.seed ?? (f.typeLabel === "array" ? [] : {}), null, 1)
            : f.seed === undefined || f.seed === null
              ? ""
              : String(f.seed),
    };
  }
  return out;
}

/** FieldState → request body. Empty optional strings are omitted; invalid
 * JSON leaves collect into `errors`. */
export function buildBody(
  fields: FieldDef[],
  state: Record<string, FieldState>,
): { body: Record<string, any>; errors: string[] } {
  const body: Record<string, any> = {};
  const errors: string[] = [];
  for (const f of fields) {
    const s = state[f.name];
    if (!s || !s.on) continue;
    switch (f.kind) {
      case "boolean":
        body[f.name] = Boolean(s.value);
        break;
      case "number": {
        const n = Number(s.value);
        if (s.value === "" && !f.required) break;
        if (Number.isNaN(n)) {
          errors.push(`${f.name}: not a number`);
        } else {
          body[f.name] = n;
        }
        break;
      }
      case "json": {
        const raw = String(s.value).trim();
        if (!raw) {
          if (!f.required) break;
        }
        try {
          body[f.name] = raw ? JSON.parse(raw) : null;
        } catch {
          errors.push(`${f.name}: invalid JSON`);
        }
        break;
      }
      default: {
        const v = String(s.value);
        if (v === "" && !f.required && f.nullable) break;
        if (v === "" && !f.required) break;
        body[f.name] = v;
      }
    }
  }
  return { body, errors };
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

export interface PlaygroundResult {
  ok: boolean;
  status: number;
  statusText: string;
  elapsedMs: number;
  headers: [string, string][];
  /** Decoded JSON body, raw text, or streamed frames. */
  body?: any;
  text?: string;
  frames?: any[];
  error?: string;
}

export async function sendRequest(opts: {
  baseUrl: string;
  method: string;
  path: string;
  query?: Record<string, string>;
  body?: any;
  /** "connect-stream" frames the body and parses envelopes; "sse" reads the
   * response as a text stream. */
  stream?: "connect" | "sse" | null;
  authToken?: string;
  signal?: AbortSignal;
  onFrame?: (frame: any) => void;
}): Promise<PlaygroundResult> {
  const url = new URL(opts.path, opts.baseUrl.endsWith("/") ? opts.baseUrl : opts.baseUrl + "/");
  for (const [k, v] of Object.entries(opts.query ?? {})) {
    if (v !== "") url.searchParams.set(k, v);
  }

  const headers: Record<string, string> = {};
  if (opts.body !== undefined || opts.stream === "connect") {
    headers["Content-Type"] =
      opts.stream === "connect" ? "application/connect+json" : "application/json";
  }
  if (opts.stream === "connect") headers["Connect-Protocol-Version"] = "1";
  if (opts.authToken) headers["Authorization"] = `Bearer ${opts.authToken}`;

  let bodyPayload: BodyInit | undefined;
  if (opts.stream === "connect") {
    const json = new TextEncoder().encode(JSON.stringify(opts.body ?? {}));
    const frame = new Uint8Array(5 + json.length);
    new DataView(frame.buffer).setUint32(1, json.length);
    frame.set(json, 5);
    bodyPayload = frame;
  } else if (opts.body !== undefined) {
    bodyPayload = JSON.stringify(opts.body);
  }

  const started = performance.now();
  let res: Response;
  try {
    res = await fetch(url, {
      method: opts.method,
      headers,
      body: bodyPayload,
      signal: opts.signal,
    });
  } catch (e: any) {
    return {
      ok: false,
      status: 0,
      statusText: "unreachable",
      elapsedMs: performance.now() - started,
      headers: [],
      error:
        e?.name === "AbortError"
          ? "request aborted"
          : `Could not reach ${opts.baseUrl} — is the Micropod daemon running?`,
    };
  }
  const elapsedMs = performance.now() - started;
  const respHeaders: [string, string][] = [];
  res.headers.forEach((v, k) => respHeaders.push([k, v]));

  const contentType = res.headers.get("content-type") ?? "";

  // Connect server-stream: parse envelope frames incrementally.
  if (opts.stream === "connect" && contentType.includes("connect+json")) {
    const frames: any[] = [];
    let trailer: any = null;
    if (res.body) {
      const reader = res.body.getReader();
      let buf = new Uint8Array(0);
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          const merged = new Uint8Array(buf.length + value.length);
          merged.set(buf);
          merged.set(value, buf.length);
          buf = merged;
          while (buf.length >= 5) {
            const len = new DataView(buf.buffer, buf.byteOffset).getUint32(1);
            if (buf.length < 5 + len) break;
            const flags = buf[0];
            const payload = buf.slice(5, 5 + len);
            buf = buf.slice(5 + len);
            try {
              const msg = JSON.parse(new TextDecoder().decode(payload));
              if (flags & 0x02) trailer = msg;
              else {
                frames.push(msg);
                opts.onFrame?.(msg);
              }
            } catch {
              /* ignore undecodable frame */
            }
          }
        }
      } catch {
        /* aborted mid-stream — return what we have */
      }
    }
    if (trailer?.error) {
      return {
        ok: false,
        status: res.status,
        statusText: trailer.error.code ?? res.statusText,
        elapsedMs,
        headers: respHeaders,
        frames,
        error: trailer.error.message,
      };
    }
    return { ok: res.ok, status: res.status, statusText: res.statusText, elapsedMs, headers: respHeaders, frames };
  }

  // SSE / plain text stream — accumulate raw text, tolerate aborts.
  if (opts.stream === "sse" || contentType.includes("text/event-stream")) {
    let text = "";
    try {
      text = res.body ? await res.text() : "";
    } catch {
      /* aborted mid-stream */
    }
    return { ok: res.ok, status: res.status, statusText: res.statusText, elapsedMs, headers: respHeaders, text };
  }

  let text = "";
  try {
    text = await res.text();
  } catch {
    /* aborted */
  }
  let parsed: any = undefined;
  try {
    parsed = JSON.parse(text);
  } catch {
    /* non-JSON body */
  }
  return {
    ok: res.ok,
    status: res.status,
    statusText: res.statusText,
    elapsedMs,
    headers: respHeaders,
    body: parsed,
    text: parsed === undefined ? text : undefined,
  };
}

/** GET {base}/health — daemon liveness for the environment bar. */
export async function pingDaemon(baseUrl: string, signal?: AbortSignal): Promise<boolean> {
  try {
    const res = await fetch(new URL("/health", baseUrl.endsWith("/") ? baseUrl : baseUrl + "/"), {
      signal,
      cache: "no-store",
    });
    return res.ok;
  } catch {
    return false;
  }
}
