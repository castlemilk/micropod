"use client";

import React, { useState } from "react";
import { CodeBlock } from "./code-block";
import type { ParsedEndpoint } from "@/lib/types";
import { generateCurl, generateGo, generateJavascript, generatePython } from "@/lib/code-samples";
import { cn } from "@/lib/utils";

interface CodePanelProps {
  endpoint: ParsedEndpoint;
  baseUrl: string;
}

export function CodePanel({ endpoint, baseUrl }: CodePanelProps) {
  const samples = [
    { label: "cURL", lang: "bash", code: generateCurl(endpoint, baseUrl) },
    { label: "JavaScript", lang: "javascript", code: generateJavascript(endpoint, baseUrl) },
    { label: "Python", lang: "python", code: generatePython(endpoint, baseUrl) },
    { label: "Go", lang: "go", code: generateGo(endpoint, baseUrl) },
  ];
  const [active, setActive] = useState(samples[0].label);

  return (
    <div className="flex h-full flex-col border-l border-border bg-card/50">
      <div className="flex items-center gap-1 border-b border-border px-3 py-1">
        {samples.map((s) => (
          <button
            key={s.label}
            onClick={() => setActive(s.label)}
            className={cn(
              "border-b-2 border-transparent px-2 py-2 text-xs font-medium",
              active === s.label
                ? "border-primary text-foreground"
                : "text-muted hover:text-foreground",
            )}
          >
            {s.label}
          </button>
        ))}
      </div>
      <div className="flex-1 overflow-auto">
        <CodeBlock code={samples.find((s) => s.label === active)!.code} language={samples.find((s) => s.label === active)!.lang} />
      </div>
    </div>
  );
}
