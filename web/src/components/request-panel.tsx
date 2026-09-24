"use client";

import React, { useState } from "react";
import { CodeBlock } from "./code-block";
import { JsonView } from "./json-view";
import type { Sample } from "@/lib/code-samples";
import { cn } from "@/lib/utils";

const TRY_IT = "__tryit";

interface RequestPanelProps {
  samples: Sample[];
  /** Label for the code section, e.g. "POST /v1/containers". */
  heading?: string;
  response?: { status: string; body?: any; raw?: string; note?: string };
  /** Live "Try it" tab content — rendered above the language samples. */
  playground?: React.ReactNode;
}

export function RequestPanel({ samples, heading, response, playground }: RequestPanelProps) {
  const [active, setActive] = useState(playground ? TRY_IT : (samples[0]?.label ?? ""));
  const current = samples.find((s) => s.label === active) ?? samples[0];

  return (
    <div className="flex h-full flex-col border-l border-border bg-card/50">
      {heading && (
        <div className="border-b border-border px-4 py-2.5">
          <span className="font-mono text-[11px] text-muted">{heading}</span>
        </div>
      )}
      <div className="flex items-center gap-0.5 overflow-x-auto border-b border-border px-2">
        {playground && (
          <button
            onClick={() => setActive(TRY_IT)}
            className={cn(
              "whitespace-nowrap border-b-2 border-transparent px-2.5 py-2 text-[11px] font-semibold",
              active === TRY_IT
                ? "border-primary text-foreground"
                : "text-muted hover:text-foreground",
            )}
          >
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
      <div className="min-h-0 flex-1 overflow-auto">
        {active === TRY_IT ? (
          playground
        ) : (
          current && <CodeBlock code={current.code} language={current.lang} />
        )}
      </div>

      {response && active !== TRY_IT && (
        <div className="max-h-[45%] shrink-0 overflow-auto border-t border-border">
          <div className="flex items-center gap-2 border-b border-border/60 px-4 py-2">
            <span
              className={cn(
                "rounded px-1.5 py-0.5 font-mono text-[10px] font-bold",
                response.status.startsWith("2")
                  ? "bg-success/15 text-success"
                  : "bg-destructive/15 text-destructive",
              )}
            >
              {response.status}
            </span>
            <span className="text-[11px] font-medium text-muted">Example response</span>
          </div>
          {response.note && (
            <p className="px-4 pt-2 font-mono text-[11px] text-warn/90">{response.note}</p>
          )}
          {response.raw ? (
            <pre className="overflow-auto p-4 font-mono text-[12px] leading-relaxed text-muted">
              {response.raw}
            </pre>
          ) : (
            <JsonView value={response.body} />
          )}
        </div>
      )}
    </div>
  );
}
