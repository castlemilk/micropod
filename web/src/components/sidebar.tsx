"use client";

import React from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";
import { methodTextColor } from "./method-badge";

export interface NavItem {
  label: string;
  href: string;
  method?: string;
}

export interface NavSection {
  title: string;
  items: NavItem[];
}

export function Sidebar({ sections }: { sections: NavSection[] }) {
  const pathname = usePathname();

  return (
    <nav className="h-full space-y-6 overflow-y-auto py-6 pr-4">
      {sections.map((section) => (
        <div key={section.title} className="border-b border-border pb-4 last:border-0">
          <h4 className="mb-2 px-2 text-xs font-bold uppercase tracking-wider text-muted">
            {section.title}
          </h4>
          <div className="grid auto-rows-max grid-flow-row gap-0.5 text-sm">
            {section.items.map((item) => {
              const isActive = pathname === item.href || pathname === item.href.replace(/\/$/, "");
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  className={cn(
                    "group flex w-full items-center rounded-md px-2 py-1 transition-colors hover:bg-secondary/60",
                    isActive ? "bg-secondary font-medium text-foreground" : "text-muted",
                  )}
                >
                  {item.method && (
                    <span
                      className={cn(
                        "mr-2 w-10 shrink-0 font-mono text-[10px] font-bold uppercase",
                        methodTextColor(item.method),
                      )}
                    >
                      {item.method}
                    </span>
                  )}
                  <span className="truncate">{item.label}</span>
                </Link>
              );
            })}
          </div>
        </div>
      ))}
    </nav>
  );
}
