import React from "react";
import Link from "next/link";
import { Github, Box } from "lucide-react";
import { SearchDialog } from "./search-dialog";
import type { SearchItem } from "@/lib/types";

export function SiteHeader({ searchItems }: { searchItems: SearchItem[] }) {
  return (
    <header className="sticky top-0 z-40 w-full border-b border-border bg-background/90 backdrop-blur">
      <div className="flex h-14 items-center gap-4 px-4 md:px-6">
        <a href="/micropod/" className="flex items-center gap-2 text-foreground">
          <Box className="h-5 w-5 text-primary" />
          <span className="font-semibold tracking-tight">micropod</span>
          <span className="rounded border border-border bg-card px-1.5 py-0.5 font-mono text-[10px] text-muted">
            api
          </span>
        </a>

        <nav className="ml-4 hidden items-center gap-4 text-sm text-muted md:flex">
          <Link href="/rest/" className="hover:text-foreground">REST</Link>
          <Link href="/grpc/" className="hover:text-foreground">Connect</Link>
          <Link href="/mcp/" className="hover:text-foreground">MCP</Link>
          <Link href="/proto/" className="hover:text-foreground">Proto</Link>
        </nav>

        <div className="ml-auto flex items-center gap-3">
          <SearchDialog items={searchItems} />
          <a
            href="https://github.com/castlemilk/micropod"
            className="text-muted transition-colors hover:text-foreground"
            aria-label="GitHub repository"
          >
            <Github className="h-4 w-4" />
          </a>
        </div>
      </div>
    </header>
  );
}
