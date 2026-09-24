"use client";

/* eslint-disable @typescript-eslint/no-explicit-any */

import React, { useState } from "react";
import { ChevronDown, ChevronRight } from "lucide-react";
import { cn } from "@/lib/utils";

interface SchemaViewerProps {
  schema: any;
  name?: string;
  required?: boolean;
  depth?: number;
}

export function SchemaViewer({ schema, name, required, depth = 0 }: SchemaViewerProps) {
  const [isOpen, setIsOpen] = useState(depth < 2);

  if (!schema) return null;

  if (schema.allOf) {
    return (
      <div className="space-y-2">
        <span className="text-[10px] font-bold uppercase text-muted">All of</span>
        {schema.allOf.map((s: any, i: number) => (
          <SchemaViewer key={i} schema={s} depth={depth} />
        ))}
      </div>
    );
  }

  if (schema.oneOf || schema.anyOf) {
    const list = schema.oneOf || schema.anyOf;
    return (
      <div className="space-y-2 rounded-md border border-dashed border-border p-2">
        <span className="text-[10px] font-bold uppercase text-primary">
          {schema.oneOf ? "One of" : "Any of"}
        </span>
        {list.map((s: any, i: number) => (
          <SchemaViewer key={i} schema={s} depth={depth + 1} />
        ))}
      </div>
    );
  }

  const isObject = schema.type === "object" || schema.properties;
  const isArray = schema.type === "array" || schema.items;
  const hasChildren = isObject || isArray;
  const toggle = () => setIsOpen(!isOpen);

  return (
    <div className={cn("text-sm", depth > 0 && "my-2 ml-4 border-l border-border pl-4")}>
      <div
        className={cn(
          "group flex items-start gap-2 rounded px-1 py-1 transition-colors",
          hasChildren && "cursor-pointer hover:bg-secondary/60",
        )}
        onClick={hasChildren ? toggle : undefined}
        onKeyDown={
          hasChildren
            ? (e) => {
                if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault();
                  toggle();
                }
              }
            : undefined
        }
        role={hasChildren ? "button" : undefined}
        tabIndex={hasChildren ? 0 : undefined}
        aria-expanded={hasChildren ? isOpen : undefined}
      >
        {hasChildren ? (
          isOpen ? (
            <ChevronDown className="mt-0.5 h-4 w-4 text-muted" />
          ) : (
            <ChevronRight className="mt-0.5 h-4 w-4 text-muted" />
          )
        ) : (
          <div className="w-4" />
        )}

        <div className="flex min-w-0 flex-1 flex-col">
          <div className="flex flex-wrap items-center gap-2">
            {name && <span className="font-mono font-semibold text-primary">{name}</span>}
            <span className="font-mono text-xs text-muted">
              {schema.type || (schema.properties ? "object" : "any")}
              {schema.format && ` <${schema.format}>`}
              {schema.enum && ` [${schema.enum.join(", ")}]`}
              {required && (
                <span className="ml-1 font-bold text-destructive" title="Required">
                  *
                </span>
              )}
            </span>
            {schema.default !== undefined && (
              <span className="rounded bg-secondary px-1 text-[10px] text-muted">
                default: {JSON.stringify(schema.default)}
              </span>
            )}
          </div>
          {schema.description && (
            <p className="mt-0.5 text-xs leading-relaxed text-muted">{schema.description}</p>
          )}
        </div>
      </div>

      {isOpen && (
        <div className="mt-1">
          {isObject &&
            schema.properties &&
            Object.keys(schema.properties).map((propName) => (
              <SchemaViewer
                key={propName}
                name={propName}
                schema={schema.properties[propName]}
                required={schema.required?.includes(propName)}
                depth={depth + 1}
              />
            ))}
          {isArray && schema.items && (
            <div className="space-y-1">
              <span className="ml-4 text-[10px] font-bold uppercase text-muted">
                Array items
              </span>
              <SchemaViewer schema={schema.items} depth={depth + 1} />
            </div>
          )}
        </div>
      )}
    </div>
  );
}
