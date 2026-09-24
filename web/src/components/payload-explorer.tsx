"use client";

/* eslint-disable @typescript-eslint/no-explicit-any */

import React, { useState } from "react";
import { ChevronDown, ChevronRight, ChevronsDownUp, ChevronsUpDown } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  exampleForSchema,
  isInt64,
  isNullable,
  primaryType,
  typeLabel,
} from "@/lib/examples";
import { JsonView } from "./json-view";

function shortExample(value: any): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value === "object") return undefined;
  const s = JSON.stringify(value);
  return s.length > 48 ? s.slice(0, 45) + "…" : s;
}

// ---------------------------------------------------------------------------
// Tree node
// ---------------------------------------------------------------------------

interface NodeProps {
  schema: any;
  name?: string;
  required?: boolean;
  depth: number;
  expandAll?: boolean;
}

function VariantPicker({ schema, depth, expandAll }: NodeProps) {
  const variants = schema.oneOf ?? schema.anyOf ?? [];
  const kind = schema.oneOf ? "oneOf" : "anyOf";
  const [active, setActive] = useState(0);
  return (
    <div className="my-1">
      <div className="flex items-center gap-1">
        <span className="mr-1 text-[10px] font-semibold uppercase tracking-wide text-warn">
          {kind}
        </span>
        {variants.map((v: any, i: number) => (
          <button
            key={i}
            onClick={() => setActive(i)}
            className={cn(
              "rounded px-1.5 py-0.5 font-mono text-[10px]",
              active === i
                ? "bg-primary/15 text-primary"
                : "text-muted hover:text-foreground",
            )}
          >
            {v.title ?? typeLabel(v)}
          </button>
        ))}
      </div>
      <div className="ml-4 mt-1 border-l border-dashed border-warn/30 pl-3">
        <FieldNode schema={variants[active]} depth={depth + 1} expandAll={expandAll} />
      </div>
    </div>
  );
}

function FieldNode({ schema, name, required, depth, expandAll }: NodeProps) {
  const [manual, setManual] = useState<boolean | undefined>(undefined);
  const isOpen = manual ?? expandAll ?? depth < 2;

  if (!schema || typeof schema !== "object") return null;

  if (schema.oneOf || schema.anyOf) {
    return (
      <VariantPicker schema={schema} name={name} required={required} depth={depth} expandAll={expandAll} />
    );
  }
  if (schema.allOf?.length === 1) {
    return <FieldNode schema={schema.allOf[0]} name={name} required={required} depth={depth} expandAll={expandAll} />;
  }
  if (schema.allOf?.length) {
    return (
      <div className="space-y-1">
        {schema.allOf.map((s: any, i: number) => (
          <FieldNode key={i} schema={s} name={i === 0 ? name : undefined} required={required} depth={depth} expandAll={expandAll} />
        ))}
      </div>
    );
  }

  const type = primaryType(schema);
  const isObj =
    (type === "object" || schema.properties) &&
    schema.properties &&
    Object.keys(schema.properties).length > 0;
  const isMap = !isObj && (type === "object" || schema.additionalProperties);
  const isArr = type === "array" || schema.items;
  const hasChildren = isObj || isArr || isMap;

  const example = exampleForSchema(schema, name);
  const leaf = shortExample(example);

  return (
    <div className={cn(depth > 0 && "ml-3 border-l border-border/70 pl-3")}>
      <div
        className={cn(
          "group flex items-baseline gap-2 rounded px-1.5 py-1",
          hasChildren && "cursor-pointer hover:bg-secondary/50",
        )}
        onClick={hasChildren ? () => setManual(!isOpen) : undefined}
        onKeyDown={
          hasChildren
            ? (e) => {
                if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault();
                  setManual(!isOpen);
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
            <ChevronDown className="h-3 w-3 shrink-0 self-center text-muted" />
          ) : (
            <ChevronRight className="h-3 w-3 shrink-0 self-center text-muted" />
          )
        ) : (
          <span className="w-3 shrink-0" />
        )}

        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
            {name && (
              <span className="font-mono text-[13px] font-medium text-foreground">{name}</span>
            )}
            <span className="font-mono text-[11px] text-primary/80">{typeLabel(schema)}</span>
            {required && (
              <span className="rounded-sm bg-destructive/15 px-1 font-mono text-[9.5px] font-semibold uppercase leading-4 text-destructive">
                required
              </span>
            )}
            {leaf !== undefined && (
              <span className="truncate font-mono text-[11px] text-muted">= {leaf}</span>
            )}
            {schema.enum && (
              <span className="flex gap-1">
                {schema.enum.map((v: any) => (
                  <span
                    key={String(v)}
                    className="rounded-sm bg-secondary px-1 font-mono text-[10px] leading-4 text-muted"
                  >
                    {v === null ? "null" : String(v)}
                  </span>
                ))}
              </span>
            )}
            {schema.default !== undefined && (
              <span className="rounded-sm bg-secondary px-1 font-mono text-[10px] leading-4 text-muted">
                default {JSON.stringify(schema.default)}
              </span>
            )}
            {schema.format && !isInt64(schema) && (
              <span className="font-mono text-[10px] text-muted/70">{schema.format}</span>
            )}
          </div>
          {schema.description && (
            <p className="mt-0.5 max-w-prose text-[12px] leading-snug text-muted">
              {schema.description}
            </p>
          )}
        </div>
      </div>

      {isOpen && hasChildren && (
        <div className="pb-1">
          {isObj &&
            Object.entries<any>(schema.properties).map(([k, v]) => (
              <FieldNode
                key={k}
                name={k}
                schema={v}
                required={schema.required?.includes(k)}
                depth={depth + 1}
                expandAll={expandAll}
              />
            ))}
          {isArr && schema.items && (
            <div className="ml-3 border-l border-border/70 pl-3">
              <span className="font-mono text-[10px] text-muted">items</span>
              <FieldNode schema={schema.items} depth={0} expandAll={expandAll} />
            </div>
          )}
          {isMap && typeof schema.additionalProperties === "object" && (
            <div className="ml-3 border-l border-border/70 pl-3">
              <span className="font-mono text-[10px] text-muted">values</span>
              <FieldNode schema={schema.additionalProperties} depth={0} expandAll={expandAll} />
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Public component — Fields / Example toggle + expand controls.
// ---------------------------------------------------------------------------

interface PayloadExplorerProps {
  schema?: any;
  /** Literal example to use instead of generating one from the schema. */
  example?: any;
  /** Section label shown above the toggle, e.g. "Request body". */
  label?: string;
  defaultView?: "fields" | "example";
}

export function PayloadExplorer({ schema, example, label, defaultView = "fields" }: PayloadExplorerProps) {
  const hasFields =
    schema &&
    (schema.properties ||
      schema.items ||
      schema.oneOf ||
      schema.anyOf ||
      schema.allOf ||
      schema.additionalProperties);
  const [view, setView] = useState<"fields" | "example">(
    hasFields ? defaultView : "example",
  );
  const [expandAll, setExpandAll] = useState<boolean | undefined>(undefined);

  const resolvedExample = example ?? (schema ? exampleForSchema(schema) : undefined);
  const showExample = view === "example" || !hasFields;

  return (
    <div className="overflow-hidden rounded-lg border border-border bg-card/60">
      <div className="flex items-center justify-between border-b border-border px-3 py-1.5">
        <div className="flex items-center gap-2">
          {label && <span className="text-xs font-semibold">{label}</span>}
          <div className="flex rounded-md bg-secondary/60 p-0.5">
            {(["fields", "example"] as const).map((v) => (
              <button
                key={v}
                onClick={() => setView(v)}
                disabled={v === "fields" && !hasFields}
                className={cn(
                  "rounded px-2 py-0.5 text-[11px] font-medium capitalize",
                  view === v || (!hasFields && v === "example")
                    ? "bg-card text-foreground shadow-sm"
                    : "text-muted hover:text-foreground disabled:opacity-40",
                )}
              >
                {v}
              </button>
            ))}
          </div>
        </div>
        {!showExample && (
          <div className="flex items-center gap-1">
            <button
              onClick={() => setExpandAll(true)}
              className="rounded p-1 text-muted hover:text-foreground"
              title="Expand all"
            >
              <ChevronsUpDown className="h-3.5 w-3.5" />
            </button>
            <button
              onClick={() => setExpandAll(false)}
              className="rounded p-1 text-muted hover:text-foreground"
              title="Collapse all"
            >
              <ChevronsDownUp className="h-3.5 w-3.5" />
            </button>
          </div>
        )}
      </div>

      {showExample ? (
        resolvedExample !== undefined ? (
          <JsonView value={resolvedExample} />
        ) : (
          <p className="p-4 text-xs text-muted">No body.</p>
        )
      ) : (
        <div className="p-2">
          {/* key remounts the tree so expand/collapse-all clears manual toggles */}
          <FieldNode key={String(expandAll)} schema={schema} depth={0} expandAll={expandAll} />
        </div>
      )}
    </div>
  );
}
