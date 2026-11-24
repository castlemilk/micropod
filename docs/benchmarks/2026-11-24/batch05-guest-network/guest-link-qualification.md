# Guest link qualification on 24 November 2026

Two deterministic source/fixture experiments use Micropod `7d9b565173a901cb18942e00384838da96e0ba98` and the worker builder's pinned Linux 7.3.5 source. Both were run offline on Darwin/arm64. Neither experiment ran a guest device or collected throughput, fresh-request latency, production loss, CPU/GiB or runnable time. Each has one first-attempt pair. The fixed inputs do not support a statistical interval.

## 233.02 · Can ipvlan inherit the existing private-MAC lease?

One archived macvlan service provided the worker's eth1 hardware address, the child mppub0 hardware address and the same kernel lease map before and after traffic. The workload was one ownership check per arm against the publisher's current Go predicate. The control supplied the recorded child address. For the candidate, the harness compiled the parent-address assignment from Linux's ipvlan driver with a six-byte address-copy shim, then supplied that address to the same compiled predicate. The candidate address is modeled. The kernel records are from `gamma-direct-macvlan.json.gz`, recording base `816121afd30fba52bda7828418cd963d4216166b`, worker `records.workers.trial`.

| Measured admission decision | Recorded private macvlan | Modeled ipvlan address |
| --- | ---: | ---: |
| Endpoint matches leased hardware address | 1/1 | 0/1 |

A kernel built with IPVLAN would still hit the direct publisher's ownership check for this endpoint. Its ingress map also selects the destination Ethernet address from the leased TCP port. Before spending a throughput slot, demonstrate an endpoint selector that works with shared hardware addresses, delivers to the right container and preserves tenant isolation. The ordinary workload-interface ipvlan path is a separate case.

Raw output `ipvlan-identity.json` has SHA-256 `b6a212307b4e4835b9c2e4f7ab715ca04bd77d7325b5158d14e64e742077c046`. The archive, driver-member and publisher digests are in the output. An initial toolchain version mismatch occurred before the Go check executed. The retained runner selects a consistent local Go toolchain. Neither arm ran during the build failure.

## 233.03 · Can source TX counters establish peer-redirect delivery?

The harness compiled the complete `netkit_xmit` and `skb_do_redirect` function bodies from the pinned Linux archive. Device lookup, program invocation, the final destination and the surrounding kernel services are explicit userspace shims. The modeled program requested an egress redirect to an interface's peer. The offered workload was 32 × 1,514-byte frames per arm. Only lookup of the target ifindex changed. Both arms also presented the same independent, synthetic complete-client receipt to the shipping-checkout link verifier to exercise the risk of attributing unrelated bytes.

| Fixed-work observation | Target present | Target absent |
| --- | ---: | ---: |
| Driver returned TX success | 32/32 | 32/32 |
| Source TX bytes | 48,448 | 48,448 |
| Source TX drop-counter increments | 0 | 0 |
| Frames reaching destination shim | 32/32 | 0/32 |
| Frames freed in the missing-target branch | 0/32 | 32/32 |
| Source-TX coverage check with independent receipt | Accepted | Accepted |

The driver increments its TX counter before calling the redirect helper. An invalid target causes the helper to free the packet, while the caller still reports transmit success. Qualify the intended program and peer at both boundaries and match a flow-specific marker or payload digest at the receiving endpoint before using TX counters for attribution. The observed drop is a functional fixture outcome. The compiler initially rejected a name collision in a shim, before either arm ran.

Raw output `netkit-redirect.json` has SHA-256 `7e01509ee7cf6204ea200b73abc278c84dad1082a5ec07c444db632f332113bb`. The two kernel member hashes and both source-TX coverage responses are in the output.

## Local reproduction

Use the same performance checkout, a local Python 3, C compiler and Go compiler. Supply the worker builder's Linux source archive as `KERNEL_ARCHIVE`. Its SHA-256 is `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. The runner verifies the exact extracted source bytes before compiling.

```sh
b=docs/benchmarks/2026-11-24/batch05-guest-network
k=$(mktemp -d)
tar -xJf "$KERNEL_ARCHIVE" -C "$k" linux-7.3.5/drivers/net/ipvlan/ipvlan_main.c \
    linux-7.3.5/drivers/net/netkit.c linux-7.3.5/net/core/filter.c
python3 -B "$b/ipvlan_identity.py" "$k/linux-7.3.5" > "$k/ipvlan-identity.json"
python3 -B "$b/netkit_redirect.py" "$k/linux-7.3.5" > "$k/netkit-redirect.json"
cmp "$k/ipvlan-identity.json" "$b/ipvlan-identity.json"
cmp "$k/netkit-redirect.json" "$b/netkit-redirect.json"
```
