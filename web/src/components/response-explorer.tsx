"use client";

/* eslint-disable @typescript-eslint/no-explicit-any */

import React, { useState } from "react";
import { JsonView } from "./json-view";
import { PayloadExplorer } from "./payload-explorer";
import { ResponsePicker, type ResponseOption } from "./request-panel";

/**
 * Left-column response documentation: a status dropdown (Fern-style) with the
 * selected response's field explorer + example underneath. Field descriptions
 * come from the OpenAPI/proto schema; the right rail keeps its own picker for
 * the live/example body.
 */
export function ResponseExplorer({ items }: { items: ResponseOption[] }) {
  const [idx, setIdx] = useState(0);
  if (items.length === 0) return null;
  const item = items[Math.min(idx, items.length - 1)];

  return (
    <div className="overflow-hidden rounded-lg border border-border bg-card/60">
      <div className="flex items-center gap-2.5 border-b border-border px-3 py-2">
        <ResponsePicker responses={items} index={idx} onChange={setIdx} />
        <span className="min-w-0 flex-1 truncate text-[12.5px] font-medium">
          {item.label}
        </span>
        {item.note && (
          <span className="shrink-0 rounded-sm bg-warn/10 px-1.5 py-0.5 font-mono text-[9.5px] font-semibold uppercase tracking-wide text-warn">
            stream
          </span>
        )}
      </div>

      {item.note && (
        <p className="border-b border-border/60 px-3 py-1.5 font-mono text-[11px] text-warn/90">
          {item.note}
        </p>
      )}

      {item.raw ? (
        <pre className="overflow-auto p-4 font-mono text-[12px] leading-relaxed text-muted">
          {item.raw}
        </pre>
      ) : item.schema ? (
        <PayloadExplorer schema={item.schema} example={item.body} bare />
      ) : item.body !== undefined ? (
        <JsonView value={item.body} />
      ) : (
        <p className="px-4 py-3 text-[12px] text-muted">No body.</p>
      )}
    </div>
  );
}
