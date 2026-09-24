import { Code, ConnectError, type Interceptor } from "@connectrpc/connect";
import { createValidator } from "@bufbuild/protovalidate";
import {
  context,
  metrics,
  trace,
  SpanKind,
  SpanStatusCode,
  type Span,
  type Tracer,
  type Meter,
} from "@opentelemetry/api";

// ---------------------------------------------------------------------------
// Retry — unary only, transient codes, exponential backoff + jitter.
// ---------------------------------------------------------------------------

export interface RetryPolicy {
  /** Total tries including the first (default 3). */
  maxAttempts?: number;
  /** Backoff before the first retry (default 100ms). */
  initialBackoffMs?: number;
  /** Backoff cap (default 2000ms). */
  maxBackoffMs?: number;
  /** Growth per retry (default 2). */
  multiplier?: number;
  /** Connect codes worth retrying. */
  retryableCodes?: Code[];
}

export const defaultRetryPolicy: Required<RetryPolicy> = {
  maxAttempts: 3,
  initialBackoffMs: 100,
  maxBackoffMs: 2000,
  multiplier: 2,
  retryableCodes: [
    Code.Unavailable,
    Code.DeadlineExceeded,
    Code.ResourceExhausted,
    Code.Aborted,
  ],
};

function sleep(ms: number, signal: AbortSignal | undefined): Promise<void> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(t);
      reject(ConnectError.from(signal?.reason ?? new Error("aborted")));
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

export function retryInterceptor(policy: RetryPolicy = {}): Interceptor {
  const p = { ...defaultRetryPolicy, ...policy };
  return (next) => async (req) => {
    if (req.stream) {
      // Streams can't be replayed mid-flight — no retry.
      return next(req);
    }
    let backoff = p.initialBackoffMs;
    let attempt = 0;
    for (;;) {
      attempt++;
      try {
        return await next(req);
      } catch (e) {
        const err = ConnectError.from(e);
        if (attempt >= p.maxAttempts || !p.retryableCodes.includes(err.code)) {
          throw err;
        }
        const jitter = Math.random() * (backoff / 2);
        await sleep(backoff - backoff / 4 + jitter, req.signal);
        backoff = Math.min(backoff * p.multiplier, p.maxBackoffMs);
      }
    }
  };
}

// ---------------------------------------------------------------------------
// Timeout — default per-call deadline when the caller set none (or a later
// one). Implemented via signal composition so it works on every runtime.
// ---------------------------------------------------------------------------

export function timeoutInterceptor(timeoutMs: number): Interceptor {
  return (next) => async (req) => {
    if (timeoutMs <= 0) return next(req);
    const ctrl = new AbortController();
    const timer = setTimeout(
      () => ctrl.abort(new ConnectError("deadline exceeded", Code.DeadlineExceeded)),
      timeoutMs,
    );
    const onAbort = () => ctrl.abort(req.signal?.reason);
    req.signal?.addEventListener("abort", onAbort, { once: true });
    try {
      return await next({ ...req, signal: ctrl.signal });
    } finally {
      clearTimeout(timer);
      req.signal?.removeEventListener("abort", onAbort);
    }
  };
}

// ---------------------------------------------------------------------------
// Validation — evaluates the buf.validate constraints declared in the protos
// against each request before it hits the wire; invalid requests fail fast
// with invalid_argument instead of a server round-trip.
// ---------------------------------------------------------------------------

export function validationInterceptor(): Interceptor {
  const validator = createValidator();
  return (next) => async (req) => {
    // Client/bidi streams send an AsyncIterable of messages — the micropod.v1
    // services have none, but guard so the interceptor stays safe elsewhere.
    if (req.stream) return next(req);
    const result = validator.validate(req.method.input, req.message);
    if (result.kind === "invalid") {
      const detail = result.violations
        .map((v) => `${String(v.field)}: ${v.message}`)
        .join("; ");
      throw new ConnectError(`invalid request — ${detail}`, Code.InvalidArgument);
    }
    return next(req);
  };
}

// ---------------------------------------------------------------------------
// OpenTelemetry — a span per call with rpc.* attributes, W3C traceparent
// propagation, duration histogram + call counter. Uses the global OTel
// providers by default; pass a tracer/meter to override.
// ---------------------------------------------------------------------------

export interface OtelOptions {
  tracer?: Tracer;
  meter?: Meter;
}

const RPC_SYSTEM = "connect_rpc";

function injectTraceparent(header: Headers, span: Span): void {
  const sc = span.spanContext();
  if (!sc.traceId || !sc.spanId) return;
  const flags = (sc.traceFlags & 1) === 1 ? "01" : "00";
  header.set("traceparent", `00-${sc.traceId}-${sc.spanId}-${flags}`);
}

export function otelInterceptor(opts: OtelOptions = {}): Interceptor {
  const tracer = opts.tracer ?? trace.getTracer("@micropod/sdk");
  const meter = opts.meter ?? metrics.getMeter("@micropod/sdk");
  const duration = meter.createHistogram("micropod.client.duration", {
    unit: "ms",
    description: "Client RPC duration",
  });
  const calls = meter.createCounter("micropod.client.calls", {
    description: "Client RPC calls",
  });

  const finish = (
    span: Span,
    service: string,
    method: string,
    start: number,
    code: Code | null,
  ) => {
    const attrs = {
      "rpc.system": RPC_SYSTEM,
      "rpc.service": service,
      "rpc.method": method,
      ...(code !== null ? { "rpc.connect.code": Code[code] } : {}),
    };
    calls.add(1, attrs);
    duration.record(Date.now() - start, attrs);
    span.setAttributes(attrs);
    span.setStatus(
      code === null
        ? { code: SpanStatusCode.OK }
        : { code: SpanStatusCode.ERROR, message: Code[code] },
    );
    span.end();
  };

  return (next) => async (req) => {
    const service = req.service.typeName;
    const method = req.method.name;
    const span = tracer.startSpan(
      `${service}/${method}`,
      { kind: SpanKind.CLIENT },
      context.active(),
    );
    injectTraceparent(req.header, span);
    const start = Date.now();
    try {
      const res = await context.with(trace.setSpan(context.active(), span), () =>
        next(req),
      );
      if (req.stream) {
        // Keep the span open until the stream finishes.
        const stream = (res as { message?: AsyncIterable<unknown> }).message;
        if (stream) {
          (res as { message: AsyncIterable<unknown> }).message = wrapStream(
            stream,
            () => finish(span, service, method, start, null),
            (e) => finish(span, service, method, start, ConnectError.from(e).code),
          );
        } else {
          finish(span, service, method, start, null);
        }
      } else {
        finish(span, service, method, start, null);
      }
      return res;
    } catch (e) {
      const err = ConnectError.from(e);
      span.recordException(err);
      finish(span, service, method, start, err.code);
      throw err;
    }
  };
}

async function* wrapStream(
  stream: AsyncIterable<unknown>,
  onEnd: () => void,
  onError: (e: unknown) => void,
): AsyncIterable<unknown> {
  try {
    for await (const m of stream) yield m;
    onEnd();
  } catch (e) {
    onError(e);
    throw e;
  }
}
