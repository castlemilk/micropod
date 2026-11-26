# Native Docker image identity, Compose health and checkout performance on Gamma

The November 25 B3 scorecards measure networking, boot and container churn on Gamma. This round runs the native managed engine through its public Unix socket with stock Docker and Compose. The CI comparison runs stock Git and real Go builds against the same 1,058-file source tree and the same locally loaded Linux image on Micropod and OrbStack. [B3 scorecards](../2026-11-25/phase-b3-results.md) · [Production plan](../../research/2026-11-25-phase-b4-plan.md)

B4 already qualified zero-`vmnet` egress and measured IPvlan sibling bulk with cubic and fq at 26,452 MiB/s on direct HVF and 18,325 MiB/s on OrbStack. The production work here targets ordinary Docker clients and the mounted-checkout gap. [B4 results](../2026-11-25/phase-b4-results.md)

## Docker image identity

The previous native runner imported named archives with an extra containerd repository digest. Eleven raw image-list filter cases selected the expected images. Stock Docker printed four, four, two and two rows in four positive CLI cases where OrbStack printed two, two, one and one. [Previous release evidence](workspace-queues-and-native-buildx.md)

Runner `5004945fa3ea` stopped creating a synthetic digest for new named archives. It retained unnamed imports and previously stored aliases. The engine verified the current repository, manifest or index, and immutable config before exposing a repository digest derived from a tag. Stock Docker inspected and ran a newly loaded image by that digest. A stopped container restarted with its original bytes after the last tag moved. Each backend passed its 28 ancestry assertions. The ordinary stores matched each other exactly on 27 cases. The native linked image graph matched all 28 expected cases. The intermediate Linux suite exposed an older history test whose mock store omitted the digest alias it claimed to contain.

Testing the newly exposed digest through two further stock commands found an archive export failure and an unsupported image removal. On OrbStack, `docker save repository@digest` exported an untagged archive with the expected content. Removing the digest removed two matching tags in that repository while preserving the other repository and a different target. A wholly unused last image disappeared.

The follow-up exports the selected immutable descriptor under a containerd content lease. Both Engine save routes returned an archive with the original config and layers, including when another client moved the tag and removed the old ID during the transfer. The removal path checks the repository and target before each mutation. An unrelated repository returned 404. Both engines rejected removing the last reference to a running container's image, including with force. Both allowed the forced stopped-container case and restarted it with its original marker. Micropod retained the immutable image ID for the restart. OrbStack restored from its snapshot after removing the image ID. [Digest export](../../../guest/runner/docker_image_export_linux.go) · [Digest removal](../../../guest/runner/docker_image_digest_delete_linux.go)

## Compose readiness

The first stock Compose fixture started a dependency with a failing probe. OrbStack held the dependent CI job in the created state, started it after the first successful check, reported unhealthy after two consecutive failures and returned to healthy after the file was restored. Runner `5004945fa3ea` rejected `Healthcheck` at container creation. Both projects cleaned up their containers and networks. [Compose qualification driver](../../../scripts/qualify_compose_health.py) · [Docker Compose startup order](https://docs.docker.com/compose/how-tos/startup-order/)

The native engine now schedules probes for health-checked containers, reads the image's declared health configuration by immutable digest and reports transitions on the Docker event stream. The stock reference confirmed a distinction between image and container configuration. Image inspection preserves the custom Dockerfile shell, while an inherited `CMD-SHELL` probe uses the container's shell and inherits its environment. An early fixture incorrectly expected the image shell to be used and a later timeout attempt preserved the benchmark image's own entrypoint. Both failed attempts and their cleanup receipts are saved. The final fixture sets PID 1 explicitly and checks the running state before accepting a probe.

Runner `375fd448fbf4` passed the stock readiness dependency, image-defined probe, explicit disable, restart and recovery checks. A 350 ms timeout produced exit code −1 and the timed-out probe PID had been reaped. Five probe results were retained, each with the first 4,096 output bytes and the stock three-dot suffix. Eight simultaneously running containers first reported eight unhealthy, then only the four explicitly marked ready became healthy, and finally all eight became healthy. Docker load, waits, cleanup and inspection all ran through the public socket.

The final native runner `55f2ae080a60` also reproduced Docker's stopped-container state. A process exiting before its first probe reported unhealthy, a zero failing streak and an empty probe log. Stopping a healthy process preserved its probe history and a restart produced a fresh healthy result. The final reference and candidate passed the same driver with 18 matching receipt fields. The Linux suite passed 543 cases with five environment-dependent skips, including subtests. The focused suite passed 191 cases. Intermediate failures exposed a partially returned malformed health configuration and an obsolete test expectation for an incomplete digest descriptor. Both have regression coverage in the final suite. [Probe lifecycle](../../../guest/runner/docker_health_linux.go) · [Image health metadata](../../../guest/runner/docker_health_image_linux.go)

## Docker API coverage

The fixed Docker 1.47 audit now matches 16 of 27 stock case groups, up from 15. The image-list label comparison is the new match. Eleven groups still differ across version negotiation, ping version headers, plugin listing and Swarm control-plane operations. The fixed comparison maps to 39 of the 107 operations in the pinned specification. Seven further operations have independent traces for registry authentication, push, image creation, BuildKit session, load and both save routes. Together these exercise 46 operations, including negative and differing responses. The final audit and the constrained image, ancestor and Compose fixtures left zero scoped rows. [Exact final API audit](native-docker-api-v1.47-image-digests-and-health.json.gz)

## CI checkout on the final engine

The final `55f2ae080a60` runner used the retained `f0747277714e` VMM and `61b4e143b260` kernel. Both the full-job and density studies met the quiet preflight of two consecutive samples at or above 90% CPU idle. Each result below is the median of four interleaved Micropod/OrbStack pairs. The eight jobs ran stock Git against one mounted source tree with independent index files.

| Final managed workload | Micropod | OrbStack |
| --- | ---: | ---: |
| Warm Git, Go build and test | 820.36 ms | 631.72 ms |
| Edited Git, Go build and test | 1,970.53 ms | 1,859.26 ms |
| Eight concurrent Git jobs, guest time to last completion | 304.53 ms | 137.02 ms |
| Eight concurrent Git jobs, host time including startup | 584.39 ms | 431.00 ms |

The earlier control also completed under ambient load. Its warm full job took 838.20 ms versus 658.11 ms, and eight Git jobs took 308.57 ms versus 140.38 ms. Two initial attempts stopped before sampling because the reference checkout failed admission. An exact file-by-file readback, repeated clean Git statuses and a fresh run of the original workload passed. The timings use the admitted retries.

## Workspace transport and completion

The VMM candidate `30bf0392091e` offers split-ring event indices on the writable workspace when `MICROPOD_VIRTIOFS_WORKSPACE_EVENT_IDX=1`. Both settings use the same signed VMM, a single request queue and the retained kernel. The host tests the driver's used-event threshold across all entries it published, including a wrapping 16-bit index. Before sleeping it rearms guest kicks, fences and checks the ring again. The unit suite passed 52 checks, including queue disable, reset and snapshot restore. [Virtio split-ring notification requirements](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html)

| Four paired runs, median milliseconds | Micropod off | OrbStack in off window | Micropod on | OrbStack in on window |
| --- | ---: | ---: | ---: | ---: |
| Warm Git, build and test | 826.33 | 655.47 | 808.03 | 633.07 |
| Edited Git, build and test | 1,974.00 | 1,912.22 | 1,924.57 | 1,853.88 |
| Eight overlapping Git jobs | 307.09 | 140.42 | 279.07 | 136.93 |

The runtime confirmed that Linux negotiated bit 29 on the writable workspace. Over the two worker lifetimes, FUSE requests were 538,891 and 539,375, workspace interrupt requests fell from 345,919 to 232,085 and total MMIO exits fell from 980,155 to 909,652. The paired eight-job time ratio improved from 2.159 to 2.047. The warm full-job ratio rose from 1.261 to 1.276 and the edited ratio from 1.031 to 1.037. Preflight load differed across the arms, and each table cell has four pairs. Event indices remain opt-in.

The independent Linux candidate `1cb0c4b4920d` can complete a bounded batch of synchronous workspace OPEN and page-backed READ requests during interrupt handling. Its comparison uses one Image with the feature switched off and on. Both arms include the queue-full retry handoff change. The original kernel and the executable used for the earlier scorecards remain available.

| Four paired runs, median milliseconds | Micropod off | OrbStack in off window | Micropod on | OrbStack in on window |
| --- | ---: | ---: | ---: | ---: |
| Warm Git, build and test | 817.67 | 628.91 | 811.89 | 621.77 |
| Edited Git, build and test | 1,948.68 | 1,861.76 | 1,952.53 | 1,866.71 |
| Eight overlapping Git jobs | 298.05 | 135.40 | 293.27 | 138.22 |

Both kernel settings passed the separate quiet-start checks. Within the scored full jobs the host measured 83.79% and 83.65% idle. The paired warm ratios were 1.280 and 1.290. The edited ratios were 1.046 and 1.047. OrbStack completed all four pairs faster in each workload. The selected CI configuration retains the existing kernel completion path.

In separate unscored traces, enabling the feature moved 1,070 of 1,076 OPEN and 958 of 1,131 READ completions into hard interrupt context. The off trace recorded zero for both. Median OPEN completion fell from 20 to 18 µs and median READ from 16 to 13 µs. Pressure tests recorded 242 and 325 actual queue-full retries. Both modes passed interrupted reads, parallel fsync, held-handle identity and last-unmount/remount checks with zero scoped containers left.

## Baseline and worker lifecycle

The November 24 preservation manifest still matches all 24 original files and all 24 sealed copies. The suite resume guard detected an earlier timed QoS pair and refused a duplicate continuation. Independent schedules completed the controlled and ambient comparisons. The completed network baseline remains 6,573.34 MiB/s. Standard and Interactive QoS delivered 7,934.1 and 6,294.1 MiB/s under controlled load. Interactive lowered fresh-request p95 from 10.187 to 6.356 ms. With Interactive fixed, two and four relay workers delivered 6,504.7 and 5,845.0 MiB/s. [Controlled QoS and relay-worker results](../2026-11-24/gamma-qos-and-workers/results.md)

Gamma created 11 worker APFS volumes and one staging volume with Spotlight indexing and persistent FSEvents logging disabled. All 12 passed a read-only remount audit with zero FSEvents journal files or bytes and were removed. One worker's open-file scan timed out after its VMM had powered off. The operator confirmed the disk identity and stopped supervisor, waited for the scanners to exit and completed an ordinary detach. The owned OrbStack tag and builder were removed. The three pre-existing image references and 26 prior artifacts matched their recorded digests. [Gamma scorecard and cleanup record](workspace-completion-transport-and-image-load-gamma.json)

Two first attempts at the stock interactive PID 1 fixture observed the initial 31 × 97 terminal size 200 ms after the host changed it to 42 × 113. In both cases the same four-case fixture passed on the next run and cleaned up. The transcripts record the guest observation only. Establishing when the resize request arrived at the engine remains an open terminal qualification check. [Raw qualification receipts](workspace-completion-transport-and-image-load-gamma-receipts.tar.gz)

The raw archive contains 713 files with individually verified SHA-256 hashes. The retained binaries include the final runner, its Linux test executable, both VMMs and both kernels. [Runtime manifest](gamma7-qualified-runtime-manifest.json)
