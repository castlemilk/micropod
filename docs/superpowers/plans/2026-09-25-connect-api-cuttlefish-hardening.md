# Connect API additions + server/SDK hardening for cuttlefish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Connect API everything a Go client needs to run isolated jobs with real exit codes and clone-backed cache volumes, and fix the server/SDK bugs that break connect-go clients today.

**Architecture:** Proto additions land first and regenerate Swift/Go/TS surfaces. The Swift `MicropodAPI` gets an exit-code registry (native `waitProcess` registered before `startProcess`), `WaitContainer`/`GetContainer`/`Ping`, a native volume service with `CloneVolume`/`CommitVolumeClone`, a multi-attach guard, transport-error → `unavailable`, backend hot-swap and a stream-flush fix. The Go SDK stops cancelling streams and gains an idempotency gate + `WithConnectOptions`. The Go apiserver implements what it can from the CLI and leaves clone commits `unimplemented`.

**Tech Stack:** Swift 6 (SwiftPM, XCTest, Network.framework), protobuf via `buf` 1.72 (`buf.gen.yaml`, `buf.gen.sdk.yaml`, `buf.gen.docs.yaml`), Go 1.26 (`connectrpc.com/connect` v1.19.2), mock CLI `Tests/MicropodIntegrationTests/Support/mock-container`.

**Spec:** `/Users/benebsworth/projects/cuttlefish/docs/superpowers/specs/2026-09-25-micropod-connect-runtime-design.md` (§3.1, §3.2, §3.9 "micropod").

## Global Constraints

- Branch `feat/connect-api-cuttlefish-hardening`; commit per task; never push or tag.
- Every proto change regenerates: `buf generate --template buf.gen.yaml`, `buf generate --template buf.gen.sdk.yaml`, `buf generate --template buf.gen.docs.yaml`; commit generated files (`Sources/MicropodCore/Generated`, `sdk/go/gen`, `sdk/ts/src/gen`, `sdk/swift/Sources/MicropodSDK/Generated`, `landing/api`). `scripts/gen-sdk.sh --check` must pass.
- New proto fields use the exact numbers in the spec (§3.1): `RunContainerRequest` 12–16, `ExecRequest.arguments = 5`, `StreamLogsRequest.skip_lines = 4`, `GetStatsRequest.ids = 1`, `Volume.allocated_bytes = 8`, `SystemStatus.runtime_backend = 6`.
- Connect codes: XPC transport errors → `unavailable`; unknown clone/volume → `not_found`; wrong state → `failed_precondition`.
- No new stored registry credentials; no `RegistryService`.
- Swift: `swift build` and `swift test` green; `task validate` green at the end. Go: `cd api && go test ./...`, `cd sdk/go && go test ./...`.
- Keep `MICROPOD_RUNTIME=cli` behaviour for the mock-CLI tests (the resolver keeps CLI when `MICROPOD_CONTAINER_CLI_PATH` is set under `auto`).

## Review Focus

1. A container that exits within milliseconds of `startProcess` — `WaitContainer` must still return `known=true` (Task 5 test: mock container that transitions to stopped immediately; live test in cuttlefish plan).
2. A `StreamContainerLogs` for a container that already stopped before the call — must return the full backlog and a clean EndStream, not hang or error (Task 3 + Task 7 tests).
3. `CommitVolumeClone` while the container is `stopping` — must be `failed_precondition`, never a rename of a dirty image (Task 8 test).
4. `CreateContainer{no_pull:true}` for an image present only for another platform — must be `not_found` with a message naming the platform, never a silent pull (Task 6 test).
5. `Ping` while the Apple runtime is stopped and the API is on the CLI backend — must answer `status=stopped, runtime_backend=cli` in under a second, not a 15 s CLI timeout (Task 4 test with the mock CLI's stopped mode).

---

### Task 1: Proto additions and regeneration

**Files:**
- Modify: `proto/micropod/v1/container.proto`, `proto/micropod/v1/volume.proto`, `proto/micropod/v1/system.proto`
- Regenerate: `Sources/MicropodCore/Generated/**`, `sdk/go/gen/**`, `sdk/ts/src/gen/**`, `sdk/swift/Sources/MicropodSDK/Generated/**`, `landing/api/**`

**Interfaces (produces):**

```proto
// container.proto
service ContainerService {
  // …existing…
  rpc GetContainer(ContainerRef) returns (Container);
  rpc WaitContainer(WaitContainerRequest) returns (WaitContainerResponse);
}
message RunContainerRequest {
  // …existing 1-11…
  optional string entrypoint = 12;
  optional string platform = 13;
  optional string workdir = 14;
  optional string user = 15;
  // Fail with not_found instead of pulling when the image is absent locally.
  bool no_pull = 16;
}
message WaitContainerRequest {
  string id = 1 [(buf.validate.field).required = true, (buf.validate.field).string.min_len = 1];
  // Seconds to wait for exit; 0 = server default (30), capped at 300.
  int32 timeout_seconds = 2 [(buf.validate.field).int32.gte = 0];
}
message WaitContainerResponse {
  bool exited = 1;      // container is no longer running/stopping
  bool known = 2;       // exit_code is authoritative
  int32 exit_code = 3;
  string state = 4;     // running|stopping|stopped|created|unknown
}
message StreamLogsRequest { /* …1-3… */ int64 skip_lines = 4 [(buf.validate.field).int64.gte = 0]; }
message GetStatsRequest { repeated string ids = 1; }
message ExecRequest { /* …1-4… */ repeated string arguments = 5; }
// `command` keeps its buf.validate `required` REMOVED; validation becomes: command non-empty OR arguments non-empty (enforced in handlers).

// volume.proto
service VolumeService {
  // …existing…
  rpc CloneVolume(CloneVolumeRequest) returns (Volume);
  rpc CommitVolumeClone(CommitVolumeCloneRequest) returns (CommitVolumeCloneResponse);
}
message Volume { /* …1-7… */ uint64 allocated_bytes = 8; }
message CloneVolumeRequest {
  string source = 1 [(buf.validate.field).required = true, (buf.validate.field).string.min_len = 1];
  string name = 2 [(buf.validate.field).required = true, (buf.validate.field).string.min_len = 1];
  optional string size = 3;           // defaults to the source's provisioned size
  repeated string labels = 4;         // key=value
}
message CommitVolumeCloneRequest {
  string container_id = 1 [(buf.validate.field).required = true, (buf.validate.field).string.min_len = 1];
  string volume = 2 [(buf.validate.field).required = true, (buf.validate.field).string.min_len = 1];
}
message CommitVolumeCloneResponse { uint64 allocated_bytes = 1; }

// system.proto
service SystemService {
  // …existing…
  rpc Ping(Empty) returns (PingResponse);
}
message PingResponse {
  string status = 1;             // running|stopped
  string runtime_backend = 2;    // native|cli
  string api_server_version = 3;
  string cli_version = 4;
}
message SystemStatus { /* …1-5… */ string runtime_backend = 6; }
```

Document every field with a `//` comment and `gnostic.openapi.v3.property` examples like the neighbouring fields.

- [ ] **Step 1: Edit the three proto files** exactly as above (keep existing field numbers; add comments/examples).
- [ ] **Step 2: Lint and regenerate**

Run:
```bash
buf lint && buf generate --template buf.gen.yaml && buf generate --template buf.gen.sdk.yaml && buf generate --template buf.gen.docs.yaml
```
Expected: no lint errors; new `*_pb.swift`, `*.pb.go`, `*connect.go`, `*_grpc.pb.go`, TS and OpenAPI files change.

- [ ] **Step 3: Build everything that consumes the generated code**

Run: `swift build 2>&1 | tail -3 && (cd sdk/go && go build ./... ) && (cd api && go build ./...)`
Expected: Swift builds (unimplemented Connect cases are fine — `ConnectMount` dispatches by method name and returns nil for unknown methods). Go apiserver builds because `Server` embeds the `Unimplemented*Handler` types, which gain the new methods.

- [ ] **Step 4: Drift check passes**

Run: `scripts/gen-sdk.sh --check`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add proto sdk Sources/MicropodCore/Generated landing/api api
git commit -m "proto: GetContainer/WaitContainer/Ping/CloneVolume/CommitVolumeClone, no_pull, entrypoint/platform/workdir/user, skip_lines, stats ids, allocated_bytes, runtime_backend"
```

---

### Task 2: Go SDK — streams never time out, idempotency gate, WithConnectOptions

**Files:**
- Modify: `sdk/go/interceptors.go`, `sdk/go/client.go`
- Test: `sdk/go/interceptors_test.go`

**Interfaces (produces):**

```go
type RetryPolicy struct {
    // …existing fields…
    // Idempotent reports whether a procedure (e.g. "/micropod.v1.ContainerService/GetContainer")
    // may be replayed. nil means every unary procedure is retried (previous behaviour).
    Idempotent func(procedure string) bool
}
// WithConnectOptions forwards connect.ClientOptions (e.g. connect.WithProtoJSON()) to every generated client.
func WithConnectOptions(opts ...connect.ClientOption) Option
```

- [ ] **Step 1: Write failing tests** in `sdk/go/interceptors_test.go`:

```go
// TestTimeoutInterceptorDoesNotCancelStreams: start an httptest connect-go server
// (use micropodv1connect.NewContainerServiceHandler with a fake that streams 5 LogChunks
// spaced 60ms apart), build the client with WithTimeout(100*time.Millisecond) and a caller
// ctx of 5s; assert all 5 chunks arrive and stream.Err() == nil.
// TestRetrySkipsNonIdempotent: fake unary handler that fails with CodeUnavailable and counts
// calls; policy with Idempotent: func(p string) bool { return false }; assert exactly 1 call.
// TestRetryHonoursIdempotent: same handler, Idempotent returns true; assert MaxAttempts calls.
// TestWithConnectOptionsProtoJSON: fake unary handler records req.Header().Get("Content-Type");
// client built with WithConnectOptions(connect.WithProtoJSON()); assert "application/json".
```
Write them fully (fake handler structs embedding `micropodv1connect.UnimplementedContainerServiceHandler`).

- [ ] **Step 2: Run** `cd sdk/go && go test ./... -run 'TestTimeoutInterceptorDoesNotCancelStreams|TestRetry|TestWithConnectOptions' -v` → FAIL (stream canceled; compile errors for the new API).
- [ ] **Step 3: Implement**
  - `timeoutInterceptor.WrapStreamingClient` returns `next` unchanged; delete `cancelOnCloseConn`. Doc comment: "Streams never receive a default deadline — a log follow has no sane default; callers bound streams with their own context."
  - `retryInterceptor.WrapUnary`: before the loop, `if r.policy.Idempotent != nil && !r.policy.Idempotent(req.Spec().Procedure) { return next(ctx, req) }`.
  - `config` gains `connectOpts []connect.ClientOption`; `NewClient` builds `opts := append([]connect.ClientOption{connect.WithInterceptors(cfg.interceptors...)}, cfg.connectOpts...)` and passes `opts...` to each generated constructor.
  - `client.go` package doc: add "Order matters: pass WithTimeout before WithRetry so each retry shares one deadline (connect-go applies the first interceptor outermost)."
- [ ] **Step 4: Run** the tests → PASS; `go vet ./...` clean.
- [ ] **Step 5: Commit** `git commit -am "sdk/go: streams never get a default deadline; RetryPolicy.Idempotent; WithConnectOptions"`.

---

### Task 3: Swift HTTP server — flush the final stream frame; reason phrases

**Files:**
- Modify: `Sources/MicropodAPI/MicropodAPIMain.swift` (`dispatch(.stream)`, `reasonLine`)
- Test: `Tests/MicropodIntegrationTests/MicropodAPITests.swift`

- [ ] **Step 1: Write the failing test** `testConnectStreamEndFrameIsDelivered`: POST `/api/micropod.v1.ContainerService/StreamContainerLogs` with header `Content-Type: application/connect+json` and body = 5-byte envelope (flags 0, big-endian length) + `{"id":"<mock container id>","tail":5}` for a container created via the mock (`POST /v1/containers` then stop it). Read the whole response body with `URLSession.shared.data(for:)`. Parse envelopes: assert ≥1 data frame with flag 0 and that the **last** frame has flag `0x02` and body is `{}` or contains `"error"`. Also assert `reasonLine` cases via a request producing 503 (POST `/api/micropod.v1.ContainerService/StartContainer` for an unknown id returns `not_found` → HTTP 404 "Not Found"; for 503 use the code path in Task 4). Keep the reason-phrase assertion simple: add a unit test in a new `Tests/MicropodIntegrationTests/HTTPReasonLineTests.swift` if `reasonLine` is made `static func reasonLine(for:)` internal (mark `@testable import MicropodAPI` is not possible for executables — instead move `reasonLine` into `HTTPServer` as `static` and test via a 503 response's status line captured by a raw `Network`/`URLSession` `HTTPURLResponse.statusCode` only). Minimum: assert the stream end frame.
- [ ] **Step 2: Run** `swift build --product MicropodAPI && swift test --filter MicropodAPITests/testConnectStreamEndFrameIsDelivered` → FAIL (last frame flag is 0 or body truncated).
- [ ] **Step 3: Implement** in `dispatch(.stream)`: replace the fire-and-forget loop with

```swift
Task {
    for await chunk in events {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            connection.send(content: chunk, completion: .contentProcessed { _ in c.resume() })
        }
    }
    // Half-close so the peer sees EOF only after every frame was processed.
    connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() })
}
```
Add reason phrases: 401 Unauthorized, 403 Forbidden, 409 Conflict, 412 Precondition Failed, 429 Too Many Requests, 499 Client Closed Request, 503 Service Unavailable, 504 Gateway Timeout.
- [ ] **Step 4: Run** the test → PASS. Also run the existing `testSSELogsStream` → PASS.
- [ ] **Step 5: Commit** `git commit -am "MicropodAPI: deliver the Connect EndStream frame before closing; HTTP reason phrases"`.

---

### Task 4: Ping, runtime_backend, stopped-runtime GetSystem, transport errors → unavailable

**Files:**
- Modify: `Sources/MicropodCore/Services/SystemService.swift` (`status()`), `Sources/MicropodCore/CLI/MicropodError.swift`, `Sources/MicropodRuntime/XPCChannel.swift`, `Sources/MicropodAPI/ConnectMount.swift`, `Sources/MicropodAPI/APIHandlers.swift`
- Test: `Tests/MicropodIntegrationTests/MicropodAPITests.swift`, `Tests/MicropodCoreTests/` (new `SystemStatusStoppedTests.swift`)

**Interfaces (produces):**
- `MicropodError.transport(String)` — new case; `XPCChannel.parseReply` throws it instead of `.message("XPC transport error …")`.
- `APIHandlers.backend` becomes a live value (see Task 9); for now expose `var runtimeBackend: RuntimeBackendKind`.
- `SystemService.status()` returns `Micropod_V1_SystemStatus` with `status = "stopped"` and `cliVersion` when `container system status` exits non-zero with output containing "not running" (case-insensitive) — never throws for a stopped runtime.

- [ ] **Step 1: Tests**
  - Core unit test: extend the mock CLI with a stopped mode (`MICROPOD_MOCK_RUNTIME_STOPPED=1` makes `system status` print `apiserver is not running and not registered with launchd` and exit 1, and makes `list`/`volume list` fail like the real CLI). In `SystemStatusStoppedTests` run `SystemService(client:).status()` with that env and assert `.status == "stopped"`.
  - API test `testPingReportsStoppedRuntimeFast`: start the API with the stopped env; `POST /api/micropod.v1.SystemService/Ping` returns 200 `{"status":"stopped","runtimeBackend":"cli", …}` in < 2 s; `GetSystem` returns 200 with `status.status == "stopped"` and no `diskUsage` totals.
  - API test `testPingRunning`: normal mock → `status == "running"`, `runtimeBackend == "cli"`, `cliVersion` non-empty.
  - Unit test in `Tests/MicropodRuntimeTests`: `ConnectMount` code mapping is private — instead test `MicropodError.transport` maps to `unavailable` through the API: not reachable with the mock. Add a tiny internal function `connectCode(for error: Error) -> ConnectWireCode` in `ConnectMount.swift` and move `ConnectWireCode` + `connectCode(for:)` into a new file `Sources/MicropodAPI/ConnectCodes.swift`; make the `MicropodAPI` target testable by adding a library target? Not worth it — keep the mapping table-driven and assert via the API test `testTransportErrorMapsToUnavailable` using `MICROPOD_MOCK_XPC_TRANSPORT_ERROR=1`? The mock is a CLI, not XPC. **Decision:** unit-test the mapping by extracting it into `MicropodCore` as `public enum ConnectCodeMapping { public static func code(for error: Error) -> String }` (returns the wire string) and test it in `MicropodCoreTests`; `ConnectMount` uses it.
- [ ] **Step 2: Run** the new tests → FAIL.
- [ ] **Step 3: Implement**
  - `MicropodError.transport(String)`; `XPCChannel.parseReply` throws `.transport("\(service): \(description)")`; install `xpc_connection_set_event_handler` that records `invalidated = true` so the next `send` fails fast with `.transport("connection invalidated")`.
  - `ConnectCodeMapping.code(for:)`: `.transport` → `"unavailable"`; `.runtimeNotRunning`, `.cliUnavailable` → `"unavailable"`; `.cliTimeout` → `"deadline_exceeded"`; `.unsupported` → `"unimplemented"`; `.pullStalled` → `"aborted"`; text prefix table as today. `ConnectMount.codeFor` delegates to it.
  - `SystemService.status()`: catch `cliFailure` whose stderr/stdout contains "not running" → return `Micropod_V1_SystemStatus.with { $0.status = "stopped"; $0.cliVersion = (try? await cliVersion()) ?? "" }`.
  - `ConnectMount` `GetSystem`: if `status.status == "stopped"` skip `diskUsage()`; set `status.runtimeBackend = handlers.runtimeBackend.rawValue`.
  - `ConnectMount` `Ping`: native backend → `api.ping(timeout: .seconds(2))` → `running`; failure → `stopped`; cli backend → `system.status()`. Fill `runtimeBackend`, `apiServerVersion`, `cliVersion` (cached).
  - REST `GET /v1/system` also carries `runtimeBackend` and the stopped shape.
  - Mock CLI stopped mode as described (document the env var at the top of the script).
- [ ] **Step 4: Run** `swift build && swift test --filter 'SystemStatusStopped|MicropodAPITests/testPing|ConnectCodeMapping'` → PASS.
- [ ] **Step 5: Commit** `git commit -am "MicropodAPI: Ping RPC, runtime_backend, stopped runtime is a status not an error, XPC transport errors are unavailable"`.

---

### Task 5: Exit-code registry, WaitContainer, GetContainer

**Files:**
- Create: `Sources/MicropodRuntime/ExitCodeRegistry.swift`
- Modify: `Sources/MicropodRuntime/NativeContainerService.swift` (`run`, `start`, `delete`, `deleteAll`, `prune`), `Sources/MicropodRuntime/RuntimeBackend.swift` (`RuntimeServices.exitCodes`), `Sources/MicropodAPI/ConnectMount.swift`, `Sources/MicropodAPI/APIHandlers.swift`
- Test: `Tests/MicropodRuntimeTests/ExitCodeRegistryTests.swift`, `Tests/MicropodIntegrationTests/MicropodAPITests.swift`

**Interfaces (produces):**

```swift
public actor ExitCodeRegistry {
    public struct Entry: Sendable, Equatable { public let exitCode: Int32?; public let exitedAt: Date }
    public init(ceiling: Duration = .seconds(7200))
    /// Registers a waiter task; `wait` is invoked immediately and its result stored.
    public func track(id: String, wait: @escaping @Sendable () async throws -> Int32)
    public func entry(for id: String) -> Entry?
    /// Suspends until an entry exists or `timeout` elapses; returns the entry or nil.
    public func await(id: String, timeout: Duration) async -> Entry?
    public func forget(id: String)   // cancels the waiter task, drops the entry
}
// ContainerServing gains (with default implementations in an extension):
extension ContainerServing {
    /// Runtime state string ("running", "stopping", "stopped", "created", "unknown") from inspect JSON.
    public func state(of id: String) async -> String
}
```

- [ ] **Step 1: Tests**
  - `ExitCodeRegistryTests`: `track` stores the result of a fast waiter; `await(timeout:)` returns nil before completion and the entry after; `forget` cancels a hanging waiter (use a `Task.sleep` waiter and check `entry == nil` after forget); ceiling records `exitCode == nil`.
  - `MicropodAPITests.testGetContainerAndWaitStopped`: run a mock container, stop it, `GetContainer` → 200 with `state == "stopped"`; `WaitContainer{id, timeout_seconds:1}` → `exited == true`, `known == false` (mock has no registry entry) and returns in < 2 s. `testWaitContainerRunningTimesOut`: running mock container → `exited == false`, `state == "running"` after ~1 s. `testWaitContainerUnknownId` → `not_found`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**
  - `ExitCodeRegistry` as above; waiter tasks are detached `Task { … }` handles kept in a dictionary; `await` uses `AsyncStream` continuations or polling every 50 ms (polling is acceptable and simplest inside an actor: loop `try? await Task.sleep(50ms)` until entry or deadline).
  - `NativeContainerService` gets `private let exitCodes: ExitCodeRegistry` (init param, default `ExitCodeRegistry()`), and in `run` and `start`: `try await api.bootstrap(id:)`; `await exitCodes.track(id: id) { try await api.waitProcess(containerId: id, processId: id) }`; `try await api.startProcess(...)`. On delete/deleteAll/prune → `exitCodes.forget(id)`.
  - `RuntimeServices` carries `exitCodes: ExitCodeRegistry?` (nil on cli) so `ConnectMount` can read it.
  - `ConnectMount` `GetContainer`: find by id in `containers.list()` (or `inspect` + map) → `not_found` if absent; set `exitCode` from registry when present. `WaitContainer`: timeout = `timeout_seconds == 0 ? 30 : min(timeout_seconds, 300)`; loop every 150 ms: `entry = registry?.entry(for:)`; `state = containers.state(of: id)`; if entry → `{exited:true, known:true, exit_code, state}`; if state is `stopped`/`unknown`/`created`-and-never-started → `{exited:true, known:false}` (created → `exited:false` while under timeout? treat `created` as not exited: return `exited:false, state:"created"` at timeout); `running`/`stopping` → keep polling until the deadline, then `{exited:false, known:false, state}`. Unknown id (inspect throws not found) → `not_found`.
  - `containerFrom`/list mapping: populate `exit_code` from the registry for stopped containers.
- [ ] **Step 4: Run** `swift test --filter 'ExitCodeRegistry|MicropodAPITests/testGetContainer|MicropodAPITests/testWait'` → PASS.
- [ ] **Step 5: Commit** `git commit -am "MicropodAPI: exit-code registry (waitProcess registered before start), WaitContainer, GetContainer"`.

---

### Task 6: RunContainer fields, no_pull, Exec argv, skip_lines, stats ids, already_exists safety

**Files:**
- Modify: `Sources/MicropodAPI/ConnectMount.swift` (`runRequest(from:)`, `Exec`, `StreamContainerLogs`, `GetStats`, `check(_ req: ExecRequest)`), `Sources/MicropodCore/CLI/ContainerCommand.swift` (`ContainerRunRequest.noPull`), `Sources/MicropodCore/Services/ContainerService.swift` (CLI create/run honour `noPull` via `ImageService.list` presence check), `Sources/MicropodRuntime/NativeContainerService.swift` (`createNativeInner`, `createNative` catch), `Sources/MicropodRuntime/ImagesServiceClient.swift` (`ensure(reference:platform:registryDomain:noPull:)`), `Sources/MicropodCore/Services/StatsSampler.swift` (`StatsSampling.snapshot(ids:)` with default), `Sources/MicropodRuntime/NativeStatsSampler.swift`
- Test: `Tests/MicropodIntegrationTests/MicropodAPITests.swift`, `Tests/MicropodRuntimeTests/`

**Interfaces (produces):**
- `ContainerRunRequest.noPull: Bool` (default false).
- `ImagesServiceClient.ensure(..., noPull: Bool)` throws `MicropodError.message("notFound: image <ref> not present locally for <os>/<arch>")` when `noPull` and no local match.
- `StatsSampling.snapshot(ids: [String]) async throws -> Micropod_V1_StatsSnapshot` — default extension filters `snapshot()`; native override calls `api.stats(id:)` per id only.

- [ ] **Step 1: Tests** (mock CLI records every invocation's argv to `$STATE_DIR/calls.log` — add this to `mock-container` if absent, one line per call)
  - `testRunContainerPassesEntrypointPlatformWorkdirUser`: `RunContainer{image, entrypoint:"/bin/sh", platform:"linux/arm64", workdir:"/w", user:"1000:1000", arguments:["-c","true"]}` → 200; `calls.log` contains a `run` line with `--entrypoint /bin/sh`, `--platform linux/arm64`, `--workdir /w` (or `-w`), `--user 1000:1000`.
  - `testCreateNoPullMissingImageIsNotFound`: `CreateContainer{image:"ghost/none:1", no_pull:true}` → 404 `not_found`, and `calls.log` has no `image pull`.
  - `testExecArgumentsVerbatim`: `Exec{id, arguments:["sh","-c","echo a  b"]}` → mock records argv with the spaced element intact; `Exec{id}` with neither command nor arguments → `invalid_argument`.
  - `testStreamLogsSkipLines`: mock emits 3 lines; `skip_lines:2` → exactly one data frame.
  - `testGetStatsIdsFilter`: two running mock containers; `GetStats{ids:[a]}` → snapshot has exactly one entry.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**
  - `runRequest(from:)` maps `entrypoint/platform/workdir/user/noPull`.
  - CLI `ContainerService.create/run`: when `noPull`, `let local = try await ImageService(client:).list()` and `localImageIsPresent(request.image, in: localImageReferenceInventory(from: local))` else throw the notFound message (platform variant check: if `request.platform` set, require a variant with that arch).
  - Native: `createNativeInner` passes `noPull: request.noPull` to `images.ensure`; in `createNative`'s catch, only `removeClones(containerID:)` when the error is **not** an already-exists error (`error.localizedDescription.hasPrefix("alreadyExists")`).
  - `Exec`: `argv = req.arguments.isEmpty ? req.command.split(" ") : req.arguments`; `check`: require one of them.
  - `StreamContainerLogs`: wrap `logs.stream(...)` in an `AsyncThrowingStream` that drops the first `skip_lines` events.
  - `GetStats`: `stats.snapshot(ids: req.ids)`.
- [ ] **Step 4: Run** the five tests → PASS; full `swift test` → PASS.
- [ ] **Step 5: Commit** `git commit -am "MicropodAPI: entrypoint/platform/workdir/user, no_pull, exec argv, skip_lines, stats ids; never remove clones on already_exists"`.

---

### Task 7: NativeLogStreamer — final drain, backoff, registry stop signal

**Files:**
- Modify: `Sources/MicropodRuntime/NativeLogStreamer.swift`
- Test: `Tests/MicropodRuntimeTests/NativeLogStreamerTests.swift`

**Interfaces (produces):**
```swift
public struct NativeLogStreamer: LogStreaming {
    public init(api: APIServerClient, exitCodes: ExitCodeRegistry? = nil)
    /// Test seam: sources + running-state provider instead of XPC.
    init(sourceProvider: @escaping @Sendable (String, Bool) async throws -> [FileHandle],
         isRunning: @escaping @Sendable (String) async -> Bool,
         exitCodes: ExitCodeRegistry? = nil)
}
```

- [ ] **Step 1: Tests** with temp files: (a) `testFinalDrainCapturesLateBytes` — `isRunning` returns true twice then false, and the test appends "tail\n" to the file **after** the second true and before the false is observed (use a controllable actor); assert "tail" is emitted. (b) `testStoppedBeforeStreamReturnsBacklogAndEnds` — file has 3 lines, `isRunning` false from the start → 3 lines then finish. (c) `testRegistryEntryEndsStream` — `isRunning` always true, registry entry appears after 200 ms → stream ends within 1 s.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**: state-check cadence 250 ms with backoff ×2 up to 1 s when quiet, reset to 80 ms drain ticks after any bytes; after observing not-running (or a registry entry), drain all sources once more, then `emitLines(final: true)`. Doc: empty lines are dropped.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -am "NativeLogStreamer: final drain after stop, state-poll backoff, exit-code registry stop signal"`.

---

### Task 8: Native volume service, CloneVolume, CommitVolumeClone, allocated_bytes, multi-attach guard

**Files:**
- Create: `Sources/MicropodRuntime/NativeVolumeService.swift`, `Sources/MicropodCore/Services/VolumeClone.swift`
- Modify: `Sources/MicropodRuntime/APIServerClient.swift` (`volumeList()`, `volumeDelete(name:)` — route names from `docs/container/Sources/Services/ContainerAPIService/Client/VolumesClient.swift`), `Sources/MicropodRuntime/APIServerProtocol.swift` (routes), `Sources/MicropodCore/Services/ResourceService.swift` (`VolumeServing.clone`, `.commitClone`), `Sources/MicropodCore/Mapper/ModelMapper.swift` (`allocatedBytes`), `Sources/MicropodRuntime/NativeContainerService.swift` (guard + shared lock), `Sources/MicropodRuntime/RuntimeBackend.swift` (`RuntimeServices.volumes`), `Sources/MicropodAPI/MicropodAPIMain.swift`/`APIHandlers.swift` (use `runtime.volumes`), `Sources/MicropodAPI/ConnectMount.swift`
- Test: `Tests/MicropodCoreTests/VolumeCloneTests.swift`, `Tests/MicropodIntegrationTests/MicropodAPITests.swift`

**Interfaces (produces):**

```swift
public protocol VolumeServing: Sendable {
    // existing list/create/delete/prune …
    /// Create `name` (size defaults to source's) and clonefile the source image over it.
    func clone(source: String, name: String, size: String?, labels: [String]) async throws -> Micropod_V1_Volume
    /// Promote container `containerID`'s clone of `volume` to be the golden image.
    func commitClone(containerID: String, volume: String) async throws -> UInt64  // allocated bytes
}
public enum VolumeClone {
    public static func allocatedBytes(atPath: String) -> UInt64          // st_blocks * 512
    public static func cloneImage(from: String, to: String) throws       // copyfile(COPYFILE_CLONE) to tmp + rename
    /// fsync `clonePath`, rename over `goldenPath`. Caller holds the per-volume lock.
    public static func commit(clonePath: String, goldenPath: String) throws -> UInt64
}
/// Per-volume-name async lock shared by commit and container delete.
public actor VolumeLocks { public static let shared = VolumeLocks(); public func withLock<T>(_ name: String, _ body: () async throws -> T) async throws -> T }
```

- [ ] **Step 1: Tests**
  - `VolumeCloneTests`: `cloneImage` produces an equal-size file with identical bytes on APFS (temp dir); `commit` replaces the golden atomically and returns `allocatedBytes > 0`; `commit` with a missing clone throws.
  - API tests: `testCloneVolume` — create volume `g` via API (mock writes a small file at the `source` path it reports; extend the mock so `volume create` creates a 1 MiB zero file at `$STATE_DIR/volumes/<name>/volume.img` and reports it as `source`), write a marker into that file from the test, `CloneVolume{source:"g", name:"c"}` → 200 and the returned volume's source file has the marker. `testCloneVolumeSourceInUseIsFailedPrecondition` — mock container running with `-v g:/x` → 412. `testCommitVolumeCloneWithoutCloneIsNotFound` → 404. `testCommitVolumeCloneRunningIsFailedPrecondition` — container running → 412. `testCommitVolumeCloneStoppedRenames` — stopped container; pre-create `~/…/volume-clones/<id>/<vol>.img` under `MICROPOD_VOLUME_CLONE_ROOT=$STATE_DIR/clones` with a marker; commit → golden source file has the marker, response `allocated_bytes > 0`. `testCreateContainerVolumeAttachedRWIsFailedPrecondition` — mock: run container A with `-v v:/x`, then `RunContainer` B with `volumes:["v:/y"]` → 412 mentioning A; with label `com.micropod.cache.clone=v` → 200 (mock has no clones; the guard must exempt clone mounts before touching the clone path — under the CLI backend clone labels are ignored, so this second assertion applies only when the native backend is active; keep it in the live cuttlefish tests instead).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**
  - `VolumeClone` helpers (Darwin `copyfile`, `fsync`, `rename`, `stat`).
  - CLI `VolumeService.clone`: `create(name, size: size ?? "<source sizeInBytes>", labels: labels + ["com.micropod.clone-of=<source>"])`; inspect both; `failed_precondition` if any running container (via `ContainerService(client:).list()`) mounts `source` without `ro`; `VolumeClone.cloneImage`. `commitClone`: throw `.unsupported("clone commit requires the native backend")`.
  - `NativeVolumeService`: list/create/delete via new XPC routes (`volumeList`, `volumeDelete`), inspect via existing; `clone` as above using XPC; `commitClone`: `VolumeLocks.shared.withLock(volume)`: state must be `stopped` (`api.managed(id)`), clone path `NativeContainerService.cloneRoot/<id>/<volume>.img` must exist (`not_found`), `volumeInspect(volume).source` must exist (`not_found`), golden not RW-attached to a running container (`failed_precondition`), then `VolumeClone.commit`.
  - `NativeContainerService.delete`/`deleteAll`/`prune`: wrap `removeClones` in `VolumeLocks.shared.withLock` per volume in that clone dir (list files). Multi-attach guard in `createNativeInner` for `.volume` mounts not in `cloneSet`: `failed_precondition` unless `MICROPOD_ALLOW_MULTI_ATTACH=1`.
  - `ModelMapper.volume(from:)`: `allocatedBytes = VolumeClone.allocatedBytes(atPath: source)`.
  - `RuntimeServices.volumes: any VolumeServing`; resolver picks native when native; `MicropodAPIMain` passes `runtime.volumes`.
  - `ConnectMount`: `CloneVolume`, `CommitVolumeClone` cases + `check()`s.
- [ ] **Step 4: Run** `swift test --filter 'VolumeClone|MicropodAPITests/testCloneVolume|MicropodAPITests/testCommitVolumeClone|MicropodAPITests/testCreateContainerVolumeAttached'` → PASS.
- [ ] **Step 5: Commit** `git commit -am "Volumes: native XPC service, CloneVolume, CommitVolumeClone (fsync+rename under a per-volume lock), allocated_bytes, RW multi-attach guard"`.

---

### Task 9: Backend hot-swap

**Files:**
- Modify: `Sources/MicropodRuntime/RuntimeBackend.swift` (`RuntimeHolder` actor), `Sources/MicropodAPI/APIHandlers.swift` (read services through the holder), `Sources/MicropodAPI/MicropodAPIMain.swift`
- Test: `Tests/MicropodRuntimeTests/RuntimeHolderTests.swift`

**Interfaces (produces):**
```swift
public actor RuntimeHolder {
    public init(initial: RuntimeServices, resolve: @escaping @Sendable () async -> RuntimeServices, minInterval: Duration = .seconds(10))
    public var current: RuntimeServices { get }
    /// Re-resolves when current.kind == .cli and minInterval elapsed (or force). Swaps atomically.
    public func refreshIfNeeded(force: Bool = false) async -> RuntimeServices
}
```
- [ ] **Step 1: Tests**: holder with a resolver that returns cli twice then native: `refreshIfNeeded()` within the interval is a no-op; after the interval it swaps to native; once native, never re-resolves.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement**; `APIHandlers` becomes a class holding `RuntimeHolder`; `Ping`/`GetSystem` call `refreshIfNeeded()` first; any handler catching `MicropodError.transport` calls `refreshIfNeeded(force: true)` after responding `unavailable`. `runtime_backend` reads `current.kind`.
- [ ] **Step 4: Run** `swift test` → PASS. **Step 5: Commit** `git commit -am "MicropodAPI: lazy backend hot-swap from cli to native"`.

---

### Task 10: Go apiserver parity

**Files:**
- Modify: `api/internal/server/server.go`, `api/internal/clicli/clicli.go`
- Test: `api/internal/server/server_test.go`

- [ ] **Step 1: Tests** (mock CLI): `GetContainer` found/not found; `WaitContainer` on a stopped mock → `exited=true, known=false`; running → `exited=false` after timeout 1; `Ping` → `running`/`cli`; `runArgs` includes `--entrypoint --platform --workdir --user` and `no_pull` on a missing image → `not_found` (checks `container image inspect` first via `clicli`); `Exec` uses `arguments`; `GetStats` filters ids; `CloneVolume` creates + `unix.Clonefile`s the mock source file; `CommitVolumeClone` → `unimplemented` (embedded default).
- [ ] **Step 2: Run** `cd api && go test ./...` → FAIL. **Step 3: Implement** (add `golang.org/x/sys` for `unix.Clonefile`; `GetSystem`/`Ping` `runtime_backend = "cli"`; `SystemStatus` stopped detection on CLI failure text). **Step 4:** PASS. **Step 5: Commit** `git commit -am "apiserver(go): GetContainer, WaitContainer, Ping, CloneVolume, run flags, no_pull, exec argv, stats ids"`.

---

### Task 11: Docs, full validation, drift check

**Files:**
- Modify: `README.md` (connect-go section: new RPCs, `WithConnectOptions(connect.WithProtoJSON())`, base URL `/api`), `docs/native-runtime.md` (exit-code registry, WaitContainer, clone/commit, multi-attach guard, hot-swap, transport errors, cuttlefish usage), `plugins/micropod/skills/micropod/SKILL.md` (Go SDK recipe)

- [ ] **Step 1:** Write the docs. **Step 2:** `task validate` and `task api-go-test` and `(cd sdk/go && go test ./...)` and `scripts/gen-sdk.sh --check` → all green. **Step 3: Commit** `git commit -am "docs: Connect API additions and hardening for Go clients"`.
