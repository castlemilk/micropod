"use client";

import React, { useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Search } from "lucide-react";
import type { SearchItem } from "@/lib/types";
import { cn } from "@/lib/utils";
import { methodTextColor } from "./method-badge";

const KIND_STYLES: Record<SearchItem["kind"], string> = {
  REST: "text-success",
  Connect: "text-primary",
  MCP: "text-warn",
};

export function SearchDialog({ items }: { items: SearchItem[] }) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const router = useRouter();

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        setOpen((o) => !o);
      }
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    if (open) {
      setQuery("");
      setCursor(0);
      requestAnimationFrame(() => inputRef.current?.focus());
    }
  }, [open]);

  const results = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return items.slice(0, 20);
    return items
      .filter(
        (i) =>
          i.title.toLowerCase().includes(q) || i.subtitle.toLowerCase().includes(q),
      )
      .slice(0, 20);
  }, [items, query]);

  const go = (item: SearchItem) => {
    setOpen(false);
    router.push(item.href);
  };

  return (
    <>
      <button
        onClick={() => setOpen(true)}
        className="flex items-center gap-2 rounded-md border border-border bg-card px-3 py-1.5 text-sm text-muted transition-colors hover:border-muted hover:text-foreground"
      >
        <Search className="h-3.5 w-3.5" />
        <span className="hidden sm:inline">Search endpoints…</span>
        <kbd className="hidden rounded border border-border bg-secondary px-1.5 font-mono text-[10px] sm:inline">
          ⌘K
        </kbd>
      </button>

      {open && (
        <div
          className="fixed inset-0 z-50 flex items-start justify-center bg-black/60 p-4 pt-[15vh]"
          onClick={() => setOpen(false)}
        >
          <div
            className="w-full max-w-xl overflow-hidden rounded-lg border border-border bg-card shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center gap-2 border-b border-border px-4">
              <Search className="h-4 w-4 text-muted" />
              <input
                ref={inputRef}
                value={query}
                onChange={(e) => {
                  setQuery(e.target.value);
                  setCursor(0);
                }}
                onKeyDown={(e) => {
                  if (e.key === "ArrowDown") {
                    e.preventDefault();
                    setCursor((c) => Math.min(c + 1, results.length - 1));
                  } else if (e.key === "ArrowUp") {
                    e.preventDefault();
                    setCursor((c) => Math.max(c - 1, 0));
                  } else if (e.key === "Enter" && results[cursor]) {
                    go(results[cursor]);
                  }
                }}
                placeholder="Search REST routes, RPCs, MCP tools…"
                className="flex-1 bg-transparent py-3 text-sm outline-none placeholder:text-muted"
              />
            </div>
            <ul className="max-h-80 overflow-y-auto py-2">
              {results.map((item, i) => (
                <li key={`${item.kind}-${item.href}`}>
                  <button
                    onClick={() => go(item)}
                    onMouseEnter={() => setCursor(i)}
                    className={cn(
                      "flex w-full items-center gap-3 px-4 py-2 text-left",
                      i === cursor && "bg-secondary",
                    )}
                  >
                    <span
                      className={cn(
                        "w-14 shrink-0 font-mono text-[10px] font-bold uppercase",
                        item.method ? methodTextColor(item.method) : KIND_STYLES[item.kind],
                      )}
                    >
                      {item.method ?? item.kind}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-sm text-foreground">{item.title}</span>
                      <span className="block truncate text-xs text-muted">{item.subtitle}</span>
                    </span>
                    <span className="shrink-0 text-[10px] uppercase text-muted">{item.kind}</span>
                  </button>
                </li>
              ))}
              {results.length === 0 && (
                <li className="px-4 py-6 text-center text-sm text-muted">
                  No results for “{query}”
                </li>
              )}
            </ul>
          </div>
        </div>
      )}
    </>
  );
}
