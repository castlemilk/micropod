import React from "react";
import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { getRestRoute, loadRestRoutes, REST_BASE_URL } from "@/lib/data";
import { restSamples } from "@/lib/code-samples";
import { restShape } from "@/lib/rest-links";
import { MethodBadge } from "@/components/method-badge";
import { PayloadExplorer } from "@/components/payload-explorer";
import { Playground } from "@/components/playground";
import { RequestPanel } from "@/components/request-panel";
import { JsonView } from "@/components/json-view";
import { cn } from "@/lib/utils";

export function generateStaticParams() {
  return loadRestRoutes().map((r) => ({ route: r.id }));
}

export function generateMetadata({ params }: { params: { route: string } }): Metadata {
  const route = getRestRoute(params.route);
  if (!route) return {};
  return {
    title: `${route.method} ${route.path}`,
    description: route.description,
  };
}

export default function RestRoutePage({ params }: { params: { route: string } }) {
  const route = getRestRoute(params.route);
  if (!route) return notFound();
  const shape = restShape(route);
  const okResponse = shape?.responses.find((r) => r.status.startsWith("2"));

  // The vsock bridge is a raw duplex byte pipe — not playable over fetch.
  const playable = route.id !== "get-v1-containers-id-vsock-port";
  const isSse = shape?.responses.some((r) => r.stream?.includes("event-stream")) ?? false;

  const panel = (
    <RequestPanel
      playground={
        playable ? (
          <Playground
            method={route.method}
            path={route.path}
            requestSchema={shape?.requestSchema}
            requestExample={shape?.requestExample}
            query={shape?.query}
            stream={isSse ? "sse" : null}
          />
        ) : undefined
      }
      samples={restSamples(route, shape, REST_BASE_URL)}
      heading={`${route.method} ${route.path}`}
      response={
        okResponse
          ? {
              status: okResponse.status,
              body: okResponse.example,
              raw: typeof okResponse.example === "string" ? okResponse.example : undefined,
              note: okResponse.stream,
            }
          : undefined
      }
    />
  );

  return (
    <div className="xl:grid xl:grid-cols-[1fr_420px]">
      <div className="space-y-8 px-6 py-8 pb-16 md:px-8">
        <div className="space-y-3">
          <div className="flex items-center gap-3">
            <MethodBadge method={route.method} />
            <code className="font-mono text-sm text-muted">{route.path}</code>
          </div>
          <h1 className="text-3xl font-bold tracking-tight">{route.description}</h1>
          <p className="text-sm text-muted">
            {route.group} · served on {REST_BASE_URL}
          </p>
        </div>

        {(route.pathParams.length > 0 || (shape?.query?.length ?? 0) > 0) && (
          <section className="space-y-3">
            <h2 className="border-b border-border pb-2 text-xl font-semibold">Parameters</h2>
            <div className="divide-y divide-border overflow-hidden rounded-lg border border-border">
              {route.pathParams.map((p) => (
                <div key={p} className="flex flex-wrap items-baseline gap-x-3 px-4 py-3">
                  <span className="font-mono text-[13px] font-medium">{p}</span>
                  <span className="font-mono text-[11px] text-primary/80">string</span>
                  <span className="text-[11px] text-muted">path</span>
                  <span className="rounded-sm bg-destructive/15 px-1 font-mono text-[9.5px] font-semibold uppercase leading-4 text-destructive">
                    required
                  </span>
                </div>
              ))}
              {shape?.query?.map((q) => (
                <div key={q.name} className="flex flex-wrap items-baseline gap-x-3 px-4 py-3">
                  <span className="font-mono text-[13px] font-medium">{q.name}</span>
                  <span className="font-mono text-[11px] text-primary/80">string</span>
                  <span className="text-[11px] text-muted">query</span>
                  {q.required ? (
                    <span className="rounded-sm bg-destructive/15 px-1 font-mono text-[9.5px] font-semibold uppercase leading-4 text-destructive">
                      required
                    </span>
                  ) : (
                    <span className="rounded-sm bg-secondary px-1 font-mono text-[9.5px] uppercase leading-4 text-muted">
                      optional
                    </span>
                  )}
                  {q.description && (
                    <span className="w-full text-[12px] text-muted">{q.description}</span>
                  )}
                </div>
              ))}
            </div>
          </section>
        )}

        {(shape?.requestSchema || shape?.requestExample) && (
          <section className="space-y-3">
            <h2 className="border-b border-border pb-2 text-xl font-semibold">Request body</h2>
            <PayloadExplorer schema={shape.requestSchema} example={shape.requestExample} />
          </section>
        )}

        <section className="space-y-4">
          <h2 className="border-b border-border pb-2 text-xl font-semibold">Responses</h2>
          <div className="space-y-4">
            {shape?.responses.map((r, i) => (
              <div key={i} className="space-y-2">
                <div className="flex items-center gap-2">
                  <span
                    className={cn(
                      "rounded px-1.5 py-0.5 font-mono text-xs font-bold",
                      r.status.startsWith("2")
                        ? "bg-success/10 text-success"
                        : "bg-destructive/10 text-destructive",
                    )}
                  >
                    {r.status}
                  </span>
                  <span className="text-sm font-medium">{r.description}</span>
                </div>
                {r.stream && (
                  <p className="pl-1 font-mono text-[11px] text-warn/90">{r.stream}</p>
                )}
                {r.example !== undefined && (
                  <div className="overflow-hidden rounded-lg border border-border bg-card/60">
                    {typeof r.example === "string" ? (
                      <pre className="overflow-auto p-4 font-mono text-[12px] leading-relaxed text-muted">
                        {r.example}
                      </pre>
                    ) : (
                      <JsonView value={r.example} />
                    )}
                  </div>
                )}
              </div>
            ))}
            {!shape && (
              <p className="text-sm text-muted">
                Returns a JSON status object; see the samples panel for the call shape.
              </p>
            )}
          </div>
        </section>
      </div>

      <div className="hidden xl:block">
        <div className="sticky top-14 h-[calc(100vh-3.5rem)]">{panel}</div>
      </div>
      <div className="border-t border-border px-6 py-8 md:px-8 xl:hidden">
        <div className="h-96 overflow-hidden rounded-lg border border-border">{panel}</div>
      </div>
    </div>
  );
}
