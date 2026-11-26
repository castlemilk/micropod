# Phase B6: Production-Grade Hardening & Live Qualification Results (2026-11-25)

**Host**: Gamma (Apple Silicon M5 Max, macOS 26.5, quiet host)
**Kernel**: `7.3.5-micropod-b5` (`idle_poll_us=150`, 16 KiB pages + Stage-2 `HV_IPA_GRANULE_16KB`)
**Receipts**:
- Production qualification (all 7 gates): `phase-b6-production-qualification.json`
- Snapshot-fork regression check: `phase-b6-snapshot-fork-check.json`

---

## Summary of Production Hardening Changes

1. **Host↔Guest Control Channel (`VSOCK_PORT_CTRL = 2379`) — Graceful Shutdown & Live Wall-Clock Sync**:
   - Added [`vmm/crates/vmm-core/src/ctrl.rs`](../../../vmm/crates/vmm-core/src/ctrl.rs) and wired `VSOCK_PORT_CTRL = 2379` into `vmm-core` + `vmm/guest-init` (`ctrl.go`, `main.go`, `boot_clock_linux_arm64.go`).
   - **Graceful `SIGTERM`/`SIGINT` guest flush**: first `SIGTERM`/`SIGINT` pushes `POWEROFF\n` over port `2379` (`guest-init` signals `start.sh` -> stops `containerd`, `service`, `job engine` -> reaps children -> `sync(2)` -> detaches Virtio-FS shares -> remounts `/` read-only -> `PSCI_SYSTEM_OFF`), falling back to hard `hv_vcpus_exit` only after a 3 s deadline or on a second `SIGTERM`/`SIGINT`.
   - **Live post-restore & lid-sleep UTC wall-clock resync**: `VirtioVsock::snapshot_pause` records active `(host_port, guest_port)` streams and `snapshot_restore` emits `VIRTIO_VSOCK_OP_RST` for stale pre-snapshot streams so `guest-init` immediately reconnects to port `2379` and receives `CLOCK <unix_ns>\n` (`SYS_CLOCK_SETTIME`), plus host watchdog detects >500 ms wall-vs-monotonic jumps (macOS lid sleep/wake or NTP steps).

2. **Memory-Safe Deterministic Shutdown Teardown (Fixed Live `SIGSEGV -11` Race)**:
   - Live Gate 1 qualification exposed a real shutdown use-after-free race where `hv_vm_destroy()` and `hv_vm_deallocate()`/`munmap()` could execute while `_watchdog` or background Virtio I/O threads still held `GuestMemory`.
   - Every async Virtio backend (`VirtioBlk`, `VirtioFs`, `VirtioVsock`, `VirtioNetEgress`, `VirtioNetBridge`) now stores and joins all worker `JoinHandle`s in `Drop` (plus `VirtioBlk` flushes on drop), and `vmm-core` wraps the watchdog in an RAII `WatchdogGuard` so all vCPU, watchdog, and I/O threads exit strictly before `hv_vm_destroy()` / RAM deallocation.

3. **Dynamic Host DNS Reload, Failover & DNS FD Hygiene (`vmm-net/src/egress.rs`)**:
   - Replaced one-shot startup DNS discovery with `DnsResolverState`: checks `/etc/resolv.conf` `mtime` every 2 s (and immediately refreshes on `VirtioNetEgress::snapshot_restore`), parses deduplicated multi-resolver lists, re-connects cached DNS UDP sockets if upstream IP changes, rotates to fallback resolvers on timeout, and reaps completed DNS UDP sockets after 5 s (preventing FD buildup under burst resolution).

4. **Snapshot Format v2 Integrity, Topology Validation & Cross-Workspace Fork Safety**:
   - Upgraded `VmSnapshot` (`vmm-core/src/snapshot.rs`) to `SNAPSHOT_VERSION = 2` with `host_os_version` (`kern.osversion`), `created_unix_secs`, trailing IEEE CRC32 integrity checksum, strict trailing-byte/vCPU checks, pre-VM `ram.bin` size verification, and per-slot `device_id` validation on restore.
   - Updated `VirtioFs::snapshot_restore` so mutable workspace shares skip phantom nodes absent in a fork's new host directory (avoiding stale `nodeid` collisions while preserving live host-inode validation).

5. **Managed Swift Runtime (`HVFWorker.swift`) & Release Packaging (`scripts/package_app.sh`)**:
   - Added validated `idle_poll_us` (`0...2000`, default `150`) to `HVFKernelArguments` and optional `restoreFrom`/`snapshotOut` arguments to `HVFWorkerLaunchSpec`.
   - Extended `CIWorker.resolveHVFPaths()` to discover `mp-hvf-init.cpio` at both sibling `<binDir>/mp-hvf-init.cpio` and `.app` bundle `<binDir>/../Resources/mp-hvf-init.cpio`.
   - Wired `micropod-vmm` (codesigned with `vmm/entitlements.plist` + `codesign --verify --strict`) and `mp-hvf-init.cpio` bundling into `scripts/package_app.sh`.

---

## Live Gamma Qualification Matrix (`phase-b6-production-qualification.json`)

| Gate | Check | Measured Result | Status |
| :--- | :--- | :--- | :---: |
| **Gate 1** | Graceful `SIGTERM` guest flush + ext4 persistence across reboot | `exit_reason="poweroff"` in **`46.1 ms`**, cold boot `274.6 ms`, reboot `204.3 ms`, persisted container intact | **PASS** |
| **Gate 2** | Post-restore UTC clock resync after 5.0 s pause + live TLS HTTPS | Clock jumped `+4.9 s` past snapshot (`0.335 s` vs host UTC, exact integer second), `https://cloudflare.com/cdn-cgi/trace` OK | **PASS** |
| **Gate 3** | Cross-workspace snapshot fork rebinding + 4/4 POSIX host-edit visibility | Isolated `fork-content\|only-in-fork\|ABSENT`; 4/4 visibility (`size` `37.3 ms`, `held` `16.2 ms`, `replace` `16.7 ms`, `unlink` `36.7 ms`) | **PASS** |
| **Gate 4** | Snapshot corruption & topology mismatch rejection | Bit-flip `CRC32`, missing `--published-net` count mismatch, and swapped slot `device_id` all rejected pre-vCPU | **PASS** |
| **Gate 5** | `eth0` egress isolation + 200-query UDP DNS churn FD hygiene | `127.0.0.1` & `169.254.169.254` blocked; **200/200** DNS OK; host FDs `25 -> 225 -> 24` (**`delta -1`**) | **PASS** |
| **Gate 6** | 24-way concurrency, cgroup OOM, published TCP, idle CPU, fork poweroff | **24/24** in `517.6 ms`; `OOMKilled=true (137)`; published TCP OK; idle host CPU `1.66%`; fork `poweroff` in `49.8 ms` | **PASS** |
| **Gate 7** | Signed VMM binary & matching initrd readiness | `codesign --verify --strict` OK, `com.apple.security.hypervisor` present, `2.1 MiB` Linux arm64 initrd | **PASS** |

## Snapshot-Fork Regression Check (`phase-b6-snapshot-fork-check.json`)

| Metric | Phase B5 Baseline | Phase B6 Hardened | Delta |
| :--- | :---: | :---: | :---: |
| Snapshot save (VMM / wall) | `166.3 / 178.3 ms` | **`121.1 / 160.9 ms`** | Faster (`v2` + CRC32) |
| Serial fork -> Docker `/_ping` (median) | `10.68 ms` (`10.07–11.53`) | **`10.62 ms`** (`10.00–12.69`) | Preserved |
| Serial fork -> first live container (median) | `126.1 ms` | **`109.4 ms`** | -13.2% |
| 5× Parallel CoW fan-out total wall | `184.7 ms` | **`154.0 ms`** | -16.6% |
| Host RSS per 4 GiB fork (median) | `124.7–125.7 MiB` | **`122.7–123.2 MiB`** | Preserved |
| CoW disk isolation & graceful teardown | 5/5 isolated | **5/5 isolated, 0 crashes** | Preserved |
