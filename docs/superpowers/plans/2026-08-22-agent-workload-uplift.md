# Micropod Agent Workload Uplift Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Micropod's existing container UI agent-aware, cache-aware, and honest about launch progress without introducing a new backend model.

**Architecture:** Add small, pure helpers in `MicropodCore` for workload labels, launch parsing, and image-reference matching. Reuse those helpers in the existing SwiftUI dashboard, container list, and run sheet, and reuse the existing operation registry for tracked launches.

**Tech Stack:** Swift 6.2, SwiftUI, Observation, Swift Protobuf, XCTest, Apple `container` CLI.

---

## Chunk 1: Core behavior

### Task 1: Workload metadata and cache matching

**Files:**
- Create: `Sources/MicropodCore/Support/WorkloadMetadata.swift`
- Test: `Tests/MicropodCoreTests/WorkloadMetadataTests.swift`

- [ ] Write failing tests for exact Micropod/Cuttlefish agent labels, independent Compose/direct source classification, the Compose-agent overlap, label search, and normalized local-image matches.
- [ ] Run `rtk swift test --filter WorkloadMetadataTests` and confirm the missing-type failure.
- [ ] Implement the smallest public helpers that satisfy the tests.
- [ ] Re-run the focused test and confirm it passes.

### Task 2: Launch input parsing

**Files:**
- Create: `Sources/MicropodCore/Support/ContainerLaunchInput.swift`
- Test: `Tests/MicropodCoreTests/ContainerLaunchInputTests.swift`

- [ ] Write failing tests for optional CPU parsing, strict comma-separated ports, positive TTL validation, and agent label generation.
- [ ] Run `rtk swift test --filter ContainerLaunchInputTests` and confirm the missing-type failure.
- [ ] Implement strict parsers and label construction without adding a new model or persistence.
- [ ] Re-run the focused test and confirm it passes.

### Task 3: Observable bounded operations

**Files:**
- Modify: `Sources/MicropodCore/Support/OperationRegistry.swift`
- Modify: `Tests/MicropodCoreTests/OperationRegistryTests.swift`

- [ ] Add failing tests that observe registry mutation, accept a container-launch kind, and retain the newest 100 finished entries plus every running operation.
- [ ] Run `rtk swift test --filter OperationRegistryTests` and confirm the expected failures.
- [ ] Apply `@Observable`, add the launch kind, and prune old completed entries on begin.
- [ ] Re-run the focused test and confirm it passes.

## Chunk 2: SwiftUI integration

### Task 4: Track launch lifecycle

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/MicropodApp/AppDependencies.swift`
- Modify: `Sources/MicropodApp/AppStore.swift`
- Create: `Tests/MicropodAppTests/AppTestSupport.swift`
- Create: `Tests/MicropodAppTests/AppStoreLaunchTests.swift`

- [ ] Add the `MicropodAppTests` target and test-only mock CLI scaffolding, then write tests that reference the wished-for `AppDependencies(client:)` seam and tracked launch API.
- [ ] Run `rtk swift test --filter AppStoreLaunchTests` and confirm RED first at the missing initializer/API.
- [ ] Add the small injected-client initializer on `AppDependencies`, keep production defaults unchanged, and re-run until RED is the missing launch behavior rather than test setup.
- [ ] Add mock-CLI assertions for valid launch → succeeded operation + refreshed list + selected ID + success activity, rejected launch → failed operation + error activity + banner, newest-first activity projection, and task cancellation propagation.
- [ ] Replace the fire-and-forget run method with a registry-backed launch method.
- [ ] On success, refresh containers, select the returned ID, and record success; on failure, finish the operation, record failure, and surface the existing error state.
- [ ] Add a tested newest-first `recentActivity(limit:)` projection; defer view wiring to Task 7.
- [ ] Register the existing Compose stream task so its existing Cancel control propagates cancellation.
- [ ] Re-run `rtk swift test --filter AppStoreLaunchTests` and confirm it passes.

### Task 5: Uplift the launch sheet

**Files:**
- Modify: `Sources/MicropodCore/Support/WorkloadMetadata.swift`
- Modify: `Sources/MicropodCore/Support/ContainerLaunchInput.swift`
- Modify: `Tests/MicropodCoreTests/WorkloadMetadataTests.swift`
- Modify: `Tests/MicropodCoreTests/ContainerLaunchInputTests.swift`
- Modify: `Sources/MicropodApp/Views/RunContainerSheet.swift`

- [ ] Extend `WorkloadMetadataTests` with local-image present/absent normalization cases and `ContainerLaunchInputTests` with the exact invalid CPU/port/TTL cases projected by the sheet.
- [ ] Run both focused tests and confirm RED for the missing helper behavior.
- [ ] Implement the minimum Core helper behavior and re-run to GREEN before changing the view.
- [ ] Add a compact local-image preflight and locally present image menu.
- [ ] Add Agent workload fields backed by standard labels; state clearly that TTL is metadata-only and cleanup remains explicit.
- [ ] Put existing advanced controls in one disclosure.
- [ ] Use tested parsers for inline validation; keep invalid input in the sheet and submit valid input through the tracked launch method.
- [ ] Re-run the focused test and confirm it passes.

### Task 6: Surface agent workloads in Containers

**Files:**
- Modify: `Sources/MicropodCore/Support/WorkloadMetadata.swift`
- Modify: `Tests/MicropodCoreTests/WorkloadMetadataTests.swift`
- Modify: `Sources/MicropodApp/Views/ContainersView.swift`

- [ ] Extend the passing `WorkloadMetadataTests` with the exact Agents-filter and label-search projections used by the view.
- [ ] Run the focused test and confirm the new cases fail for the expected reason.
- [ ] Implement the minimum matching/classification helper behavior in `WorkloadMetadata.swift` and re-run to GREEN.
- [ ] Add the Agents filter, exact label-aware search, and compact independent Agent/source/job metadata.

### Task 7: Reorder the dashboard and expose local-image state

**Files:**
- Modify: `Sources/MicropodApp/AppStore.swift`
- Modify: `Sources/MicropodApp/Views/DashboardView.swift`
- Modify: `Sources/MicropodApp/Views/MenuBarPanelView.swift`
- Modify: `Tests/MicropodAppTests/AppStoreLaunchTests.swift`

- [ ] Add failing AppStore projection assertions for agent/workload counts, local image count + total stored bytes, and newest-first bounded activity.
- [ ] Run `rtk swift test --filter AppStoreLaunchTests` and confirm the projection failures.
- [ ] Implement the minimal AppStore projections used by both dashboard and menu-bar surfaces.
- [ ] Move workloads ahead of charts and render compact independent Agent/source/job metadata.
- [ ] Make Images read as local inventory with count and total stored bytes.
- [ ] Render recent activity through the tested newest-first projection in the dashboard and menu bar.
- [ ] Re-run `rtk swift test --filter AppStoreLaunchTests` and confirm it passes.

## Chunk 3: Verification

### Task 8: Validate behavior and presentation

**Files:**
- Modify only if needed for deterministic fixtures: `Tests/MicropodIntegrationTests/Support/mock-container`
- Test if fixture controls are added: `Tests/MicropodIntegrationTests/MockContainerControlTests.swift`
- Evidence: `docs/visuals/2026-08-22-micropod-dashboard-light.png`
- Evidence: `docs/visuals/2026-08-22-micropod-dashboard-dark.png`
- Evidence: `docs/visuals/2026-08-22-micropod-agents.png`
- Evidence: `docs/visuals/2026-08-22-micropod-launch-agent.png`
- Evidence: `docs/visuals/2026-08-22-micropod-uplift-validation.md`

- [ ] Run focused Core tests for the three new/changed behavior units.
- [ ] Run `rtk swift build`.
- [ ] Run `rtk swift test`.
- [ ] Run `rtk task lint` and `rtk task validate`.
- [ ] Create a fixture directory with `FIXTURE_DIR=$(mktemp -d /tmp/micropod-ui-XXXXXX)`, seed a local image and labelled agent with `MICROPOD_MOCK_STATE_DIR="$FIXTURE_DIR" Tests/MicropodIntegrationTests/Support/mock-container image pull alpine:latest` and `MICROPOD_MOCK_STATE_DIR="$FIXTURE_DIR" Tests/MicropodIntegrationTests/Support/mock-container run --detach --name agent-demo --label com.micropod.agent=true --label com.micropod.job=job-42 alpine:latest`.
- [ ] Launch with `MICROPOD_MOCK_STATE_DIR="$FIXTURE_DIR" MICROPOD_CONTAINER_CLI_PATH="$PWD/Tests/MicropodIntegrationTests/Support/mock-container" swift run MicropodApp` and record exact pass/fail observations for Agents filter + label search, local-image present/absent preflight, invalid CPU/port/TTL remaining in the sheet, valid launch → succeeded operation → selected labelled container, newest-first activity, and keyboard traversal.
- [ ] If the fixture lacks deterministic failure or delay controls, write `MockContainerControlTests.swift`, run `rtk swift test --filter MockContainerControlTests` to see RED, add `MICROPOD_MOCK_FAIL_RUN=1` and `MICROPOD_MOCK_COMPOSE_DELAY_SECONDS=<n>` branches, re-run to GREEN, then relaunch with those env vars and verify launch failure appears in drawer/activity/banner and Compose Cancel changes the task to cancelled.
- [ ] Record commands, fixture values, and exact pass/fail observations in `docs/visuals/2026-08-22-micropod-uplift-validation.md`.
- [ ] Capture dashboard in light and dark appearances plus one Agents-filter and one Launch-Agent screenshot at the four listed evidence paths.
- [ ] Compare the implementation against the approved design and record any remaining limitations without broadening scope.
