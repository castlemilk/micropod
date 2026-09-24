import React from "react";
import type { ParsedEndpoint } from "@/lib/types";
import { PayloadExplorer } from "./payload-explorer";
import { exampleForSchema, typeLabel } from "@/lib/examples";
import { cn } from "@/lib/utils";

export function EndpointContent({
  endpoint,
  eyebrow,
  actions,
  urlBar,
}: {
  endpoint: ParsedEndpoint;
  eyebrow?: string;
  actions?: React.ReactNode;
  urlBar?: React.ReactNode;
}) {
  return (
    <div className="space-y-8 pb-16">
      <div className="space-y-3">
        {eyebrow && <p className="text-[13px] font-medium text-primary">{eyebrow}</p>}
        <h1 className="text-3xl font-bold tracking-tight">
          {endpoint.summary ?? endpoint.path}
        </h1>
        {actions}
        {urlBar}
        {endpoint.description && (
          <p className="text-muted">{endpoint.description}</p>
        )}
      </div>

      {endpoint.parameters.length > 0 && (
        <section className="space-y-3">
          <h2 className="border-b border-border pb-2 text-xl font-semibold">Headers</h2>
          <div className="divide-y divide-border overflow-hidden rounded-lg border border-border">
            {endpoint.parameters.map((param, i) => (
              <div key={i} className="flex flex-wrap items-baseline gap-x-3 gap-y-1 px-4 py-3">
                <span className="font-mono text-[13px] font-medium">{param.name}</span>
                <span className="font-mono text-[11px] text-primary/80">
                  {typeLabel(param.schema)}
                </span>
                <span className="text-[11px] text-muted">{param.in}</span>
                {param.required && (
                  <span className="rounded-sm bg-destructive/15 px-1 font-mono text-[9.5px] font-semibold uppercase leading-4 text-destructive">
                    required
                  </span>
                )}
                <span className="w-full text-[12px] text-muted sm:w-auto sm:flex-1 sm:text-right">
                  {param.description ?? (
                    <span className="font-mono">
                      = {JSON.stringify(exampleForSchema(param.schema, param.name))}
                    </span>
                  )}
                </span>
              </div>
            ))}
          </div>
        </section>
      )}

      {endpoint.requestBody && (
        <section className="space-y-3">
          <h2 className="border-b border-border pb-2 text-xl font-semibold">Request body</h2>
          {endpoint.requestBody.description && (
            <p className="text-sm text-muted">{endpoint.requestBody.description}</p>
          )}
          {Object.entries(endpoint.requestBody.content).map(([contentType, content], i) => (
            <div key={i} className="space-y-2">
              <span className="font-mono text-xs text-muted">{contentType}</span>
              <PayloadExplorer schema={content.schema} />
            </div>
          ))}
        </section>
      )}

      <section className="space-y-4">
        <h2 className="border-b border-border pb-2 text-xl font-semibold">Responses</h2>
        <div className="space-y-6">
          {Object.entries(endpoint.responses).map(([code, response], i) => (
            <div key={i} className="space-y-2">
              <div className="flex items-center gap-2">
                <span
                  className={cn(
                    "rounded px-1.5 py-0.5 font-mono text-xs font-bold",
                    code.startsWith("2")
                      ? "bg-success/10 text-success"
                      : "bg-destructive/10 text-destructive",
                  )}
                >
                  {code}
                </span>
                <span className="text-sm font-medium">{response.description}</span>
              </div>
              {response.content &&
                Object.entries(response.content).map(([contentType, content], j) => (
                  <div key={j} className="space-y-1">
                    <span className="pl-1 font-mono text-xs text-muted">{contentType}</span>
                    <PayloadExplorer schema={content.schema} defaultView="example" />
                  </div>
                ))}
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}
