export { createMicropodClient } from "./client.js";
export type { MicropodClient, MicropodClientOptions } from "./client.js";
export {
  retryInterceptor,
  timeoutInterceptor,
  otelInterceptor,
  defaultRetryPolicy,
} from "./interceptors.js";
export type { RetryPolicy, OtelOptions } from "./interceptors.js";

// Generated protobuf-es surface — messages + service descriptors.
export * as micropodv1 from "./gen/micropod/v1/api_pb.js";
export * as micropodv1Container from "./gen/micropod/v1/container_pb.js";
export * as micropodv1Image from "./gen/micropod/v1/image_pb.js";
export * as micropodv1System from "./gen/micropod/v1/system_pb.js";
export * as micropodv1Compose from "./gen/micropod/v1/compose_pb.js";
export * as sandboxv3 from "./gen/com/apple/containerization/sandbox/v3/sandbox_context_pb.js";

// Re-export the connect bits consumers always need.
export { ConnectError, Code } from "@connectrpc/connect";
export type { Interceptor, Transport } from "@connectrpc/connect";
