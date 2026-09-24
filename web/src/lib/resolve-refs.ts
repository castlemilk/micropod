/* eslint-disable @typescript-eslint/no-explicit-any */

/**
 * Inline every `$ref` in an OpenAPI fragment against a schema dictionary.
 *
 * The cycle guard is keyed by ref name along the current resolution path:
 * a ref already being expanded above is left as an inert `$ref` node rather
 * than recursing forever (proto messages can be self-recursive). Diamonds
 * still expand fully — the name is removed on the way out.
 */
export function resolveRefs(
  obj: any,
  schemas: Record<string, any>,
  refPath: Set<string> = new Set<string>(),
): any {
  if (!obj || typeof obj !== "object") return obj;

  if (obj.$ref) {
    const refName = String(obj.$ref).split("/").pop()!;
    const resolved = schemas[refName];
    if (resolved) {
      if (refPath.has(refName)) return obj;
      const { $ref: _, ...rest } = obj;
      refPath.add(refName);
      try {
        return resolveRefs({ ...resolved, ...rest }, schemas, refPath);
      } finally {
        refPath.delete(refName);
      }
    }
  }

  if (Array.isArray(obj)) {
    return obj.map((item) => resolveRefs(item, schemas, refPath));
  }

  const out: any = {};
  for (const key of Object.keys(obj)) {
    out[key] = resolveRefs(obj[key], schemas, refPath);
  }
  return out;
}
