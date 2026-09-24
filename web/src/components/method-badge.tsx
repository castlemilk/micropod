import { cn } from "@/lib/utils";

const METHOD_STYLES: Record<string, string> = {
  GET: "bg-success/10 text-success border-success/25",
  POST: "bg-primary/10 text-primary border-primary/25",
  PUT: "bg-warn/10 text-warn border-warn/25",
  DELETE: "bg-destructive/10 text-destructive border-destructive/25",
  PATCH: "bg-secondary text-muted border-border",
};

export function MethodBadge({
  method,
  className,
}: {
  method: string;
  className?: string;
}) {
  return (
    <span
      className={cn(
        "rounded border px-2 py-0.5 font-mono text-[11px] font-bold uppercase tracking-wide",
        METHOD_STYLES[method] ?? METHOD_STYLES.PATCH,
        className,
      )}
    >
      {method}
    </span>
  );
}

export function methodTextColor(method: string): string {
  switch (method) {
    case "GET":
      return "text-success";
    case "POST":
      return "text-primary";
    case "PUT":
      return "text-warn";
    case "DELETE":
      return "text-destructive";
    default:
      return "text-muted";
  }
}
