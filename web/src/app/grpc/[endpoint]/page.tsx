import React from "react";
import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { getConnectEndpoint, loadConnectServices, REST_BASE_URL } from "@/lib/data";
import { connectSamples } from "@/lib/code-samples";
import { connectSdkSamples } from "@/lib/sdk-samples";
import { exampleForSchema, requestExampleFor, responseExampleFor } from "@/lib/examples";
import { endpointMarkdown } from "@/lib/markdown";
import { EndpointContent } from "@/components/endpoint-content";
import { PageActions } from "@/components/page-actions";
import { Playground } from "@/components/playground";
import { EndpointUrlBar } from "@/components/url-bar";
import { RequestPanel } from "@/components/request-panel";

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
  const samples = connectSamples(endpoint, REST_BASE_URL);
  const ok = responseExampleFor(endpoint);
  const reqExample = requestExampleFor(endpoint);

  // Connect errors are JSON envelopes; codes map to HTTP statuses
  // (not_found → 404, invalid_argument → 400, internal → 500).
  const errorEnvelopeSchema = {
    type: "object",
    title: "ConnectError",
    properties: {
      code: {
        type: "string",
        description:
          "Connect error code — e.g. not_found, invalid_argument, internal.",
      },
      message: { type: "string", description: "Human-readable error detail." },
    },
    required: ["code", "message"],
  };
  const resourceKeys = ["id", "name", "reference"];
  const hasResource = resourceKeys.some((k) => k in (reqExample ?? {}));
  // Per-RPC honest errors — the update RPCs proxy the app's control socket:
  // `unavailable` when the app isn't running, `failed_precondition` when the
  // app answers but the call fails (e.g. nothing downloaded to apply).
  const rpcErrorOverrides: Record<string, { status: string; label: string; body: any }[]> = {
    CheckForUpdates: [
      { status: "412", label: "Check failed", body: { code: "failed_precondition", message: "update check failed in app" } },
      { status: "503", label: "App not running", body: { code: "unavailable", message: "no control socket at ~/.micropod/app-control.sock" } },
    ],
    GetUpdateStatus: [
      { status: "412", label: "Status unavailable", body: { code: "failed_precondition", message: "update status call failed in app" } },
      { status: "503", label: "App not running", body: { code: "unavailable", message: "no control socket at ~/.micropod/app-control.sock" } },
    ],
    ApplyUpdate: [
      { status: "412", label: "No update staged", body: { code: "failed_precondition", message: "no downloaded update to apply" } },
      { status: "503", label: "App not running", body: { code: "unavailable", message: "no control socket at ~/.micropod/app-control.sock" } },
    ],
  };
  const rpcName = endpoint.operationId?.split(".").pop() ?? "";
  const errorResponses = [
    ...(rpcErrorOverrides[rpcName] ?? (hasResource
      ? [{
          status: "404",
          label: "Not found",
          body: { code: "not_found", message: "resource not found" },
        }]
      : [{
          status: "400",
          label: "Invalid request",
          body: { code: "invalid_argument", message: "invalid request field" },
        }])),
    {
      status: "500",
      label: "Internal error",
      body: { code: "internal", message: "internal error" },
    },
  ].map((r) => ({ ...r, schema: errorEnvelopeSchema }));

  const schema = endpoint.requestBody?.content?.["application/json"]?.schema;
  const isStreaming = Object.values(endpoint.responses).some((r) =>
    Object.keys(r.content ?? {}).some((ct) => ct.includes("connect+json")),
  );
  // Field explorer for the 200 body — skipped on streams, where the example
  // shows multiple frames but the schema describes a single frame message.
  const okSchema = !isStreaming
    ? endpoint.responses?.["200"]?.content?.["application/json"]?.schema
    : undefined;

  const panel = (
    <RequestPanel
      playground={
        !isSandbox ? (
          <Playground
            method={endpoint.method}
            path={endpoint.path}
            requestSchema={schema}
            stream={isStreaming ? "connect" : null}
          />
        ) : undefined
      }
      samples={samples}
      sdkSamples={connectSdkSamples(endpoint)}
      heading={`${endpoint.method} ${endpoint.path}`}
      url={`${REST_BASE_URL}${endpoint.path}`}
      responses={
        ok
          ? [
              { status: ok.status, label: "OK", schema: okSchema, body: ok.body },
              ...errorResponses,
            ]
          : undefined
      }
    />
  );

  return (
    <div className="xl:grid xl:grid-cols-[1fr_420px]">
      <div className="px-6 py-8 md:px-8">
        {isSandbox && (
          <p className="mb-6 rounded-md border border-warn/25 bg-warn/5 px-3 py-2 text-sm text-warn">
            Guest-side contract — served by vminitd over vsock port 1024 inside each
            container VM, not over host HTTP. Samples assume a vsock bridge (see
            <code className="mx-1 font-mono text-xs">/v1/containers/{"{id}"}/vsock/{"{port}"}</code>).
          </p>
        )}
        <EndpointContent
          endpoint={endpoint}
          eyebrow={service.title}
          extraResponses={isSandbox ? undefined : errorResponses}
          actions={
            <PageActions
              markdown={endpointMarkdown({
                title: endpoint.summary ?? endpoint.path,
                method: endpoint.method,
                url: `${REST_BASE_URL}${endpoint.path}`,
                description: endpoint.description,
                requestExample: schema ? exampleForSchema(schema) : undefined,
                responses: ok
                  ? [{ status: ok.status, description: "Success", example: ok.body }]
                  : undefined,
                notes: isSandbox
                  ? "Guest-side contract — served by vminitd over vsock port 1024 inside each container VM, not over host HTTP."
                  : undefined,
              })}
              curl={samples.find((s) => s.label === "cURL")?.code}
            />
          }
          urlBar={
            !isSandbox ? (
              <EndpointUrlBar method={endpoint.method} url={`${REST_BASE_URL}${endpoint.path}`} />
            ) : undefined
          }
        />
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
