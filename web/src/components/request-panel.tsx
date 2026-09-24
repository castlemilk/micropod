"use client";

import React, { useState } from "react";
import { Check, ChevronDown, Copy, Play } from "lucide-react";
import { CodeBlock } from "./code-block";
import { JsonView } from "./json-view";
import type { Sample } from "@/lib/code-samples";
import { cn } from "@/lib/utils";

const TRY_IT = "__tryit";

export interface ResponseOption {
  status: string;
  label?: string;
  body?: any;
  raw?: string;
  note?: string;
}

interface RequestPanelProps {
  samples: Sample[];
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

export function RequestPanel({ samples, heading, url, responses, playground }: RequestPanelProps) {
  const [active, setActive] = useState(playground ? TRY_IT : (samples[0]?.label ?? ""));
  const [respIdx, setRespIdx] = useState(0);
  const [copied, setCopied] = useState(false);
  const current = samples.find((s) => s.label === active) ?? samples[0];
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

      {/* Tab strip */}
      <div className="flex items-center gap-0.5 overflow-x-auto border-b border-border px-2">
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
        {samples.map((s) => (
          <button
            key={s.label}
            onClick={() => setActive(s.label)}
            className={cn(
              "whitespace-nowrap border-b-2 border-transparent px-2.5 py-2 text-[11px] font-medium",
              active === s.label
                ? "border-primary text-foreground"
                : "text-muted hover:text-foreground",
            )}
          >
            {s.label}
          </button>
        ))}
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
      {responses && responses.length > 0 && active !== TRY_IT && (
        <div className="max-h-[45%] shrink-0 overflow-auto border-t border-border">
          <div className="flex items-center gap-2 border-b border-border/60 px-4 py-2">
            {responses.length > 1 ? (
              <div className="relative">
                <select
                  value={respIdx}
                  onChange={(e) => setRespIdx(Number(e.target.value))}
                  className={cn(
                    "appearance-none rounded py-0.5 pl-1.5 pr-6 font-mono text-[10px] font-bold outline-none",
                    response!.status.startsWith("2")
                      ? "bg-success/15 text-success"
                      : "bg-destructive/15 text-destructive",
                  )}
                  aria-label="Response status"
                >
                  {responses.map((r, i) => (
                    <option key={i} value={i}>
                      {r.status} {r.label ?? ""}
                    </option>
                  ))}
                </select>
                <ChevronDown className="pointer-events-none absolute right-1 top-1/2 h-3 w-3 -translate-y-1/2 opacity-70" />
              </div>
            ) : (
              <span
                className={cn(
                  "rounded px-1.5 py-0.5 font-mono text-[10px] font-bold",
                  response!.status.startsWith("2")
                    ? "bg-success/15 text-success"
                    : "bg-destructive/15 text-destructive",
                )}
              >
                {response!.status}
              </span>
            )}
            <span className="text-[11px] font-medium text-muted">Response</span>
          </div>
          {response?.note && (
            <p className="px-4 pt-2 font-mono text-[11px] text-warn/90">{response.note}</p>
          )}
          {response?.raw ? (
            <pre className="overflow-auto p-4 font-mono text-[12px] leading-relaxed text-muted">
              {response.raw}
            </pre>
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
