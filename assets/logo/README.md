# Micropod brand

Logo assets generated via the **BrandBrain flow-orchestrator MCP**
(~/projects/brandbrain/mcp/flow-orchestrator) against the local backend,
`logo-exploration` template, live mode (OpenAI `gpt-image-1`).

## Files

- `Micropod.icns` — app icon: the generated mark composited as a white
  glyph on the Micropod blue gradient rounded square, full 16–1024px
  icon set. Bundled by `scripts/package_app.sh` (programmatic SF-symbol
  icon in `scripts/make_icon.swift` is the fallback if this is absent).
- `exploration-1.png` — first exploration: geometric "M" mark (stylized
  shipping container + terminal cursor) in `#0A84FF` on warm off-white.
  **This mark is the app icon.**
- `exploration-2.png` — second exploration (white-ground variant).

## The flow

1. Boot local backend: `USE_MEMORY_STORE=true
   BRANDBRAIN_FLOW_TEMPLATE_ROOT=~/projects/brandbrain/evals/flows
   BRANDBRAIN_FLOW_ARTIFACT_ROOT=/tmp/bb-flow-runs bin/server` (fresh
   build: `go build -o /tmp/bb-server ./cmd/server`).
2. Mint a flow token: `POST /api/v1/ml/auth/tokens` with
   `X-BrandBrain-Mint-Secret` (set `ML_TOKEN_MINT_SECRET` on the backend),
   scopes `["agent:flows"]`.
3. `create_asset_flow` (templateId `logo-exploration`) with the Micropod
   brief; refine `prompt_mark`/`style_mark` via `update_flow_node`
   (monochrome-first, `#0A84FF`/`#0B1E3F` palette, favicon-legible,
   no text/gradients).
4. `validate_asset_flow` → `start_asset_flow_run` `mock` (free) → `live`
   (spend-capped) → pull the artifact from
   `BRANDBRAIN_FLOW_ARTIFACT_ROOT/objects/sha256/…` (WebP).

Session: `flow_session_ad86b0b40587` (backend shut down after generation).
