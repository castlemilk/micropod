"use client";

import React, { useEffect, useRef, useState } from "react";
import {
  Check,
  ChevronDown,
  Copy,
  ExternalLink,
  FileText,
  TerminalSquare,
  X,
} from "lucide-react";
import { cn } from "@/lib/utils";

const MCP_CLAUDE = "claude mcp add micropod -- ~/.local/bin/micropod-mcp";
const MCP_CURSOR = `{
  "mcpServers": {
    "micropod": { "command": "~/.local/bin/micropod-mcp" }
  }
}`;

interface PageActionsProps {
  /** Markdown rendering of the page (built server-side). */
  markdown: string;
  /** cURL sample for this endpoint, when one exists. */
  curl?: string;
}

export function PageActions({ markdown, curl }: PageActionsProps) {
  const [copied, setCopied] = useState<string | null>(null);
  const [showMd, setShowMd] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!menuOpen) return;
    const close = (e: MouseEvent) => {
      if (!menuRef.current?.contains(e.target as Node)) setMenuOpen(false);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [menuOpen]);

  useEffect(() => {
    if (!showMd) return;
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setShowMd(false);
    document.addEventListener("keydown", esc);
    return () => document.removeEventListener("keydown", esc);
  }, [showMd]);

  const flash = async (key: string, text: string) => {
    await navigator.clipboard.writeText(text);
    setCopied(key);
    setTimeout(() => setCopied(null), 1500);
  };

  const item = "flex w-full items-center gap-2.5 px-3 py-2 text-left text-[12.5px] text-foreground hover:bg-secondary/70";

  return (
    <>
      <div className="flex items-center gap-1 text-[12px] text-muted">
        <ActionButton
          onClick={() => flash("page", markdown)}
          icon={copied === "page" ? <Check className="h-3.5 w-3.5 text-success" /> : <Copy className="h-3.5 w-3.5" />}
        >
          {copied === "page" ? "Copied" : "Copy page"}
        </ActionButton>
        <ActionButton onClick={() => setShowMd(true)} icon={<FileText className="h-3.5 w-3.5" />}>
          View as Markdown
        </ActionButton>

        <div className="relative" ref={menuRef}>
          <ActionButton onClick={() => setMenuOpen((o) => !o)}>
            More actions
            <ChevronDown className={cn("h-3.5 w-3.5 transition-transform", menuOpen && "rotate-180")} />
          </ActionButton>

          {menuOpen && (
            <div className="absolute left-0 top-full z-50 mt-1 w-72 overflow-hidden rounded-lg border border-border bg-card shadow-xl">
              <div className="border-b border-border/60 px-3 py-2 text-[10px] font-semibold uppercase tracking-wider text-muted">
                Use this API from an agent
              </div>
              <button
                className={item}
                onClick={() => {
                  void flash("claude", MCP_CLAUDE);
                  setMenuOpen(false);
                }}
              >
                <TerminalSquare className="h-4 w-4 shrink-0 text-muted" />
                <span className="flex-1">
                  <span className="block font-medium">Connect to Claude Code</span>
                  <span className="block text-[11px] text-muted">
                    {copied === "claude" ? "Copied — paste into your terminal" : "Copy MCP add command"}
                  </span>
                </span>
                <ExternalLink className="h-3.5 w-3.5 text-muted" />
              </button>
              <button
                className={item}
                onClick={() => {
                  void flash("cursor", MCP_CURSOR);
                  setMenuOpen(false);
                }}
              >
                <Copy className="h-4 w-4 shrink-0 text-muted" />
                <span className="flex-1">
                  <span className="block font-medium">Connect to Cursor</span>
                  <span className="block text-[11px] text-muted">
                    {copied === "cursor" ? "Copied — paste into ~/.cursor/mcp.json" : "Copy MCP server config"}
                  </span>
                </span>
                <ExternalLink className="h-3.5 w-3.5 text-muted" />
              </button>
              {curl && (
                <button
                  className={cn(item, "border-t border-border/60")}
                  onClick={() => {
                    void flash("curl", curl);
                    setMenuOpen(false);
                  }}
                >
                  <FileText className="h-4 w-4 shrink-0 text-muted" />
                  <span className="flex-1">
                    <span className="block font-medium">Copy as cURL</span>
                    <span className="block text-[11px] text-muted">
                      {copied === "curl" ? "Copied" : "This endpoint as a shell command"}
                    </span>
                  </span>
                </button>
              )}
            </div>
          )}
        </div>
      </div>

      {/* Markdown overlay */}
      {showMd && (
        <div
          className="fixed inset-0 z-[100] flex items-start justify-center bg-black/60 p-6 pt-[10vh]"
          onClick={() => setShowMd(false)}
        >
          <div
            className="flex max-h-[75vh] w-full max-w-2xl flex-col overflow-hidden rounded-xl border border-border bg-card shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
              <span className="font-mono text-[11px] text-muted">Markdown source</span>
              <div className="flex items-center gap-1">
                <button
                  onClick={() => flash("md", markdown)}
                  className="rounded p-1.5 text-muted hover:text-foreground"
                  aria-label="Copy markdown"
                >
                  {copied === "md" ? <Check className="h-4 w-4 text-success" /> : <Copy className="h-4 w-4" />}
                </button>
                <button
                  onClick={() => setShowMd(false)}
                  className="rounded p-1.5 text-muted hover:text-foreground"
                  aria-label="Close"
                >
                  <X className="h-4 w-4" />
                </button>
              </div>
            </div>
            <pre className="min-h-0 flex-1 overflow-auto p-4 font-mono text-[12px] leading-relaxed text-muted">
              {markdown}
            </pre>
          </div>
        </div>
      )}
    </>
  );
}

function ActionButton({
  children,
  icon,
  onClick,
}: {
  children: React.ReactNode;
  icon?: React.ReactNode;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="flex items-center gap-1.5 rounded-md px-2.5 py-1.5 transition-colors hover:bg-secondary/70 hover:text-foreground"
    >
      {icon}
      {children}
    </button>
  );
}
