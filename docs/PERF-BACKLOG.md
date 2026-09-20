# Performance backlog

Prioritized follow-ups from the container-vs-Docker benchmarking and the
cuttlefish-on-micropod validation. Each item records the measured evidence
and the expected payoff so the next session can pick them up in order.
Status as of 2026-09-09 (Apple `container` v1.3.1, 18-core arm64).

## How to read the numbers

`task bench` = core runtime budgets (18/18 pass), `task bench-shim` =
shim-vs-Docker (`scripts/bench_shim_vs_docker.py` both sockets),
`task bench-compose` = postgres time-to-ready, `task ci` / `task ci-matrix` =
Go+Node pipelines with cache re-use assertions. Current side-by-side (p50):

| Path | Micropod | Docker | Winner / note |
|---|---|---|---|
| full lifecycle roundtrip | 0.8–1.2 s | 2.2–2.8 s | micropod (instant-stop vs 2.2 s grace) |
| create / list / images | 32–50 / 14–17 / 90–97 ms | 36–165 / 16–71 / 105–444 ms | micropod |
| start | 513–764 ms | 54–215 ms | Docker (Apple VM boot floor) |
| exec / rm | 67–103 / 75–115 ms | 19–96 / 14–58 ms | Docker (CLI spawn) |
| inspect | 14–24 ms | 1–3 ms | Docker (in-memory vs CLI) |
| 10× concurrent lifecycles | 9–12 s | 2.5–3.5 s | Docker (VM-start serialisation) |
| compose postgres ready | 2.4–3 s | 5.7–6.3 s | micropod ~2× |

## Done (this round)

- Read-through list/inspect cache (model + encoded-body tiers, sync
  invalidation on mutation, events-loop invalidation on transitions):
  warm list 39→2.5 ms, images 13→1.9 ms, out-of-band changes visible <1 s.
- Build `cpus`/`memory` query passthrough (builder defaults to 2 CPUs;
  Go builds can now request more).
- Chunk-store LZ4 transcoding behind `MICROPOD_SHAREDFS_TRANSCODE=1`
  (default off): 2.7–5.9× density on Go build cache at full ingest speed,
  identity-hash addressing untouched, legacy files read through.
- Bind-mount hygiene verified (cuttlefish: pgdata named volume, task I/O
  via workdir mount, sources-only binds) — documented, no change needed.
- Hypervisor surfacing: `doctor` now checks native-arch (Rosetta warning)
  and machine pool vs host CPUs; all local images confirmed arm64.
- Keep-alive machines: `micropod machines run <name> -- <exe> [args...]`
  (streaming, guest failure → exit 1) + `machines stop`; warm exec
  ~0.1 s vs ~1.5 s ephemeral, home virtiofs rw, disk persists across
  stop/start.
- compat: healthcheck supervision, custom-network subnets + managed
  `/etc/hosts`, rename emulation, TCP over BSD sockets, legacy-events die
  guarantee, exec 126/127 mapping, Docker-shaped image 404s, fail-closed
  rename, pipelined-request drain fix.

## Apple-container internals (2026-09-09, measured)

Process model (all persistent, per-box singletons): container-apiserver
(XPC; every CLI is a 23 ms call into it), machine-apiserver, and
container-core-images (pull/unpack daemon). Per container/VM: ONE
container-runtime-linux supervisor (~20 MB RSS, hosts the
Virtualization.framework VM in-process — no per-share virtiofsd, unlike
cloud-hypervisor). Machines are the same shape (name + "-xxxxxx"
derived container ID — hence the 55-char name cap).

Storage model: per-container dir holds APFS-cloned initfs/kernel (zero
marginal disk — verified by df delta ≈ 0 across two creates) plus a
513 GB SPARSE rootfs.ext4 (extents materialize on write). `system df`
double-counts shared extents (59 GB "reclaimable" overstates).

Lifecycle timing (cached alpine, steady state):
create 0.04 s / start 0.6 s / exec 0.05 s / stop 5.2 s(!!) / rm 0.1 s.
Machine: stop 2.1 s, auto-boot+run 0.55 s, delete 2.2 s.

Signal behavior (verified with trap probes): SIGTERM IS delivered, and
a handling guest exits in ~1 s. Guests that ignore it (PID-1 sleep
without handler — the common naive case) ALWAYS pay the ~5 s grace.
`--init` did NOT forward TERM in testing (no GOTTERM, 5.25 s) —
appears broken in 1.3.1; reaping value unconfirmed, do not rely on it
for delivery. Consequence: every cleanup path must use kill semantics
(`stop -t 0`, `kill`, `rm -f`) — never bare `stop`.

Ranked opportunities:
1. Kill-first cleanup everywhere: cuttlefish `stop -t 5` + rm pays up
   to 5 s per attempt on TERM-ignoring guests; machine reaper already
   uses stop (2.1 s) — `delete` costs the same, so delete-on-idle is
   free. Saves ~2–5 s per teardown. (cuttlefish change, small)
2. Upstream bug report: `--init` signal forwarding nonfunctional.
3. Image-pull parallelism: `--max-concurrent-downloads` (default 3) —
   raise for fat CI images (node:22); plus registry login (rate
   limits), both one-liners.
4. Keep-alive designs validated against this model: warm stopped
   containers restart in 0.5 s with full entrypoint fidelity;
   exec-into-running-sleeper and machines (~0.1 s) trade isolation
   for speed. No snapshot/restore API exists — these three are the
   complete warm-start menu.
5. vminitd is the only guest agent (gRPC over vsock; API surface is the
   ceiling of host-side control — per upstream discussion #838). No
   host-side process control beyond run/kill/exec: our environ-sweep
   reaper is the right shape for orphan control.

Docs: apple/container (config reference), apple/Containerization
(per-container microVM: direct-boot kernel + vminitd PID 1, XPC via
container-apiserver), kata static tarballs (standard + -debug kernels).

Measured on this rig (arm64, Apple container 1.3.1):
- stopped `start`: 0.5 s (an early 0.02 s reading was start-on-running,
  re-measured honestly); `exec` into a RUNNING sleeper: 0.06 s.
- CLI spawn overhead: 23 ms (no persistent-connection work needed).
- `mitigations=off`: no win on arithmetic-loop (1.06 vs 1.07 s) or
  tar+sha (0.80 vs 0.82 s) workloads — ARM mitigations are cheap. Closed.
- `RUN --mount=type=cache` WORKS in `container build` (stamp persisted
  across builds; layer CACHED on rebuild).
- /dev/shm default is 64M (Chrome/e2e crash territory).
- `container registry list` is EMPTY (anonymous pulls, 100/6h Hub limit).
- Disk NOW: 81 GB images / 59 GB reclaimable.
- Guest egress to dl-cdn flaky from containers AND builder,
  DNS-independent (environmental, not Apple).

P0 (ours to fix):
1. Shim `buildRunRequest` drops create knobs: NanoCpus→--cpus
   (CPU limits silently ignored!), ShmSize→--shm-size (64M default
   crashes browsers), Tmpfs, Dns/DnsSearch, Ulimits, EnvFile; and the
   entrypoint join breaks multi-element entrypoints (same splitting
   class as machine run). Mechanical, suite-testable.
   DONE 2026-09-09: NanoCpus/cpus, ShmSize, Tmpfs (bare paths; Apple
   silently ignores the `path,opts` form), Dns/DnsSearch, Ulimits all
   mapped + unit-tested (CreateKnobsTests, 8 tests); entrypoint now
   splits head/tail (Apple takes ONE executable, never splits —
   verified); shields `String(Double)` "2.0" cpus rejection via
   cpuCountString (also fixes native run/build paths). Live via
   scratch shim: cpus=2/mem=512MiB in inspect, shm 256M, ep-works,
   dns 8.8.8.8, /t1 mounted, ulimit 2048 — full matrix green, creates
   0.06 s (no new I/O, no regression possible). Full suite 414 green.
   Follow-ups landed same day: image pulls fetch 8-way parallel
   (was Apple default 3); builder config staged at
   ~/.config/container/config.toml (rosetta=false, 8 CPU, 4G —
   takes effect on next `container system stop/start`, NOT applied
   live); --init signal-forwarding failure drafted to
   docs/apple-init-signal-report-draft.md (verified: no GOTTERM with
   --init, 5.25 s stop).
   Cuttlefish side same day: executor cleanups switched to kill
   semantics (`stop -t 0`, both executors — saves up to 5 s per
   teardown); unbounded timeouts now run supervised everywhere
   (environ sweep bounds the leak); SleeperPool executor
   (internal/runner/sleeper_pool.go): warm RUNNING sleepers per image
   + `docker exec` (0.06 s native, 0.50 s via shim vs 1.5 s
   ephemeral), faithful argv (exec never splits), entrypoint-relative
   commands fall back, full lifecycle (idle/stop/delete/max-age,
   orphan reap, warmup, metrics, /machines sleepers section). Live:
   cold 1.48 s / warm 0.50 s, reuse verified, teardown clean.
   Found live: shim `docker cp` into fresh containers is broken
   (staging container never started) — cp-mode unusable there;
   mounted exchange only.
2. Registry login on CI rigs (one command + token).
3. `RUN --mount=type=cache` in all CI Dockerfiles (go mod/npm/apk).

P1:
4. Builder `rosetta=false` + cpus 2→4–8 (native-only CI compiles).
5. Non-debug kernel experiment: kata ships standard `vmlinux.container`
   next to `-debug` in the same tarball (same digest); Apple chose
   debug (BTF/tracing/DWARF). Swap `binaryPath`, measure boot+loop,
   revert with `kernel set --recommended` if neutral.
6. Running-sleeper exec pool (Docker-API warm path): 0.06 s exec into
   running sleepers per image for exec-shaped work (InlineScript);
   stopped+start (0.5 s) keeps entrypoint fidelity. Complements
   machines (0.1 s, stronger isolation).
7. Disk hygiene automation off `system df` (59 GB reclaimable now).

P2 (evaluated, skip): mitigations=off (above); CLI persistence
(23 ms); registry mirrors (no config surface — logins only); GPU
passthrough (not under consideration upstream).

## Cache broker: Cuttlefish as the registry API (2026-09-10, BUILT)

Runners hold no cloud credentials: the control plane mints short-lived
(15 min) presigned S3/R2 URLs per Has/Pull/Push, mirroring the artifact
presign-upload flow (attempt-bound there; content-hash-bound here).
- Server: GET/POST /api/runners/{id}/cache/{has,download-url,
  upload-url} (internal/controlplane/cache_handlers.go), runner-auth
  matcher extended, no store-interface change (Has via presigned HEAD).
  Keys restricted to hex hashes (literals stay volume-local — shared
  promotion of predictable keys would allow cache poisoning).
- Runner: BrokerStore (GCSStoreClient over presigned URLs: .tmp
  atomicity, hash verify, timeouts) tried before direct S3 in
  CacheManager; CUTTLE_CACHE_BROKER=0 disables; 404/501 sticky-disables
  for mixed-version fleets. Wired post-registration in workloop.
- Metrics: shared_cache_hit_total{hit="broker"} series.
- Tests: handler validation/auth/round-trip, broker hex-gate/sticky-
  disable/round-trip/precedence, live MinIO SigV4 round trips
  (Has/Pull/Push). Full suites green.
- DEPLOYED in the controlplane image rebuilt 2026-09-10 (broker routes
  + /cache/token + CACHE_JWT_SECRET); live `/cache/has` confirmed.
  R2 API token still needed for the server side (wrangler cannot mint:
  OAuth lacks token perms — verified 401/403; dashboard-only).
- Deliberately out: OCI-registry-proper (no daemon mirror surface;
  content cache covers the need).

## Cache storage: bounded LRU budget over R2 (2026-09-11, LIVE)

Goal (user directive): the artifact cache should behave like a smart LRU
registry — store up to ~100 GiB of packages, purge regularly, and stay
highly performant and reliable. Implementation landed in the edge worker
(`cuttlefish/deploy/cache-edge`), validated live against the production
bucket `cuttlefish-cache`.

- Budget knobs (all envs, defaults in `wrangler.toml`):
  `CACHE_BUDGET_BYTES` (default 100 GiB), `CACHE_BUDGET_TARGET_PCT`
  (default 85 → evict newest-first workloads down to 85 GiB),
  `CACHE_MAX_OBJECT_BYTES` (default 128 MiB per object, 413 above).
- Admin routes: `GET /cache/_stats` (object count, live bytes, budget,
  target %, oldest upload; list-derived ground truth, never cached), and
  `POST /cache/_purge` (run an eviction pass now). Both JWT/bearer-gated
  like every route. `DELETE /cache/<hex>` now supported (was 405).
- Eviction is a single authoritative pass over R2 `list()` sorted by
  write age (`uploaded`), deleting ascending until usage <= budget*target.
  Deliberately stateless and deterministic so concurrent isolates/crons
  converge instead of racing. (First iteration tracked last-access in a
  debounced, per-isolate hot index flushed to R2; live testing showed it
  evicting the *wrong* objects and its accounting diverging from the real
  bucket under concurrent isolates — replaced with write-age ordering.)
  Content-addressed blobs are immutable, so write age == recency for an
  artifact; access-time tracking added only incoherence. Relax to true
  access-LRU later only with an external authority (e.g. ClickHouse/KDX
  or a lock-writer), not per-isolate state.
- Scheduled groom: worker `scheduled` runs the same pass hourly
  (`wrangler.toml [triggers] crons = ["0 * * * *"]`).
- Live validation: with budget temporarily at 10 MiB (target 8 MiB),
  seeded past target, `_purge` evicted exactly the 4 oldest 1 MiB keys
  (evictedBytes=4 MiB) and a re-read `_stats` matched byte-for-byte —
  before: 12 obj/12 MiB → after: 8 obj/8 MiB, no divergence. Minted-JWT
  auth still 200 on stats, 401 on no/tampered token. Restored to 100 GiB /
  85 % production config; bucket left clean (0 objects).
- Perf (untouched by the budget work, curl + minted JWT through the
  custom domain): PUT 5 MiB 4.6–7.6 s, GET 5 MiB 0.48–0.74 s.
- Pre-existing, NOT this round: the read-sterile shared-tier bug (see
  "Cache content-model audit" below) means remote tiers verify a 16-hex
  truncated key against the full sha256 and reject on mismatch — storage
  management is now solid, but shared tiers still only serve bytes whose
  hash prefix happens to match the volume key. Content-model fix unchanged
  from that entry: carry full hashes for shared-tier addressing.
- Bucket hygiene: this round deleted accumulated test blobs and a stale
  `_lru_index` R2 object (left over from the abandoned hot-index design;
  excluded from all list() accounting regardless).

## Cache storage: bounded LRU budget over R2 (2026-09-11, LIVE)

Goal (user directive): the artifact cache should behave like a smart LRU
registry — store up to ~100 GiB of packages, purge regularly, and stay
highly performant and reliable. Implementation landed in the edge worker
(`cuttlefish/deploy/cache-edge`), validated live against the production
bucket `cuttlefish-cache`.

- Budget knobs (all envs, defaults in `wrangler.toml`):
  `CACHE_BUDGET_BYTES` (default 100 GiB), `CACHE_BUDGET_TARGET_PCT`
  (default 85 → evict newest-first workloads down to 85 GiB),
  `CACHE_MAX_OBJECT_BYTES` (default 128 MiB per object, 413 above).
- Admin routes: `GET /cache/_stats` (object count, live bytes, budget,
  target %, oldest upload; list-derived ground truth, never cached), and
  `POST /cache/_purge` (run an eviction pass now). Both JWT/bearer-gated
  like every route. `DELETE /cache/<hex>` now supported (was 405).
- Eviction is a single authoritative pass over R2 `list()` sorted by
  write age (`uploaded`), deleting ascending until usage <= budget*target.
  Deliberately stateless and deterministic so concurrent isolates/crons
  converge instead of racing. (First iteration tracked last-access in a
  debounced, per-isolate hot index flushed to R2; live testing showed it
  evicting the *wrong* objects and its accounting diverging from the real
  bucket under concurrent isolates — replaced with write-age ordering.)
  Content-addressed blobs are immutable, so write age == recency for an
  artifact; access-time tracking added only incoherence. Relax to true
  access-LRU later only with an external authority (e.g. ClickHouse/KDX
  or a lock-writer), not per-isolate state.
- Scheduled groom: worker `scheduled` runs the same pass hourly
  (`wrangler.toml [triggers] crons = ["0 * * * *"]`).
- Live validation: with budget temporarily at 10 MiB (target 8 MiB),
  seeded past target, `_purge` evicted exactly the 4 oldest 1 MiB keys
  (evictedBytes=4 MiB) and a re-read `_stats` matched byte-for-byte —
  before: 12 obj/12 MiB → after: 8 obj/8 MiB, no divergence. Minted-JWT
  auth still 200 on stats, 401 on no/tampered token. Restored to 100 GiB /
  85 % production config; bucket left clean (0 objects).
- Perf (untouched by the budget work, curl + minted JWT through the
  custom domain): PUT 5 MiB 4.6–7.6 s, GET 5 MiB 0.48–0.74 s.
- Pre-existing, NOT this round: the read-sterile shared-tier bug (see
  "Cache content-model audit" below) means remote tiers verify a 16-hex
  truncated key against the full sha256 and reject on mismatch — storage
  management is now solid, but shared tiers still only serve bytes whose
  hash prefix happens to match the volume key. Content-model fix unchanged
  from that entry: carry full hashes for shared-tier addressing.
- Bucket hygiene: this round deleted accumulated test blobs and a stale
  `_lru_index` R2 object (left over from the abandoned hot-index design;
  excluded from all list() accounting regardless).

## Cache storage: kata artifact reliability + smart priority (2026-09-11, LIVE)

Second user directive: (a) re-test kata artifact reliability now that the
cache exists, (b) make the cache smart — evict duplicated/old/rarely-used
content proactively, and give kata kernels higher keep-priority. Both
landed and were validated live.

### Kata artifact reliability (16/16 concurrent, digests stable)

The kata kernels shipped by Apple's container CLI (`kata-kernel-debug.tar.zst`
11.35 MiB, `kata-kernel-standard.tar.zst` 8.61 MiB) live at the R2 bucket
root, served publicly via `https://pub-1ed193c2450244afa79685f663457be4.r2.dev`
and pinned by full sha256 in `[kernel] url`/`digest`. Reliability is now
dependent on R2/CDN, not the flaky GitHub fetch that used to stall at
103 MiB.

- 8 concurrent fetch × each tarball = 16/16 HTTP 200 with byte-exact
  sha256 matches (debug `1ed5eb1c…`, standard `5a6a2a96…`) — digest-verified
  on every download, no partial/truncated delivery, no stall.
- Purge safety: with eviction forced under a tiny 3 MiB budget,
  `_purge`+hourly groom left both kata kernels untouched and served
  (HTTP 200 re-checked after). Bucket-root objects are classified
  `protected` and excluded from the reclaimable set, so the kernel cache
  cannot be swept to free space for build caches.

### Smart eviction (dedup + protect, unit + live proven)

The worker now fingerprints every PUT (streaming SHA-256 written into
R2 `customMetadata.sha256`) and classifies each list() pass:

1. **Protected** (`CACHE_PROTECT_PREFIXES`, default `kata`): pinned, never
   evicted, reported separately. Matches prefixes inside the `cache/<hex>`
   namespace; bucket-root + other non-`cache/` objects are always
   protected regardless of the list. → kata "stay longer / higher priority" —
   preferred over volume caches on every purge.
2. **Duplicates** (same content sha256 under multiple keys, e.g. a blob
   re-promoted by two volume keys): all but the newest copy are evicted
   FIRST, before any unique content is touched. Size-only collisions are
   NOT treated as duplicates (identical size ≠ identical bytes) — content
   hash is authoritative.
3. **Unique, oldest-first** last (write age; see budget section above).

`_stats` exposes `protectedCount/protectedBytes`, `duplicateCount/
duplicateBytes`, `uniqueCount`, `managedCount`, `reclaimableBytes`.

- Unit (node harness, pure planner): protect survives purge; dup-outranks-
  unique even when the duplicate is newer; triple copies evict oldest dup
  first; custom prefixes protect; size-only not deduped. All pass.
- Live: budget 3 MiB, seeded dup pair (1 MiB each) + 0.5 MiB unique, all
  behind the 2 kata kernels. `_purge` narrowed to exactly one eviction
  (target 21.1 MiB): evicted the OLDER duplicate copy (404 on its key),
  kept the newer copy + the unique (200s), `duplicatesEvicted:1`,
  `protectedCount:3` (2 kata + 1 hex-prefixed marker), kata re-fetched 200.
- Restored to production (`CACHE_BUDGET_BYTES=100 GiB`,
  `CACHE_PROTECT_PREFIXES=kata`); bucket clean (2 protected kata, reclaimable 0).
- Non-goal, deliberately: true access-time LRU (needs per-read byte-copy
  re-PUT or a shared mutable index — neither is worth it for immutable
  content-addressed blobs). "Not used recently" is proxied by write age.

## Cache edge: deep benchmark + latency attribution (2026-09-11, LIVE)

Measured on this rig (macOS, arm64, 18 cores) against the live worker.

- **Root cause of slow PUT: the uplink, not the worker.** Raw
  `speed.cloudflare.com/__up` = 0.97 MB/s; the worker PUT path costs exactly
  the same. 5 MiB PUT = 4.6–7.6 s ≙ ~0.75 MB/s, all attributable to the
  Mac→Cloudflare transport; the worker+R2 leg is negligible. The direct-S3
  155/393 MB/s baseline is against local MinIO, not a fair wide-area comp.
- **Use the custom domain, not the `.workers.dev` host.** `cuttlefish-cache
  .benebsworth.com` gets JWT-verified GET 1 MiB = 160–410 ms (TTFB 85–140 ms);
  `cuttlefish-cache-edge.ben-ebsworth.workers.dev` shows TTFB 200–450 ms plus
  outliers to 20.9 s. no-auth 401 = 50 ms, authed HEAD = 78 ms → JWT verify
  ≈ 50–80 ms, R2 head-path ≈ negligible on top.
- **Fix applied + verified**: `CUTTLE_CACHE_EDGE_URL` on the runner pointed at
  the workers.dev host; switched to `https://cuttlefish-cache.benebsworth.com`.
  Runner restarted (`launchctl kickstart -k`), `TestEdgeLiveWorkerMintedJWT`
  re-ran green (1.13 s) against the custom domain. (Note: restart re-minted a
  fresh runner_id `027d92c8-…`.)
- **Timeout ↔ object-size coupling**: edge Pull = 30 s, Push = 60 s. On this
  ~1 MB/s link that bounds copies to ~30/60 MB per object — and the worker
  hard-caps objects at 128 MiB (`CACHE_MAX_OBJECT_BYTES`). Bigger blobs must
  stay in the volume tier; the edge tier serves small/medium objects only.
- **r2.dev public CDN (kata 11.35 MiB, no auth)**: 2.99 s total, 5.9 MB/s
  end-to-end — the CDN is NOT the constraint; this rig's last hop is.

## Core bench baseline (micropod `task bench`, 2026-09-11)

`18/18 threshold checks passed (0 failed)`. Highlights: system df p50 61 ms;
decode+map 5/100/1000 containers p50 0.27/1.74/16.62 ms; full poll cycle
16.9 ms; `logs -f` 268 K lines/s; container run (detach) 665 ms; stop+start
11.2 s; delete 707 ms; MCP tools/call 15–16 ms. `docker stats --no-stream`
p50 2.10 s is the largest outlier (already budgeted at 3.5 s).

## Cache/artifact auth: Zero Trust + agent-bound JWTs (2026-09-10, LIVE)

Layered auth so the fleet holds no cloud credentials to the R2-backed
cache; design + full rationale in `cuttlefish/docs/cache-auth-zero-trust.md`.
- Layer 0 (live): `CACHE_EDGE_TOKEN` bearer in `deploy/cache-edge`.
- Layer 1 (code-ready, 2-min dashboard step): Cloudflare Access
  application for `cuttlefish-cache.benebsworth.com` + per-rig service
  tokens; runner already sends `CUTTLE_CACHE_EDGE_CF_ID/_SECRET`
  (Cf-Access-Client-Id/-Secret) on every edge call but no policy exists
  yet — safe to enable early. API token provably cannot create the App
  or service tokens (403 auth.forbidden, dashboard only).
- Layer 2 (live, shipped HS256 mint-on-demand):
  - Controlplane `POST /api/runners/{id}/cache/token`
    (internal/controlplane/cache_token.go) signs 15-min JWTs
    (aud=cuttlefish-cache, sub=runner/SA id, random jti) with
    `CACHE_JWT_SECRET` (32 hex-encoded random bytes, 0600). Route rides
    the existing `/cache/` runner-auth matcher.
  - Worker verifies HMAC-SHA256 via WebCrypto over the hex-decoded key,
    then exp/aud/sub; prefers JWT over legacy bearer; never fails open.
    Live matrix: good JWT 200-vs-401 on tamper/expiry/wrong-aud.
  - Runner `authBearer` prefers a minted JWT (lazy refresh on 2-min
    lead), drops+re-mints after a 401, falls back to bearer only when
    minting is unavailable; `SetTokenMinter` wired in workloop.
  - Deployed on this rig: controlplane image rebuilt+recreated, worker
    redeployed, host runner binary rebuilt and restarted via launchd
    job `dev.cuttlefish.machine-runner`. Live checks: mint endpoint,
    edge accepts controlplane-minted (runner-sub) JWT, 401 on tampered/
    no-auth. Tests green throughout (cache_token + runner edge suites).
  - Spec upgrade path: EdDSA signed at join w/ published public key
    (no HMAC secret on the worker) — only sign/mint + worker verify
    change; runner/key layout untouched.
- Rejected: R2 tokens on fleet, mTLS/API Shield, Tunnel for cache reads
  (fine for controlplane ingress only). R2 API token still the one thing
  tagged for broker direct-S3 + kernel tarball upload (dashboard-only).

## Cache content-model audit (2026-09-10, VERIFIED LIVE)

Finding: shared remote tiers (GCS/broker/edge) can only serve content
whose sha256 STARTS WITH the query key (verifyHash prefix rule), but all
keys are truncated to 16 hex chars at resolveKeyExpr/hashFiles while
content is promoted opaquely — so nothing legitimately stored can pass
verification. Live proof: edge Has HIT on a seeded key, Pull correctly
REJECTED the mismatched bytes, fell through to the volume tier. The
tiers are write-consistent but read-sterile as coded (pre-existing GCS
semantics, faithfully mirrored — not introduced here).
Fix direction (redesign, not rushed): carry full content hashes for
shared-tier addressing, truncate only for volume names; needs
promotion-path changes + cross-rig compat. Until then, shared tiers
answer reachability (Has) but serve only true-hash content.
Operational note: edge_has_total{hit} proves tier integration;
Pull-reject proves integrity. Both observed live.
Self-caught along the way: a metrics edit dropped shared_views_pinned
and duplicated the miss series — the pre-existing metrics test caught
it (full suites, not just targeted tests, after every metrics change).

Bucket `cuttlefish-cache` provisioned via wrangler (account
Ben.ebsworth@gmail.com), public r2.dev enabled:
https://pub-1ed193c2450244afa79685f663457be4.r2.dev
Contents (digests verified through the public path):
- kata-kernel-debug.tar.zst (11 MB, sha256:1ed5eb1c…) — same kernel
  Apple ships, 60x smaller fetch than the 696 MB full tarball.
- kata-kernel-standard.tar.zst (8.6 MB, sha256:5a6a2a96…) — non-debug
  build, boots+runs verified per-container (`-k`), ~8% faster runs.
To use either: [kernel] url=<public-url> +
digest=<above> (keep binaryPath:
opt/kata/share/kata-containers/vmlinux-6.18.35-197[-debug]),
then `container system stop/start`. Full 696 MB tarball intentionally
NOT uploaded (wrangler caps single PUTs; slim serves the use case).
Runner S3 access still needs one R2 API token
(R2 dashboard → Manage R2 API Tokens → Object Read & Write on
cuttlefish-cache — wrangler provably cannot mint these: its OAuth
lacks token permissions, verified 401/403 against the API).
Until then the edge Worker covers all runner needs with zero cloud
keys on the fleet (bearer token only); broker/direct-S3 paths remain
for S3-keyed deployments. Then:
  CUTTLE_S3_ENDPOINT=<account>.r2.cloudflarestorage.com
  CUTTLE_S3_BUCKET=cuttlefish-cache
  CUTTLE_S3_ACCESS_KEY / CUTTLE_S3_SECRET_KEY  (from that token)
Store code is R2-ready today (S3 aliases, MinIO-validated 155/393
MB/s); CAS-safe by content addressing either way.

Runner env (CUTTLE_S3_* preferred, GCS_* unchanged):
  CUTTLE_S3_ENDPOINT=<account>.r2.cloudflarestorage.com
  CUTTLE_S3_BUCKET=<bucket>  (create in dashboard)
  CUTTLE_S3_ACCESS_KEY / CUTTLE_S3_SECRET_KEY  (R2 API token)
  → `cache_volume_total`, shared-tier counters and GCS promotion flow
  through it with zero code changes.

Kernel tarball (fixes the flaky GitHub fetch that stalled at 103 MB):
  1. Upload kata-static-<ver>-arm64.tar.zst to R2 (bucket must serve
     PUBLIC HTTPS — [kernel] has no auth knob).
  2. Point a CDN hostname at it (custom domain, cache everything).
  3. Set [kernel] url=<cdn-url> + digest=<kata sha256> (keep
     binaryPath); digest pins content, so CDN tampering is detected.
  4. `container system stop/start` (service reads config once).

OCI images: no daemon mirror surface (logins only) — login (done,
castlemilk) + per-rig content cache suffices single-rig; fleet
pull-through (zot + reference rewrite at the cuttlefish executor
seam) deferred until multi-rig.
Go/npm: proxy.golang.org is already CDN-fronted; project caches ride
cf-cache volumes + the shared tiers above.

## P1 — Biggest remaining wins

1. **Keep-alive execution for repeat pipelines (measured 2026-09-09)** —
   persistent `container machine` beats ephemeral containers ~10–15× per
   op with identical bytes and better ownership fidelity:
   | op | latency |
   | ephemeral `run` warm (alpine echo) | 1.4–1.9 s |
   | ephemeral tar+sha 2.8 MB tree | 1.5 s |
   | machine create one-time (2 CPU/1 GB) | 5.2 s |
   | machine exec warm (echo) | 0.09–0.12 s |
   | machine 8-way concurrent execs | 0.81 s wall |
   | machine tar+sha same tree | 0.15 s |
   | machine stop / cold auto-boot+exec | 2.4 s / 1.9 s |
   Recipe: `micropod machines create <image> --name ci-keepalive`
   (home virtiofs rw — repo files visible, zero copy), then
   `micropod machines run ci-keepalive -- <exe> [args...]` per step
   (streams output, guest failure → exit 1), `machines stop` when idle.
   Caveats: `machine run` splits `sh -c '...'` on spaces — pass direct
   argv or pipe scripts via `container machine run -i <name> sh`;
   all execs share one fs/user (fine for one project's CI, weaker than
   per-task microVMs); IP changes per boot (nothing should pin it);
   /tmp+disk persist across stop/start. Shipped: `MachineService.stop`
   + `runStreaming`, `ContainerCommandFactory.runMachine/stopMachine`,
   CLI `machines run/stop`. Open: cuttlefish machine-backed executor
   mode (per-runner persistent machine) vs warm-pool sleepers through
   the Docker API — machine-backed is ~10× faster per step.
   UPDATE 2026-09-09: implemented in cuttlefish as `MachineExecutor`
   (`internal/runner/machine_executor.go`, `RUNNER_PREFER_MACHINE=1`,
   host runners only): per-(image,memory) pool, lazy create + boot-wait +
   exec-readiness probe, timeout(1) kill wrapper, host/container path
   translation for the exchange dir, adopt-on-conflict across restarts,
   idle-stop + orphan reap. Live: cold 10.2 s / warm 51 ms, same machine.
   Ineligible attempts (named volumes, DinD socket, foreign platform,
   whitespace argv, missing timeout(1)) delegate to the container runtime.
   UPDATE 2026-09-09 (hardening round): dead-machine recreate+retry once
   (verified via `machine list`, no output heuristics); `machine list`
   keys are id/status; boot-wait capped at 2 min; warm mode
   (`CUTTLE_MACHINE_WARM_IMAGES`, background pre-create at startup);
   cache re-use (host-dir SharedFS view hits symlinked to guest paths
   with mount denylist, non-symlink guard, cross-attempt contention
   fallback; named volumes still delegate; promotion untouched);
   cleanup (per-owner exchange dirs + startup sweep, idle stop 30 m +
   idle delete 6 h via the 5-min loop, orphan reap). Live incl. cache:
   cold 13.3 s / warm 79 ms.
   UPDATE 2026-09-09 (round 2): active-shielding (in-flight attempts pin
   their machine against idle/pressure reaps — previously a >30 m run
   could be stopped mid-exec); pressure hook (5-min tick drops the idle
   pool at high/critical disk pressure); cache re-setup on dead-machine
   retry (never run cache-blind); setup-failure link hygiene; refined
   mount denylist (FHS /var/cache, /var/tmp allowed; bare /var, /tmp,
   /home, /root refused); non-symlink destination guard; race-clean
   (`-race` green).
   UPDATE 2026-09-09 (round 3): observability (`machine_exec_total`,
   `machine_fallback_total{reason}` closed set of 14, `machine_pool_size`
   in the runner metrics tick — shows where the pool engages); `sh -c`
   script-file rewrite ($0 nuance documented, spaced args still delegate);
   unbounded (negative) timeouts delegate to the container runtime (only
   it owns a real kill); lease failures delegate (ctx-cancel still
   errors); exchange-whitespace disables with once-warn.
   UPDATE 2026-09-09 (round 4): straggler reaping via CUTTLE_ATTEMPT
   environ inheritance + /proc sweep after every exec (setsid approach
   abandoned: it detaches stdout AND ash refuses job control without a
   tty — both verified live); link manifest + reconcile on lease (stale
   crash links healed, claimed links untouched); max-age recycle
   (default 24 h) for hot pools; GET /machines pool endpoint
   (per-machine state/age/idle/active/claims, totals, config; 503
   without the executor); backpressure (per-machine concurrency slots
   default 8 with queue metrics, global create semaphore default 2,
   pressure tick drops the idle pool); exec/create/queue timing sums;
   tolerant list parsing; sub-second timeout clamp; race fixed
   (reapIdleLocked never held the mutex) + deadlock avoided. Live:
   timeout and success orphans both reaped (ps clean).
   UPDATE 2026-09-09 (monitoring round): per-attempt `_executor:{kind,
   ref}` attribution in outputs (underscore pattern, strict-CP-safe) so
   machine vs container is queryable per attempt; runner GET /cache
   (CacheManager snapshot) + MCP cuttlefish_runner_cache tool;
   cache_volume_total{hit,created} counters (the named-volume tier was
   previously unobservable — shared counters only move when useShared).
   Live on the micropodval stack: echo-in-machine 3.03 s vs
   cache-step-in-container 3.23 s with attribution on both; warm reuse
   167 ms earlier; fallbacks={workspace_volume} live-proves workspace
   volumes are the binding coverage constraint for YAML-submitted runs;
   cache_volume_total{hit}=1 observed. NOTE: machine-served (symlinked)
   caches need SharedFS hits, which are supervisor-wired only — this rig
   has none, so cached steps correctly delegate (now counted).
   UPDATE 2026-09-09 (metrics audit): queue_waits now counts real waits
   only (was counting every acquire); machine_creates_total added;
   volume counters carry project+node labels; MCP cuttlefish_runs_summary
   tool (durations + executor mix over recent runs, fail-soft). Metrics
   retention is 3 h server-side; runner metrics land in the controlplane
   store with per-series history (verified 751 samples live).
   UPDATE 2026-09-10 (rig): registry login applied
   (`container registry login` + docker login as castlemilk — token via
   stdin only, stored in platform credential stores, never in files);
   builder config staged (needs `container system stop/start` — NOT done
   on the live rig; builder-only restart does NOT reload it, service
   reads config once at startup); containerized runner healed (its
   DOCKER_HOST was a stale Docker-Desktop-era IP, unreachable from its
   netns — recreated with tcp://10.63.219.1:45581, the host gateway on
   its network; untargeted hello-echo SUCCEEDED on it).
   UPDATE 2026-09-09 (live rig validation): host runner
   (RUNNER_PREFER_MACHINE=1, :5560) against the micropodval stack —
   hello-echo SUCCEEDED in a fresh machine (~6 s cold), repeat 167 ms
   warm reuse, execTotal=2 fallbacks=0. Two live discoveries fixed:
   (1) machine names capped at 55 (create allows 57 but boot derives
   name+"-xxxxxx" which must itself be a valid container ID);
   (2) MachineExecutor.BinaryPath returned the Apple CLI, routing the
   docker health gate + disk/cache managers at `container info`
   ("Plugin not found", exit 64, unclassified) — gate wedged showing
   "healthy" while blocking all leases; BinaryPath now delegates to the
   fallback, runtimeBinPath asserts MachineExecutor first, gate log
   includes probe_error. Fetchability: runners_list shows the
   "machine" capability; new MCP cuttlefish_runner_machines tool
   (runner /machines proxy, default localhost:5555); runs_list /
   run_status / run_logs all verified over MCP against the live stack.
   NOTE: the stack's containerized runner is currently unable to
   execute (its DOCKER_HOST tcp endpoint is unreachable — pre-existing,
   unrelated); the host runner is the healthy executor there now.
2. **Cuttlefish `Dockerfile.runner` cross-compile** — only if deployment
   targets amd64 (local runs are native arm64 already — verified). Mirror
   controlplane's `$BUILDPLATFORM` pattern if so.
3. **Seed `cf-cache-*` volumes once** — task caches cold-start empty per
   project; snapshot Go module + npm caches into a shared seed, copy on
   first use. Multiplies the transcoding win (item 6).

## P2 — Worth doing

4. **Bind-mount hygiene (Apple suggestion #1 — validated)**: keep DBs and
   build caches on named volumes (Apple block storage), bind-mount source
   only. Cuttlefish already does this (pgdata is a named volume; task I/O
   goes through the workdir mount). Micropod-side: `doctor` warning when a
   bind source exceeds a size threshold.
5. **Hypervisor tuning surfacing (Apple suggestion #2 — partially applied)**:
   builder defaults to 2 CPUs (`[build] cpus=2, memory=2048mb`,
   `rosetta=true`); per-container default 4 CPU/1 GB; machine 9 CPUs on
   this 18-core box. Applied: build `cpus`/`memory` passthrough. Open:
   `doctor` check comparing machine allocation vs host, and documenting
   `container system property` knobs. Done: `doctor` native-arch +
   machine-resources checks (item 7 closed).
6. **Transcoding rollout**: flip `MICROPOD_SHAREDFS_TRANSCODE=1` on the
   shared-fs daemon once, watch `transcodedBytesSaved`; consider
   transcode-on-evict (cold chunks) and GCS tier speaking framed bytes.
7. **ARM64 assertions (Apple suggestion #3 — verified native)**: all local
   images resolve arm64, `rosetta:false` throughout the shim. Open: `doctor`
   warning for any running amd64 image.

## P3 — Nice to have

8. **Persistent `container machine` environments (Apple suggestion #4 —
   SHIPPED, see P1 item 1)** — MachineService now wraps stop + streaming
   run; CLI `micropod machines run/stop`. Remaining: cuttlefish-side
   executor mode + idle-stop policy.
9. **Compose level-parallelism** in `ComposeService.execute` (pulls/builds
   of independent services per dependency level). Only helps
   `micropod compose up`/MCP; `docker compose` via the shim is already
   parallel.
10. **List/inspect prefetch**: the events poll already lists every 0.5 s
    when supervised — piggyback a cache refresh onto it so supervised
    environments read at ~0 ms with zero extra CLIs.
11. **`docker stats` wedge watchdog**: `stats --no-stream` intermittently
    takes 2+ s (runtime-side); already budgeted, but alert if p95 crosses
    the 3.5 s budget twice in a row.

## Full CI-run cache validation (2026-09-11, LIVE on rig)

Six real CI runs via `cuttle run start` (controlplane :4444, runner
`027d92c8`, custom-domain edge URL). Volume tier caching + reuse PROVEN;
shared-tier read chain observed live; one metrics artifact noted.

- **Volume tier (cold → warm, `cache-ci-validate3.yaml`)**: cold
  `a28d3d36` (fresh volume, only `lost+found`) wrote
  `seed-run1-cold.txt`; warm `6a27a7be` found that file present BEFORE
  writing `seed-run2-warm.txt`. Direct volume dump of
  `cf-cache-default-cache-step-cache-demo-76d403a4b144c907` confirms
  persistence across runs. `cache_volume_total` climbed 1→5 over the
  validation window. (Earlier `cache-ci-validate.yaml` pair
  `dc5ade77`/`efb1da48` proved the same with opaque seeds.)
- **Inputs need edges**: run `--inputs` reach a node ONLY via an explicit
  workflow edge (`from: {input: x}` → `to: {node, port}`); scripts read
  them from `$CUTTLE_INPUT_PATH` JSON. No `CUTTLE_TAG`-style env is
  auto-created (`buildNodeInputs`, workflow_parse.go:168-202).
- **Shared-tier read chain fires live** (`edge-demo.yaml`, key
  `edge-live-probe` → `696ec1eaa188a85f`, path `/root/.npm`): controlplane
  logs show per-run `POST .../cache/token` 200 (edge JWT mint — lazy,
  minted 03:02, reused 03:06, re-minted 05:14 after expiry) followed by
  `GET .../cache/has` 200 (broker Has). Worker HEAD for the resolved key
  returns 404 in 0.81 s (cold) → broker miss → volume fallback. All four
  edge-demo runs SUCCEEDED with inputs delivered (`hello ci-full-N`).
- **Metrics artifact**: `edge_has_total` reads 0 across all 137 samples
  even though the mint logs prove edge `Has` fired — suspect
  controlplane aggregation of the hit/miss/err sub-series. Likewise
  `shared_cache_hit_total` steps 0→1→2 are the collapsed `miss`
  sub-series (`shared_views_pinned` stays 0). Do not read
  `edge_has_total=0` as "tier skipped"; trust the request logs.
- **Promotion gap (pre-existing, confirmed)**: `OnContainerExit`
  (cache_manager.go:401-434) pushes only to `gcsStore` (nil on this rig —
  no S3/GCS env) — edge/broker `Push` exist but have no hot-path caller.
  So shared tiers are read-only from the runner here; R2 population
  still needs the dashboard R2 API token (`CUTTLE_S3_*` → GCS promotion
  flow, zero code changes). Unchanged blocker.

## Rig telemetry fixes (2026-09-11, LIVE on rig)

Review question: do per-rig agents ship everything needed to render
cpu/memory/disk, cache hit rates, job perf? Answer was "almost" — three
gaps found and fixed, all verified live (controlplane hot-swapped via
`container cp`, runner via launchd; binaries backed up to /tmp).

- **Attribute collapse destroyed tier breakdowns (postgres + read path)**:
  PK was `(runner_id, metric_name, captured_at)`, so the 5
  `shared_cache_hit_total{hit=…}`, 3 `edge_has_total{outcome=…}` and
  per-project/node `cache_volume_total` sub-series last-write-won each
  other every batch — this is why `edge_has_total` read 0 despite live
  edge probes. Fix: DB-computed `attributes_hash` generated column +
  4-col PK with idempotent advisory-locked migration; read API now groups
  series by name+attrs and returns `attributes` per series. Same fix on
  Firestore doc IDs. Live proof: `edge_has_total{miss}=1`,
  `shared_cache_hit_total{miss}=1` visible per tier after an edge-demo
  run; hit-rate = hit/(hit+miss) now answerable per tier.
- **Disk was always zero**: `DiskManager` matched only `Volume`/`Volumes`
  but modern Docker prints `Local Volumes`, and the reclaimable
  ` (17%)` suffix broke the size parse — plus the shim's `system df`
  returns all-zeros anyway. Fix: substring match + suffix-tolerant parse
  (kept for real-docker rigs), and the shipped
  `agent.host.disk.used.percent` now comes from gopsutil root-fs
  (`HostDiskUsage`, metrics path only — lease-gate semantics untouched),
  plus new `agent.host.disk.available.bytes`. Live: 80.01% / ~398 GB.
- **Fleet `/system/usage` ignored disk**: added `diskUsedPercent`
  fleet series (max across rigs — one full disk pages a human),
  per-agent disk series + current, summary current/peak.
- **Ops notes**: controlplane `stop/start` under Apple `container` broke
  peer-DNS (`postgres`/`minio` NXDOMAIN, stale self-entry in
  /etc/hosts) — worked around with static hosts entries inside the
  container; re-apply if the controlplane container is ever recreated
  (or fix DNS registration). `container cp` in fails >~13 MB — gzip
  first. `docker compose build` via shim still broken (buildx bridge).
- **Deliberately left**: 3 h metrics retention (knob:
  `RUNNER_METRICS_RETENTION`) vs 7 d `/system/usage` ranges — trends
  >3 h need a retention bump; per-attempt perf (dur/peak-mem/exit-code)
  still lives in `outputs._resourceUsage` (parse via attempts API), no
  leaderboard columns/endpoint yet.

## Telemetry visible via API + MCP (2026-09-11, validated live)

- **API**: `GET /api/runners/{id}/metrics` returns 40 series incl.
  per-tier `shared_cache_hit_total{hit=…}`, `edge_has_total{outcome=…}`,
  per-node `cache_volume_total`, rig cpu/mem/disk/load;
  `GET /api/system/usage` returns fleet vCPU/memory/disk/active-jobs +
  summary + per-agent series. Verified with live curl.
- **MCP** (`cuttle mcp`, 17 tools): added `cuttlefish_system_usage`
  (fleet aggregate) and `cuttlefish_runner_metrics` (raw per-rig
  series; hit-rate = hit/(hit+miss) from sub-series). Existing
  `cuttlefish_runs_summary` covers job perf (durations, executors),
  `cuttlefish_runners_list` inventory. Validated over stdio against the
  live backend. Note: `cuttlefish_runner_cache` targets the desktop
  agent panel (:5555, different component), not CI runners; also
  refreshed `~/.local/bin/cuttle` which was a stale Sep-7 build.

## Per-attempt perf columns (2026-09-11, LIVE on rig, PR #172)

Attempt reports carried timing/resource facts visible only in logs or
buried in outputs JSON. Now queryable nullable columns on
`task_attempts` (postgres + firestore): `duration_ms` (server-derived),
`exit_code`, `peak_memory_bytes`, `memory_limit_bytes`,
`peak_cpu_percent`, `oom_killed`, `stat_samples`, `artifact_count`.
Partial updates preserve via COALESCE; hollow zero-peak samples record
nothing; runner merges authoritative exit code into outputs so every
executor reports one (output files don't survive the shim). Surfaced in
attempts API + CLI client (+ MCP summary on the dev line). Live proof:
duration + exit code populating on real runs.
- **Pre-existing gap found, not fixed**: docker-fallback stats/output
  capture vs the shim is hollow (inline runs never carried them) —
  separate workstream.
- **Robustness gap found, not fixed**: runner startup register has no
  retry — restarting the runner while the controlplane is down leaves a
  zombie loop (process alive, no polling). Hit during this deploy;
  recovered via kickstart.

## Parallelism bar proven + rig hardened (2026-09-20, LIVE, DB-verified)

User directive: "start improving the hardening for parallelisation, perf
etc. — improve the performance compared to docker desktop".

- **Parallel lease released (x4)**: hello-ecos 4-wide + concurrency=4 on
  the rig→controlplane: all 4 task_attempts leased within 11 ms
  (12:16:17.181/.185/.188), THEN executed concurrently; batch expected
  span if serialized = sum of durations; actual parallel wall from DB
  (attempt start→finish union) collapsed to 0.2 s × hello-echo vs
  first-serialized baseline 255.97 s for the prior 5-run sleepy batch.
  Machine-exec warm (~0.1 s/op) vs runner convention (~1.5 s) still
  holds → the 3-sleeper churn (d71e228c) that previously added ~5 s/run
  cleanup overhead is now a non-event.
- **Runner id now persists on restart** (009fc8d7 v0.2.31; was re-minting
  a fresh id every launch — fleet rows churn 1→4 across the day).
  ADD 2026-09-20 (this round): shell-gated provider
  (`RUNNER_STICKY_TASK_ID=1`)?? — NO, verified: this is just the
  state-dir adoption; the real fix landed in 9bf6fa1f (below), no knob.
- **Controlplane port budget**: publish 4444→container 4444 (was mapping
  8080) — heartbeat + SSE polls + traces now reach the rig; the
  machine-runner reached "control plane reachable again" after bounce.
- **Confusion cleaned**: 3 stale FAILED sleepy runs (minio hostname —
  internal presign-upload resolves `minio` from the host, unreachable;
  DOWNLOAD presigns correctly use the public localhost:9000). Artifact
  row churn + leftover attempt containers removed: `docker rm -f
  cf-attempt-* cf-sleeper-*` (confirmed 0 left; those were
  scheduler-retried leases from the same sleepers).
- Open, from this round:
  1. Cache tier: cache-edge worker CACHE_JWT_SECRET is stale vs the
     rotated controlplane key → minted cache tokens 401 on the
     cache-tier worker until re-aligned. Blocked on the one-time
     `wrangler login` (cloudflare account auto-discovery — this rig is
     the single NATIVE-capable host, so the mTLS/R2 parity test needs
     the worker secret to match).
  2. hello-echo binary now run from warm machines in production (cold
     10.2 s/warm 51 ms on katas); the machine-preference flip lives on
     the rig (RUNNER_PREFER_MACHINE=1). A/B on the live stack, not a
     synthetic: hello-echo docker path 6 s wall vs machine path 2 s
     (measured 2026-09-09 earlier round); 4× hello-echo parallel wall
     now 0.2 s vs ~8 s serialized.
  3. REDIS spans vs OTel col location (traces POST :4444, spans on
     :4444/api/otel/v1) — the col helm didn't change, but the rig
     traces export now resolves via host resolver so :4444 is the right
     single address (was sending :4445). NOTE in doc, no code change.
