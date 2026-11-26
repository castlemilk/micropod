# Guest TCP and virtio eBPF observer

24 November 2026 · Instrumentation for direction 231.08 · Source/fixture verification · Local implementation `e7040b8825111bd589202a21f700b40e9cfa7f6c` on batch-seven base `833c2c8ebaf5f51fdfe389c250839f38ea74d2db`.

The diagnostic follows a response from the guest service's TCP send return to the virtio TX queue and the receiving Mac's HTTP body reader. The sender and driver hooks share a guest monotonic interval. A ready/stop handshake encloses one invocation of the existing fixed-arrival client. Its 32 streams and 240 fresh arrivals retain their original scoring window and guardrails. Guest queue totals include other traffic on that queue. The receiver preserves its full-invocation and scored body totals separately. This trace can distinguish a queue charging zero bytes from a failed or misattributed observation. Aggregate counts alone do not locate a delay in time.

| Offline verification | Result |
| --- | --- |
| Compiled eBPF object against the archived stock 7.3.5 arm64 Image | Three hook prototypes matched. All 12 CO-RE relocations resolved, including the TX queue array stride, cumulative charge and service socket scope. The checker rejected three damaged target fixtures with a missing accounting field or hook. |
| Linux guest loader | Go 1.27.2 cross-built static arm64 and x86-64 executables. The compiled object passed the map layout test. Linux arm64 Go vet passed. |
| Original eBPF handler bodies with synthetic kernel helpers | Native C fixture passed under AddressSanitizer and UndefinedBehaviorSanitizer. It covers queue selection, wraparound, a mismatched return, overlaps, boundary crossings, read errors and positive, short, zero and error send returns. |
| Host controller, identity, topology and admission | 40 Python tests passed. Go tests covered sender PID-file changes, task identity, CPU aggregation, timeouts and ABI. A changed guest namespace or workload identity prevents the client from starting. A dirty or interrupted attempt remains in the evidence directory. |

The observed stock kernel Image SHA-256 is `7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd`. The compiled BPF object SHA-256 is `a1efa9cc1f77474b35630e7a60b6a5ae4951296a57176bcc5c1ee8fd8fd948ac`. Apple Clang 21 produced BPF-target LLVM IR with Linux headers. LLVM from the installed Rust 1.99.1 toolchain emitted the checked ELF. The standard Linux build command and full collector invocation are in the [usage guide](../../../../scripts/relaybench/bpf/README.md). [Stock kernel compatibility receipt](stock-corecheck.json) · [Test output and binary hashes](offline-validation.json)

An existing conmon container PID file can supply the sender identity. A saved Netavark setup result can supply an independently cross-checked service interface identity. Both are optional. The stock Micropod diagnostic uses its existing containerd service and network.

At 13:24 AEDT Cuttlefish reported 0/6 leases on Gamma-128GB and 1/1 on isolated Linux. The known owner checkout remained at `ad0646d6292076b6ddf7647f2dc806d785d8f8fb`. The diagnostic had no released, disk-cleared window for an already-serving scope. No probe was attached, and there is no observer-overhead, revised-VM throughput or OrbStack result in this receipt. The count stays at 70 optimization comparisons across 37 registered directions. The untraced revised stock four-vCPU, two-worker baseline and fixed-budget worker comparison remain first in the live queue.
