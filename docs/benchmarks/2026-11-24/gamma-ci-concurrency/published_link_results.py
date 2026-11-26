"""Verify the negotiated publication path and replay the container and relay measurements."""

import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from statistics import median

import low_level
from qualify import peer, relay
from replay import check, check_retirement, common, read


def link(folder, arms):
    plan = read(folder, "plan.json")
    mtu = plan["publication_mtu"]
    fixtures = read(folder, "fixtures-before.json")
    worker = fixtures["A"]
    count = plan.get("link_workers", 2)
    build = read(folder, "worker-build.json") if (folder / "worker-build.json").exists() else {}
    from private_link import BUILD_SHA

    if not build or not build.get("guest_mtu_at_boot"):
        check(plan["worker"] == BUILD_SHA, "unrecognized private MTU worker")
    else:
        patch = folder / "worker.patch"
        check(
            hashlib.sha256(patch.read_bytes()).hexdigest() == build["patch_sha256"],
            "production feature patch differs from the binary build receipt",
        )
    kernel_sha = relay.STOCK_KERNEL
    if "kernel_page_kib" in plan:
        from build_pages import verify_run
        kernel_sha = verify_run(folder, plan, fixtures)
    elif "mthp_16k" in plan:
        from build_thp import verify_run
        kernel_sha = verify_run(folder, plan, fixtures)
    peer.verify_arms(
        fixtures, kernel_sha=kernel_sha,
        candidate_sha=plan["worker"],
        workers=count,
        callback_events=128 if count == 2 else 24,
        read_bytes=plan["relay_read_kib"] * 1024 if plan.get("relay_read_kib") else build.get("experimental_read_bytes", 262144),
        process_type=plan.get("link_role", "Standard"),
        source_revision=build.get("base_revision", relay.STOCK_RELAY_REV),
    )
    publication = worker["publication"]
    check(
        publication["worker"] == worker["worker"]
        and publication["instance"] == worker["instance"]
        and publication["candidate_sha256"] == plan["worker"]
        and publication["mtu"] == mtu,
        "wrong publication owner",
    )
    sizes = {256, 1472, mtu - 28} | ({2000} if mtu > 1500 else set())
    df = read(folder, "df.json")
    check(
        len(df) == len(sizes) * 3
        and all(row["result"] == "verified" for row in df)
        and {(r["bytes"], r["attempt"]) for r in df} == {(n, i) for n in sizes for i in range(3)},
        "DF echo failed",
    )
    check(
        re.search(rf"^bridge\d+:.*\bmtu {mtu}$", (folder / "host-link.txt").read_text(), re.MULTILINE)
        and re.search(rf"^\d+: eth1:.*\bmtu {mtu}\b", (folder / "guest-link.txt").read_text(), re.MULTILINE),
        "private NIC MTU mismatch",
    )
    result = {
        **({"kernel_page_kib": plan["kernel_page_kib"], "kernel_image_sha256": kernel_sha} if "kernel_page_kib" in plan else {}),
        **({"mthp_16k": plan["mthp_16k"], "kernel_image_sha256": kernel_sha} if "mthp_16k" in plan else {}),
        "mtu": mtu,
        "workers": count,
        "receive_mode": plan.get("relay_mode", "kqueue-interactive"),
        "process_type": worker["process_type"],
        "callback_events": worker["callback_events"],
        "read_bytes": worker["read_bytes"],
    }
    if plan.get("parent_reply_mac"):
        result["rewritten_reply_packets"] = parent_reply_packets(folder)
    if activity := plan.get("concurrent_host_work"):
        result["concurrent_host_work"] = activity
    if plan.get("guest_ipv4_tso") == "off":
        original, applied, final = [
            (folder / f"ipv4-tso-{suffix}.txt").read_text() for suffix in ("before", "applied", "after")
        ]
        check("tx-tcp-segmentation: on" in original and applied == final
              and "tx-tcp-segmentation: off" in final and "generic-receive-offload: on" in final
              and "tx-tcp6-segmentation: on" in final, "guest segmentation settings changed")
        result["guest_ipv4_tso"] = "off"
    if cap := plan.get("guest_gso_bytes"):
        at_boot = plan.get("gso_at_creation")
        phases = ("before", "after") if at_boot else ("before", "applied", "after")
        sizes = (cap, cap) if at_boot else (65536, cap, cap)
        captures = sorted(folder.glob("guest-*-gso-*.txt"))
        original = read(folder, "ipv4-gso-before.json")
        for path, phase, size in zip(captures, phases, sizes, strict=True):
            macs = read(folder, f"ipv4-gso-{phase}.json")
            check(len(macs) == 33 and set(macs) == set(original) and set(macs.values()) == {str(size)},
                  "private publication GSO limit or lease identity changed")
            state = dict(line.split() for line in path.read_text().splitlines())
            check(state == {**macs, "parent": str(size), "ipv4-tso": "on"},
                  "parent or service segmentation limit differs from its live readback")
        result["guest_ipv4_gso_limit"] = cap
        if at_boot:
            (live,) = folder.glob("guest-*-runner-sha.txt")
            if plan.get("gso_origin") == "worker":
                sha = build["guest_runner_sha256"]
                check(read(folder / "a", "worker.json")["publishedGSOBytes"] == cap,
                      "worker did not persist the measured GSO limit")
            else:
                sha = read(folder, "guest-runner-build.json")["binary_sha256"]
            check(live.read_text().strip() == sha == plan["guest_runner_sha256"], "running guest engine differs")
            result["guest_runner_sha256"] = sha
    if limit := plan.get("guest_tsq_bytes"):
        import kernel_ci

        captures = sorted(folder.glob("guest-*-tsq-*.txt"))
        states = [dict(line.split() for line in path.read_text().splitlines()) for path in captures]
        if plan.get("docker_tsq"):
            original, final = states
            tenants = read(folder, "tenants-A-32.json")["tenants"]
            reference = read(folder, "tenants-B-32.json")["tenants"]
            alternate = plan.get("alternate_docker_tsq")
            queues = (limit, alternate or limit)
            check(len(reference) == 32 and all(j["identity"]["tcp_queue"] == str(queues[i % 2])
                                               for i, j in enumerate(reference)),
                  "OrbStack services did not receive the matching Docker queue")
            check(final == kernel_ci.small_queue_state(original, limit, tenants, alternate), "Docker queue readback differs")
            if alternate:
                result["alternate_docker_tsq"] = alternate
            (live,) = folder.glob("guest-*-runner-sha.txt")
            source = build if plan["boot_steering"] == "worker" else read(folder, "guest-runner-build.json")
            key = "guest_runner_sha256" if plan["boot_steering"] == "worker" else "binary_sha256"
            check(live.read_text().strip() == plan["guest_runner_sha256"] == source[key], "running engine differs")
            result.update(docker_tsq=True, guest_runner_sha256=source[key])
        else:
            original, applied, final = states
            check(applied == final == kernel_ci.small_queue_state(original, limit), "TCP queue or GSO readback differs")
        result.update(guest_tsq_bytes=limit, original_tsq_bytes=int(original["tsq-root"]))
    if qdisc := plan.get("private_qdisc"):
        captures = sorted(folder.glob("guest-*-qdisc-*.txt"))
        check(len(captures) == 3, "missing private NIC queue receipts")
        (initial,), (applied,), (final,) = [json.loads(path.read_bytes()) for path in captures]
        check(initial["kind"] == "fq" and all(q["root"] for q in (initial, applied, final))
              and initial["ifindex"] == applied["ifindex"] == final["ifindex"]
              and all(q["gso_ipv4_bytes"] == 65536 for q in (initial, applied, final))
              and applied["kind"] == final["kind"] == qdisc and applied["handle"] == final["handle"]
              and final["bytes"] > applied["bytes"], "private NIC queue was not active for the comparison")
        result.update(private_qdisc=qdisc, private_qdisc_delta={
            key: final[key] - applied[key] for key in ("bytes", "packets", "drops", "overlimits", "requeues")
        })
    journal = (folder / "a/service.stderr").read_text()
    result["oom_watch_errors"] = sum("failed to watch oom events" in line for line in journal.splitlines())
    if plan.get("guest_start_sha256"):
        guest_facts = (folder / "guest-link.txt").read_text()
        limit = int(re.search(r"^inotify_instances=(\d+)$", guest_facts, re.MULTILINE)[1])
        check(limit >= 512 and result["oom_watch_errors"] == 0
              and plan["guest_start_sha256"] == plan["sources"]["ci/runner/start.sh"],
              "guest bootstrap did not supply healthy containerd OOM watches")
        result.update(inotify_instances=limit, guest_start_sha256=plan["guest_start_sha256"])
    if plan.get("boot_steering"):
        proof = read(folder, "boot-steering.json")
        start, end = proof["before"], proof["after"]
        guest_boot = (folder / "guest-link.txt").read_text().splitlines()
        script = plan["guest_publication_sha256"]
        check(
            "requested_rps=off-irq" in guest_boot and "rx0_rps=7" in guest_boot
            and script == plan["sources"]["ci/runner/published-ports.sh"]
            and all(start[k] == end[k] for k in ("boot", "virtio", "ifindex", "irq", "driver", "effective"))
            and start["driver"] == "virtio_net" and start["effective"] == "3"
            and start["boot"] == worker["guest_boot"]
            and int(start["rps_cpus"], 16) == int(end["rps_cpus"], 16) == 7,
            "guest boot did not keep its verified publication receive queue",
        )
        flow = plan.get("flow_steering")
        receive_cpus = plan.get("receive_cpus")
        first, last = start, end
        if receive_cpus:
            receipt = read(folder, "receive-cpus.json")
            first, last = receipt["applied"], receipt["final"]
            mask = {"irq-pair": 12, "all": 15}[receive_cpus]
            check(receipt["initial"] == start and all(x[k] == start[k] for k in
                  ("boot", "ifindex", "virtio", "irq", "effective", "driver") for x in receipt.values())
                  and int(first["rps_cpus"], 16) == int(last["rps_cpus"], 16) == mask
                  and int(receipt["restored"]["rps_cpus"], 16) == 7 and flow == "off",
                  "private receive CPU mask or restoration differs")
            result["receive_cpus"] = receive_cpus
        deltas = [(int(last[f"received_rps_{cpu:08x}"], 16) - int(first[f"received_rps_{cpu:08x}"], 16)) % 2**32
                  for cpu in range(4)]
        expected_wakeups = [2] if receive_cpus == "irq-pair" else [0, 1, 2]
        check(all(deltas[i] > 0 for i in expected_wakeups)
              and (flow == "on" or receive_cpus or deltas[3] == 0), "unexpected receive steering CPUs")
        if flow:
            settings = read(folder, "flow-steering.json")
            original, configured = settings["before"], settings["configured"]
            test_keys = ("boot", "virtio", "ifindex", "irq", "effective", "rps_cpus", "egress_flow_entries")
            check(flow in ("on", "off") and original["boot"] == worker["guest_boot"]
                  and int(original["rps_cpus"], 16) == int(first["rps_cpus"], 16)
                  and all(original[k] == configured[k] for k in test_keys)
                  and original["queue_flow_entries"] == "0", "wrong starting flow steering configuration")
            tables = [configured[k] for k in ("global_flow_entries", "queue_flow_entries")]
            check(tables == (["32768", "32768"] if flow == "on" else [original["global_flow_entries"], "0"]),
                  "socket and private queue flow tables differ from the requested setting")
            result.update(flow_steering=flow, socket_and_private_flow_entries=list(map(int, tables)))
        if plan["boot_steering"] == "worker":
            check(script == build["guest_publication_script_sha256"]
                  and read(folder / "a", "worker.json")["publishedRPS"] == "off-irq",
                  "worker did not select the production steering policy")
        result.update(receive_steering=plan["boot_steering"], guest_publication_sha256=script,
                      rps_wakeups_by_cpu=deltas)
        sent = int(end["tx_bytes"]) - int(start["tx_bytes"])
        packets = int(end["tx_packets"]) - int(start["tx_packets"])
        kicks = int(end["tx_kicks"]) - int(start["tx_kicks"])
        check(sent > 0 and packets > 0 and kicks > 0, "private transmit counters did not advance")
        result.update(private_tx_bytes_per_driver_packet=sent / packets,
                      private_tx_kicks_per_driver_gib=kicks * 2**30 / sent)
    for arm in arms:
        services = read(folder, f"tenants-{arm}-32.json")["tenants"]
        if placement := plan.get("service_cpus"):
            check(placement in ("shared", "spread", "pairs"), "unknown service CPU placement")
            for phase in ("before", "after"):
                sample = read(folder, f"service-cpus-{arm}-{phase}.json")
                check(len(sample) == len(services) == 32, "missing service thread masks")
                for i, (m, service) in enumerate(zip(sample, services, strict=True)):
                    expected = str(i // 2 % 4) if placement == "spread" else "0-3"
                    if placement == "pairs":
                        expected = "0-1" if i % 4 < 2 else "2-3"
                    check(m["id"] == service["id"] and m["name"] == service["name"] and m["mask"] == expected
                          and m["threads"] > 0, "service thread affinity or identity changed")
                    if plan.get("docker_cpuset"):
                        check(m.get("cgroup_cpus") == expected, "service cgroup CPU mask differs")
            result["service_cpus"] = placement
            if plan.get("docker_cpuset"):
                result["docker_cpuset"] = True
                if "guest_runner_sha256" not in result:
                    (live,) = folder.glob("guest-*-runner-sha.txt")
                    sha = (build["guest_runner_sha256"] if plan.get("boot_steering") == "worker" else
                           read(folder, "guest-runner-build.json")["binary_sha256"])
                    check(live.read_text().strip() == sha == plan["guest_runner_sha256"], "CPU placement engine differs")
                    result["guest_runner_sha256"] = sha
                proof = read(folder, "docker-cpuset-restart.json")
                check(proof["states"] == [["1-2", "1-2", "100000 100000"]] * 2 and proof["removed"]
                      and proof["out_of_range"] == "0,4" and "CPU 4 is unavailable" in proof["rejection"],
                      "container restart, quota or out-of-allocation rejection differs")
        evidence = read(folder, f"link-{arm}.json")
        check(
            len(services) == len(evidence) == 32
            and [(s["name"], s["cookie"]) for s in services] == [(s["name"], s["cookie"]) for s in evidence],
            "socket identity differs",
        )
        if arm == "A":
            check(
                all(s["links"]["mppub0"] == mtu and mtu - 80 <= s["mss"] <= mtu - 40 for s in evidence),
                "guest MSS differs",
            )
        result[arm + "_mss"] = sorted({s["mss"] for s in evidence})
    if (folder / "relay-backends.json").exists():
        rows = read(folder, "relay-backends.json")
        tenants = read(folder, "tenants-A-32.json")["tenants"]
        check(
            len(rows) == 32 and len({r["after"]["peer_port"] for r in rows}) == 32, "missing backend sockets"
        )
        for row, tenant in zip(rows, tenants, strict=True):
            check(all(row[k] == tenant[k] for k in ("name", "cookie", "port")), "backend owner changed")
            before, after = row["before"], row["after"]
            check(
                all(
                    before[k] == after[k]
                    for k in ("pid", "local_port", "local_address", "peer_port", "peer_address", "send_mss")
                )
                and after["pid"] == worker["pids"]["relay"]
                and after["peer_address"] == publication["worker_ipv4"]
                and mtu - 80 <= after["send_mss"] <= mtu - 40,
                "changed live backend",
            )
        result["host_receive_space_bytes"] = [
            min(r["after"]["receive_space"] for r in rows),
            max(r["after"]["receive_space"] for r in rows),
        ]
    if (folder / "worker-build.json").exists():
        check(
            build["worker_executable_sha256"] == plan["worker"]
            and build["base_revision"] == worker["mapped_relay_build"]["source_revision"],
            "worker source or binary differs",
        )
        if build.get("guest_mtu_at_boot"):
            check(worker["relay_controls_origin"] == "live worker session", "missing production controls")
            result["worker_revision"] = build["base_revision"]
            result["worker_sha256"] = plan["worker"]
            members = re.findall(r"member: (vmenet[0-9]+)", (folder / "host-link.txt").read_text())
            check(
                len(set(members)) >= 2
                and all(
                    re.search(rf"^{name}:.*\bmtu {mtu}$", (folder / f"{name}.txt").read_text(), re.MULTILINE)
                    for name in members
                ),
                "host bridge attachment MTU differs",
            )
        if (folder / "worker-ext4.txt").exists():
            (root_options,) = [
                line.split()[1]
                for line in (folder / "worker-ext4.txt").read_text().splitlines()
                if line.startswith("/ ")
            ]
            result["root_ext4_options"] = root_options.split(",")
        if plan.get("ext4_batch_us") is not None:
            check(
                f"max_batch_time={plan['ext4_batch_us']}" in result.get("root_ext4_options", []),
                "ext4 commit interval differs",
            )
            result["ext4_batch_us"] = plan["ext4_batch_us"]
    if (folder / "link-repair.json").exists():
        recovery = read(folder, "link-repair.json")
        check(
            [recovery[k] for k in ("original", "disturbed", "end")] == [mtu, 1500, mtu]
            and recovery["worker_receipt"]["instance"].lower() == publication["instance"].lower()
            and recovery["worker_receipt"]["cause"] == "guest-link-restored"
            and not recovery["worker_receipt"].get("error")
            and recovery["existing_service"] == publication["name"],
            "private MTU repair receipt differs",
        )
        result["repair_seconds"] = recovery["seconds"]
        if (folder / "service-links-after-repair.json").exists():
            after = read(folder, "service-links-after-repair.json")
            initial = read(folder, "link-A.json")
            check(
                recovery["existing_mtu_before"] == recovery["existing_mtu_after"] == mtu
                and len(after) == len(initial) == 32
                and all(
                    all(a[k] == b[k] for k in ("name", "cookie", "mss", "links"))
                    and a["links"]["mppub0"] == mtu
                    for a, b in zip(after, initial, strict=True)
                ),
                "existing service MTUs or TCP segment sizes differ after recovery",
            )
            result["recovered_service_count"] = len(after)
    return result


def scored_build_slots(row, build_slots=4):
    """Lower bound on mean occupied CI slots in the client's scored interval."""
    origin = row["job_release_monotonic_s"]
    start = row["invocation"]["started_s"] - origin
    end = row["invocation"]["ended_s"] - origin
    scored = row["client"]["window_s"]
    check(0 < scored <= end - start, "invalid client measurement clock")
    occupied = sum(max(0.0, min(end, j["finished_s"]) - max(start, j["submitted_s"])) for j in row["jobs"])
    # Warm-up and drain can each occupy all slots. Subtract their maximum
    # contribution because the pinned client only exposes its scored duration.
    return max(0.0, occupied - build_slots * (end - start - scored)) / scored


def published_targets(folder):
    targets = {}
    for arm in "AB":
        path = folder / f"targets-{arm}.tsv"
        services = read(folder, f"tenants-{arm}-32.json")["tenants"]
        expected = "".join(f"http://127.0.0.1:{s['port']}\t{s['name']}\n" for s in services)
        check(path.read_bytes() == expected.encode(), "client targets differ from the published services")
        targets[arm] = path, hashlib.sha256(path.read_bytes()).hexdigest()
    return targets


def invocation_process_work(row, pid):
    client = row["client"]
    return relay.process_work(
        row["counter_before"], row["counter_after"], pid, client["bytes"],
        invocation_bytes=relay.invocation_bulk_bytes(client, clean=True),
    )


def flow_window(row, service_ids, configured):
    a, b = row["counter_before"], row["counter_after"]
    old, new = a["service_cgroups"], b["service_cgroups"]
    check(set(old) == set(new) == service_ids and len(service_ids) == 32, "service cgroups changed")
    usage = Counter()
    for cid in service_ids:
        for k in ("usage_usec", "nr_throttled", "throttled_usec"):
            delta = new[cid][k] - old[cid][k]
            check(delta >= 0, "service CPU counter regressed")
            usage[k] += delta
    gib = relay.invocation_bulk_bytes(row["client"], clean=True) / 2**30
    out = {"service_cpu_s_per_bulk_gib": usage["usage_usec"] / 1e6 / gib,
           "service_throttled_s": usage["throttled_usec"] / 1e6, "service_throttled_periods": usage["nr_throttled"]}
    if not configured:
        return out
    before, after = a["guest_queue"], b["guest_queue"]
    keys = ("boot", "virtio", "driver", "ifindex", "irq", "effective", "rps_cpus",
            "global_flow_entries", "queue_flow_entries", "egress_flow_entries")
    check(all(before[k] == after[k] == configured[k] for k in keys), "flow table or NIC changed during a window")
    for k in ("tx_errors", "rx_errors", "tx_dropped", "rx_dropped", "tx_tx_timeouts"):
        check(before[k] == after[k], "private NIC drop, timeout or error during flow steering comparison")
    tx = int(after["tx_bytes"]) - int(before["tx_bytes"])
    kicks = int(after["tx_kicks"]) - int(before["tx_kicks"])
    packets = int(after["tx_packets"]) - int(before["tx_packets"])
    check(min(tx, kicks, packets) > 0, "private transmit counters did not advance in the client window")
    out.update(driver_kicks_per_driver_gib=kicks * 2**30 / tx, driver_bytes_per_packet=tx / packets)
    totals = [0, 0, 0]
    wakeups = 0
    for cpu in range(4):
        key = f"softnet_{cpu:08x}"
        for i, (first, last) in enumerate(zip(before[key].split(","), after[key].split(","), strict=True)):
            totals[i] += (int(last, 16) - int(first, 16)) % 2**32
        key = f"received_rps_{cpu:08x}"
        wakeups += (int(after[key], 16) - int(before[key], 16)) % 2**32
    for key, metric in (("irq_counts", "private_irq_per_driver_gib"), ("NET_RX", "guest_rx_softirq_per_driver_gib")):
        old, new = (s[key].split(",") for s in (before, after))
        check(len(old) == len(new) == 4, "interrupt receipt has a different CPU topology")
        out[metric] = sum((int(b) - int(a)) % 2**32 for a, b in zip(old, new, strict=True)) * 2**30 / tx
    out["guest_rps_wakeups_per_driver_gib"] = wakeups * 2**30 / tx
    out.update(softnet_processed=totals[0], softnet_dropped=totals[1], softnet_budget_exhausted=totals[2])
    return out


def build_cpu_window(row):
    stats = [j["cpu_stat_delta"] for j in row["jobs"] if j["kind"] == "pass"]
    return {"builds_throttled": sum(v["nr_throttled"] > 0 for v in stats),
            "build_throttled_s": sum(v["throttled_usec"] for v in stats) / 1e6,
            "build_user_s": sum(v["user_usec"] for v in stats) / 1e6,
            "build_system_s": sum(v["system_usec"] for v in stats) / 1e6}


def peer_run(folder):
    import kernel_ci

    result = low_level.file_peer(folder)
    result["link"] = link(folder, "AB")
    if placement := read(folder, "plan.json").get("build_cpu_placement"):
        result["link"]["build_cpu_placement"] = placement
        result["link"]["build_scratch"] = read(folder, "plan.json")["build_scratch"]
        result["build_execution"] = {}
        for arm, name in (("A", "micropod"), ("B", "orbstack")):
            rows = [read(folder, f"churn-{i}-{arm}.json") for i in range(8)]
            usage = [build_cpu_window(row) for row in rows]
            filesystems = Counter(j["scratch_mount"]["filesystem"] for row in rows for j in row["jobs"] if j["kind"] == "pass")
            result["build_execution"][name] = {
                "windows": len(rows), "healthy_jobs_by_scratch_filesystem": dict(filesystems),
                "throttled_healthy_jobs": sum(v["builds_throttled"] for v in usage),
                "median_per_window": {k: median(v[k] for v in usage) for k in usage[0]},
            }
            if read(folder, "plan.json").get("build_accounting"):
                from build_pages import summarize_usage
                result["build_execution"][name]["go_phases"] = summarize_usage(rows)
            if ("kernel_page_kib" in result["link"] and not read(folder, "plan.json").get("build_accounting")) or "mthp_16k" in result["link"]:
                from build_pages import vm_changes
                result["build_execution"][name]["guest_memory"] = vm_changes(folder, arm)
            if result["link"]["build_scratch"] == "volume":
                cleanup = read(folder, f"build-scratch-cleanup-{arm}.json")
                caches = cleanup["shared_caches"]
                check(cleanup["service"] == read(folder, f"tenants-{arm}-32.json")["tenants"][0]["id"]
                      and cleanup["remaining_scratch"] == [] and len(caches) == 2
                      and all(re.fullmatch(rf"/cache/{kind} \d+:\d+", record)
                              for kind, record in zip(("build", "mod"), caches, strict=True)),
                      "private build scratch survived or a cache directory disappeared")
    result["build_slots"] = read(folder, "file-peer-plan.json")["build_slots"]
    result["unverified_build_overlap"] = []
    check(read(folder, "file-peer-plan.json")["fixed_client_sha256"] == peer.CLIENT, "wrong peer client")
    targets = published_targets(folder)
    for offset, mode in enumerate(kernel_ci.peer_modes("mixed_services" in result)):
        windows = {arm: [read(folder, f"churn-{i}-{arm}.json") for i in range(offset, 8, 2)] for arm in "AB"}
        for arm, rows in windows.items():
            path, digest = targets[arm]
            check(
                all(
                    row["invocation"]["arguments"] == ["--targets", str(path)]
                    and row["invocation"]["target_sha256"] == digest
                    for row in rows
                ),
                "client did not use the published ports",
            )
            bounds = {
                f"churn-{row['block']}-{arm}.json": scored_build_slots(row, result["build_slots"])
                for row in rows
            }
            result["conditions"][arm + "-" + mode]["min_scored_build_slots_lower_bound"] = min(
                bounds.values()
            )
            result["unverified_build_overlap"].extend(name for name, slots in bounds.items() if slots == 0)
        for key in ("provision_and_inspect_s", "provision_to_final_cleanup_s"):
            for arm, rows in windows.items():
                check(
                    all(
                        0 < r["provision_and_inspect_s"] < r["provision_to_final_cleanup_s"]
                        and r["last_job_s"] < r["provision_to_final_cleanup_s"]
                        for r in rows
                    ),
                    "invalid CI lifecycle receipt",
                )
                result["conditions"][arm + "-" + mode][key] = median(r[key] for r in rows)
            ratios = [a[key] / b[key] for a, b in zip(windows["A"], windows["B"], strict=True)]
            result["paired"][f"B-{mode}_to_A-{mode}"][key] = {
                "median_ratio": median(ratios),
                "higher": sum(x > 1 for x in ratios),
            }
        for arm, rows in windows.items():
            if result["link"].get("service_cpus") in ("spread", "pairs"):
                masks = [s["mask"] for s in read(folder, f"service-cpus-{arm}-before.json")]
                by_mask, slowest = defaultdict(list), Counter()
                for row in rows:
                    client = row["client"]
                    streams = client["per_stream_bytes"]
                    for mask in set(masks):
                        total = sum(n for cpu, n in zip(masks, streams, strict=True) if cpu == mask)
                        by_mask[mask].append(total / 2**20 / client["window_s"])
                    minimum = min(streams)
                    for mask in {cpu for cpu, n in zip(masks, streams, strict=True) if n == minimum}:
                        slowest[mask] += 1
                condition = result["conditions"][arm + "-" + mode]
                condition["mib_s_by_service_cpu_mask"] = {k: median(v) for k, v in sorted(by_mask.items())}
                condition["windows_with_slowest_service_by_mask"] = dict(sorted(slowest.items()))
            if rows[0].get("counter_before") is None:
                continue
            fixture = read(folder, "fixtures-before.json")[arm]
            if "flow_steering" in result["link"]:
                service_ids = {str(t["identity"]["cgroup"]) for t in read(folder, f"tenants-{arm}-32.json")["tenants"]}
                configured = read(folder, "flow-steering.json")["configured"] if arm == "A" else None
                windows_work = [flow_window(row, service_ids, configured) for row in rows]
                result["conditions"][arm + "-" + mode].update(
                    {key: median(w[key] for w in windows_work) for key in windows_work[0]})
            for role, pid in fixture["pids"].items():
                costs = [invocation_process_work(row, pid)["invocation_cpu_s_per_bulk_gib"] for row in rows]
                result["conditions"][arm + "-" + mode][role + "_cpu_s_per_gib"] = median(costs)
    return result


def steering_run(folder):
    import kernel_ci

    settings = link(folder, "AB")
    plan = read(folder, "steering-plan.json")
    fixed = plan["initial"]
    fixtures = read(folder, "fixtures-before.json")
    order = plan["order"]
    slots = plan["build_slots"]
    check(
        order == kernel_ci.paired_order(("A-local", "A-steered", "B-ref0", "B-ref1"), plan["order_seed"])
        and slots in (4, 6, 8) and plan["artifact"] == "memory"
        and plan["service_file_sha256"] == kernel_ci.BODY_SHA and plan["fixed_client_sha256"] == peer.CLIENT
        and fixed["boot"] == fixtures["A"]["guest_boot"]
        and fixed["effective"] == "3" and fixed["driver"] == "virtio_net",
        "receive steering setup differs",
    )
    identity = ("boot", "virtio", "ifindex", "irq", "effective", "driver")
    restored = read(folder, "steering-restored.json")
    check(int(fixed["rps_cpus"], 16) == int(restored["rps_cpus"], 16) == 0
          and all(fixed[k] == restored[k] for k in identity), "wrong final receive queue")
    targets = published_targets(folder)
    for arm in "AB":
        low_level.service_memory(folder, arm)
        check_retirement(folder, arm)
    seen, products, blocks, overlap = set(), {}, [], []
    for i, conditions in enumerate(order):
        block = {}
        for condition in conditions:
            arm, mode = condition.split("-")
            index = 2 * i + int(mode in ("steered", "ref1"))
            row = read(folder, f"churn-{index}-{arm}.json")
            path, digest = targets[arm]
            check(row["invocation"]["arguments"] == ["--targets", str(path)]
                  and row["invocation"]["target_sha256"] == digest
                  and row["arm"] == arm and row["block"] == index, "incorrect window or client target")
            score, hashes = low_level.window(row, seen, "0-3", slots)
            check(products.setdefault(index, hashes) == hashes, "CI build artifacts differ across engines")
            overlap.append(scored_build_slots(row, slots))
            before, after = row["counter_before"], row["counter_after"]
            c = row["client"]
            n = relay.invocation_bulk_bytes(c, clean=True)
            for role, pid in fixtures[arm]["pids"].items():
                work = relay.process_work(before, after, pid, c["bytes"], invocation_bytes=n)
                score[role + "_cpu_s_per_gib"] = work["invocation_cpu_s_per_bulk_gib"]
            score["provision_to_final_cleanup_s"] = row["provision_to_final_cleanup_s"]
            if arm == "A":
                start, end = before["guest_queue"], after["guest_queue"]
                mask = 7 if mode == "steered" else 0
                check(
                    all(s[k] == fixed[k] for s in (start, end) for k in identity)
                    and int(start["rps_cpus"], 16) == int(end["rps_cpus"], 16) == mask,
                    "receive mask or queue changed during measurement",
                )
                irqs = [int(b) - int(a) for a, b in zip(start["irq_counts"].split(","),
                                                          end["irq_counts"].split(","), strict=True)]
                check(len(irqs) == 4 and irqs[:3] == [0, 0, 0] and irqs[3] > 0, "IRQ placement changed")
                for cpu in range(4):
                    key = f"received_rps_{cpu:08x}"
                    score[f"rps_wakeups_cpu{cpu}"] = (int(end[key], 16) - int(start[key], 16)) % 2**32
                for key in ("tx_errors", "rx_errors", "tx_dropped", "rx_dropped"):
                    check(start[key] == end[key], "NIC errors or drops during the comparison")
                score["virtio_tx_kicks_per_gib"] = (int(end["tx_kicks"]) - int(start["tx_kicks"])) * 2**30 / n
            block[condition] = score
        blocks.append(block)
    check(min(overlap) > 0, "scored window had unverified CI overlap")
    pairs = [("A-local", "A-steered"), ("B-ref0", "A-local"), ("B-ref1", "A-steered")]
    result = low_level.summary(blocks, pairs)
    return dict(result, link=settings, build_slots=slots, min_scored_build_slots_lower_bound=min(overlap),
                paired_build_products=sum(map(len, products.values())), healthy_jobs=480,
                intentional_failures=16, intentional_cancellations=16, fresh=3840)


def route_run(folder):
    result = {"link": link(folder, "A")}
    plan = read(folder, "routes-plan.json")
    order = plan["order"]
    check(
        plan["source"] == "memory"
        and plan["client"] == peer.CLIENT
        and sorted(order) == [["direct", "loopback"]] * 2 + [["loopback", "direct"]] * 2,
        "wrong paired routes",
    )
    routes = read(folder, "relay-backends.json")
    direct = (folder / "direct-targets.tsv").read_text()
    expected = "".join(
        f"http://{r['after']['peer_address']}:{r['after']['peer_port']}\t{r['name']}\n" for r in routes
    )
    check(
        direct == expected and hashlib.sha256(direct.encode()).hexdigest() == plan["direct_sha256"],
        "direct target file differs",
    )
    low_level.service_memory(folder, "A")
    check_retirement(folder, "A")
    pids = read(folder, "fixtures-before.json")["A"]["pids"]
    ids, blocks = set(), []
    for i, pair in enumerate(order):
        block = {}
        for j, route in enumerate(pair):
            r = read(folder, f"churn-{2 * i + j}-A.json")
            path = folder / ("direct-targets.tsv" if route == "direct" else "targets-A.tsv")
            invocation = r["invocation"]
            check(
                invocation["arguments"] == ["--targets", str(path)]
                and invocation["target_sha256"] == hashlib.sha256(path.read_bytes()).hexdigest(),
                "unexpected transfer path",
            )
            row, _ = low_level.window(r, ids, "0-3")
            n = relay.invocation_bulk_bytes(r["client"], clean=True)
            for role in ("relay", "vmm"):
                work = relay.process_work(
                    r["counter_before"],
                    r["counter_after"],
                    pids[role],
                    r["client"]["bytes"],
                    invocation_bytes=n,
                )
                row[role + "_cpu_s_per_gib"] = work["invocation_cpu_s_per_bulk_gib"]
            block[route] = row
        blocks.append(block)
    result["conditions"] = {k: {m: median(b[k][m] for b in blocks) for m in blocks[0][k]} for k in order[0]}
    ratios = [b["direct"]["mib_s"] / b["loopback"]["mib_s"] for b in blocks]
    return dict(
        result,
        paired_direct_to_loopback=median(ratios),
        direct_wins=sum(x > 1 for x in ratios),
        healthy_jobs=240,
        intentional_failures=8,
        intentional_cancellations=8,
        fresh=1920,
    )


def parent_reply_packets(folder):
    proof = (folder / "parent-replies.txt").read_text()
    mac = re.search(r"^parent_mac=([\da-f:]{17})$", proof, re.MULTILINE)[1]
    check("link/ether " + mac + " brd " in (folder / "guest-link.txt").read_text(),
          "rewritten source differs from the private parent")
    rule = rf"ether saddr \. tcp sport @replies ether saddr set {mac} counter packets ([1-9]\d*) bytes [1-9]\d* accept"
    return int(re.search(rule, proof)[1])


def handshake_window(folder, row):
    """Count TCP setup observed on the guest's private parent during this invocation."""
    backends = [r["after"] for r in read(folder, "relay-backends.json")]
    (guest,) = {r["peer_address"] for r in backends}
    (gateway,) = {r["local_address"] for r in backends}
    ports = {r["peer_port"] for r in backends}
    lo, hi = (row[key]["epoch_ns"] / 1e6 for key in ("counter_before", "counter_after"))
    incoming, replies = defaultdict(list), defaultdict(list)
    following_replies = {}
    resets, arp = Counter(), Counter()
    in_macs, out_macs = Counter(), Counter()
    lines = (folder / "publication-setup-trace").read_text().splitlines()
    for line in lines:
        fields = line.split()
        if len(fields) < 5 or fields[0] != "eth1" or not lo <= int(fields[1]) <= hi + 1000:
            continue
        stamp = int(fields[1])
        if fields[2].startswith("arp="):
            if stamp <= hi:
                arp[fields[2] + " " + fields[4]] += 1
            continue
        src, dest = fields[3].split(">")
        src_ip, src_port = src.rsplit(":", 1)
        dst_ip, dst_port = dest.rsplit(":", 1)
        flags = int(fields[4].split("=")[1], 16)
        if stamp > hi:
            if (src_ip, dst_ip) == (guest, gateway) and int(src_port) in ports and flags & 18 == 18:
                key = int(dst_port), int(src_port)
                following_replies[key] = min(following_replies.get(key, stamp), stamp)
            continue
        if (src_ip, dst_ip) == (gateway, guest) and int(dst_port) in ports:
            key = int(src_port), int(dst_port)
            if flags & 2 and not flags & 16:
                incoming[key].append(stamp)
                in_macs[fields[2].split(">")[1]] += 1
            if flags & 4:
                resets["from_mac"] += 1
        elif (src_ip, dst_ip) == (guest, gateway) and int(src_port) in ports:
            key = int(dst_port), int(src_port)
            if flags & 18 == 18:
                replies[key].append(stamp)
                out_macs[fields[2].split(">")[0]] += 1
            if flags & 4:
                resets["from_guest"] += 1
    delay = [min(replies[k]) - min(ts) for k, ts in incoming.items() if k in replies]
    stalled = {k[1] for k, ts in incoming.items() if k not in replies or min(replies[k]) - min(ts) >= 1000}
    start = min((min(ts) for ts in incoming.values()), default=None)
    first = {k for k, ts in incoming.items() if min(ts) < start + 1000}
    result = {
        "timestamp_source": "kernel socket" if "# clock=kernel-socket-realtime-ms" in lines else "guest userspace",
        "first_second_syn_ports": len({k[1] for k in first}),
        "first_second_syn_flows_with_reply_within_second": sum(k in replies and min(replies[k]) < start + 1000 for k in first),
        "incoming_syn_destination_macs": dict(in_macs),
        "outgoing_synack_source_macs": dict(out_macs),
        "guest_window_observed_syn_flows": len(incoming),
        "guest_window_unanswered_syn_flows": len(incoming.keys() - replies.keys()),
        "guest_window_retransmitted_syns": sum(len(ts) - 1 for ts in incoming.values()),
        "guest_window_retransmitted_synacks": sum(len(ts) - 1 for ts in replies.values()),
        "guest_window_first_synack_median_ms": median(delay) if delay else None,
        "guest_window_first_synack_max_ms": max(delay, default=None),
        "guest_window_ports_with_missing_or_delayed_synack": sorted(stalled),
        "guest_window_resets": dict(resets),
        "guest_window_arp": dict(arp),
    }
    after_window = [following_replies[k] - min(incoming[k])
                    for k in (incoming.keys() - replies.keys()) & following_replies.keys()]
    result["syn_flows_answered_in_following_second"] = len(after_window)
    result["first_synack_after_window_max_delay_ms"] = max(after_window, default=None)
    pressure = list(folder.glob("guest-*-pressure-stop.txt"))
    if pressure:
        (capture,) = pressure
        samples = [dict(field.split("=", 1) for field in line.split()) for line in capture.read_text().splitlines()]
        # Discard the partial seconds at both edges. Guest uptime measures the intervals within the sample.
        selected = [s for s in samples if lo <= int(s["epoch"]) * 1000 and (int(s["epoch"]) + 1) * 1000 <= hi]
        if len(selected) >= 2:
            intervals = [(float(b["uptime"]) - float(a["uptime"]), a, b) for a, b in zip(selected, selected[1:])]
            check(all(dt > 0 for dt, _, _ in intervals), "guest pressure sampler clock regressed")
            summary = {"samples": len(selected), "longest_sample_interval_s": max(dt for dt, _, _ in intervals),
                       "peak_runnable_tasks": max(int(s["procs_running"]) for s in selected),
                       "peak_blocked_tasks": max(int(s["procs_blocked"]) for s in selected)}
            # The aggregate /proc/stat line counts time over all four guest CPUs.
            cpu_fractions = []
            for _, a, b in intervals:
                ticks = [int(b[f"cpu{i}"]) - int(a[f"cpu{i}"]) for i in range(8)]
                total = sum(ticks)
                if total > 0 and min(ticks) >= 0:
                    cpu_fractions.append(((total - ticks[3] - ticks[4]) / total, ticks[4] / total))
            if cpu_fractions:
                summary["peak_busy_cpu_fraction"] = max(busy for busy, _ in cpu_fractions)
                summary["peak_iowait_cpu_fraction"] = max(wait for _, wait in cpu_fractions)
            if all("tx_bytes" in s for s in selected):
                rates = [(int(b["tx_bytes"]) - int(a["tx_bytes"])) / dt / 2**20 for dt, a, b in intervals]
                if min(rates) >= 0:
                    summary["min_private_tx_mib_s"] = min(rates)
                    summary["max_private_tx_mib_s"] = max(rates)
            for key in ("cpu_some_us", "io_some_us", "io_full_us", "memory_full_us"):
                if all(key in s for s in selected):
                    summary[key + "_peak_fraction"] = max((int(b[key]) - int(a[key])) / (dt * 1e6)
                                                          for dt, a, b in intervals)
            result["guest_pressure"] = summary
    return result


def pooled_peer(folders, results):
    """Combine paired blocks from independent boots of the same production configuration."""
    identity = None
    boots = set()
    seeds = set()
    mixed = "mixed_services" in results[folders[0].name]
    samples = {"mixed": []} if mixed else {"memory": [], "file": []}
    process_samples = defaultdict(list)
    for folder in folders:
        result = results[folder.name]
        fixtures = read(folder, "fixtures-before.json")
        fixture = fixtures["A"]
        settings = result["link"]
        key = tuple(
            settings[name]
            for name in (
                "worker_sha256",
                "mtu",
                "workers",
                "receive_mode",
                "process_type",
                "callback_events",
                "read_bytes",
                "root_ext4_options",
            )
        )
        key += (result["build_slots"], settings.get("receive_steering"), settings.get("guest_publication_sha256"),
                settings.get("guest_start_sha256"), settings.get("guest_runner_sha256"),
                settings.get("guest_tsq_bytes"), settings.get("alternate_docker_tsq"),
                settings.get("guest_ipv4_gso_limit"), settings.get("docker_tsq"), settings.get("flow_steering"),
                settings.get("service_cpus"), settings.get("receive_cpus"), settings.get("docker_cpuset"),
                settings.get("build_cpu_placement"), settings.get("build_scratch"), settings.get("mthp_16k"),
                settings.get("kernel_image_sha256"), "mixed_services" in result)
        if mixed:
            plan = read(folder, "plan.json")
            key += (plan["tenant_binary_sha256"], plan["job_sha256"], plan["manifest_id"],
                    fixture["kernel_image_sha256"], fixtures["B"]["engine_version"], fixtures["B"]["release"],
                    read(folder, "file-peer-plan.json").get("dispatch_sha256"), plan.get("accounted_job_sha256"), plan.get("build_usage_sha256"))
        check(
            identity is None or key == identity,
            "cannot pool different workers, CI concurrency or workloads",
        )
        identity = key
        check(fixture["guest_boot"] not in boots, "repeat uses the same guest boot")
        boots.add(fixture["guest_boot"])
        if mixed:
            seed = read(folder, "file-peer-plan.json")["order_seed"]
            check(seed not in seeds, "mixed repeat uses the same order")
            seeds.add(seed)
        for offset, mode in enumerate(samples):
            for i in range(offset, 8, len(samples)):
                pair = {}
                for arm in "AB":
                    r = read(folder, f"churn-{i}-{arm}.json")
                    c = r["client"]
                    pair[arm] = {
                        "mib_s": c["mib_s"],
                        "fresh_p95_ms": c["fresh_p95_us"] / 1000,
                        "fresh_p99_ms": c["fresh_p99_us"] / 1000,
                        "last_job_s": r["last_job_s"],
                        "provision_to_final_cleanup_s": r["provision_to_final_cleanup_s"],
                    }
                    if mixed:
                        stream_bytes = c["per_stream_bytes"]
                        pair[arm]["slowest_stream_mib_s"] = min(stream_bytes) / 2**20 / c["window_s"]
                        for parity, group in ((i % 2, "file"), (1 - i % 2, "memory")):
                            pair[arm][group + "_streams_mib_s"] = sum(stream_bytes[parity::2]) / 2**20 / c["window_s"]
                        if r.get("counter_before") is not None:
                            for role, pid in fixtures[arm]["pids"].items():
                                process_samples[arm, role].append(invocation_process_work(r, pid))
                samples[mode].append(pair)
    out = {
        "runs": [f.name for f in folders],
        "worker_sha256": results[folders[0].name]["link"]["worker_sha256"],
        "build_slots": results[folders[0].name]["build_slots"],
        "receive_steering": results[folders[0].name]["link"].get("receive_steering", "kernel default"),
    }
    for key in ("fresh", "healthy_jobs", "intentional_failures", "intentional_cancellations"):
        out[key] = sum(results[f.name][key] for f in folders)
    if process_samples:
        work = {"micropod": {}, "orbstack": {}}
        for (arm, role), rows in process_samples.items():
            engine = "micropod" if arm == "A" else "orbstack"
            counters = {"windows": len(rows)}
            for metric in ("cpu_s_per_bulk_gib", "instructions_per_bulk_byte", "cycles_per_bulk_byte"):
                values = [r["invocation_" + metric] for r in rows]
                if all(v is not None for v in values):
                    counters[metric] = median(values)
            work[engine][role] = counters
        out["host_process_work"] = work
    if mixed and settings.get("docker_tsq"):
        limit = settings["guest_tsq_bytes"]
        alternate = settings.get("alternate_docker_tsq", limit)
        out["docker_queue_bytes_even_odd"] = [limit, alternate]
        if limit != alternate:
            samples["file-even"] = samples["mixed"][::2]
            samples["file-odd"] = samples["mixed"][1::2]
    for mode, rows in samples.items():
        out[mode] = {"pairs": len(rows)}
        for metric in rows[0]["A"]:
            ratios = [p["A"][metric] / p["B"][metric] for p in rows]
            out[mode][metric] = {
                "micropod_median": median(p["A"][metric] for p in rows),
                "orbstack_median": median(p["B"][metric] for p in rows),
                "paired_micropod_to_orbstack": median(ratios),
                "micropod_higher": sum(x > 1 for x in ratios),
            }
    return out


def compare_scheduling(control, candidate, results):
    """Match the same service modes, CI inputs and temporal positions on two fresh boots."""
    folders = (control, candidate)
    plans = [read(d, "plan.json") for d in folders]
    fixtures = [read(d, "fixtures-before.json") for d in folders]
    runs = [results[d.name] for d in folders]
    fields = ("worker", "guest_runner_sha256", "guest_start_sha256", "guest_publication_sha256", "tenant_binary_sha256",
              "job_sha256", "ci_config_sha256", "manifest_id", "layer_ids", "host", "cpus", "vm_mib",
              "job_cpus", "job_mib", "pids", "cache", "fresh_per_second", "link_role", "link_workers", "relay_mode", "publication_mtu",
              "guest_tsq_bytes", "alternate_docker_tsq", "docker_tsq", "mixed_artifacts", "guest_gso_bytes",
              "relay_read_kib", "boot_steering", "ext4_batch_us", "private_qdisc", "guest_ipv4_tso", "parent_reply_mac",
              "docker_cpuset", "trace_handshakes", "build_accounting", "build_usage_sha256", "accounted_job_sha256", "pagecompat_sha256")
    schedules = [read(d, "file-peer-plan.json") for d in folders]
    page_pair = [p.get("kernel_page_kib") for p in plans] == [4, 16]
    thp_pair = [p.get("mthp_16k") for p in plans] == ["never", "always"]
    if thp_pair:
        check(read(control, "mthp-build.json") == read(candidate, "mthp-build.json"), "THP policy used different builds")
        for arm in "AB":
            before, after = [read(d, f"kernel-vm-{arm}-before.json") for d in folders]
            policies = [{k: v for k, v in x["sizes"].items() if arm == "B" or k != "hugepages-16kB"} for x in (before, after)]
            check(before["thp_policy"] == after["thp_policy"] and policies[0] == policies[1], "other THP policies changed")
    if page_pair:
        check(read(control, "kernel-page-pair.json") == read(candidate, "kernel-page-pair.json"),
              "page variants belong to different kernel builds")
    # file_peer has already verified the requested build placement in every window.
    for order in schedules:
        del order["build_cpus"]
    check(all(plans[0].get(k) == plans[1].get(k) for k in fields)
          and schedules[0] == schedules[1]
          and fixtures[0]["A"]["guest_boot"] != fixtures[1]["A"]["guest_boot"]
          and (page_pair or fixtures[0]["A"]["kernel_image_sha256"] == fixtures[1]["A"]["kernel_image_sha256"])
          and fixtures[0]["A"]["cli_sha256"] == fixtures[1]["A"]["cli_sha256"] == plans[0]["worker"]
          and fixtures[0]["B"]["engine_version"] == fixtures[1]["B"]["engine_version"]
          and all(run["link"].get("flow_steering") and not run["unverified_build_overlap"] for run in runs),
          "CI inputs, order, counter collection or platforms differ")
    changed = {k: [p.get(k, "off-irq" if k == "receive_cpus" else None) for p in plans]
               for k in ("service_cpus", "flow_steering", "receive_cpus", "build_cpu_placement", "build_scratch", "kernel_page_kib", "mthp_16k")
               if plans[0].get(k) != plans[1].get(k)}
    check(len(changed) == 1 and next(iter(changed.values())) in
          (["off", "on"], ["shared", "spread"], ["shared", "pairs"], ["spread", "pairs"],
           ["off-irq", "irq-pair"], ["off-irq", "all"], ["root", "volume"], [4, 16], ["never", "always"]),
          "expected one controlled scheduling change")
    out = {"runs": [d.name for d in folders], "change": changed}
    if (page_pair or thp_pair) and plans[0].get("build_accounting"):
        from build_pages import compare_usage
        out["go_phases"] = {name: compare_usage(control, candidate, arm)
                            for arm, name in (("A", "micropod"), ("B", "orbstack"))}
    from kernel_ci import peer_modes
    mixed = plans[0].get("mixed_artifacts", False)
    schedules = [(mode, range(parity, 8, 2)) for parity, mode in enumerate(peer_modes(mixed))]
    if mixed:
        schedules.append(("mixed", range(8)))
    for mode, indices in schedules:
        out[mode] = {}
        throughput_ratios = {}
        for arm, engine in (("A", "micropod"), ("B", "orbstack")):
            series = []
            for folder, fixture in zip(folders, fixtures, strict=True):
                rows = []
                ids = {str(t["identity"]["cgroup"]) for t in read(folder, f"tenants-{arm}-32.json")["tenants"]}
                configured = read(folder, "flow-steering.json")["configured"] if arm == "A" else None
                for i in indices:
                    row = read(folder, f"churn-{i}-{arm}.json")
                    cpu = flow_window(row, ids, configured)
                    sample = {"mib_s": row["client"]["mib_s"], "fresh_p95_ms": row["client"]["fresh_p95_us"] / 1000,
                              "slowest_stream_mib_s": min(row["client"]["per_stream_bytes"]) / 2**20 / row["client"]["window_s"],
                              "last_job_s": row["last_job_s"], "lifecycle_s": row["provision_to_final_cleanup_s"],
                              "healthy_build_cpu_s": sum(receipt["cpu_s"] for job in row["jobs"] for receipt in job["receipts"]),
                              "service_cpu_s_per_bulk_gib": cpu["service_cpu_s_per_bulk_gib"]}
                    if mixed:
                        streams = row["client"]["per_stream_bytes"]
                        for source, parity in (("file", i % 2), ("memory", 1 - i % 2)):
                            sample[source + "_streams_mib_s"] = sum(streams[parity::2]) / 2**20 / row["client"]["window_s"]
                    if plans[0].get("build_cpu_placement"):
                        sample.update(build_cpu_window(row))
                    for role, pid in fixture[arm]["pids"].items():
                        sample[role + "_cpu_s_per_bulk_gib"] = invocation_process_work(row, pid)["invocation_cpu_s_per_bulk_gib"]
                    if configured:
                        for key in ("driver_kicks_per_driver_gib", "private_irq_per_driver_gib",
                                    "guest_rx_softirq_per_driver_gib", "guest_rps_wakeups_per_driver_gib"):
                            sample[key] = cpu[key]
                    rows.append(sample)
                series.append(rows)
            metrics = {}
            for key in series[0][0]:
                old, new = ([r[key] for r in rows] for rows in series)
                if key in ("builds_throttled", "build_throttled_s"):
                    metrics[key] = {"control": median(old), "candidate": median(new),
                                    "median_change": median(b - a for a, b in zip(old, new, strict=True)),
                                    "pairs": len(old)}
                    continue
                ratios = [b / a for a, b in zip(old, new, strict=True)]
                if key == "mib_s":
                    throughput_ratios[engine] = ratios
                metrics[key] = {"control": median(old), "candidate": median(new),
                                "median_ratio": median(ratios), "higher": sum(r > 1 for r in ratios), "pairs": len(ratios)}
            out[mode][engine] = metrics
        if not changed.keys() & {"service_cpus", "build_cpu_placement", "build_scratch"}:
            adjusted = [a / b for a, b in zip(throughput_ratios["micropod"], throughput_ratios["orbstack"], strict=True)]
            out[mode]["throughput_ratio_relative_to_reference"] = {
                "median": median(adjusted), "higher": sum(r > 1 for r in adjusted), "pairs": len(adjusted)}
    return out


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--pool",
        nargs="+",
        type=Path,
        action="append",
        required=True,
        help="independent peer runs of the same production build, latest group last",
    )
    parser.add_argument("--mixed-pool", nargs="+", type=Path, action="append",
                        help="independent boots of one mixed-service configuration, repeat for another configuration")
    parser.add_argument("--compare-scheduling", nargs=2, type=Path, action="append", metavar=("CONTROL", "CANDIDATE"),
                        help="match fresh receive steering or service affinity boots with the same CI order")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    peers, routes, steering, traced, transmit, excluded, boots = {}, {}, {}, {}, {}, {}, {}
    for folder in sorted(here.glob("20*-*link-*/status.json")):
        folder = folder.parent
        status = read(folder, "status.json")
        if status.get("profile") in ("link-peer", "link-route", "link-steering") and status["complete"]:
            profile = common(folder)
            if profile == "link-steering":
                steering[folder.name] = steering_run(folder)
            elif profile == "link-peer":
                measured = peer_run(folder)
                plan = read(folder, "plan.json")
                if measured["unverified_build_overlap"]:
                    excluded[folder.name] = {
                        "complete": True,
                        "error": "scored CI build overlap could not be verified",
                        "windows": measured["unverified_build_overlap"],
                        "scope_removed": True,
                    }
                    if plan.get("kernel_page_kib"):
                        diagnostics = {}
                        for name in measured["unverified_build_overlap"]:
                            w = read(folder, name)
                            warm = w["client"]["bulk_body_bytes"]["warmup"]
                            totals = warm["per_stream_bytes"]
                            diagnostics[name] = {
                                "client_invocation_s": w["invocation"]["ended_s"] - w["invocation"]["started_s"],
                                "scored_s": w["client"]["window_s"], "last_job_s": w["last_job_s"],
                                "warmup_bytes": warm["bytes"], "slowest_warmup_stream": totals.index(min(totals)),
                                "warmup_bytes_min": min(totals), "warmup_bytes_second_lowest": sorted(totals)[1],
                                "reopened": w["client"]["reopened"],
                            }
                        excluded[folder.name]["overlap_diagnostics"] = diagnostics
                elif plan.get("trace_handshakes"):
                    measured["setup_windows"] = {r.name: handshake_window(folder, read(folder, r.name))
                                                 for r in sorted(folder.glob("churn-*-A.json"))}
                    traced[folder.name] = measured
                elif any(key in plan for key in
                         ("guest_tsq_bytes", "private_qdisc", "parent_reply_mac", "guest_ipv4_tso", "guest_gso_bytes",
                          "flow_steering", "service_cpus")):
                    transmit[folder.name] = measured
                else:
                    peers[folder.name] = measured
            else:
                routes[folder.name] = route_run(folder)
        else:
            cleanup = read(folder, "cleanup.json") if (folder / "cleanup.json").exists() else {}
            entry = {
                "complete": status["complete"],
                "error": status.get("error"),
                "windows_recorded": len(list(folder.glob("churn-*.json"))),
                "scope_removed": cleanup.get("retained") is False and not cleanup.get("errors"),
            }
            if (folder / "parent-replies.txt").is_file():
                entry["rewritten_reply_packets"] = parent_reply_packets(folder)
            if (folder / "ipv4-tso-after.txt").is_file():
                entry["guest_ipv4_tso_off_at_end"] = "tx-tcp-segmentation: off" in (folder / "ipv4-tso-after.txt").read_text()
            if (folder / "ipv4-gso-applied.json").is_file() or (folder / "ipv4-gso-before.json").is_file():
                entry["guest_ipv4_gso_limit"] = read(folder, "plan.json")["guest_gso_bytes"]
            if (folder / "plan.json").exists() and (limit := read(folder, "plan.json").get("guest_tsq_bytes")):
                entry["guest_tsq_bytes"] = limit
            if (folder / "plan.json").exists() and (qdisc := read(folder, "plan.json").get("private_qdisc")):
                entry["private_qdisc"] = qdisc
            if (folder / "plan.json").exists() and read(folder, "plan.json").get("boot_steering"):
                entry["boot_steering"] = read(folder, "plan.json")["boot_steering"]
                log = folder / "a/service.stderr"
                if log.exists():
                    journal = log.read_text()
                    entry["oom_watch_errors"] = journal.count("failed to watch oom events")
                    profiles = [json.loads(line.split("published TCP profile ", 1)[1]) for line in journal.splitlines()
                                if "published TCP profile {" in line]
                    dial = [{k: row[k] for k in ("first_dial_stage", "first_dial_errno", "last_connect_errno",
                             "accepted", "connected", "route_waits")} for row in profiles if "first_dial_stage" in row]
                    if dial:
                        entry["published_dial_failures"] = dial
                    diagnostics = re.findall(r"published TCP local network diagnostic guest=(\S+) udp_path=(\S+)", journal)
                    if diagnostics:
                        (address, outcome), = diagnostics
                        check(address == read(folder / "a", "session.json")["publishedAddress"],
                              "privacy diagnostic used a different guest address")
                        entry["mac_local_network_diagnostic"] = outcome
                        entry["direct_tcp_probes_passed"] = sum(
                            r.get("correct") is True for r in read(folder, "boot-routes.json"))
                entry["failed_job_receipts"] = [path.name for path in sorted(folder.glob("failed-job-*.json"))]
            if (folder / "link-repair.json").exists():
                recovery = read(folder, "link-repair.json")
                entry["repair_seconds"] = recovery.get("seconds")
                if "existing_mtu_after" in recovery:
                    entry["service_mtu_after"] = recovery["existing_mtu_after"]
            if (folder / "failed-network-counters.json").is_file():
                values = read(folder, "failed-network-counters.json")
                first, last = values["before"], values["after"]
                if all(first[k] == last[k] for k in ("boot", "virtio", "ifindex", "driver")):
                    entry["failed_run_nic_delta"] = {
                        key: int(last[key]) - int(first[key]) for key in
                        ("tx_tx_timeouts", "tx_errors", "tx_dropped", "rx_errors", "rx_dropped", "tx_kicks")
                    }
            if status.get("guest_repair_only") and status["complete"]:
                proof = read(folder, "guest-service-repair.json")
                owner = read(folder, "identity.json")
                plan = read(folder, "plan.json")
                lowered = (folder / "repair-lowered-links").read_text().splitlines()
                check(
                    proof["control"] == "native Docker Unix socket"
                    and len(set(proof["services"]))
                    == len(set(proof["published_endpoints"]))
                    == len(lowered)
                    == 32
                    and all(" mtu 1500 " in line for line in lowered)
                    and proof["before"] == proof["after"] == [plan["mtu"]] * 32
                    and owner["candidate_sha256"] == plan["build"]
                    and recovery["worker_receipt"]["instance"].lower() == owner["instance"].lower()
                    and entry["scope_removed"]
                    and read(folder, "verification.json")
                    == {"baseline_files": 24, "extra_cleanup_errors": []},
                    "invalid control-plane recovery evidence",
                )
                entry["recovered_services"] = len(lowered)
                if "kernel_page_kib" in plan or "mthp_16k" in plan:
                    import build_pages
                    runtime = read(folder, "kernel-page-runtime.json")
                    kib = plan.get("kernel_page_kib", 4)
                    if "mthp_16k" in plan:
                        import build_thp
                        image = read(folder, "mthp-build.json")["image"]
                        build_thp.validate_boot((folder / "mthp-policy.txt").read_text().splitlines(),
                                                (folder / "a/guest-facts.txt").read_text().splitlines(), plan["mthp_16k"])
                        entry["mthp_16k"] = plan["mthp_16k"]
                    else:
                        image = read(folder, "kernel-page-pair.json")["control" if kib == 4 else "candidate"]
                    build_pages.validate_mappings(runtime["mapping"], kib)
                    check(runtime["container"] == owner["container"] and runtime["kernel_image_sha256"]
                          == plan["kernel_image_sha256"] == image["image_sha256"]
                          and runtime["kernel_config_sha256"] == plan["kernel_config_sha256"] == image["config_sha256"]
                          and "config_sha256=" + image["config_sha256"] in (folder / "a/guest-facts.txt").read_text().splitlines(),
                          "packaged kernel provenance differs")
                    entry["kernel_page_kib"] = kib
                    if plan.get("node_sqlite"):
                        import node_pages
                        db = read(folder, "node-sqlite-pages.json")
                        check(db["image_id"] == node_pages.INDEX and db["source_sha256"] ==
                              hashlib.sha256((folder / "node-pages.mjs").read_bytes()).hexdigest(), "Node input differs")
                        node_pages.verify(db["stages"], kib)
                        entry["sqlite_rows"] = db["stages"]["verify"]["rows"]
                if plan.get("docker_cpu_sets"):
                    masks = read(folder, "docker-cpu-sets.json")
                    product = read(folder, "worker-build.json")
                    requested = [None, "0", "1-2", "0,3"] * 8
                    (engine,) = folder.glob("guest-*-runner-sha.txt")
                    check(product["worker_executable_sha256"] == plan["build"]
                          and product["guest_runner_sha256"] == plan["guest_runner_sha256"] == engine.read_text().strip()
                          and masks["services"] == proof["services"] and masks["requested"] == requested
                          and masks["before"] == masks["after"] == [m or "0-3" for m in requested]
                          and masks["restarted"] == proof["services"][3], "packaged CPU placement or repair differs")
                    entry["docker_cpu_sets"] = dict(Counter(masks["after"]))
                if plan.get("docker_tcp_queues"):
                    queues = read(folder, "docker-tcp-queues.json")
                    default = queues["worker_default"]
                    targets = [int(n) if n is not None else default for n in queues["requested"]]
                    check(len(targets) == 32 and queues["services"] == proof["services"]
                          and set(targets) == {163840, 196608, default} and default > 196608
                          and queues["before"] == queues["after_start"] == targets
                          and queues["restarted"] == queues["services"][1],
                          "per-container TCP queues changed across restart")
                    captures = sorted(folder.glob("guest-*-tsq-read.txt"))
                    check(len(captures) == 2, "missing TCP queue readback before or after restart")
                    for record in captures:
                        state = dict(line.split() for line in record.read_text().splitlines())
                        counts = Counter(int(v) for k, v in state.items() if k.startswith("tsq-") and k != "tsq-root")
                        check(counts == Counter(targets) and int(state["tsq-root"]) == default,
                              "kernel TCP queues differ from service namespaces")
                    entry.update(docker_tcp_queues=dict(Counter(targets)), tcp_queue_restart=True)
                if limit := plan.get("worker_gso_bytes"):
                    captures = sorted(folder.glob("guest-*-gso-*.txt"))
                    (engine,) = folder.glob("guest-*-runner-sha.txt")
                    product = read(folder, "worker-build.json")
                    check(product["worker_executable_sha256"] == plan["build"]
                          and product["guest_runner_sha256"] == engine.read_text().strip() == plan["guest_runner_sha256"]
                          and read(folder / "a", "worker.json")["publishedGSOBytes"] == limit,
                          "packaged native GSO configuration or engine differs")
                    leases = None
                    for path, size in zip(captures, (limit, 65536, limit), strict=True):
                        raw = dict(line.split() for line in path.read_text().splitlines())
                        check(raw.pop("ipv4-tso") == "on" and raw.pop("parent") == str(size)
                              and len(raw) == 32 and set(raw.values()) == {str(size)}
                              and (leases is None or set(raw) == leases), "native GSO recovery changed lease or limit")
                        leases = set(raw)
                    entry.update(worker_gso_bytes=limit, repaired_gso_services=len(leases),
                                 guest_runner_sha256=plan["guest_runner_sha256"])
                if limit := plan.get("parent_only_gso"):
                    fact = read(folder, "gso-inheritance.json")
                    before = (folder / "repair-owned-links").read_text()
                    child_limits = [int(x) for x in re.findall(r"\bgso_ipv4_max_size (\d+)", before)]
                    check(len(child_limits) == 32 and child_limits == fact["child_limits"] and fact["parent"] == limit
                          and f"gso_ipv4_max_size {limit} " in (folder / "guest-link.txt").read_text(),
                          "private GSO inheritance readback differs")
                    entry["parent_gso_bytes"] = limit
                    entry["child_gso_counts"] = dict(Counter(child_limits))
                    if "guest_runner_sha256" in plan:
                        candidate = read(folder, "guest-runner-build.json")
                        check(set(child_limits) == {limit} and candidate["binary_sha256"] == plan["guest_runner_sha256"],
                              "guest candidate did not propagate the private NIC limit")
                        entry["guest_runner_sha256"] = candidate["binary_sha256"]
                if plan.get("boot_steering") == "worker":
                    queue = recovery["publication_queue_before"]
                    check(queue == recovery["publication_queue_after"] and int(queue[0]) > 0
                          and int(queue[1], 16) == 7
                          and read(folder / "a", "worker.json")["publishedRPS"] == "off-irq",
                          "native worker lost receive steering during guest repair")
                    entry["recovered_receive_mask"] = queue[1]
                if plan.get("verified_oom_watch"):
                    fault = read(folder, "oom-fault.json")
                    running = set(fault["running_at_release"])
                    left = set(fault["running_after"])
                    check(len(running) == 64 and len(left) == 63 and running - {fault["target"]} == left
                          and set(proof["services"]).issubset(left)
                          and fault["target_limit"] == 32 << 20 and fault["wait"] == fault["state"]["ExitCode"] == 137
                          and fault["state"]["OOMKilled"] and not fault["state"]["Running"]
                          and entry["oom_watch_errors"] == 0
                          and "inotify_instances=512" in (folder / "guest-link.txt").read_text().splitlines(),
                          "native worker did not isolate and classify the bounded OOM")
                    entry["oom_fault_surviving_siblings"] = len(left)
                    if plan.get("guest_start_origin") == "packaged":
                        product = read(folder, "worker-build.json")
                        check(product["worker_executable_sha256"] == owner["candidate_sha256"]
                              and product["guest_start_sha256"] == plan["guest_start_sha256"]
                              and product["guest_publication_script_sha256"] == plan["guest_publication_sha256"],
                              "native worker booted a different runner bundle")
                        entry["guest_start_origin"] = "packaged"
            for path in sorted(folder.glob("churn-*.json")):
                row = read(folder, path.name)
                if row["client_exit"]:
                    entry["failed_window"] = {
                        "file": path.name,
                        "reopened": row["client"]["reopened"],
                        "fresh": row["client"]["arrivals"],
                        "errors": row["client"]["errors"] or [],
                        "invocation_s": row["invocation"]["ended_s"] - row["invocation"]["started_s"],
                        "last_job_s": row["last_job_s"],
                    }
                    if (folder / "publication-setup-trace").exists() and row["arm"] == "A":
                        entry["failed_window"].update(handshake_window(folder, row))
            (excluded if status.get("profile") else boots)[folder.name] = entry
    groups = [pooled_peer([p.resolve() for p in cohort], peers) for cohort in args.pool]
    mixed_groups = []
    inputs = peers | transmit
    for cohort in args.mixed_pool or []:
        check(len(cohort) >= 2 and all("mixed_services" in inputs[p.name] for p in cohort),
              "pool requires two completed mixed-service boots")
        mixed_groups.append(pooled_peer(cohort, inputs))
    summary = {
        "repeated_production": groups[-1],
        **({"repeated_mixed_services": mixed_groups} if mixed_groups else {}),
        **({"scheduling_comparisons": [compare_scheduling(a, b, inputs) for a, b in args.compare_scheduling]}
           if args.compare_scheduling else {}),
        "earlier_production": groups[:-1],
        "peer_runs": peers,
        "route_diagnostics": routes,
        "receive_steering": steering,
        "handshake_diagnostics": traced,
        "guest_transmit_experiments": transmit,
        "excluded_peer_runs": excluded,
        "link_preflights": boots,
    }
    print(json.dumps(summary, indent=2))
