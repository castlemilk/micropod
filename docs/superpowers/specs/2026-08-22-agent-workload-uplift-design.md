# Micropod Agent Workload Uplift

## Outcome

Make Micropod feel like the fastest native way to launch and supervise Apple
containers, especially containers started by coding agents and worker systems.
The interface should answer three questions immediately: what is running, who
or what launched it, and whether the next launch is already cached locally.

## Considered approaches

1. **Derive agent workloads from container labels (recommended).** Reuse the
   existing container protobuf, list polling, image inventory, activity feed,
   and operation registry. This delivers the requested experience with no new
   daemon, persistence layer, or API entity.
2. **Add a first-class Agent service and protobuf.** This would support durable
   sessions and automated TTL cleanup, but duplicates the runtime's resource
   model and is too large for the requested concise uplift.
3. **Visual restyle only.** This would improve polish but leave launch progress,
   agent ownership, and cache readiness unclear.

Approach 1 is selected.

## Interaction design

### Workload-first dashboard

Keep the native sidebar and runtime controls. Move the workload list above
charts and secondary resource cards. Each row shows state, name, image, and a
small launch-source treatment: Compose or Direct. Agent status is independent,
so a Compose-launched agent can show both Compose and Agent. Agent rows may also
show job or owner metadata. The image summary reports local image count and
stored size using data Micropod already fetches.

### Agent-aware containers

Add an `Agents` segment to the existing All/Running/Stopped filter. Search
matches container names, image references, label keys, and label values. Rows
remain compact and sortable; agent/source context is a secondary line inside
the name cell instead of a new wide table or a separate navigation destination.

Agent classification is explicit: a container is an agent when
`com.micropod.agent == "true"` or `com.cuttlefish.job` has a non-empty value.
Job, owner, ephemeral, and TTL labels are metadata and do not independently
classify a container as an agent. Micropod-native labels are:

- `com.micropod.agent=true`
- `com.micropod.job=<job id>`
- `com.micropod.owner=<owner>`
- `com.micropod.ephemeral=true`
- `com.micropod.ttl-minutes=<positive integer>`

Existing workers remain visible as agents when they carry the exact supported
integration label `com.cuttlefish.job`. Arbitrary `*.job` labels are not
classified as agents.

### Fast launch sheet

The default sheet is short: image, optional name, local image presence, and an
Agent workload toggle. Locally present images are selectable from a menu. Agent mode
adds Job ID, Owner, Ephemeral, and optional TTL metadata. Existing resource,
environment, port, volume, platform, and entrypoint controls move under one
Advanced disclosure.

CPU, port, and TTL input is validated inline. TTL is tracking metadata only;
the UI must not claim automatic cleanup because Micropod has no reaper yet.

### Honest operations

Make the existing operation registry observable and bounded. The session-visible
drawer retains the newest 100 completed entries plus every active entry,
evicting the oldest completed entry first. A launch becomes
a tracked operation, reports success or failure to activity, refreshes the
container list, and selects the returned container ID. The sheet can dismiss
after valid submission because launch state remains visible in the session-visible
Operations drawer.

Recent activity is rendered newest-first. The existing Compose operation already
shows a Cancel control, so its task is registered with the same operation
registry to make that existing control truthful; no new Compose UI is added.

## Visual direction

Use the generated prototype as the layout target: native macOS title bars,
semantic materials, hairline separators, SF typography, monospaced technical
values, restrained blue, and green/orange only for semantic state. Avoid adding
marketing heroes, gradients, floating card grids, or decorative container art.
The one signature detail is the local-image preflight row in the launch sheet.

## Data flow

1. Existing polling refreshes containers and images.
2. Pure Core helpers classify workload source, extract agent metadata, match
   label-aware search, parse launch input, and normalize local image references.
3. SwiftUI projects those helpers into dashboard, table, and launch views.
4. Valid launch input becomes the existing `ContainerRunRequest` with labels.
5. `AppStore` registers the launch, runs the existing container service, then
   refreshes and selects the new container.

No protobuf or service API changes are required.

## Error handling

- Invalid CPU, port, or TTL input stays in the sheet with a concrete message.
- An image absent from the local inventory is described as requiring a pull;
  it is not an error and the UI does not claim layer-level cache certainty.
- Launch errors finish the operation as failed, stay visible in the drawer and
  activity feed, and populate the existing refresh-error banner.
- Empty/stopped runtime behavior continues to use existing safeguards.

## Testing

- Unit-test agent classification across Micropod and Cuttlefish labels, source
  classification across Compose/direct containers, and the overlap case where
  one workload is both an agent and Compose-launched.
- Unit-test label-aware search, launch parsing, generated labels, and image
  reference normalization/cache matching.
- Unit-test operation observability, launch kind, cancellation, and bounded
  history.
- Run the complete Swift unit/integration suite, app smoke, and lint.
- Launch the app and visually review dashboard, Agents filter, and launch sheet
  in both light and dark appearances where practical.

## Explicitly out of scope

- A durable Agent/Job database or new protobuf entity.
- Automatic TTL deletion/reaper behavior.
- New polling loops or higher stats frequency.
- Cache-layer internals, quotas, or BuildKit redesign.
- A separate Agents sidebar tab.
