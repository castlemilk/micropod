**24 November 2026 · 233.02 · Qualifying ipvlan against the current published-endpoint ownership check**

Source/fixture at `7d9b565173a901cb18942e00384838da96e0ba98`. Used one real prior macvlan endpoint whose address matched at both ends of the archived trial. The control presented its recorded child address to the current publisher predicate. The only candidate change was to feed the child address computed by the original Linux 7.3.5 ipvlan parent-MAC assignment. Guest driver source SHA-256 `eef07b562f696ce552a56cda013231d0a19d6eb100e5e9ddd95e785941f8c094`.

The same predicate admitted the control 1/1 and rejected the modeled ipvlan child 1/1 for an ownership mismatch. One archived endpoint, deterministic evaluation, no uncertainty estimate. No ipvlan device or network traffic ran. Delivery, fresh p95/p99, drops, throughput, CPU/GiB and runnable time remain unmeasured.

Enabling IPVLAN in the kernel alone cannot qualify the current MAC-keyed publication path. A future isolated guest candidate needs an endpoint identity and forwarding scheme that distinguishes leases sharing the parent MAC, then verified ownership, isolation and service-byte delivery. Raw-verified local output `ipvlan-identity.json` SHA-256 `b6a212307b4e4835b9c2e4f7ab715ca04bd77d7325b5158d14e64e742077c046`, replay `ipvlan_identity.py`. Private endpoint details remain local.
