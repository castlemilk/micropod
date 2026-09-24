export type HTTPMethod = "GET" | "POST" | "PUT" | "DELETE" | "PATCH";

export interface Parameter {
  name: string;
  in: "header" | "query" | "path" | "cookie";
  required?: boolean;
  schema: unknown;
  description?: string;
}

export interface RequestBody {
  description?: string;
  content: Record<string, { schema: unknown }>;
  required?: boolean;
}

export interface Response {
  description: string;
  content?: Record<string, { schema: unknown }>;
}

export interface ParsedEndpoint {
  id: string;
  method: HTTPMethod;
  path: string;
  service: string;
  summary?: string;
  description?: string;
  operationId?: string;
  parameters: Parameter[];
  requestBody?: RequestBody;
  responses: Record<string, Response>;
}

export interface NavigationGroup {
  title: string;
  endpoints: ParsedEndpoint[];
}

export interface OpenAPISpec {
  file: string;
  info: { title: string; description?: string; version: string };
  endpoints: ParsedEndpoint[];
  groups: NavigationGroup[];
  schemaCount: number;
}

export interface RestRoute {
  id: string;
  method: HTTPMethod;
  path: string;
  description: string;
  group: string;
  pathParams: string[];
}

export interface McpTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  group: string;
}

export interface SearchItem {
  kind: "REST" | "Connect" | "MCP" | "SDK";
  title: string;
  subtitle: string;
  href: string;
  method?: string;
}
