"use client";

import React, { useMemo, useState } from "react";
import { Check, Copy } from "lucide-react";
import { highlight } from "@/lib/highlight";

export function CodeBlock({ code, language }: { code: string; language?: string }) {
  const [copied, setCopied] = useState(false);
  const html = useMemo(() => highlight(code, language), [code, language]);
  const lines = code.split("\n").length;

  const copy = async () => {
    await navigator.clipboard.writeText(code);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="group relative h-full">
      <button
        onClick={copy}
        aria-label="Copy code"
        className="absolute right-3 top-3 z-10 rounded-md border border-border bg-card p-1.5 text-muted opacity-0 transition-opacity hover:text-foreground focus:opacity-100 group-hover:opacity-100"
      >
        {copied ? <Check className="h-3.5 w-3.5 text-success" /> : <Copy className="h-3.5 w-3.5" />}
      </button>
      <pre className="h-full overflow-auto py-3 font-mono text-[12.5px] leading-relaxed text-foreground">
        <code className="grid grid-cols-[auto_1fr]">
          <span
            aria-hidden
            className="sticky left-0 select-none border-r border-border/50 pr-3 pl-4 text-right text-muted/40"
          >
            {Array.from({ length: lines }, (_, i) => (
              <span key={i} className="block">
                {i + 1}
              </span>
            ))}
          </span>
          <span className="pl-3 pr-4" dangerouslySetInnerHTML={{ __html: html }} />
        </code>
      </pre>
    </div>
  );
}
