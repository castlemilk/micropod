"use client";

import React, { useMemo, useState } from "react";
import Link from "next/link";
import type { RestRoute } from "@/lib/types";
import { MethodBadge } from "@/components/method-badge";
import { cn } from "@/lib/utils";

const METHODS = ["ALL", "GET", "POST", "PUT", "DELETE"];

export function RestTable({ routes }: { routes: RestRoute[] }) {
  const [method, setMethod] = useState("ALL");
  const [query, setQuery] = useState("");

  const filtered = useMemo(
    () =>
      routes.filter(
        (r) =>
          (method === "ALL" || r.method === method) &&
          (r.path.toLowerCase().includes(query.toLowerCase()) ||
            r.description.toLowerCase().includes(query.toLowerCase())),
      ),
    [routes, method, query],
  );

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        {METHODS.map((m) => (
          <button
            key={m}
            onClick={() => setMethod(m)}
            className={cn(
              "rounded-md border px-2.5 py-1 font-mono text-xs font-semibold",
              method === m
                ? "border-primary bg-primary/10 text-primary"
                : "border-border text-muted hover:text-foreground",
            )}
          >
            {m}
          </button>
        ))}
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Filter paths…"
          className="ml-auto rounded-md border border-border bg-card px-3 py-1 text-sm outline-none placeholder:text-muted focus:border-primary"
        />
      </div>

      <div className="divide-y divide-border overflow-hidden rounded-lg border border-border">
        {filtered.map((r) => (
          <Link
            key={r.id}
            href={`/rest/${r.id}/`}
            className="flex items-center gap-3 bg-card px-4 py-2.5 transition-colors hover:bg-secondary/50"
          >
            <MethodBadge method={r.method} />
            <code className="shrink-0 font-mono text-sm">{r.path}</code>
            <span className="ml-auto truncate pl-4 text-right text-xs text-muted">
              {r.description}
            </span>
          </Link>
        ))}
        {filtered.length === 0 && (
          <p className="bg-card px-4 py-8 text-center text-sm text-muted">
            No routes match.
          </p>
        )}
      </div>
    </div>
  );
}
