"use client";

import React, { useEffect, useRef, useState } from "react";
import { Check, ChevronDown, Copy, Play } from "lucide-react";
import { CodeBlock } from "./code-block";
import { JsonView } from "./json-view";
import { LangIcon } from "./lang-icons";
import { PayloadExplorer } from "./payload-explorer";
import type { Sample } from "@/lib/code-samples";
import { cn } from "@/lib/utils";

const TRY_IT = "__tryit";

export interface ResponseOption {
  status: string;
  label?: string;
  /** JSON Schema for the body — enables the field explorer. */
  schema?: any;
  body?: any;
  raw?: string;
  note?: string;
}

interface RequestPanelProps {
  /** Raw-HTTP samples (cURL, fetch, requests, net/http, URLSession). */
  samples: Sample[];
  /** Typed-client samples (TypeScript/Go/Swift SDKs) — shown first. */
  sdkSamples?: Sample[];
  /** Request line shown in the card header, e.g. "POST /v1/containers". */
  heading?: string;
  /** Full copyable request target, e.g. "POST http://localhost:45454/v1/containers". */
  url?: string;
  responses?: ResponseOption[];
  /** Live "Try it" tab content — rendered above the language samples. */
  playground?: React.ReactNode;
}

const METHOD_COLOR: Record<string, string> = {
  GET: "text-success",
  POST: "text-primary",
  PUT: "text-warn",
  DELETE: "text-destructive",
  PATCH: "text-warn",
};

function statusBadgeClass(status: string): string {
  return status.startsWith("2")
    ? "bg-success/15 text-success"
    : status.startsWith("5") || status.startsWith("4")
      ? "bg-destructive/15 text-destructive"
      : "bg-warn/15 text-warn";
}

export function ResponsePicker({
  responses,
  index,
  onChange,
}: {
  responses: ResponseOption[];
  index: number;
  onChange: (i: number) => void;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const current = responses[index];

  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [open]);

  if (responses.length === 1) {
    return (
      <span
        className={cn(
          "rounded px-1.5 py-0.5 font-mono text-[10px] font-bold",
          statusBadgeClass(current.status),
        )}
      >
        {current.status}
      </span>
    );
  }

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        aria-label="Response status"
        className={cn(
          "flex items-center gap-1.5 rounded py-0.5 pl-1.5 pr-1.5 font-mono text-[10px] font-bold",
          statusBadgeClass(current.status),
        )}
      >
        {current.status}
        {current.label && (
          <span className="font-sans font-medium normal-case">{current.label}</span>
        )}
        <ChevronDown className="h-3 w-3 opacity-70" />
      </button>
      {open && (
        <div className="absolute left-0 top-full z-30 mt-1 w-64 overflow-hidden rounded-md border border-border bg-card shadow-lg">
          {responses.map((r, i) => (
            <button
              key={i}
              onClick={() => {
                onChange(i);
                setOpen(false);
              }}
              className={cn(
                "flex w-full items-center gap-2 px-3 py-2 text-left transition-colors hover:bg-secondary/70",
                i === index && "bg-secondary/40",
              )}
            >
              <span
                className={cn(
                  "rounded px-1.5 py-0.5 font-mono text-[10px] font-bold",
                  statusBadgeClass(r.status),
                )}
              >
                {r.status}
              </span>
              <span className="truncate text-[11.5px] text-foreground">
                {r.label ?? "Response"}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export function RequestPanel({ samples, sdkSamples, heading, url, responses, playground }: RequestPanelProps) {
  // One flat tab strip: typed SDK calls first (recommended path), then the
  // raw-HTTP mechanisms hitting the same endpoint.
  const allSamples = [...(sdkSamples ?? []), ...samples];
  const [active, setActive] = useState(playground ? TRY_IT : (allSamples[0]?.label ?? ""));
  const [respIdx, setRespIdx] = useState(0);
  const [copied, setCopied] = useState(false);
  const current = allSamples.find((s) => s.label === active) ?? allSamples[0];
  const response = responses?.[respIdx];

  const copyUrl = async () => {
    if (!url) return;
    await navigator.clipboard.writeText(url);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="flex h-full flex-col border-l border-border bg-card/50">
      {/* Request card header — METHOD path, copyable */}
      {heading && (
        <div className="flex items-center gap-2 border-b border-border px-4 py-3">
          <span
            className={cn(
              "rounded px-1.5 py-0.5 font-mono text-[10px] font-bold",
              "bg-secondary",
              METHOD_COLOR[heading.split(" ")[0]] ?? "text-foreground",
            )}
          >
            {heading.split(" ")[0]}
          </span>
          <span className="min-w-0 flex-1 truncate font-mono text-[11.5px] text-muted">
            {heading.slice(heading.indexOf(" ") + 1)}
          </span>
          {url && (
            <button
              onClick={copyUrl}
              aria-label="Copy request URL"
              className="shrink-0 rounded p-1 text-muted transition-colors hover:text-foreground"
            >
              {copied ? <Check className="h-3.5 w-3.5 text-success" /> : <Copy className="h-3.5 w-3.5" />}
            </button>
          )}
        </div>
      )}

      {/* Tab strip — Try it + SDK calls + raw-HTTP mechanisms */}
      <div className="flex items-center border-b border-border">
        <div className="flex min-w-0 flex-1 items-center gap-0.5 overflow-x-auto px-2">
          {playground && (
            <button
              onClick={() => setActive(TRY_IT)}
              className={cn(
                "flex items-center gap-1 whitespace-nowrap border-b-2 border-transparent px-2.5 py-2 text-[11px] font-semibold",
                active === TRY_IT
                  ? "border-primary text-foreground"
                  : "text-muted hover:text-foreground",
              )}
            >
              <Play className="h-2.5 w-2.5" />
              Try it
            </button>
          )}
          {allSamples.map((s) => (
            <button
              key={s.label}
              onClick={() => setActive(s.label)}
              className={cn(
                "flex items-center gap-1.5 whitespace-nowrap border-b-2 border-transparent px-2.5 py-2 text-[11px] font-medium",
                active === s.label
                  ? "border-primary text-foreground"
                  : "text-muted hover:text-foreground",
              )}
            >
              <LangIcon icon={s.icon} className="h-3 w-3" />
              {s.label}
            </button>
          ))}
        </div>
      </div>

      {/* Body */}
      <div className="min-h-0 flex-1 overflow-auto">
        {active === TRY_IT ? (
          playground
        ) : (
          current && <CodeBlock code={current.code} language={current.lang} />
        )}
      </div>

      {/* Try-it CTA on code tabs — flips into the playground */}
      {playground && active !== TRY_IT && (
        <div className="border-t border-border p-3">
          <button
            onClick={() => setActive(TRY_IT)}
            className="flex w-full items-center justify-center gap-1.5 rounded-md bg-success py-2 text-[12px] font-semibold text-black transition-opacity hover:opacity-90"
          >
            <Play className="h-3 w-3" /> Try it
          </button>
        </div>
      )}

      {/* Example response card with status selector */}
      {responses && responses.length > 0 && (
        <div className="max-h-[45%] shrink-0 overflow-auto border-t border-border">
          <div className="flex items-center gap-2 border-b border-border/60 px-4 py-2">
            <ResponsePicker responses={responses} index={respIdx} onChange={setRespIdx} />
            <span className="text-[11px] font-medium text-muted">Response</span>
          </div>
          {response?.note && (
            <p className="px-4 pt-2 font-mono text-[11px] text-warn/90">{response.note}</p>
          )}
          {response?.raw ? (
            <pre className="overflow-auto p-4 font-mono text-[12px] leading-relaxed text-muted">
              {response.raw}
            </pre>
          ) : response?.schema ? (
            <PayloadExplorer schema={response.schema} example={response.body} bare />
          ) : response?.body !== undefined ? (
            <JsonView value={response.body} />
          ) : (
            <p className="px-4 py-3 text-[11px] text-muted">{response?.label ?? "No body."}</p>
          )}
        </div>
      )}
    </div>
  );
}
