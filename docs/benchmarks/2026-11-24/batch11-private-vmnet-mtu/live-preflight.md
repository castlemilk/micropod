# Live private MTU preflight

The collector attaches to one already-serving, uniquely named local fixture. Both arms use the signed checkout build recorded in `private-build/build.json` (SHA-256 `ea735da27a7cbef8db1a9201192af431511454ff6f41bc271fdd3ce0d4661af9`). Use the same binary with a persisted `benchmarkPublicationMTU` string of `1500` or `9000`. The launcher's preserved arm scope must still contain the live container ID, supervisor PID, endpoint, and launch job. Run the preflight before the owner tears down the arm.

1. From this directory set `mtu` to the arm MTU and `scope` to its current `.../data/a` or `.../data/b` folder. Select a new local output directory with sufficient capacity.
2. Immediately before and after collecting the route, interface, two-way DF and reverse bridge observations, run the first command below. Save those objects as `identity_before` and `identity_after` inside the same `df.json` receipt. The existing `scripts/relaybench/mtu_path.py` module documents the exact Darwin and Linux commands and raw capture format. At MTU 1500 use a 1,472-byte echo payload. At 9000 use 8,972 bytes. Both arms require independent gateway-bound and worker-bound DF probes and the matching three reverse requests on the actual routed bridge.
3. Once the complete DF receipt exists, use `collect`. It verifies the DF observations before opening one connection to the scoped loopback address. `service-first.json` must be a new file. Partial observations survive failure. Use `replay` for subsequent verification without any network or process inspection.

```sh
python3 -B service_preflight.py identity --mtu "$mtu" --scope "$scope"
python3 -B service_preflight.py collect --mtu "$mtu" --scope "$scope" --df "$out/df.json" --raw "$out/service-first.json"
python3 -B service_preflight.py replay --mtu "$mtu" --raw "$out/service-first.json"
```

The service receives a marker request and an exact HTTP range request over one keep-alive connection. Its 206 response must return the pinned 8 MiB of `micropod` bytes with the full range, expected length and SHA-256. The receiver snapshots that same transfer's Linux service socket via `/mpcheck/ss` and its Mac relay backend via the public proc info API. The relay PID, gateway IPv4 address/port, worker IPv4 address, backend port, service address and service port bind the two readbacks through the direct-path port translation. The effective payload MSS at both senders must be MTU less 40 or 52 bytes (ordinary IPv4/TCP headers, with room for timestamps). A service readback with explicit timestamps must use 52. The service route and socket PMTU must also agree with the selected arm.

This preflight records the effective sender MSS before and after response delivery. SYN-advertised MSS, wire TCP segment sizes, bulk upload delivery and timed throughput are separate measurements. The full-size DF evidence concerns IP packets on the private hop. Access prerequisites are an owner-authorized collector on the actual Mac bridge, a worker-side iputils ping supporting the required identifier and DF flags, namespace-appropriate JSON route/link output, ordinary scoped process visibility and the live pinned service. The recovered post-restart fixture includes `ss`, its libraries, `check` and `pathproof`. Its bundled network packages include `iproute2-minimal`; a verified worker-side iputils ping is still missing.

On 24 November the socket helper compiled against the installed Darwin SDK and synthetic fixtures passed at 1500 and 9000 with the upstream bidirectional DF verifier. Negative fixtures covered mismatched scope and socket, clamped MSS, incorrect PMTU, incomplete/mismatched payload and missing reverse DF evidence. No bridge, VM or network connection was opened for this preparation. Batch credit is zero.
