import React from "react";
import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { getRestRoute, loadRestRoutes, REST_BASE_URL } from "@/lib/data";
import { generateRestCurl } from "@/lib/code-samples";
import { MethodBadge } from "@/components/method-badge";
import { CodeBlock } from "@/components/code-block";

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

  return (
    <div className="mx-auto max-w-3xl space-y-8 px-6 py-10 md:px-10">
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

      {route.pathParams.length > 0 && (
        <section className="space-y-3">
          <h2 className="border-b border-border pb-2 text-xl font-semibold">Path parameters</h2>
          <ul className="space-y-2">
            {route.pathParams.map((p) => (
              <li key={p} className="flex items-center gap-2">
                <code className="font-mono text-sm font-semibold text-primary">{`{${p}}`}</code>
                <span className="text-xs text-muted">path · required</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="space-y-3">
        <h2 className="border-b border-border pb-2 text-xl font-semibold">Example</h2>
        <div className="overflow-hidden rounded-lg border border-border bg-card">
          <CodeBlock code={generateRestCurl(route, REST_BASE_URL)} language="bash" />
        </div>
      </section>
    </div>
  );
}
