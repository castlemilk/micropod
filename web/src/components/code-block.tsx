"use client";

import React, { useState } from "react";
import { Check, Copy } from "lucide-react";

export function CodeBlock({ code, language }: { code: string; language?: string }) {
  const [copied, setCopied] = useState(false);

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
        className="absolute right-3 top-3 rounded-md border border-border bg-card p-1.5 text-muted opacity-0 transition-opacity hover:text-foreground focus:opacity-100 group-hover:opacity-100"
      >
        {copied ? <Check className="h-3.5 w-3.5 text-success" /> : <Copy className="h-3.5 w-3.5" />}
      </button>
      <pre className="h-full overflow-auto p-4 font-mono text-[13px] leading-relaxed text-foreground">
        <code data-language={language}>{code}</code>
      </pre>
    </div>
  );
}
