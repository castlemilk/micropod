# Trace a published TCP download

This opt-in diagnostic follows the existing 32-stream, fixed-arrival Micropod download through the guest TCP sender, the guest virtio transmit queue and the receiving Mac client. It writes one private attempt directory. The scored stock, worker and peer pilots continue to run with tracing off.

| Observation | Counter and scope |
| --- | --- |
| Bytes accepted at the sender | `sender_counters.accepted_bytes` sums positive returns of `tcp_sendmsg` for the verified service TGID, socket namespace and local TCP port. Requested bytes, short writes, zero returns and errors are separate counters. This includes HTTP headers and fresh responses on that service. Calls using other kernel send paths are outside coverage. |
| Bytes offered to the NIC driver | `counters.attempted_bytes` sums SKB lengths at transmit entry on the chosen guest namespace, ifindex and TX queue. A retry can count a buffer again. The queue can also carry traffic from other processes. |
| Bytes charged to the queue | `counters.dql_charged_bytes` sums the unsigned 32-bit change in the queue's cumulative `dql.num_queued` across each matched transmit call. Reclaim updates a different counter. The OK, busy and other driver return counts are separate. The pinned virtio driver can return OK after dropping a buffer. |
| Bytes received by the client | `receiver.invocation_body_bytes` includes warmup, scored work and drain. `receiver.scored_body_bytes` covers the six-second scored interval. Both come from actual HTTP body reads by the Mac client. The raw client output preserves per-stream bytes, fresh p95/p99, errors and reopens. |

The guest hooks aggregate in per-CPU maps. They read kernel metadata and retain no packet contents. Both hooks use the same guest monotonic start and cutoff. The controller waits for the guest's ready receipt, runs the existing client once and requests a stop after it exits. This establishes that the guest capture enclosed the entire client invocation without subtracting timestamps from different machines. The guest interval also includes control latency and a short stop margin. The scored six seconds are a subset. Differences between these byte counts cannot be converted into packet loss, queue depth or time spent waiting.

## Build and check offline

On a Linux build machine with Go, a Clang build supporting the BPF target, Linux UAPI and libbpf development headers, run these from the benchmark checkout. For an arm64 guest set `GOARCH=arm64` if the build machine uses another architecture.

```sh
make -C scripts/relaybench/bpf OUT=.build
export GUEST_TX_TEST_OBJECT="$PWD/scripts/relaybench/bpf/.build/guest_tx.bpf.o"
export GUEST_TX_TEST_TARGET="$STOCK_KERNEL_IMAGE"
make -C scripts/relaybench/bpf test OUT=.build
(cd scripts/relaybench/bpf/guesttx && go run ../corecheck/main.go "$GUEST_TX_TEST_OBJECT" "$GUEST_TX_TEST_TARGET")
(cd scripts/relaybench && python3 -B -m unittest test_guest_tx_trace test_guest_link_path)
```

The compatibility check resolves the object's field relocations against archived kernel BTF and verifies its hook prototypes. Loading on a guest additionally requires usable kernel tracing permissions and kernel verifier acceptance.

## Run one separately admitted diagnostic

Use an owner handoff for mode `guest-tx-trace` and the exact already-serving four-vCPU, two-worker stock scope. The host entry point checks the fleet, effective disk window, fixture identity, direct Reno route, mapped relay build, running service and tool binaries. A current `bql_capture.sh eth1` receipt from the already-authorized guest uplink namespace supplies the expected boot, namespace, MAC, ifindex and queue 0. The two guest artifacts must already be available in the diagnostic scope.

The command below uses `transport` as a shell array for the owner's already-authorized non-TTY guest command transport, with stdin and stdout forwarded. The guest process needs the uplink network namespace and access to the guest's initial-namespace procfs. Supply the guest-initial TGID of the service, the service network namespace inode and its local TCP port. The service namespace can differ from the uplink namespace.

```sh
python3 -B scripts/relaybench/guest_tx_trace.py \
  --scope "$SCOPE" --release "$HANDOFF" --fleet "$FLEET" \
  --tools "$BENCH_TOOLS" --relay-sha256 "$RELAY_SHA" \
  --queue-capture "$QUEUE_BEFORE" --bpf-object "$LOCAL_BPF_OBJECT" --out "$NEW_ATTEMPT_DIR" \
  -- "${transport[@]}" "$GUEST_OBSERVER" --object "$GUEST_BPF_OBJECT" \
  --boot "$GUEST_BOOT" --interface eth1 --queue 0 --duration-ms 60000 --stop-stdin \
  --service-tgid "$SERVICE_TGID" --service-netns "$SERVICE_NETNS" --service-port 8080
```

The host compares the workload cgroup with the running container's verified stats and checks the digest of the service arguments, including its fixture marker. The guest pins the task identity, checks its start time and rechecks the namespace, cgroup and command arguments when the trace ends. Wrong identities, expired admission, an early observer exit, unmatched calls and counter read errors leave an incomplete attempt. A 60-second guest watchdog bounds the attachment if the transport disappears. The raw guest JSONL, standard error and client attempt remain in the output directory. For an explicitly queue-only diagnostic, pass `--queue-only` to the host and omit the service flags on the guest.

**conmon.** For a service already launched under conmon, `--service-pidfile PATH` can replace `--service-tgid` using conmon's container PID file. The conmon monitor's own PID identifies a different process. The Micropod stock service uses its existing containerd workload identity. Neither path needs a new monitor process. [conmon lifecycle](https://github.com/containers/conmon) · [conmon PID file options](https://github.com/containers/conmon/blob/main/docs/conmon.8.md)

**Netavark.** For an existing Netavark fixture, add `--netavark-status SAVED_SETUP.json --network NETWORK` to `guest_link_path.py` with its ordinary capture, device, link kind and direction arguments. It verifies the saved interface name and MAC against both observed service snapshots and records the saved file digest, boot, namespace and interface index. This consumes an existing setup result. The stock Micropod path uses its own observed topology. [Netavark](https://github.com/containers/netavark) · [Network status fields](https://docs.rs/netavark/latest/netavark/network/types/struct.StatusBlock.html)

## Read the first capture

Start with the raw attempt's delivery errors, fresh latency, interface drops and per-process CPU and runnable time. If service sends and driver attempts are present while the charge stays zero on a complete trace, check the effective queue-0 TX NAPI mode with `guest_nic_capture.sh --tx-queue0`. If charges are present and receiver progress stalls, queue-stop/completion timing and per-stream receiver progress are the next discriminators. These aggregate counters establish what the guest accounted for. The first admitted traced/untraced control comparison should measure observer overhead before anyone uses traced throughput to compare configurations.
