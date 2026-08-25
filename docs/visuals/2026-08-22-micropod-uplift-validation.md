# Micropod agent/workload uplift validation

Validated on 2026-08-22 against the stateful `mock-container` fixture and the real macOS SwiftUI app.

## Automated gates

- `task validate`: passed.
  - Swift build passed.
  - 182 tests passed with 0 failures; 14 opt-in `MICROPOD_REAL_E2E=1` tests were skipped.
  - MCP end-to-end suite passed 19/19 checks.
  - App smoke passed: alive after six seconds of polling and terminated cleanly.
- `task lint`: passed.
- Focused launch/cache regressions passed:
  - `AppStoreLaunchTests`: 11/11.
  - `WorkloadMetadataTests`: 17/17.
  - `ContainerLaunchInputTests`: 10/10.
  - `ContainerCLIClientTests`: 7/7.
  - `ComposeServiceTests`: 12/12.
  - `OperationRegistryTests`: 10/10.

The tests cover exact agent-label classification, Direct/Compose independence, strict CPU/port/TTL parsing, canonical metadata labels, local tag/digest matching, stale inventory invalidation, attached and detached launch selection, operation retention/cancellation, and Compose producer cancellation.

## Real-window visual smoke

The app was launched with two local images, one canonical agent workload, and one Compose workload. The following captures were inspected manually:

- [Dashboard — Light](2026-08-22-micropod-dashboard-light.png)
- [Dashboard — Dark](2026-08-22-micropod-dashboard-dark.png)
- [Dashboard — inventory and disk usage](2026-08-22-micropod-dashboard-inventory.png)
- [Containers — Agents filter](2026-08-22-micropod-agents.png)
- [Launch — Agent workload](2026-08-22-micropod-launch-agent.png)

Verified visually: workload-first hierarchy, simultaneous Agent and Direct/Compose metadata, responsive row truncation, Agents filtering, local-image selection, “Present locally” preflight, agent metadata fields, explicit metadata-only TTL copy, and light/dark legibility.

## Prototype note

[The generated prototype](2026-08-22-micropod-agent-uplift-prototype.png) guided hierarchy, density, and native macOS styling. Its early “auto-remove after duration” wording is superseded by the implementation: TTL is metadata only and cleanup remains explicit. No reaper or automatic deletion was added.
