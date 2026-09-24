import React from "react";
import type { Metadata } from "next";
import { loadRestRoutes, REST_BASE_URL } from "@/lib/data";
import { RestTable } from "./rest-table";

export const metadata: Metadata = {
  title: "REST API",
  description: "HTTP REST routes served by the Micropod daemon.",
};

export default function RestIndexPage() {
  const routes = loadRestRoutes();

  return (
    <div className="mx-auto max-w-4xl space-y-8 px-6 py-10 md:px-10">
      <div className="space-y-3">
        <h1 className="text-3xl font-bold tracking-tight">REST API</h1>
        <p className="text-muted">
          {routes.length} routes served by the Micropod daemon on{" "}
          <code className="font-mono text-xs">{REST_BASE_URL}</code>. This is the
          surface the app, CLI, and Docker shim use. Extracted from{" "}
          <code className="font-mono text-xs">Sources/MicropodAPI/APIHandlers.swift</code>{" "}
          — regenerate with <code className="font-mono text-xs">scripts/gen-api-docs.py</code>.
        </p>
      </div>
      <RestTable routes={routes} />
    </div>
  );
}
