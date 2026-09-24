import React from "react";
import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { getRestRoute, loadRestRoutes } from "@/lib/data";
import { restRpcEndpoint } from "@/lib/sdk-samples";
import { Redirect } from "@/components/redirect";

export function generateStaticParams() {
  return loadRestRoutes().map((r) => ({ route: r.id }));
}

export function generateMetadata(): Metadata {
  return { title: "Moved", robots: { index: false } };
}

export default function RestRouteRedirect({ params }: { params: { route: string } }) {
  const route = getRestRoute(params.route);
  if (!route) return notFound();
  const rpc = restRpcEndpoint(route);
  // Mapped routes forward to the Connect endpoint page; REST-only infra
  // routes (health, metrics, vsock bridge) land on the API index.
  const href = rpc ? `../../grpc/${rpc.id}/` : "../../grpc/";
  const label = rpc ? `Connect · ${rpc.summary ?? rpc.path}` : "API reference";
  return <Redirect href={href} label={label} />;
}
