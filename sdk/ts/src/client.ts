import {
  createClient as createConnectClient,
  type Client,
  type Interceptor,
  type Transport,
} from "@connectrpc/connect";
import { createConnectTransport } from "@connectrpc/connect-web";
import { MicropodService } from "./gen/micropod/v1/api_pb.js";
import {
  otelInterceptor,
  retryInterceptor,
  timeoutInterceptor,
  type OtelOptions,
  type RetryPolicy,
} from "./interceptors.js";

export interface MicropodClientOptions {
  /**
   * Custom transport — e.g. `@connectrpc/connect-node`'s HTTP/2 transport,
   * or a vsock-bridged transport for guest calls. Defaults to fetch-based
   * Connect transport (JSON over HTTP/1.1, works on Node 18+ and browsers).
   */
  transport?: Transport;
  /** Retry policy for unary calls; pass false to disable. */
  retry?: RetryPolicy | false;
  /** Default per-call timeout in ms (applied when the call has no earlier deadline). */
  timeoutMs?: number;
  /** OpenTelemetry tracing + metrics. `true` uses global providers. */
  otel?: boolean | OtelOptions;
  /** Extra interceptors, appended after the built-in chain. */
  interceptors?: Interceptor[];
}

export type MicropodClient = Client<typeof MicropodService>;

/**
 * Create a typed MicropodService client with the resiliency +
 * instrumentation chain applied.
 *
 * const client = createMicropodClient("http://localhost:45454", {
 *   retry: { maxAttempts: 3 },
 *   timeoutMs: 10_000,
 *   otel: true,
 * });
 */
export function createMicropodClient(
  baseUrl: string,
  opts: MicropodClientOptions = {},
): MicropodClient {
  const interceptors: Interceptor[] = [];
  if (opts.retry !== false) interceptors.push(retryInterceptor(opts.retry ?? {}));
  if (opts.timeoutMs !== undefined) interceptors.push(timeoutInterceptor(opts.timeoutMs));
  if (opts.otel) interceptors.push(otelInterceptor(opts.otel === true ? {} : opts.otel));
  interceptors.push(...(opts.interceptors ?? []));

  // Interceptors attach to the transport, not the client, in connect-es v2.
  const transport =
    opts.transport ?? createConnectTransport({ baseUrl, interceptors });
  return createConnectClient(MicropodService, transport);
}
