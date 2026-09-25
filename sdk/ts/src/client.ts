import {
  createClient as createConnectClient,
  type Client,
  type Interceptor,
  type Transport,
} from "@connectrpc/connect";
import { createConnectTransport } from "@connectrpc/connect-web";
import { ContainerService } from "./gen/micropod/v1/container_pb.js";
import { ImageService } from "./gen/micropod/v1/image_pb.js";
import { VolumeService } from "./gen/micropod/v1/volume_pb.js";
import { NetworkService } from "./gen/micropod/v1/network_pb.js";
import { ComposeService } from "./gen/micropod/v1/compose_pb.js";
import { SystemService } from "./gen/micropod/v1/system_pb.js";
import { K8sService } from "./gen/micropod/v1/k8s_pb.js";
import {
  otelInterceptor,
  retryInterceptor,
  timeoutInterceptor,
  validationInterceptor,
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
  /**
   * Validate requests against the buf.validate constraints declared in the
   * protos before sending (default true). Invalid requests throw a ConnectError
   * with code `invalid_argument` without a network round-trip.
   */
  validate?: boolean;
  /** Extra interceptors, appended after the built-in chain. */
  interceptors?: Interceptor[];
}

/**
 * The daemon API is grouped into per-domain services (ContainerService,
 * ImageService, VolumeService, NetworkService, ComposeService,
 * SystemService, K8sService). Method names are unique across services, so the facade
 * merges them into one flat call surface — `client.listContainers()`,
 * `client.composeUp()`, etc.
 */
export type MicropodClient = Client<typeof ContainerService> &
  Client<typeof ImageService> &
  Client<typeof VolumeService> &
  Client<typeof NetworkService> &
  Client<typeof ComposeService> &
  Client<typeof SystemService> &
  Client<typeof K8sService>;

/**
 * Create a typed client for all micropod.v1 services with the resiliency +
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
  if (opts.validate !== false) interceptors.push(validationInterceptor());
  if (opts.retry !== false) interceptors.push(retryInterceptor(opts.retry ?? {}));
  if (opts.timeoutMs !== undefined) interceptors.push(timeoutInterceptor(opts.timeoutMs));
  if (opts.otel) interceptors.push(otelInterceptor(opts.otel === true ? {} : opts.otel));
  interceptors.push(...(opts.interceptors ?? []));

  // Interceptors attach to the transport, not the client, in connect-es v2.
  // One transport shared by all seven service clients.
  const transport =
    opts.transport ?? createConnectTransport({ baseUrl, interceptors });
  return Object.assign(
    {},
    ...[
      ContainerService,
      ImageService,
      VolumeService,
      NetworkService,
      ComposeService,
      SystemService,
      K8sService,
    ].map((svc) => createConnectClient(svc, transport)),
  ) as MicropodClient;
}
