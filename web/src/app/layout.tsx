import React from "react";
import type { Metadata } from "next";
import "./globals.css";
import { SiteHeader } from "@/components/site-header";
import { Sidebar, type NavSection } from "@/components/sidebar";
import { buildSearchIndex, loadConnectServices, loadMcpTools, mcpGroups } from "@/lib/data";

export const metadata: Metadata = {
  title: { default: "Micropod API Reference", template: "%s | Micropod API" },
  description:
    "Connect-RPC and MCP API reference for Micropod — Docker Desktop-class container management on Apple's container runtime.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  const services = loadConnectServices();
  const tools = loadMcpTools();

  const sections: NavSection[] = [
    {
      title: "Reference",
      items: [
        { label: "Overview", href: "/" },
        { label: "Client SDKs", href: "/sdk/" },
        { label: "Protobuf reference", href: "/proto/" },
      ],
    },
    ...services.map((svc) => ({
      // The daemon API is one service per domain (ContainerService, …);
      // SandboxContext is the vminitd guest contract over the vsock bridge.
      title: svc.service.startsWith("micropod.") ? svc.title : `Guest API · ${svc.title}`,
      items: svc.spec.endpoints.map((e) => ({
        label: e.summary ?? e.path,
        href: `/grpc/${e.id}/`,
        method: e.method,
      })),
    })),
    ...mcpGroups(tools).map((g) => ({
      title: `MCP · ${g.title}`,
      items: g.tools.map((t) => ({ label: t.name, href: `/mcp/${t.name}/` })),
    })),
  ];

  return (
    <html lang="en" className="dark">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          href="https://fonts.googleapis.com/css2?family=Instrument+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap"
          rel="stylesheet"
        />
      </head>
      <body className="min-h-screen font-sans antialiased">
        <SiteHeader searchItems={buildSearchIndex()} />
        <div className="mx-auto flex max-w-[1600px] items-start">
          <aside className="sticky top-14 hidden h-[calc(100vh-3.5rem)] w-64 shrink-0 border-r border-border pl-4 md:block lg:w-72">
            <Sidebar sections={sections} />
          </aside>
          <main className="min-h-screen min-w-0 flex-1">{children}</main>
        </div>
      </body>
    </html>
  );
}
