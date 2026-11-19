# Reconciled implementation roadmap

This roadmap replaces the assumption that Micropod is a new runtime project. It links all **86 original research rows** to the actual code and current work owners. The first filing created **40 issues, #136–175**, not 20. Several aliases diverge from the original report; GitHub issue numbers are the stable work identities. No runtime change or measured speedup is claimed by this reconciliation.

[Research index](README.md) · [Existing state](existing-state.md) · [Craft investigation](craft-anything-investigation.md) · [Rust evaluation](rust-anything-buildout.md) · [Benchmark plan](benchmark-plan.md) · [Machine-readable crosswalk](roadmap-crosswalk.json)

## How to use the backlog

The original research IDs are retained for traceability. They are not a one-to-one key into the filed issues. For example, original **MACH-004** means Fedora/RHEL support, while filed **#157 / MACH-004** means machine CLI. Original **FS-004** means guest filesystem RPC, while **#163 / FS-004** means metadata caching. Original **NET-003** means port-event discovery, while **#175 / NET-003** means host gateway. The crosswalk below resolves these explicitly.

The 40 existing issues receive source-backed replacement scopes and concrete acceptance criteria, with their original descriptions retained as historical context. Dispositions are **25 extend/qualify, 14 gated experiments/designs, and one duplicate (#162 → #93)**. “Gate” remains open: it does not mean implemented or approved to deploy. Source-unaware estimates in the original descriptions are superseded; re-estimate after architecture and baseline evidence resolve the actual delta.

Fourteen focused issues cover the audit tracker, the two tool workflows, measurement, architectural choice and uncovered product gaps. Related original rows are consolidated when they share one implementation and acceptance boundary; all remain individually traceable below. This avoids refiling already implemented CLI/UI/runtime foundations or assigning another owner to active update work.

## Phases and exit criteria

| Phase | Work | Exit evidence |
|---|---|---|
| 0. Correctness and current ownership | #179 readiness; #93 notifications; #66 exits; active #135/#176/#177/#178; docs and source identity | Correct outcomes, exact source/installed receipts, no duplicate owner or false completion |
| 1. Evidence and benchmark validity | #181 Craft investigation, #182 harness repairs, #191 diagnostics identity | Versioned behavior matrix, raw samples, equivalent semantics, reliable failure accounting |
| 2. Improve current developer workflows | #147–149 shim/context/Buildx, #160–167 files, #173–175 networking, #185–190 integrations | End-to-end Docker/Compose/files/ports/k3s/SSH journeys pass on supported Mac configurations |
| 3. Decide shared-kernel development | #183, then gated #136–146 and #154–159 as justified | ADR with measured density/resource benefit, explicit trust domain and retained isolated profile |
| 4. Selective optimization | #184 Rust candidate, #142 reclaim, #163/#166 FS, profile-driven network changes | Matched end-to-end improvement with no correctness/latency/resource regression; reversible adoption |
| 5. Persistent product qualification | #168–172 storage, #187 cluster data, #89/#90/#178 release path, #192 migration | Interrupted operation recovery, data integrity, compatibility, signed installed receipts and repeatable comparison |

Phases express dependencies, not a calendar or a requirement to hold independent small fixes. #179 can proceed immediately. A shared-kernel architecture or Rust experiment may end with a documented no-go; that is a valid result.

## Newly scoped issues

| Issue | Scope | Priority |
|---|---|---|
| [#180](https://github.com/castlemilk/micropod/issues/180) | [Roadmap] Reconcile OrbStack parity with existing Micropod implementation | P0 |
| [#183](https://github.com/castlemilk/micropod/issues/183) | [Architecture] Decide optional shared-kernel mode and preserve isolated VM guarantees | P0 |
| [#181](https://github.com/castlemilk/micropod/issues/181) | [Research] Capture versioned OrbStack behavior with Craft Anything | P0 |
| [#182](https://github.com/castlemilk/micropod/issues/182) | [Performance] Extend existing harness for fair OrbStack comparisons and regression gates | P0 |
| [#184](https://github.com/castlemilk/micropod/issues/184) | [Performance] Evaluate one profiled Go unit with rust-anything before adopting Rust | P1 |
| [#179](https://github.com/castlemilk/micropod/issues/179) | [Kubernetes] Parse node conditions instead of matching Ready inside NotReady | P0 |
| [#187](https://github.com/castlemilk/micropod/issues/187) | [Kubernetes] Separate stop from reset and preserve cluster data across lifecycle changes | P1 |
| [#188](https://github.com/castlemilk/micropod/issues/188) | [Kubernetes] Qualify existing networking, ingress, image and storage integration | P1 |
| [#185](https://github.com/castlemilk/micropod/issues/185) | [Networking] Add lifecycle local domains and qualify macOS resolver/proxy integration | P1 |
| [#186](https://github.com/castlemilk/micropod/issues/186) | [Networking] Provide opt-in local HTTPS with owned certificates and service routing | P1 |
| [#189](https://github.com/castlemilk/micropod/issues/189) | [Machines] Add versioned SSH access and opt-in agent forwarding to selected machines | P1 |
| [#190](https://github.com/castlemilk/micropod/issues/190) | [Product] Qualify existing CLI and native UI against the reconciled capability matrix | P1 |
| [#191](https://github.com/castlemilk/micropod/issues/191) | [Diagnostics] Reconcile runtime identity, resource metrics and redacted support evidence | P1 |
| [#192](https://github.com/castlemilk/micropod/issues/192) | [Compatibility] Import selected Docker Desktop images and volumes with verified recovery | P2 |

## Original research crosswalk — all 86 items

“Exists” means code was found at the pinned audit commit. It does not certify the installed release, hardware support or performance. A row linked to an existing open PR remains open work until its own review and qualification complete.

### VIRT

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **VIRT-001** — Define VM backend interface | [#136](https://github.com/castlemilk/micropod/issues/136) | **Existing interfaces; extension needed.** Retain RuntimeEngine, EngineRegistry and RuntimeServices; distinguish execution engine, VM topology and native/CLI/managed-gateway transport. Specify capability, ownership, state and failure behavior for any optional shared-kernel engine. |
| **VIRT-002** — vfkit prototype backend | [#137](https://github.com/castlemilk/micropod/issues/137) | **Direct Swift VZ exists; optional reference experiment.** Keep open only as a bounded external reference experiment. Micropod already boots direct Swift VZ sandbox VMs; vfkit is not a prerequisite or a proposed production dependency. |
| **VIRT-003** — Native Swift VZ backend | [#138](https://github.com/castlemilk/micropod/issues/138) | **Native Swift VZ implemented in sandbox.** Extend SandboxVM and existing ownership/cleanup machinery only where the chosen topology requires it. Preserve direct VZ and Apple Containerization integration rather than building another boot path. |
| **VIRT-004** — Build minimal ARM64 kernel | [#139](https://github.com/castlemilk/micropod/issues/139) | **Apple kernel consumed; custom build absent.** Make custom kernel ownership conditional on a required guest feature or a measured boot/footprint improvement. Current SandboxVM already consumes the installed Apple kernel and sets boot optimization arguments. |
| **VIRT-005** — Tiny guest init | [#140](https://github.com/castlemilk/micropod/issues/140) | **Apple vminitd exists; shared supervisor absent.** Reuse the pinned Apple vminitd contract for current VMs. Design additional guest supervision only for a selected shared-kernel/system-distribution mode, including its service and trust boundaries. |
| **VIRT-006** — vsock control protocol | [#141](https://github.com/castlemilk/micropod/issues/141) | **Guest gRPC/vsock and duplex bridge implemented.** Extend the existing vminitd gRPC client, generated protocols and vsock bridge with explicit compatibility, authorization, cancellation and bounded lifecycle behavior. Coordinate abandoned unary-call handling with PR #176. |
| **VIRT-007** — Memory balloon/reclaim experiments | [#142](https://github.com/castlemilk/micropod/issues/142) | **Per-VM limits exist; reclaim controls unqualified.** Investigate supported Virtualization.framework and Containerization reclaim controls rather than assuming ballooning exists. Separate configured capacity, guest RSS/page cache and actual host physical footprint. |
| **VIRT-008** — Rosetta integration | [#143](https://github.com/castlemilk/micropod/issues/143) | **Automatic Rosetta selection implemented.** Turn existing native automatic Rosetta selection into a supported compatibility and performance matrix across CLI, API, shim and build paths. |
| **VIRT-009** — Intel VZ compatibility | [#144](https://github.com/castlemilk/micropod/issues/144) | **ARM-specific sandbox; Intel support not qualified.** Resolve product and dependency feasibility before promising Intel execution. Package requires macOS 26 and SandboxVM selects ARM kernel/init paths; translation support does not establish Intel host support. |
| **VIRT-010** — Dedicated isolated-VM mode | [#145](https://github.com/castlemilk/micropod/issues/145) | **Isolated sandbox VM already implemented.** Preserve and qualify the current per-sandbox VM boundary while defining any shared-kernel alternative. Treat dedicated macOS service-account isolation as a separate layer. |
### RUN

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **RUN-001** — Bundle/version Moby, containerd and runc | [#146](https://github.com/castlemilk/micropod/issues/146) | **New daemon stack only relevant to selected shared engine.** Keep the default Apple and sandbox engines independent of a new Moby/containerd/runc bundle. Scope guest Docker integration to an explicitly selected optional shared-kernel engine. |
| **RUN-002** — Forward Docker Unix socket to macOS | [#147](https://github.com/castlemilk/micropod/issues/147) | **Docker Unix socket and shim implemented.** Harden the existing shim and Unix socket instead of creating them again. Maintain deliberate Apple-engine routing to prevent loops through the external Docker adapter. |
| **RUN-003** — Docker context installer | [#148](https://github.com/castlemilk/micropod/issues/148) | **DOCKER_HOST documented; reversible installer absent in reviewed paths.** Install and select an opt-in Docker context for the existing shim socket without taking over other runtime contexts. |
| **RUN-004** — BuildKit integration | [#149](https://github.com/castlemilk/micropod/issues/149) | **Legacy build delegation exists; Buildx session gap.** Preserve current POST /build and context caching while choosing and implementing a complete builder/session strategy. Current shim requires the legacy Docker build path and does not proxy Buildx gRPC sessions. |
| **RUN-005** — containerd image store mode | [#150](https://github.com/castlemilk/micropod/issues/150) | **Apple image store exists; optional containerd mode absent.** Scope containerd storage to an optional selected engine and explicit interoperability requirements rather than replacing the existing Apple image store by default. |
| **RUN-006** — registry credential bridge | [#151](https://github.com/castlemilk/micropod/issues/151) | **Registry operations exist; helper interoperability unqualified.** Extend existing registry list/login/logout ownership and investigate Apple and Docker helper APIs before introducing another credential store. |
| **RUN-007** — lazy service activation | [#152](https://github.com/castlemilk/micropod/issues/152) | **Durable lifecycle and manual-stop state exist.** Integrate demand-driven startup with existing lifecycle, maintenance and admission state. A read such as docker ps must not override an explicit user stop. |
| **RUN-008** — direct containerd/nerdctl profile | [#153](https://github.com/castlemilk/micropod/issues/153) | **Existing engines independent of Docker; nerdctl profile absent.** Document current Apple/sandbox Docker independence and add a nerdctl profile only if it solves a concrete selected-engine need. |
### MACH

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **MACH-001** — System-container supervisor | [#154](https://github.com/castlemilk/micropod/issues/154), [#183](https://github.com/castlemilk/micropod/issues/183) | **New architecture; gated.** Optional shared-kernel supervisor after the trust-domain ADR; retain independent-VM mode. |
| **MACH-002** — Ubuntu/Debian rootfs importer | [#155](https://github.com/castlemilk/micropod/issues/155) | **Generic machine creation exists; distro profiles incomplete.** Verified Ubuntu/Debian rootfs import, provenance, init, users and package management. |
| **MACH-003** — Alpine/OpenRC support | [#156](https://github.com/castlemilk/micropod/issues/156) | **Profile qualification remains.** Alpine/OpenRC qualification; the filed issue additionally includes Arch, which was not this original report row. |
| **MACH-004** — Fedora/RHEL-family support | [#155](https://github.com/castlemilk/micropod/issues/155), [#159](https://github.com/castlemilk/micropod/issues/159) | **Not lost; added as explicit profile decision.** Evaluate Fedora/RHEL-family image provenance, package manager and supported init/security policy; declare support or defer with evidence. Filed MACH-004 #157 is lifecycle, not this row. |
| **MACH-005** — UID/GID and home mapping | [#165](https://github.com/castlemilk/micropod/issues/165) | **Mapping qualification remains.** UID/GID, home and supplementary-group contract. Filed MACH-005 #158 is quota work. |
| **MACH-006** — Per-machine network namespace | [#154](https://github.com/castlemilk/micropod/issues/154), [#173](https://github.com/castlemilk/micropod/issues/173), [#74](https://github.com/castlemilk/micropod/issues/74) | **Existing VM networking; shared-distro namespace new.** Namespace/veth/IPAM ownership, deterministic ranges, collision recovery and API network selection. Filed MACH-006 #159 is init work. |
| **MACH-007** — CPU/RAM/process limits | [#158](https://github.com/castlemilk/micropod/issues/158) | **VM limits exist; shared cgroups new.** CPU/memory/pids/pressure controls and supervisor survival under peer pressure. |
| **MACH-008** — distro create/delete/clone | [#157](https://github.com/castlemilk/micropod/issues/157), [#172](https://github.com/castlemilk/micropod/issues/172) | **Machine CLI and disk clones exist.** Complete distro lifecycle/import/export and COW clone contract without duplicating current commands. |
| **MACH-009** — systemd/OpenRC/runit validation matrix | [#159](https://github.com/castlemilk/micropod/issues/159) | **Compatibility matrix incomplete.** systemd/OpenRC/runit support decision, user managers, shutdown/reboot and cgroup delegation. |
| **MACH-010** — privileged/kernel-feature compatibility suite | [#154](https://github.com/castlemilk/micropod/issues/154), [#145](https://github.com/castlemilk/micropod/issues/145) | **Gated compatibility/security lane.** Declare Docker-in-machine, VPN, eBPF and FUSE support per trust profile; no implicit privilege escalation. |
### FS

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **FS-001** — Mac→guest VirtioFS mounts | [#160](https://github.com/castlemilk/micropod/issues/160) | **Implemented; qualify.** Direct VirtioFS, SharedFS views and overlay semantics need distinct correctness and performance receipts. |
| **FS-002** — inotify/FSEvents correctness suite | [#93](https://github.com/castlemilk/micropod/issues/93), [#161](https://github.com/castlemilk/micropod/issues/161) | **Existing watcher and open defect owner.** Live notification loss/recovery, actual cross-boundary inotify and broader filesystem semantics; #162 is a duplicate, not the original FS-003 cache experiment. |
| **FS-003** — cache-mode experimentation | [#163](https://github.com/castlemilk/micropod/issues/163), [#167](https://github.com/castlemilk/micropod/issues/167) | **Capability/profile experiment.** Identify real cache knobs, coherent metadata and safe policy defaults before optimization. |
| **FS-004** — guest filesystem RPC | [#164](https://github.com/castlemilk/micropod/issues/164), [#141](https://github.com/castlemilk/micropod/issues/141) | **New reverse-filesystem transport.** Versioned authenticated guest filesystem operations, bounded requests, disconnect/replay and metadata semantics. Filed FS-004 #163 is a different cache issue. |
| **FS-005** — macOS `~/Product` filesystem frontend | [#164](https://github.com/castlemilk/micropod/issues/164) | **New mounted reverse view.** Finder/shell frontend, supported OS/install model and guest-root access policy. |
| **FS-006** — reverse-share metadata cache/invalidation | [#164](https://github.com/castlemilk/micropod/issues/164), [#163](https://github.com/castlemilk/micropod/issues/163) | **Depends on reverse view.** Reverse metadata invalidation and 50k-file traversal at correct consistency; filed FS-006 #165 is UID/path mapping. |
### STOR

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **STOR-001** — sparse VM data image creation | [#168](https://github.com/castlemilk/micropod/issues/168) | **Images and COW exist.** Capacity/accounting and optional shared-image topology; 8 TB logical size is not a requirement. |
| **STOR-002** — ext4 grow/discard/fstrim | [#169](https://github.com/castlemilk/micropod/issues/169), [#170](https://github.com/castlemilk/micropod/issues/170) | **Unqualified backend capabilities.** Safe online/offline grow and guest-to-host discard. Growth and reclamation are separate operations. |
| **STOR-003** — storage corruption/recovery tests | [#171](https://github.com/castlemilk/micropod/issues/171), [#172](https://github.com/castlemilk/micropod/issues/172) | **Recovery semantics incomplete.** Owned crash/interruption/fsync/corrupt-image recovery fixtures and documented consistency; filed STOR-003 #170 is TRIM. |
| **STOR-004** — APFS COW snapshots/clones | [#172](https://github.com/castlemilk/micropod/issues/172), [#171](https://github.com/castlemilk/micropod/issues/171) | **APFS cloning and disk checkpoints exist.** Disk/metadata atomicity, compatible rollback, quiescence and backup separation; filed STOR-004 #171 is backup. |
| **STOR-005** — ASIF evaluation | [#168](https://github.com/castlemilk/micropod/issues/168) | **Optional format evaluation.** ASIF versus existing RAW/APFS sparse/clones: framework/OS support, allocation, copy/move, migration and measured value; filed STOR-005 #172 is snapshots. |
### NET

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **NET-001** — Bootstrap NAT with gvproxy or equivalent | [#173](https://github.com/castlemilk/micropod/issues/173) | **NAT/vmnet implemented.** Qualify current backend before considering gvproxy or a replacement. |
| **NET-002** — Linux unified bridge/IPAM | [#173](https://github.com/castlemilk/micropod/issues/173), [#154](https://github.com/castlemilk/micropod/issues/154), [#74](https://github.com/castlemilk/micropod/issues/74) | **Existing subnet allocator; shared topology gated.** Shared engine bridge/IPAM design must not merge isolation domains; filed NET-002 #174 is port forwarding. |
| **NET-003** — Docker-event port listener | [#174](https://github.com/castlemilk/micropod/issues/174), [#147](https://github.com/castlemilk/micropod/issues/147) | **Events and published ports exist.** Lifecycle reconciliation for requested ports; distinguish automatic listener discovery. Filed NET-003 #175 is host gateway. |
| **NET-004** — TCP/UDP forwarder | [#174](https://github.com/castlemilk/micropod/issues/174) | **TCP forwarding exists; protocol gaps.** Sandbox UDP and IPv6 bind support/gating, bind defaults, churn, backpressure and recovery. |
| **NET-005** — custom high-throughput host path | [#173](https://github.com/castlemilk/micropod/issues/173), [#182](https://github.com/castlemilk/micropod/issues/182) | **Profile-first; no replacement mandated.** Custom packet path only if measured end-to-end benefit exceeds the retained baseline after correctness. |
| **NET-006** — host-resolver DNS proxy | [#185](https://github.com/castlemilk/micropod/issues/185) | **Host resolver qualification/new integration.** Scoped macOS/VPN/split DNS behavior; guest hosts files are not host DNS integration. |
| **NET-007** — automatic container/machine domains | [#185](https://github.com/castlemilk/micropod/issues/185) | **New host-side local domains.** Lifecycle-managed names and reconciliation with containers, machines and Kubernetes. |
| **NET-008** — macOS host-reachable container IPs | [#173](https://github.com/castlemilk/micropod/issues/173), [#74](https://github.com/castlemilk/micropod/issues/74) | **Existing addresses; qualify per engine.** Host-reachable direct IPs, fixed network selection, route/VPN collisions and denied reachability. |
| **NET-009** — proxy settings bridge | [#185](https://github.com/castlemilk/micropod/issues/185) | **Separate proxy integration.** HTTP/HTTPS/SOCKS/NO_PROXY support contract and safe change propagation; not the outbound secrets proxy. |
### TLS

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **TLS-001** — local CA and Keychain storage | [#186](https://github.com/castlemilk/micropod/issues/186) | **New integrated local HTTPS.** Owned CA/Keychain, scoped certificate issuance and reverse routing are checklists in one cohesive feature; unrelated sandbox CA is not parity. |
| **TLS-002** — service certificate issuer | [#186](https://github.com/castlemilk/micropod/issues/186) | **New integrated local HTTPS.** Owned CA/Keychain, scoped certificate issuance and reverse routing are checklists in one cohesive feature; unrelated sandbox CA is not parity. |
| **TLS-003** — reverse proxy and port discovery | [#186](https://github.com/castlemilk/micropod/issues/186) | **New integrated local HTTPS.** Owned CA/Keychain, scoped certificate issuance and reverse routing are checklists in one cohesive feature; unrelated sandbox CA is not parity. |
### KUBE

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **KUBE-001** — Integrate pinned K3s | [#179](https://github.com/castlemilk/micropod/issues/179), [#188](https://github.com/castlemilk/micropod/issues/188) | **k3s implemented; readiness defect.** Fix NotReady substring parsing, then qualify pinned cluster/components with complete readiness. |
| **KUBE-002** — host kubeconfig/context | [#187](https://github.com/castlemilk/micropod/issues/187), [#188](https://github.com/castlemilk/micropod/issues/188) | **Host kubeconfig implemented.** Preserve unrelated contexts and validate endpoint/certificate/address changes through persistent lifecycle. |
| **KUBE-003** — Kubernetes DNS/network bridge | [#188](https://github.com/castlemilk/micropod/issues/188) | **Networking components exist; qualify.** Pod/service/CoreDNS/host network fixtures and failure/restart receipts. |
| **KUBE-004** — LoadBalancer/Ingress host integration | [#188](https://github.com/castlemilk/micropod/issues/188), [#185](https://github.com/castlemilk/micropod/issues/185), [#186](https://github.com/castlemilk/micropod/issues/186) | **MetalLB/Traefik exist; domain/TLS gap.** Join existing ingress to local DNS/HTTPS with owned ports and backend support. |
| **KUBE-005** — local-path storage + Mac bind mounts | [#187](https://github.com/castlemilk/micropod/issues/187), [#188](https://github.com/castlemilk/micropod/issues/188), [#160](https://github.com/castlemilk/micropod/issues/160) | **Durable cluster contract incomplete.** Persistent data/PVC lifecycle plus qualified Mac bind semantics; current down deletes state. |
| **KUBE-006** — Kubernetes GUI objects/logs | [#190](https://github.com/castlemilk/micropod/issues/190) | **Kubernetes UI scope to qualify/extend.** Reuse native resource UI; add honest pod/service/ingress/storage/log journeys where absent. |
| **KUBE-007** — kind/multi-node compatibility | [#188](https://github.com/castlemilk/micropod/issues/188) | **Optional unqualified capability.** Two/three-node kind lane is a separate go/no-go; single-node k3s is not this acceptance. |
### CLI

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **CLI-001** — CLI command model | [#190](https://github.com/castlemilk/micropod/issues/190), [#157](https://github.com/castlemilk/micropod/issues/157) | **Substantial CLI exists.** Stable output/error/capability model across current engines; extend missing operations only. |
| **CLI-002** — machine shell/exec | [#157](https://github.com/castlemilk/micropod/issues/157), [#190](https://github.com/castlemilk/micropod/issues/190), [#66](https://github.com/castlemilk/micropod/issues/66) | **Machine execution exists.** Preserve cwd/env/TTY/signals/known exits, existing shim exit-status issue retains ownership. |
### SSH

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **SSH-001** — built-in SSH proxy | [#189](https://github.com/castlemilk/micropod/issues/189) | **Dedicated SSH integration gap.** Machine identity, transport, OpenSSH config ownership and host keys. |
| **SSH-002** — SSH-agent forwarding | [#189](https://github.com/castlemilk/micropod/issues/189) | **Opt-in integration gap.** Scoped forwarding lifetime and agent revocation; no key copying. |
### GUI

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **GUI-001** — native SwiftUI menu/status app | [#190](https://github.com/castlemilk/micropod/issues/190) | **Native UI exists; qualify/extend.** Source/UI journey matrix, honest runtime state, bounded logs and measured idle polling; do not rebuild the app. |
| **GUI-002** — container/image/volume browser | [#190](https://github.com/castlemilk/micropod/issues/190) | **Native UI exists; qualify/extend.** Source/UI journey matrix, honest runtime state, bounded logs and measured idle polling; do not rebuild the app. |
| **GUI-003** — terminal/log viewer | [#190](https://github.com/castlemilk/micropod/issues/190) | **Native UI exists; qualify/extend.** Source/UI journey matrix, honest runtime state, bounded logs and measured idle polling; do not rebuild the app. |
### PKG

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **PKG-001** — signed/notarised `.pkg`/app bundle | [#89](https://github.com/castlemilk/micropod/issues/89), [#190](https://github.com/castlemilk/micropod/issues/190) | **Existing signed release pipeline.** Keep completed managed installation closed; link exact signed release and fresh-host receipt in capability docs, not another installer implementation. |
| **PKG-002** — first-run entitlement/helper setup | [#89](https://github.com/castlemilk/micropod/issues/89), [#190](https://github.com/castlemilk/micropod/issues/190) | **Managed setup completed in existing owner.** Preserve #89 final acceptance; qualify changed first-run flows through existing release workflow. |
### UPD

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **UPD-001** — atomic application updater | [#90](https://github.com/castlemilk/micropod/issues/90), [#178](https://github.com/castlemilk/micropod/pull/178) | **Existing continuity owner and open component PR.** Application continuity acceptance remains #90; PR #178 component update is not merged/installed proof. |
| **UPD-002** — guest component A/B update | [#180](https://github.com/castlemilk/micropod/issues/180), [#90](https://github.com/castlemilk/micropod/issues/90), [#178](https://github.com/castlemilk/micropod/pull/178) | **Partial; guest A/B rollback not established.** Track explicit guest kernel/init/rootfs compatibility and last-known-good boot semantics after current component-update work. Do not equate helper rollback with full guest A/B recovery. |
### MIG

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **MIG-001** — Docker Desktop migration importer | [#192](https://github.com/castlemilk/micropod/issues/192) | **Complete migration workflow not found.** Selected verified image/volume import, capacity/checksum/consistency and recoverable staging. |
### OBS

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **OBS-001** — structured host/guest logging | [#191](https://github.com/castlemilk/micropod/issues/191) | **Collectors/logs exist; end-to-end evidence incomplete.** Inventory and extend correlation, precise resource accounting, component identity and redacted support bundles. |
| **OBS-002** — CPU/RAM/disk/network metrics | [#191](https://github.com/castlemilk/micropod/issues/191) | **Collectors/logs exist; end-to-end evidence incomplete.** Inventory and extend correlation, precise resource accounting, component identity and redacted support bundles. |
| **OBS-003** — diagnostic bundle with redaction | [#191](https://github.com/castlemilk/micropod/issues/191) | **Collectors/logs exist; end-to-end evidence incomplete.** Inventory and extend correlation, precise resource accounting, component identity and redacted support bundles. |
### SEC

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **SEC-001** — threat model | [#183](https://github.com/castlemilk/micropod/issues/183) | **Architecture gate.** Trust-domain threat model and invariants for current and optional shared engines. |
| **SEC-002** — authenticated vsock RPC | [#141](https://github.com/castlemilk/micropod/issues/141) | **Existing vsock; authorization qualification.** Versioned capability, per-VM identity, bounded messages, replay/cancellation and unauthorized request tests. |
| **SEC-003** — host mount policy | [#160](https://github.com/castlemilk/micropod/issues/160), [#165](https://github.com/castlemilk/micropod/issues/165) | **Mount validation exists; qualify.** Explicit allowed roots, read-only policy, ownership and path/symlink escape behavior. |
| **SEC-004** — system-container capability/seccomp profile | [#154](https://github.com/castlemilk/micropod/issues/154), [#183](https://github.com/castlemilk/micropod/issues/183) | **New shared-mode controls.** Capability/seccomp/cgroup/device policy with shared-kernel limitation stated. |
| **SEC-005** — isolated-VM security profile | [#145](https://github.com/castlemilk/micropod/issues/145) | **Independent microVM already exists.** Qualify existing default mount/network/agent/secrets grants and isolation; dedicated host account is another boundary. |
### BENCH

| Original ID and scope | Current owner(s) | Source disposition and remaining work |
|---|---|---|
| **BENCH-001** — benchmark schema/runner | [#182](https://github.com/castlemilk/micropod/issues/182) | **Harness exists; extend and repair.** See the distinct suite/checklist in benchmark-plan.md; all raw receipts required before complete coverage or superiority claims. |
| **BENCH-002** — OrbStack/Colima/Docker/Rancher adapters | [#182](https://github.com/castlemilk/micropod/issues/182) | **Harness exists; extend and repair.** See the distinct suite/checklist in benchmark-plan.md; all raw receipts required before complete coverage or superiority claims. |
| **BENCH-003** — start/runtime/idle suite | [#182](https://github.com/castlemilk/micropod/issues/182) | **Harness exists; extend and repair.** See the distinct suite/checklist in benchmark-plan.md; all raw receipts required before complete coverage or superiority claims. |
| **BENCH-004** — filesystem suite | [#182](https://github.com/castlemilk/micropod/issues/182) | **Harness exists; extend and repair.** See the distinct suite/checklist in benchmark-plan.md; all raw receipts required before complete coverage or superiority claims. |
| **BENCH-005** — networking suite | [#182](https://github.com/castlemilk/micropod/issues/182) | **Harness exists; extend and repair.** See the distinct suite/checklist in benchmark-plan.md; all raw receipts required before complete coverage or superiority claims. |
| **BENCH-006** — BuildKit suite | [#182](https://github.com/castlemilk/micropod/issues/182) | **Harness exists; extend and repair.** See the distinct suite/checklist in benchmark-plan.md; all raw receipts required before complete coverage or superiority claims. |
| **BENCH-007** — Kubernetes readiness suite | [#182](https://github.com/castlemilk/micropod/issues/182) | **Harness exists; extend and repair.** See the distinct suite/checklist in benchmark-plan.md; all raw receipts required before complete coverage or superiority claims. |
| **BENCH-008** — power/energy suite | [#182](https://github.com/castlemilk/micropod/issues/182) | **Harness exists; extend and repair.** See the distinct suite/checklist in benchmark-plan.md; all raw receipts required before complete coverage or superiority claims. |

## Additional obligations consolidated into existing issues

- **#155 / #159:** Preserve the original Fedora/RHEL-family and runit compatibility decisions, rather than losing them behind the changed machine aliases. A deferred distribution must have a reason and a documented support boundary.
- **#164:** Own both guest filesystem RPC and the mounted reverse frontend. Include event-driven metadata invalidation, batch/bulk I/O, per-root authorization and a 50k-file traversal fixture; a UI file browser is not a mounted filesystem.
- **#168:** Own the optional ASIF versus current RAW/APFS evaluation. No format migration is required without capability, recovery and measured-benefit evidence.
- **#171 / #172:** Cover storage corruption/interrupted fsync/checkpoint recovery, not only successful cloning. An APFS clone is not a portable backup or complete running-VM snapshot.
- **#173 / #174:** Preserve shared-engine IPAM, direct-IP qualification and event-driven forward reconciliation. A new packet service is gated on a measured bottleneck, not an assumption that existing NAT is missing.
- **#180 with #90 / PR #178:** Keep original guest A/B update requirements explicit. The open component updater's helper rollback does not by itself establish last-known-good kernel/init/rootfs boot recovery or compatible cluster datastore rollback. Scope that remaining delta after the existing owner lands and qualifies its current contract.

## Evidence and completion rules

An issue closes with the specified implementation and qualification evidence, or an explicit documented no-go/unsupported decision where the issue is a capability experiment. No issue is marked implemented from this audit alone. Record source SHA, installed component identity, test environment, first-attempt outcomes and limitations. Benchmark gates are detailed in [benchmark-plan.md](benchmark-plan.md); tool-specific limits and staged commands are in the two runbooks.

Existing owners remain authoritative: [#89 completed installation](https://github.com/castlemilk/micropod/issues/89), [#90 workload continuity](https://github.com/castlemilk/micropod/issues/90), [#93 live notifications](https://github.com/castlemilk/micropod/issues/93), [#66 exit status](https://github.com/castlemilk/micropod/issues/66), [#74 network selection](https://github.com/castlemilk/micropod/issues/74), and open PRs [#193](https://github.com/castlemilk/micropod/pull/193), [#131](https://github.com/castlemilk/micropod/pull/131), [#135](https://github.com/castlemilk/micropod/pull/135), [#176](https://github.com/castlemilk/micropod/pull/176), [#177](https://github.com/castlemilk/micropod/pull/177), [#178](https://github.com/castlemilk/micropod/pull/178). PR author-reported tests and measurements are attributed, not rerun here.

Final refresh: [PR #193](https://github.com/castlemilk/micropod/pull/193) is stacked on #178 and proposes the stopped-runtime recovery contract. Treat it as active unmerged work; retain its paired rollout and physical qualification gates.
