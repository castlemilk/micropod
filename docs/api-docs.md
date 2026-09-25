# API documentation explorer

The API reference at <https://castlemilk.github.io/micropod/api/> is a Next.js
static-export app in `web/` — a grouped sidebar, per-endpoint pages with a
deep payload explorer (expandable field trees with type chips, required
badges, enums, and inline example values, plus a syntax-highlighted Example
view), generated samples in one flat strip (typed SDKs first — TypeScript /
Go / Swift — then raw HTTP: cURL, fetch, requests, net/http, URLSession),
and ⌘K search across every surface.

**The daemon's public API is `micropod.v1` over Connect — six domain
services (`ContainerService`, `ImageService`, `VolumeService`,
`NetworkService`, `ComposeService`, `SystemService`, `K8sService`).**
Unary calls are plain `POST` + proto-JSON, so curl and browsers hit the same
endpoints the typed SDKs do; server-streaming RPCs use the Connect envelope
protocol. The legacy `/v1/*` REST facade still answers for compatibility but
isn't documented as a separate API — `/rest/*` doc URLs redirect to their
Connect counterparts (`REST_TO_RPC` in `web/src/lib/sdk-samples.ts`).
`GET /health`, `GET /metrics`, and the vsock bridge are infra endpoints that
stay outside the RPC surface (documented on the landing page instead).

Every endpoint page also has a **Try it** playground (Fern-style) in the
right rail — an editable base-URL bar with a live daemon-reachability
indicator, per-field request editors seeded from the generated examples,
and a Send button that calls the daemon directly from the browser (default
`http://localhost:45454`). Server-streaming RPCs (`StreamContainerLogs`,
`PullImage`, `ComposeUp`) are decoded as Connect envelope frames. The
`SandboxContext` endpoints (guest-side, over vsock) get docs but no
playground. Browser calls depend on the daemon's CORS policy in
`Sources/MicropodAPI/CORSPolicy.swift` — add new docs origins there.

- `web/src/lib/examples.ts` — schema→example generator (field-name heuristics,
  proto JSON conventions like int64-as-string, curated overrides for flagship
  RPCs) and the MCP `Arguments:` description parser that synthesizes tool
  input schemas.
- `web/src/lib/sdk-samples.ts` — typed-client samples per RPC (TS facade,
  Go `NewClient` + `connect.NewRequest`, Swift `MicropodClient`), the
  REST→RPC map behind `/rest/*` redirects, and the `/sdk` call-map table.

## Surfaces

| Section | Source of truth | Artifact |
|---------|-----------------|----------|
| `/grpc/` (the API) | `proto/**` via buf `sudorandom-connect-openapi` | `landing/api/**/*.openapi.json` |
| `/rest/` | redirect stubs → `/grpc/*` | `landing/api/rest-routes.json` (legacy manifest) |
| `/mcp/` | live `tools/list` from the `MicropodMCP` binary | `landing/api/mcp-tools.json` |
| `/proto/` | buf `pseudomuto-doc` | `landing/api/proto-reference.html` |
| `/sdk/` | method spellings from `sdk-samples.ts` | — |

Nothing is hand-copied — every page renders from the generated artifacts. The
API section covers the seven `micropod.v1` domain services (daemon, host HTTP) and
`com.apple.containerization.sandbox.v3.SandboxContext` (vminitd, vsock 1024)
under a separate "Guest API" heading.

Proto field comments become OpenAPI `description`s and SDK doc comments — keep
them accurate. Two annotation layers enrich the spec:

- `buf.validate` field options (`required`, `min_len`, `gt`, …) surface as
  `required`/`minLength`/`exclusiveMinimum`/… and are enforced three ways:
  the Go apiserver's `connectrpc.com/validate` interceptor, the TypeScript
  SDK's client-side protovalidate interceptor (`validate: false` opts out),
  and the per-field `check` calls in `ConnectMount.swift`.
- `gnostic.openapi.v3` options (`property` on fields, `operation`/`schema` on
  RPCs and messages) surface as `examples`, `format`, `externalDocs`, etc.
  Field examples are written as `{yaml: "'…'"}` scalars — quote string values
  inside the YAML. Note `schema.example` on messages stringifies to a Go
  `map[…]` dump in the plugin output, so examples go on fields, not messages.
  The `buf.build/gnostic/gnostic` dep is descriptor-only for Go/Swift; the TS
  SDK vendors `src/vendor/gnostic/openapi/v3/*_pb.ts` (no npm package ships
  it) and `buf.gen.sdk.yaml` `rewrite_imports` points generated code there.

## Local development

```sh
cd web
npm install
npm run dev     # predev copies landing/api -> public/specs, serves at /micropod/api/
npm run build   # static export -> web/out/
```

The app reads the artifacts straight from `landing/api/` at build time
(`src/lib/data.ts`), so run `python3 scripts/gen-api-docs.py` first if you've
changed routes, protos, or MCP tools.

## Deployment

`.github/workflows/gh-pages.yml` regenerates the artifacts, runs `npm ci &&
npm run build` in `web/`, then overlays `web/out/` onto `landing/api/`:

- `out/index.html` replaces the old static `landing/api/index.html`.
- Generated JSON/proto artifacts remain at `/api/` (from `landing/`) and are
  also bundled under `/api/specs/` (from `public/specs/`) so raw-file links
  work identically in `next dev` and on Pages.
- `basePath` is `/micropod/api` — keep it in `next.config.mjs` or every
  generated link breaks.

## Adding a surface

Add a loader in `web/src/lib/data.ts`, a route group under
`web/src/app/<surface>/`, and a section in the `sections` array in
`web/src/app/layout.tsx`. The search index (`buildSearchIndex`) picks it up
from the same loader, so new content is searchable without extra wiring.
