"use client";

import React, { useState } from "react";
import { Check, Copy } from "lucide-react";
import { cn } from "@/lib/utils";

const METHOD_COLOR: Record<string, string> = {
  GET: "text-success bg-success/10",
  POST: "text-primary bg-primary/10",
  PUT: "text-warn bg-warn/10",
  DELETE: "text-destructive bg-destructive/10",
  PATCH: "text-warn bg-warn/10",
};

/** Fern-style endpoint URL bar — METHOD chip + copyable full URL. */
export function EndpointUrlBar({ method, url }: { method: string; url: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="group flex items-center gap-3 overflow-hidden rounded-lg border border-border bg-card/60 px-3.5 py-2.5">
      <span
        className={cn(
          "shrink-0 rounded px-1.5 py-0.5 font-mono text-[10.5px] font-bold",
          METHOD_COLOR[method] ?? "text-foreground bg-secondary",
        )}
      >
        {method}
      </span>
      <code className="min-w-0 flex-1 truncate font-mono text-[13px] text-muted">{url}</code>
      <button
        onClick={async () => {
          await navigator.clipboard.writeText(`${method} ${url}`);
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        }}
        aria-label="Copy endpoint URL"
        className="shrink-0 rounded p-1 text-muted opacity-0 transition-opacity hover:text-foreground focus:opacity-100 group-hover:opacity-100"
      >
        {copied ? <Check className="h-3.5 w-3.5 text-success" /> : <Copy className="h-3.5 w-3.5" />}
      </button>
    </div>
  );
}
