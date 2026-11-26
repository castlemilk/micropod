# Native Docker registries and host-mounted CI on Gamma

The native HVF worker can log in, publish images and pull a tag that exists only on a private registry. The preceding guest returned HTTP 501 for login and push. An independent registry client verified the manifest digest, configuration bytes and uncompressed layer identity. Eight Engine API clients also published eight distinct images concurrently. [Stock-client and registry driver](../../../scripts/qualify_docker_push.py) · [Build, raw measurements and cleanup](native-push-and-fuse-gamma-receipts.tar.gz)

## Eight and sixteen CI containers on the combined engine

A fresh Gamma worker combined the event-driven HVF VMM `4b25f7d3ae9a`, kernel `61b4e143b260` and native Docker runner `e00d6da9b0b2`. A stock container read `Y` from the running kernel's workspace async-release setting. Each CI container ran stock Git, compiled Micropod's seven-file guest helper and ran its five Linux tests from the host-mounted checkout. Both engines used identical tools and produced identical binaries for every revision. Each timed wave reached all eight or all sixteen active jobs. [Combined scorecard](native-combined-integration-gamma.json) · [Drivers, per-job clocks and cleanup](native-combined-integration-gamma-receipts.tar.gz)

| CI jobs | Condition | Micropod | OrbStack | Faster Micropod pairs |
| ---: | --- | ---: | ---: | ---: |
| 8 | Warm | 381.9 ms | 417.7 ms | 4/4 |
| 8 | After a host edit | 660.8 ms | 737.9 ms | 4/4 |
| 16 | Warm | 816.2 ms | 851.6 ms | 4/4 |
| 16 | After a host edit | 1,364.2 ms | 1,387.6 ms | 2/4 |

The clock starts at the first timed Git operation and ends when the last test finishes. Each guest had four vCPUs and 4 GiB. Eight-job runs gave each job 0.5 CPU and 384 MiB. Sixteen-job runs gave each job 0.25 CPU and 384 MiB, with cold caches prepared in two groups of eight. Those cold preparations took 68.05 s on Micropod and 72.63 s on OrbStack. Jobs used automatic CPU placement throughout. Weighted host idle was 81.44% and 81.88% at the two densities. All 48 CI containers across both engines were checked absent by ID. [Per-job limits, artifact digests and warm-up timings](native-combined-integration-gamma.json)

During cleanup, the native API rejected Docker's `ps --filter ancestor=…` query. The verifier checked the exact container IDs and enumerated the private native endpoint. OrbStack also accepted the ancestor filter. Image-ancestor filtering remains a stock-client compatibility case. [Cleanup observations and recovery](native-combined-integration-gamma-receipts.tar.gz)

The same Micropod worker then passed the stock image-retention and private TLS registry tests. A separate registry client verified bytes after a concurrent client deleted the uploading image's local tag and ID. The eight-image wave completed in 155.5 ms with all eight response streams open together for 39.1 ms. All nine other fixture IDs were removed with explicit force. Login and push to the untrusted second certificate failed, and the registry confirmed the tag was absent. [Combined Docker and kernel receipts](native-combined-integration-gamma-receipts.tar.gz)

The combined worker and staging drive were read-only remounted for inspection and removed. Both had Spotlight disabled and zero FSEvents journal files or bytes. The integration archive contains 98 individually verified entries. [Final integration cleanup](native-combined-integration-gamma.json)

## Stock Git, Go build and test

Four alternating comparisons per setting used a 1,058-file Mac checkout, the same Git and Go binaries, four virtual CPUs per engine and a two-CPU, 1,536 MiB job. The normal and asynchronous close settings ran on the same Linux 7.3.5 kernel image, VMM and runner. Times are medians of the three measured phases in milliseconds.

| Workspace setting | Micropod warm | OrbStack warm | Micropod after edit | OrbStack after edit |
| --- | ---: | ---: | ---: | ---: |
| Normal close | 902.8 | 644.3 | 2,122.9 | 1,931.3 |
| Asynchronous close | 845.2 | 675.7 | 2,011.4 | 1,940.3 |

The stock Git phase went from 179.7 to 140.0 ms on a warm checkout. A separate six-sample comparison of untraced Git checks went from 177.4 to 137.9 ms. In Linux traces, all 1,072 measured closes returned before the release reply with the option enabled. At the original setting each close waited. Aggregate time in those close calls fell from 24.49 to 0.57 ms. Guest thread placement also differed between traces. Whole-host idle during the two workload runs was 79.5% and 78.6%. On the asynchronous setting OrbStack won each of the four warm and four edited job pairs. [Kernel change and lifecycle evidence](virtiofs-workspace-async-release.md) · [Matched hardware results](native-push-and-fuse-gamma.json)

### CPU placement

The first placement comparison used the preceding ordinary kernel and the native registry guest. Ten balanced rounds ran the same unmodified Git command in each allowed CPU set. Both engines recognized a same-size edit with the original mtime and returned clean after restoration. All samples used the same read-only Mac index. Whole-host idle was 82.5% over the run.

| Allowed guest CPUs | Micropod Git (ms) | OrbStack Git (ms) |
| --- | ---: | ---: |
| All four | 181.7 | 50.8 |
| 0 | 115.3 | 54.2 |
| 1 | 179.8 | 55.7 |
| 0 and 1 | 129.1 | 53.7 |
| 2 and 3 | 184.3 | 54.4 |

CPU 0 won all ten rounds against automatic scheduling on Micropod and consumed 37.1 ms of cgroup CPU per check, down from 52.6 ms. OrbStack's automatic scheduling won all ten against CPU 0. In two separate Micropod traces the VirtioFS request completion callbacks and the main request completions all ran on guest CPU 0. [Placement driver](../../../scripts/bench_git_cpu_placement.py) · [Raw samples](native-push-and-fuse-gamma-receipts.tar.gz)

A fresh worker enabled asynchronous close and ran two comparisons. In the full job, only Git inherited the CPU restriction. Go builds and tests could use all four vCPUs within their two-CPU quota. Each engine ran four pairs per condition, checked the edited file's bytes and produced identical binaries for each revision. The eight-container test gave each job half a CPU, 256 MiB and a private read-only copy of the Mac index. All eight stock Git commands overlapped in all 16 scored waves across engines and modes. [Full job driver](../../../scripts/bench_workspace_git_gate.py) · [Eight-job driver](../../../scripts/bench_git_gate_density.py)

| Median time (ms) | Micropod automatic | Micropod Git on CPU 0 | OrbStack automatic | OrbStack Git on CPU 0 |
| --- | ---: | ---: | ---: | ---: |
| One warm Git/build/test job | 842.8 | 802.1 | 678.0 | 674.1 |
| One job after an edit | 2,057.7 | 1,992.8 | 1,984.2 | 1,949.4 |
| Eight concurrent Git checks, first start to last finish | 309.0 | 513.6 | 143.2 | 412.4 |

The single-job Micropod gain held in all four warm and all four edited pairs. Pinning eight jobs to CPU 0 slowed every wave, adding a median paired 204.9 ms on Micropod. Automatic CPU placement remains the shared CI policy. The full-job and eight-container runs recorded 79.4% and 71.1% host idle respectively. [Per-container timings, CPU accounting and cleanup](native-push-and-fuse-gamma-receipts.tar.gz)

On a separate worker, moving only the workspace VirtioFS interrupt moved the fast Git CPU. With the interrupt on CPU 0, Git took 100.9 ms on CPU 0 and 147.4 ms on CPU 1. With the interrupt on CPU 1, those times became 144.3 and 101.7 ms. Automatic placement took 144.7 and 146.0 ms. The exact workspace interrupt delivered 319,427 interrupts to CPU 0 in the first interval and 320,157 to CPU 1 in the second, with zero on the other CPUs in each interval. The experiment restored the original effective CPU and allowed mask. Distributing completions across queues is a candidate for the remaining concurrent CI gap. [IRQ identification and kernel evidence](virtiofs-workspace-async-release.md) · [Control and per-round receipts](native-push-and-fuse-gamma-receipts.tar.gz)

## Registry and Docker API

Guest `a2c8f6de935f` passed stock Docker login with a valid password, rejected an invalid password and refused an unauthorized push. The runner pushed a single tag and all tags for a repository. Docker then pulled a remote-only tag, and its saved image contained the exact expected configuration and layer. A second registry served the same valid credentials with an independently generated, untrusted certificate. Its own authenticated client received 200. Both native login and push failed, and the manifest stayed absent. Only the disposable Linux worker trusted the test CA. [Registry authentication](../../../guest/runner/docker_registry_login_linux.go) · [Push transport](../../../guest/runner/docker_registry_push_linux.go) · [Distribution TLS and authentication](https://distribution.github.io/distribution/about/deploying/)

Eight independent pushes used distinct one-MiB payloads and configurations. On the second native replay every stream had delivered progress during a common 38.4 ms interval, and all eight completed in 150.9 ms. The reference OrbStack daemon passed the same content and authentication checks through a registry published on its loopback interface. Its first-to-last interval was 291.6 ms. Transport and trust differed between the two routes, so these timings establish concurrency on each engine. The stock reference also returned a manifest digest in the remote pull's inspect ID where Micropod returned its config digest. Both archives contained the expected config bytes. [Eight-stream protocol and byte checks](../../../scripts/qualify_docker_push.py) · [containerd 2.4.2 transfer](https://github.com/containerd/containerd/blob/v2.4.2/core/transfer/local/push.go)

Both registry guests ran the unchanged API 1.47 audit. The final guest matched **13 of 24** differential groups and exercised **38 of 107** operations. The separate registry fixture exercised three additional operation IDs, `SystemAuth`, `ImagePush` and `ImageCreate`, bringing the observed union to **41 of 107**. Push with a requested platform, pre-issued registry access tokens, and cross-registry bearer interoperability remain compatibility work. The first live registry binary passed 358 Linux assertions and subtests, with five environment-dependent skips. The focused registry suite passed all 28. [Final pinned audit](native-docker-api-v1.47-image-id-final.json.gz) · [Scorecard and source receipts](native-push-and-fuse-gamma.json)

The eleven differing groups cover the version advertisement and accepted version range, GET and HEAD ping headers, plugins and six Swarm-related groups. The BuildKit service already has an independent managed endpoint. Stock Buildx against the installed native Docker socket, live network attachment, Compose readiness and a sustained mixed CI run remain production acceptance cases. [Final differential](native-docker-api-v1.47-image-id-final.json.gz) · [Managed BuildKit qualification](../2026-11-25/managed-engine-compatibility.md)

### Image removal and retained containers

The first registry guest left nine private image IDs after every named tag was removed. Stock `docker image rm` by ID returned 501. Guest `1a5dc3d7f91b` added removal of an unused single-manifest config ID. The runtime verifies the manifest content against the ID, checks retained Docker and CRI containers and pins, removes verified digest aliases first and removes the config ID last. The nine fixture images each still had immutable import or registry aliases. Unforced removal returned a conflict, and explicit force removed all nine. Full and short ID lookups immediately returned 404 on the separate retention fixture. Physical blob reclamation belongs to containerd GC. [Guarded ID removal](../../../guest/runner/docker_image_id_delete_linux.go) · [Stock-client retention fixture](../../../scripts/qualify_docker_image_id.py)

Both engines returned 409 for removing an image behind a running container, with or without force. Both returned 409 for an unforced request after the container stopped. OrbStack allowed forced removal of the stopped container's image and could still restart the container. Micropod preserved the image and returned 409 for the forced request. After its final tag had moved, both restarted the retained container with the original environment. The stricter native behavior is a remaining Docker difference. [Stock and native responses](native-push-and-fuse-gamma-receipts.tar.gz) · [Docker image removal](https://docs.docker.com/reference/cli/docker/image/rm/)

The first ID-aware guest exposed five outdated history and inspect tests. Their fake CRI responses named a config ID without the corresponding containerd image record. The final guest restored the authoritative records in those fixtures, added explicit missing-ID and legacy hexadecimal-name tests, and collapsed duplicate display names after every raw alias had been removed. Build `e00d6da9b0b2` passed 119 focused Linux cases and subcases. The full suite passed 386 and explicitly skipped five environment-dependent cases. The Go 1.27.2 Linux ARM64 vet completed successfully. Final full and short ID lookups returned 404 immediately, the removed image was absent from the image list, and the preloaded Alpine image remained usable. [Final guest inputs, logs and test counts](native-push-and-fuse-gamma-receipts.tar.gz)

The final push code also leases the selected manifest in containerd. A private forwarding listener paused an actual push after accepting its TCP connection. While the registry was waiting, another request removed the source tag and forced deletion of both its config ID and an unrelated unused ID. Both deletions returned 200 and both IDs returned 404. After the listener resumed, stock Docker finished the push and reported the same manifest digest as the registry. Its config and uncompressed layer matched the original bytes. The concurrent eight-image wave on this guest took 151.9 ms, with all eight streams open together for 37.4 ms. All nine other fixture IDs were also removed before the worker shut down. [Push lease implementation](../../../guest/runner/docker_registry_push_linux.go) · [Paused upload and registry byte checks](../../../scripts/qualify_docker_push.py)

ID deletion currently accepts a verified, unused single manifest. A named image, a pinned image, an unverified descriptor or an index requires separate handling. Direct containerd and BuildKit clients can change metadata independently of the Docker handler's lock. The implementation guards each deletion against a target change and retains the ID until the last step. Concurrent out-of-process changes to a pin on an otherwise identical target and full image pruning remain release cases. [Image ID checks and guarded deletion](../../../guest/runner/docker_image_id_delete_linux.go)

## Scope of the scorecards

The November 24 controlled relay tests favored Standard for bulk throughput in all eight QoS pairs. Interactive reduced fresh-request p95 from 10.19 to 6.36 ms. Two relay workers beat four in all four controlled and four ambient throughput pairs. B3 records the direct bridge and ipvlan networking comparisons. The measurements above exercise the native Docker socket and managed host-mounted CI path in B4.4 and B4.5. B5's snapshot-fork and managed identity gates remain independent. [QoS and workers](../2026-11-24/gamma-qos-and-workers/results.md) · [B3 three-way scorecards](../2026-11-25/phase-b3-results.md) · [B4 and B5 production plan](../../research/2026-11-25-phase-b4-plan.md)

All ten worker volumes and their staging volume passed a read-only remount audit. Spotlight indexing was disabled and each per-volume FSEvents journal contained zero files and zero bytes. On the first registry worker the per-file open-holder probe timed out after a clean shutdown. A whole-volume holder check found zero open files, the raw image inode still matched, and the read-only remount passed. The disks, their guest processes and sockets, the temporary registry credentials and the scoped OrbStack image were removed. All 24 original baseline files and all 24 preserved copies matched the November 24 manifest. The published archive contains 457 individually hashed entries. [Disk audits and artifact manifest](native-push-and-fuse-gamma.json) · [Original baseline manifest](../2026-11-24/disposable-local-fixture/20261124T101312Z-local-iad8j2_g/preserved/manifest.json)
