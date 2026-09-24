import React from "react";
import type { ParsedEndpoint } from "@/lib/types";
import { PayloadExplorer } from "./payload-explorer";
import { ResponseExplorer } from "./response-explorer";
import type { ResponseOption } from "./request-panel";
import { exampleForSchema, typeLabel } from "@/lib/examples";

/** Picks the best schema + stream note out of a response's content map. */
function responseOption(code: string, response: any): ResponseOption {
  const content = response.content ?? {};
  const jsonCt = Object.keys(content).find((ct) => ct === "application/json");
  const streamCt = Object.keys(content).find(
    (ct) => ct.includes("connect+") || ct.includes("grpc"),
  );
  const ct = jsonCt ?? streamCt ?? Object.keys(content)[0];
  return {
    status: code,
    label: response.description ?? "Response",
    schema: ct ? content[ct]?.schema : undefined,
    note: streamCt
      ? `${streamCt} — server stream; each frame carries one message of this type`
      : undefined,
  };
}

export function EndpointContent({
  endpoint,
  eyebrow,
  actions,
  urlBar,
  extraResponses,
}: {
  endpoint: ParsedEndpoint;
  eyebrow?: string;
  actions?: React.ReactNode;
  urlBar?: React.ReactNode;
  /** Additional response variants (e.g. Connect error envelopes). */
  extraResponses?: ResponseOption[];
}) {
  const responseItems: ResponseOption[] = [
    ...Object.entries(endpoint.responses).map(([code, r]) => responseOption(code, r)),
    ...(extraResponses ?? []),
  ];

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
        {endpoint.externalDocs && (
          <a
            href={endpoint.externalDocs.url}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1.5 text-[13px] text-primary hover:underline"
          >
            {endpoint.externalDocs.description ?? "Reference docs"} ↗
          </a>
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
        <ResponseExplorer items={responseItems} />
      </section>
    </div>
  );
}
