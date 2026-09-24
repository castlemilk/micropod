import React from "react";
import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { getConnectEndpoint, loadConnectServices, REST_BASE_URL } from "@/lib/data";
import { EndpointContent } from "@/components/endpoint-content";
import { CodePanel } from "@/components/code-panel";

export function generateStaticParams() {
  return loadConnectServices().flatMap((svc) =>
    svc.spec.endpoints.map((e) => ({ endpoint: e.id })),
  );
}

export function generateMetadata({ params }: { params: { endpoint: string } }): Metadata {
  const found = getConnectEndpoint(params.endpoint);
  if (!found) return {};
  return {
    title: found.endpoint.summary ?? found.endpoint.path,
    description: found.endpoint.description,
  };
}

export default function ConnectEndpointPage({
  params,
}: {
  params: { endpoint: string };
}) {
  const found = getConnectEndpoint(params.endpoint);
  if (!found) return notFound();

  const { endpoint, service } = found;
  const isSandbox = service.service.startsWith("com.apple");

  return (
    <div className="xl:grid xl:grid-cols-[1fr_400px]">
      <div className="px-6 py-8 md:px-8">
        {isSandbox && (
          <p className="mb-6 rounded-md border border-warn/25 bg-warn/5 px-3 py-2 text-sm text-warn">
            Guest-side contract — served by vminitd over vsock port 1024 inside each
            container VM, not over host HTTP. Samples assume a vsock bridge (see
            <code className="mx-1 font-mono text-xs">/v1/containers/{"{id}"}/vsock/{"{port}"}</code>).
          </p>
        )}
        <EndpointContent endpoint={endpoint} />
      </div>
      <div className="hidden xl:block">
        <div className="sticky top-14 h-[calc(100vh-3.5rem)]">
          <CodePanel endpoint={endpoint} baseUrl={REST_BASE_URL} />
        </div>
      </div>
      <div className="border-t border-border px-6 py-8 md:px-8 xl:hidden">
        <div className="h-96 overflow-hidden rounded-lg border border-border">
          <CodePanel endpoint={endpoint} baseUrl={REST_BASE_URL} />
        </div>
      </div>
    </div>
  );
}
