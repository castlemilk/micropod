# Micropod agent skill

The canonical skill now lives at
[`plugins/micropod/skills/micropod/SKILL.md`](../../plugins/micropod/skills/micropod/SKILL.md)
so it can ship inside the Claude Code plugin instead of floating in docs.

## Install routes

- **Claude Code plugin (recommended)** — this repo is a plugin marketplace:
  ```
  /plugin marketplace add castlemilk/micropod
  /plugin install micropod@micropod
  ```
  Installing the plugin registers the `micropod` MCP server (32 tools) and
  adds the skill automatically.
- **`scripts/install.sh`** — installs Micropod.app, `micropod-mcp`,
  `micropod`, and copies the skill to `~/.claude/skills/micropod`.
- **Any agent** — copy `plugins/micropod/skills/micropod/` into your agent's
  skills directory (`.devin/skills/`, `.cursor/skills/`, `~/.claude/skills/`…)
  and register the MCP server with `command: micropod-mcp` (installed to
  `~/.local/bin/`).

## What's in it

- All 32 MCP tools grouped by domain (containers, images, volumes, networks,
  compose, shared mounts, build cache, system/update).
- The Connect API contract — six `micropod.v1` domain services at
  `/api/micropod.v1.<Service>/<Method>` — plus the `/v1/*` REST facade and
  the Docker Engine shim for unmodified docker clients (incl. real
  Testcontainers/Ryuk).
- SDK quickstarts (TypeScript/Go/Swift) and the measured-at-scale notes:
  ~0.9–1.0 s micro-VM boot floor, ~330 MB host RSS per container, fleet
  sizing (cores ÷ 2), SIGTERM/disk-hygiene gotchas.
