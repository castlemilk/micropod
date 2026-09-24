import React from "react";
import Link from "next/link";
import type { Metadata } from "next";
import { loadConnectServices } from "@/lib/data";
import { MethodBadge } from "@/components/method-badge";

export const metadata: Metadata = {
  title: "Connect API",
  description: "Protobuf-defined Connect-RPC services exposed by Micropod.",
};

export default function GrpcIndexPage() {
  const services = loadConnectServices();

  return (
    <div className="mx-auto max-w-4xl space-y-10 px-6 py-10 md:px-10">
      <div className="space-y-3">
        <h1 className="text-3xl font-bold tracking-tight">Connect / gRPC</h1>
        <p className="text-muted">
          Protobuf-defined services rendered from the connect-openapi specs. Connect
          speaks unary JSON over plain HTTP — the same messages as the proto contract.
        </p>
      </div>

      {services.map((svc) => (
        <section key={svc.service} className="space-y-4">
          <div className="space-y-1">
            <div className="flex items-baseline gap-3">
              <h2 className="text-xl font-semibold">{svc.title}</h2>
              <code className="font-mono text-xs text-muted">{svc.service}</code>
            </div>
            <p className="text-sm text-muted">{svc.blurb}</p>
          </div>
          <div className="divide-y divide-border overflow-hidden rounded-lg border border-border">
            {svc.spec.endpoints.map((e) => (
              <Link
                key={e.id}
                href={`/grpc/${e.id}/`}
                className="flex items-center gap-3 bg-card px-4 py-2.5 transition-colors hover:bg-secondary/50"
              >
                <MethodBadge method={e.method} />
                <span className="font-semibold">{e.summary ?? e.path}</span>
                <span className="ml-auto truncate pl-4 text-right text-xs text-muted">
                  {e.description}
                </span>
              </Link>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
