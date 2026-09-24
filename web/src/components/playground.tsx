"use client";

import React, { useCallback, useEffect, useRef, useState } from "react";
import { JsonView } from "./json-view";
import {
  buildBody,
  fieldsForSchema,
  initialState,
  pingDaemon,
  sendRequest,
  type FieldDef,
  type FieldState,
  type PlaygroundResult,
} from "@/lib/playground";
import { cn } from "@/lib/utils";

const BASE_KEY = "micropod.playground.base";
const DEFAULT_BASE = "http://localhost:45454";

export interface PlaygroundProps {
  method: string;
  /** Request path — may contain {param} placeholders. */
  path: string;
  /** Body schema (drives the field editor) or a literal example object. */
  requestSchema?: any;
  requestExample?: any;
  query?: { name: string; description?: string; required?: boolean }[];
  /** "connect" = Connect server-stream envelopes, "sse" = text/event-stream. */
  stream?: "connect" | "sse" | null;
}

export function Playground({ method, path, requestSchema, requestExample, query, stream }: PlaygroundProps) {
  const pathParams = [...path.matchAll(/\{([^}]+)\}/g)].map((m) => m[1]);

  // Body fields: schema-driven when available, else inferred from the example.
  const fields: FieldDef[] =
    requestSchema?.properties
      ? fieldsForSchema(requestSchema)
      : requestExample && typeof requestExample === "object"
        ? fieldsForSchema({
            properties: Object.fromEntries(
              Object.entries(requestExample).map(([k, v]) => [
                k,
                {
                  type: Array.isArray(v) ? "array" : typeof v === "object" && v !== null ? "object" : typeof v,
                },
              ]),
            ),
          })
        : [];

  const [base, setBase] = useState(DEFAULT_BASE);
  const [live, setLive] = useState<boolean | null>(null);
  const [state, setState] = useState<Record<string, FieldState>>(() => initialState(fields));
  const [paramState, setParamState] = useState<Record<string, string>>({});
  const [queryState, setQueryState] = useState<Record<string, string>>({});
  const [result, setResult] = useState<PlaygroundResult | null>(null);
  const [sending, setSending] = useState(false);
  const [errors, setErrors] = useState<string[]>([]);
  const abortRef = useRef<AbortController | null>(null);

  // Persisted base URL + daemon liveness ping.
  useEffect(() => {
    const saved = window.localStorage.getItem(BASE_KEY);
    if (saved) setBase(saved);
  }, []);
  useEffect(() => {
    window.localStorage.setItem(BASE_KEY, base);
    let cancelled = false;
    setLive(null);
    pingDaemon(base).then((ok) => !cancelled && setLive(ok));
    return () => {
      cancelled = true;
    };
  }, [base]);

  const send = useCallback(async () => {
    const { body, errors: errs } = buildBody(fields, state);
    setErrors(errs);
    if (errs.length) return;

    let resolved = path;
    for (const p of pathParams) resolved = resolved.replace(`{${p}}`, encodeURIComponent(paramState[p] ?? ""));

    abortRef.current?.abort();
    const ctl = new AbortController();
    abortRef.current = ctl;
    setSending(true);
    setResult(null);
    const res = await sendRequest({
      baseUrl: base,
      method,
      path: resolved,
      query: queryState,
      body: method === "GET" || method === "DELETE" ? undefined : body,
      stream,
      signal: ctl.signal,
    });
    setResult(res);
    setSending(false);
  }, [base, fields, state, path, pathParams, paramState, queryState, method, stream]);

  return (
    <div className="flex h-full flex-col">
      {/* Environment bar */}
      <div className="border-b border-border px-4 py-2.5">
        <div className="flex items-center gap-2 rounded-md border border-border bg-background px-2.5 py-1.5">
          <span
            className={cn(
              "h-1.5 w-1.5 shrink-0 rounded-full",
              live === null ? "bg-muted" : live ? "bg-success" : "bg-destructive",
            )}
            title={live === null ? "checking…" : live ? "daemon reachable" : "daemon unreachable"}
          />
          <input
            value={base}
            onChange={(e) => setBase(e.target.value)}
            spellCheck={false}
            className="w-full bg-transparent font-mono text-[11.5px] text-foreground outline-none placeholder:text-muted/60"
            placeholder={DEFAULT_BASE}
            aria-label="Daemon base URL"
          />
        </div>
        {live === false && (
          <p className="mt-1.5 text-[10.5px] leading-snug text-warn">
            Can&apos;t reach the daemon — start Micropod, or point at another host.
          </p>
        )}
      </div>

      <div className="min-h-0 flex-1 overflow-auto">
        {/* Path parameters */}
        {pathParams.length > 0 && (
          <Section title="Path parameters">
            {pathParams.map((p) => (
              <Row key={p} name={p} type="string" required>
                <TextInput
                  value={paramState[p] ?? ""}
                  placeholder="9f2e4a1b3c7d"
                  onChange={(v) => setParamState((s) => ({ ...s, [p]: v }))}
                />
              </Row>
            ))}
          </Section>
        )}

        {/* Query parameters */}
        {(query?.length ?? 0) > 0 && (
          <Section title="Query parameters">
            {query!.map((q) => (
              <Row key={q.name} name={q.name} type="string" required={q.required} description={q.description}>
                <TextInput
                  value={queryState[q.name] ?? ""}
                  onChange={(v) => setQueryState((s) => ({ ...s, [q.name]: v }))}
                />
              </Row>
            ))}
          </Section>
        )}

        {/* Body fields */}
        {fields.length > 0 && method !== "GET" && (
          <Section title="Body">
            {fields.map((f) => (
              <FieldRow
                key={f.name}
                field={f}
                state={state[f.name]}
                onChange={(next) => setState((s) => ({ ...s, [f.name]: next }))}
              />
            ))}
          </Section>
        )}

        {errors.length > 0 && (
          <div className="px-4 py-2">
            {errors.map((e) => (
              <p key={e} className="font-mono text-[10.5px] text-destructive">
                {e}
              </p>
            ))}
          </div>
        )}

        {/* Send */}
        <div className="px-4 py-3">
          <button
            onClick={() => void send()}
            disabled={sending}
            className={cn(
              "w-full rounded-md py-2 text-[12px] font-semibold transition-colors",
              sending
                ? "bg-secondary text-muted"
                : "bg-primary text-primary-foreground hover:opacity-90",
            )}
          >
            {sending ? "Sending…" : "Send Request"}
          </button>
          {sending && (
            <button
              onClick={() => abortRef.current?.abort()}
              className="mt-1.5 w-full rounded-md border border-border py-1 text-[11px] text-muted hover:text-foreground"
            >
              Cancel
            </button>
          )}
        </div>

        {/* Live response */}
        {result && (
          <div className="border-t border-border">
            <div className="flex items-center gap-2 border-b border-border/60 px-4 py-2">
              <span
                className={cn(
                  "rounded px-1.5 py-0.5 font-mono text-[10px] font-bold",
                  result.ok ? "bg-success/15 text-success" : "bg-destructive/15 text-destructive",
                )}
              >
                {result.status || "ERR"}
              </span>
              <span className="font-mono text-[10px] text-muted">
                {Math.round(result.elapsedMs)}ms
                {result.frames ? ` · ${result.frames.length} frames` : ""}
              </span>
            </div>
            {result.error && (
              <p className="px-4 py-2 text-[11px] leading-snug text-destructive">{result.error}</p>
            )}
            {result.frames ? (
              <div className="space-y-1.5 p-3">
                {result.frames.map((f, i) => (
                  <div key={i} className="overflow-hidden rounded-md border border-border/60 bg-card/60">
                    <JsonView value={f} />
                  </div>
                ))}
                {result.frames.length === 0 && !result.error && (
                  <p className="px-1 text-[11px] text-muted">Stream ended with no messages.</p>
                )}
              </div>
            ) : result.body !== undefined ? (
              <JsonView value={result.body} />
            ) : result.text ? (
              <pre className="overflow-auto whitespace-pre-wrap p-4 font-mono text-[11.5px] leading-relaxed text-muted">
                {result.text}
              </pre>
            ) : (
              <p className="px-4 py-3 text-[11px] text-muted">Empty response body.</p>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Field rows
// ---------------------------------------------------------------------------

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="border-b border-border/60 px-4 py-3">
      <h4 className="mb-2 text-[10px] font-semibold uppercase tracking-wider text-muted">{title}</h4>
      <div className="space-y-2">{children}</div>
    </div>
  );
}

function Row({
  name,
  type,
  required,
  description,
  on,
  onToggle,
  children,
}: {
  name: string;
  type: string;
  required?: boolean;
  description?: string;
  on?: boolean;
  onToggle?: (on: boolean) => void;
  children: React.ReactNode;
}) {
  return (
    <div className={cn(on === false && "opacity-45")}>
      <div className="flex items-center gap-2">
        {onToggle && (
          <button
            onClick={() => onToggle(!on)}
            aria-label={on ? `omit ${name}` : `include ${name}`}
            className={cn(
              "flex h-3 w-3 shrink-0 items-center justify-center rounded-[3px] border",
              on ? "border-primary bg-primary" : "border-muted/50",
            )}
          >
            {on && (
              <svg viewBox="0 0 10 8" className="h-2 w-2 fill-none stroke-primary-foreground" strokeWidth="1.6">
                <path d="M1 4l2.5 2.5L9 1" />
              </svg>
            )}
          </button>
        )}
        <span className="font-mono text-[11.5px] font-medium">{name}</span>
        <span className="font-mono text-[9.5px] text-primary/70">{type}</span>
        {required && (
          <span className="rounded-sm bg-destructive/15 px-1 font-mono text-[8.5px] font-semibold uppercase leading-4 text-destructive">
            req
          </span>
        )}
      </div>
      <div className="mt-1">{children}</div>
      {description && <p className="mt-0.5 text-[10px] leading-snug text-muted/80">{description}</p>}
    </div>
  );
}

function TextInput({
  value,
  onChange,
  placeholder,
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
}) {
  return (
    <input
      value={value}
      onChange={(e) => onChange(e.target.value)}
      spellCheck={false}
      placeholder={placeholder}
      className="w-full rounded border border-border bg-background px-2 py-1 font-mono text-[11px] outline-none placeholder:text-muted/50 focus:border-primary/50"
    />
  );
}

function FieldRow({
  field,
  state,
  onChange,
}: {
  field: FieldDef;
  state: FieldState;
  onChange: (s: FieldState) => void;
}) {
  const toggle = field.required ? undefined : (on: boolean) => onChange({ ...state, on });

  let editor: React.ReactNode;
  if (field.kind === "boolean") {
    editor = (
      <select
        value={String(state.value)}
        onChange={(e) => onChange({ ...state, value: e.target.value === "true" })}
        className="w-full rounded border border-border bg-background px-2 py-1 font-mono text-[11px] outline-none focus:border-primary/50"
      >
        <option value="true">true</option>
        <option value="false">false</option>
      </select>
    );
  } else if (field.kind === "enum") {
    editor = (
      <select
        value={String(state.value)}
        onChange={(e) => onChange({ ...state, value: e.target.value })}
        className="w-full rounded border border-border bg-background px-2 py-1 font-mono text-[11px] outline-none focus:border-primary/50"
      >
        {field.enumValues!.map((v) => (
          <option key={v} value={v}>
            {v}
          </option>
        ))}
      </select>
    );
  } else if (field.kind === "json") {
    editor = (
      <textarea
        value={String(state.value)}
        onChange={(e) => onChange({ ...state, value: e.target.value })}
        spellCheck={false}
        rows={Math.min(6, String(state.value).split("\n").length + 1)}
        className="w-full resize-y rounded border border-border bg-background px-2 py-1 font-mono text-[10.5px] leading-snug outline-none focus:border-primary/50"
      />
    );
  } else {
    editor = <TextInput value={String(state.value)} onChange={(v) => onChange({ ...state, value: v })} />;
  }

  return (
    <Row
      name={field.name}
      type={field.typeLabel}
      required={field.required}
      description={field.description}
      on={state.on}
      onToggle={toggle}
    >
      {editor}
    </Row>
  );
}
