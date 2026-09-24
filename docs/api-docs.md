# API documentation explorer

The API reference at <https://castlemilk.github.io/micropod/api/> is a Next.js
static-export app in `web/` — a grouped sidebar, per-endpoint pages with a
deep payload explorer (expandable field trees with type chips, required
badges, enums, and inline example values, plus a syntax-highlighted Example
view), generated curl/JavaScript/Python/Go/Swift samples with real request
bodies, and ⌘K search across every surface.

Every REST and Connect page also has a **Try it** playground (Fern-style) in
the right rail — an editable base-URL bar with a live daemon-reachability
indicator, per-field request editors seeded from the generated examples,
and a Send button that calls the daemon directly from the browser (default
`http://localhost:45454`). Server-streaming RPCs (`StreamContainerLogs`,
`PullImage`) are decoded as Connect envelope frames; the REST logs endpoint
reads SSE. The two pages without a playground are the vsock bridge (a raw
duplex byte pipe) and the `SandboxContext` endpoints (guest-side, not host
HTTP). Browser calls depend on the daemon's CORS policy in
`Sources/MicropodAPI/CORSPolicy.swift` — add new docs origins there.

- `web/src/lib/examples.ts` — schema→example generator (field-name heuristics,
  proto JSON conventions like int64-as-string, curated overrides for flagship
  RPCs) and the MCP `Arguments:` description parser that synthesizes tool
  input schemas.
- `web/src/lib/rest-links.ts` — per-route request/response shapes matching
  `APIHandlers.swift` projections; update it when a REST handler's JSON
  contract changes.

## Surfaces

| Section | Source of truth | Artifact |
|---------|-----------------|----------|
| `/rest/` | `Sources/MicropodAPI/APIHandlers.swift` route table | `landing/api/rest-routes.json` |
| `/grpc/` | `proto/**` via buf `sudorandom-connect-openapi` | `landing/api/**/*.openapi.json` |
| `/mcp/` | live `tools/list` from the `MicropodMCP` binary | `landing/api/mcp-tools.json` |
| `/proto/` | buf `pseudomuto-doc` | `landing/api/proto-reference.html` |

Nothing is hand-copied — every page renders from the generated artifacts. The
Connect section covers `micropod.v1.MicropodService` (daemon, host HTTP) and
`com.apple.containerization.sandbox.v3.SandboxContext` (vminitd, vsock 1024).

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
