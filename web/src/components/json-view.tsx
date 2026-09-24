"use client";

import React, { useMemo, useState } from "react";
import { Check, Copy } from "lucide-react";

// Minimal JSON tokenizer — no syntax-highlight dep, colors keyed to the
// explorer palette: keys primary-blue, strings green, numbers amber,
// literals violet, punctuation muted.

const COLORS = {
  key: "text-[#7cb3ff]",
  string: "text-[#5fd68b]",
  number: "text-[#ffd60a]",
  literal: "text-[#bf8bff]",
  punct: "text-muted",
};

function tokenize(src: string): { text: string; cls: string }[] {
  const tokens: { text: string; cls: string }[] = [];
  // Stack of enclosing contexts: true = inside object (strings after {/, are keys)
  const ctx: boolean[] = [];
  let expectKey = false;
  let i = 0;

  while (i < src.length) {
    const ch = src[i];
    if (/\s/.test(ch)) {
      tokens.push({ text: ch, cls: "" });
      i++;
      continue;
    }
    if (ch === "{") {
      ctx.push(true);
      expectKey = true;
      tokens.push({ text: ch, cls: COLORS.punct });
      i++;
      continue;
    }
    if (ch === "[") {
      ctx.push(false);
      expectKey = false;
      tokens.push({ text: ch, cls: COLORS.punct });
      i++;
      continue;
    }
    if (ch === "}" || ch === "]") {
      ctx.pop();
      expectKey = false;
      tokens.push({ text: ch, cls: COLORS.punct });
      i++;
      continue;
    }
    if (ch === ",") {
      expectKey = ctx[ctx.length - 1] === true;
      tokens.push({ text: ch, cls: COLORS.punct });
      i++;
      continue;
    }
    if (ch === ":") {
      expectKey = false;
      tokens.push({ text: ch, cls: COLORS.punct });
      i++;
      continue;
    }
    if (ch === '"') {
      let j = i + 1;
      while (j < src.length && src[j] !== '"') {
        if (src[j] === "\\") j++;
        j++;
      }
      const text = src.slice(i, Math.min(j + 1, src.length));
      tokens.push({ text, cls: expectKey ? COLORS.key : COLORS.string });
      expectKey = false;
      i = j + 1;
      continue;
    }
    const m = /^-?\d+(\.\d+)?([eE][+-]?\d+)?/.exec(src.slice(i));
    if (m) {
      tokens.push({ text: m[0], cls: COLORS.number });
      i += m[0].length;
      continue;
    }
    const lit = /^(true|false|null)/.exec(src.slice(i));
    if (lit) {
      tokens.push({ text: lit[0], cls: COLORS.literal });
      i += lit[0].length;
      continue;
    }
    tokens.push({ text: ch, cls: "" });
    i++;
  }
  return tokens;
}

export function JsonView({ value, raw }: { value?: any; raw?: string }) {
  const src = useMemo(() => raw ?? JSON.stringify(value, null, 2) ?? "null", [value, raw]);
  const tokens = useMemo(() => tokenize(src), [src]);
  const [copied, setCopied] = useState(false);

  return (
    <div className="group relative">
      <button
        onClick={async () => {
          await navigator.clipboard.writeText(src);
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        }}
        aria-label="Copy JSON"
        className="absolute right-2 top-2 rounded-md border border-border bg-card p-1.5 text-muted opacity-0 transition-opacity hover:text-foreground focus:opacity-100 group-hover:opacity-100"
      >
        {copied ? <Check className="h-3.5 w-3.5 text-success" /> : <Copy className="h-3.5 w-3.5" />}
      </button>
      <pre className="overflow-auto p-4 font-mono text-[12.5px] leading-relaxed">
        <code>
          {tokens.map((t, i) => (
            <span key={i} className={t.cls || undefined}>
              {t.text}
            </span>
          ))}
        </code>
      </pre>
    </div>
  );
}
