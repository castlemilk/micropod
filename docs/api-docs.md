# API documentation explorer

The API reference at <https://castlemilk.github.io/micropod/api/> is a Next.js
static-export app in `web/` — a grouped sidebar, per-endpoint pages with
expandable request/response schemas, generated curl/JavaScript/Python/Go
samples, and ⌘K search across every surface.

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
