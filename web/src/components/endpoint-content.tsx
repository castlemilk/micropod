import React from "react";
import type { ParsedEndpoint } from "@/lib/types";
import { SchemaViewer } from "./schema-viewer";
import { MethodBadge } from "./method-badge";
import { cn } from "@/lib/utils";

export function EndpointContent({ endpoint }: { endpoint: ParsedEndpoint }) {
  return (
    <div className="space-y-8 pb-16">
      <div className="space-y-3">
        <div className="flex items-center gap-3">
          <MethodBadge method={endpoint.method} />
          <code className="font-mono text-sm text-muted">{endpoint.path}</code>
        </div>
        <h1 className="text-3xl font-bold tracking-tight">
          {endpoint.summary ?? endpoint.path}
        </h1>
        {endpoint.description && (
          <p className="text-muted">{endpoint.description}</p>
        )}
      </div>

      {endpoint.parameters.length > 0 && (
        <section className="space-y-4">
          <h2 className="border-b border-border pb-2 text-xl font-semibold">Headers</h2>
          <div className="space-y-4">
            {endpoint.parameters.map((param, i) => (
              <div key={i} className="flex flex-col gap-1 border-b border-border pb-4 last:border-0">
                <div className="flex items-center gap-2">
                  <span className="font-mono font-semibold text-primary">{param.name}</span>
                  <span className="text-xs uppercase text-muted">{param.in}</span>
                  {param.required && (
                    <span className="rounded bg-destructive/10 px-1.5 py-0.5 text-[10px] font-bold uppercase text-destructive">
                      Required
                    </span>
                  )}
                </div>
                {param.description && <p className="text-sm text-muted">{param.description}</p>}
                <SchemaViewer schema={param.schema} depth={1} />
              </div>
            ))}
          </div>
        </section>
      )}

      {endpoint.requestBody && (
        <section className="space-y-4">
          <h2 className="border-b border-border pb-2 text-xl font-semibold">Request body</h2>
          {endpoint.requestBody.description && (
            <p className="text-sm text-muted">{endpoint.requestBody.description}</p>
          )}
          {Object.entries(endpoint.requestBody.content).map(([contentType, content], i) => (
            <div key={i} className="space-y-2">
              <span className="font-mono text-xs text-muted">{contentType}</span>
              <SchemaViewer schema={content.schema} />
            </div>
          ))}
        </section>
      )}

      <section className="space-y-4">
        <h2 className="border-b border-border pb-2 text-xl font-semibold">Responses</h2>
        <div className="space-y-8">
          {Object.entries(endpoint.responses).map(([code, response], i) => (
            <div key={i} className="space-y-2">
              <div className="flex items-center gap-2">
                <span
                  className={cn(
                    "rounded px-1.5 py-0.5 text-xs font-bold",
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
                  <div key={j} className="ml-4 space-y-2">
                    <span className="font-mono text-xs text-muted">{contentType}</span>
                    <SchemaViewer schema={content.schema} />
                  </div>
                ))}
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}
