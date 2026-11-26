"""Replay the crossed cached and uncached worker-disk trials with fsync in both arms."""

import argparse
import json
import re
from hashlib import sha256
from pathlib import Path

import sibling_job_parent_results as shared
import sibling_paced_results as paced
import sibling_slice_350_results as signed
import sibling_tmpfs
import sibling_worker_volume_results as host_volume
from qualify import require, terminal
from sibling_results import docker_time_ns, read


MODES = ("cached", "uncached")
SEED_ORDER = {250231: MODES, 250233: MODES[::-1]}
PRODUCT = "sibling-worker-disk-cache-product.json"
PRODUCT_SOURCE = "Sources/MicropodRuntime/SandboxVM.swift"
MODE = "worker_disk_cache"
SYNC = "worker_disk_sync_mode"
LAYOUT = "grouped"
ATTACHMENT_PREFIX = "micropod-bench-worker-disk "


def check_product():
    here = Path(__file__).resolve().parent
    receipt = read(here, PRODUCT)
    parent_receipt = read(here, shared.PRODUCT)
    current, previous = (Path(receipt[key]) for key in ("current_product", "previous_product"))
    require(previous == Path(parent_receipt["current_product"]), "disk trial did not derive from the verified job-parent product")
    candidate, parent = (read(path.parent, path.name) for path in (current, previous))
    delta_patch = current.with_name("worker-disk-cache.patch")
    arena = sha256(previous.read_bytes() + b"\0" + delta_patch.read_bytes()).hexdigest()[:16]
    lock = current.parent / "src/Package.resolved"
    containerization, = [row["state"] for row in read(lock.parent, lock.name)["pins"] if row["identity"] == "containerization"]
    require(current.name == "product.json" and current.parent.name == "ci-published-link-" + arena and
            candidate["source_product"] == str(previous) and candidate["source_product_sha256"] == terminal.digest(previous) and
            terminal.digest(delta_patch) == candidate["worker_disk_cache_patch_sha256"] == receipt["worker_disk_cache_patch_sha256"] and
            containerization == candidate["containerization"] == {
                "revision": "c0185aea5c04fcd4d1cfe9359e0066a380835403", "version": "0.42.0"},
            "disk trial source product, patch or Containerization pin differs")
    stable = {"guest_runner_sha256": parent_receipt["new_guest_sha256"],
              "guest_start_sha256": parent_receipt["bootstrap_sha256"], "base_revision": parent_receipt["base_revision"],
              "entitlements": parent_receipt["entitlements"], "guest_publication_script_sha256": parent["guest_publication_script_sha256"]}
    require(all(product[key] == value for product in (candidate, parent) for key, value in stable.items()) and
            candidate["worker_executable_sha256"] == receipt["host_sha256"] and
            parent["worker_executable_sha256"] == receipt["old_host_sha256"] == parent_receipt["host_sha256"] and
            receipt["host_sha256"] != receipt["old_host_sha256"] and
            receipt["new_guest_sha256"] == stable["guest_runner_sha256"] and
            receipt["new_bootstrap_sha256"] == stable["guest_start_sha256"] and
            receipt["base_revision"] == stable["base_revision"] and receipt["entitlements"] == stable["entitlements"],
            "disk trial changed additional guest inputs or reused the previous host executable")
    old, new = (product["compiled_sources"] for product in (parent, candidate))
    changed = {name for name in old.keys() | new.keys() if old.get(name) != new.get(name)}
    require(changed == set(receipt["changed_packaged_inputs"]) == {PRODUCT_SOURCE} and
            {name: new[name] for name in changed} == receipt["sha256_by_changed_input"],
            "disk trial changed compiled inputs outside its host patch")
    require(terminal.digest(Path(candidate["worker_executable"])) == candidate["worker_executable_sha256"] and
            terminal.digest(current.with_name("worker.patch")) == candidate["patch_sha256"] and
            all(terminal.digest(current.parent / "src" / name) == new[name] for name in changed) and
            new["Package.resolved"] == old["Package.resolved"] == terminal.digest(lock),
            "disk trial signed host, patch, or dependency lock differs")
    tools = current.parent / "micropod-oci-tools" / "runner"
    require(terminal.digest(tools / "bin" / "job") == stable["guest_runner_sha256"] and
            terminal.digest(tools / "start.sh") == stable["guest_start_sha256"] and
            terminal.digest(tools / "published-ports.sh") == stable["guest_publication_script_sha256"],
            "disk trial packaged guest bytes differ")
    product = {**receipt, "host_sha256": candidate["worker_executable_sha256"], "new_guest_sha256": stable["guest_runner_sha256"],
               "new_bootstrap_sha256": stable["guest_start_sha256"], "base_revision": stable["base_revision"],
               "entitlements": stable["entitlements"]}
    return product, candidate


def check_plan(folder, plan):
    seed, mode = plan.get("seed"), plan.get(MODE)
    pages = plan["pages"]
    require(type(seed) is int and seed in SEED_ORDER and mode in MODES and plan.get(SYNC) == "fsync" and
            read(folder, "status.json") == {"complete": True}, "disk trial seed, cache mode, sync mode or completion differs")
    require(all(plan.get(key) == value for key, value in signed.WORKLOAD.items()) and
            plan["worker_next_buddy"] is plan["cpu_groups"] is True and type(plan["build_nice"]) is int and
            pages["kernel_page_kib"] == 16 and pages["kernel_ipvlan"] is True and
            not any(pages.get(key) for key in ("kernel_hz", "kernel_bounded_buddy")) and
            "guest_fair" not in plan and plan.get("slice_target", "all") == "all" and
            not any(plan.get(key) is not None for key in
                    ("fair_slice_us", "build_slice_us", "build_policy", "builder_shares", "compiler_affinity",
                     "compiler_runtime", "job_parent", "ext4_cache_profile", "mthp_64k")) and
            not (folder / "ext4-cache-plan.json").exists(), "disk trial requires the fixed flat 250 µs worker workload")
    return seed, mode


def check_attachment(folder, plan):
    raw = (folder / "a/service.stderr").read_text()
    lines = [line.removeprefix(ATTACHMENT_PREFIX) for line in raw.splitlines() if line.startswith(ATTACHMENT_PREFIX)]
    require(len(lines) == 1, "disk trial needs exactly one actual native VZ attachment record")
    attachment = json.loads(lines[0])
    identity = read(folder, "worker-identity.json")
    role = read(folder, "launch-role.json")
    instance = identity["instance"].lower()
    expected = {"cache_mode": plan[MODE], "sync_mode": "fsync", "read_only": False,
                "device_type": "VZVirtioBlockDeviceConfiguration", "image_format": "raw",
                "vm_id": "ci-" + instance, "pid": identity["relay_pid"], "storage_device_index": 1}
    require(all(attachment[key] == value for key, value in expected.items()) and
            Path(attachment["disk_path"]).resolve() == Path(plan["scope"]).resolve() / "a/worker.ext4" and
            attachment["read_only"] is False and type(attachment["pid"]) is type(attachment["storage_device_index"]) is int and
            re.fullmatch(paced.BOOT_ID, instance) and attachment["pid"] == role["pid"] > 0,
            "actual native VZ attachment cache, fsync, block device or owning process differs")
    return attachment


def stable_device(device):
    # Bind mount IDs, directory inodes and cgroup boot IDs are local to one VM.
    return {**{key: device[key] for key in ("driver", "features", "block_bytes", "ext4_options", "queue", "mq")},
            "mount": {key: device["mount"][key] for key in ("target", "filesystem", "source", "options")}}


def device_geometry(device):
    # The attachment can change the advertised FLUSH and CONFIG_WCE features.
    features = "".join("*" if index in (9, 11) else bit for index, bit in enumerate(device["features"]))
    return {**device, "features": features,
            "queue": {key: value for key, value in device["queue"].items() if key not in ("write_cache", "fua")}}


def check_calibration(calibration, queue):
    phases = calibration["stages"]
    size = calibration["bytes"]
    require(calibration["guest_fsync_succeeded"] is True and size == 1 << 20 and
            set(phases) == {"write", "cold", "warm", "direct"}, "incomplete four-stage disk calibration")
    payload = {phase: int(result["stat_delta"]["read_sectors"]) * 512 for phase, result in phases.items() if phase != "write"}
    write = phases["write"]["stat_delta"]
    flushes = write["flushes"]
    witness = None
    if flushes > 0:
        witness = "completed_separate_flush"
    elif flushes == 0 and queue["write_cache"] == "write through":
        witness = "write_through_without_separate_flush"
    elif flushes == 0 and queue.get("fua") == "1":
        witness = "fua_capable_without_separate_flush"
    require(witness is not None and write["write_sectors"] * 512 >= size and
            payload["cold"] >= size and payload["direct"] >= size and 0 <= payload["warm"] < size,
            "disk calibration did not distinguish the fsynced write, device reads and warm guest read")
    return {**calibration, "write_bytes": write["write_sectors"] * 512, "write_flushes": flushes,
            "flush_evidence": witness, "separate_flush_observed": flushes > 0, "device_read_bytes": payload}


def check_work(run):
    rows = run["rows"][LAYOUT]
    totals = run["totals"]
    waves = 2 * shared.ROUNDS
    require(len(rows) == shared.ROUNDS and sorted(row["order"] for row in rows) == ["AB", "AB", "BA", "BA"] and
            totals["offered_requests"] == totals["completed_requests"] == waves * shared.OFFERED and
            totals["warm_connections"] == waves * paced.PAIRS and
            (totals["jobs"], totals["revisions"], totals["test_passes"]) ==
            (waves * paced.BUILDERS, waves * 2 * paced.BUILDERS, waves * 16 * paced.BUILDERS),
            "disk trial completed an unexpected number of windows, offers or builds")
    require(all(wave[arm]["completed_after_first_build"] == 0 and wave[arm]["first_build_end_margin_ns"] >= 0
                for wave in rows for arm in shared.ENGINES), "disk trial lost build overlap through HTTP drain")
    return rows


def workload_protocol(folder, plan):
    values = {name: value for name, value in plan.items() if name not in ("scope", "seed", MODE)}
    names = ["host-disk-calibration.json", *(f"host-disk-{index}-{arm}.json"
              for index in range(shared.ROUNDS) for arm in shared.ENGINES)]
    present = [name for name in names if (folder / name).is_file()]
    if present:
        require(present == names, "incomplete optional Mac disk sampler")
        samplers = {(result["driver_sha256"], result["sampler_sha256"]) for result in (read(folder, name) for name in names)}
        require(len(samplers) == 1 and all(re.fullmatch(r"[0-9a-f]{64}", digest) for digest in next(iter(samplers))),
                "Mac disk observer changed within the trial")
        values["host_disk_sampler"] = samplers.pop()
    return values


def compare_windows(windows):
    return {
        "within_engine": {engine: shared.outcomes([w[arm] for w in windows["cached"]], [w[arm] for w in windows["uncached"]], MODES)
                          for arm, engine in shared.ENGINES.items()},
        "within_mode": {mode: shared.outcomes([w["B"] for w in rows], [w["A"] for w in rows], ("orbstack", "micropod"))
                        for mode, rows in windows.items()},
    }


def summarize(verified):
    by_seed, pooled = [], {mode: [] for mode in MODES}
    for seed, order in SEED_ORDER.items():
        boots = {mode: verified[seed, mode] for mode in MODES}
        windows = {mode: item["rows"] for mode, item in boots.items()}
        first, second = (boots[mode]["admission"] for mode in order)
        require(docker_time_ns(first["last_utc"]) < docker_time_ns(second["first_utc"]), "disk trial boot order or scope overlap differs")
        for cached, uncached in zip(windows["cached"], windows["uncached"], strict=True):
            require(cached["order"] == uncached["order"] and
                    len({tuple(row[arm]["build"]["products"]) for row in (cached, uncached) for arm in shared.ENGINES}) == 1,
                    "disk trial changed engine order or built artifacts within a seed")
        for mode, rows in windows.items():
            pooled[mode].extend(rows)
        by_seed.append({"seed": seed, "cache_mode_order": list(order),
                        "boots": {mode: item["receipt"] for mode, item in boots.items()}, **compare_windows(windows)})
    work = [wave[arm] for rows in pooled.values() for wave in rows for arm in shared.ENGINES]
    return {
        "native_boots": len(verified), "matched_boot_pairs": len(by_seed), "engine_windows": len(work),
        "rate_per_second": shared.RATE, "offer_duration_ns": paced.OFFER_NS, "rounds_per_boot": shared.ROUNDS,
        "offered_requests": sum(wave["offered_requests"] for wave in work),
        "completed_requests": sum(wave["requests"] for wave in work),
        "build_jobs": sum(wave["build"]["jobs"] for wave in work),
        "build_revisions": sum(wave["build"]["revisions"] for wave in work),
        "test_passes": sum(wave["build"]["test_passes"] for wave in work),
        "minimum_first_build_end_margin_ns": min(wave["first_build_end_margin_ns"] for wave in work),
        "by_seed": by_seed, **compare_windows(pooled),
    }


def verified_run(folder, plan, *, volume=None):
    import sibling_worker_disk_cache_evidence as evidence

    attachment = check_attachment(folder, plan)
    if host_volume.volume_strategy(folder, plan) == host_volume.POLICY:
        if volume is None:
            volume = host_volume.verify_volume(folder)
        require(host_volume.same_path(attachment["disk_path"], Path(volume["raw_disk"]["path"])),
                "VZ attachment does not use the attested dedicated RAW disk")
    inventory = read(folder, f"{LAYOUT}-inventory.json")
    require(inventory.keys() == shared.ENGINES.keys(), "disk trial missing an engine cohort")
    placement = shared.check_placement_inventory(inventory, plan, LAYOUT)
    require(placement == signed.PLACEMENT[LAYOUT], "disk trial changed the fixed CPU map")
    admission = shared.check_admission(folder, inventory)
    boots = evidence.boots(folder)
    require(set(boots) == set(shared.ENGINES) and all(re.fullmatch(paced.BOOT_ID, boot) for boot in boots.values()) and
            boots["A"] != boots["B"], "disk trial did not prove separate guest boots")
    disk = evidence.verify(folder, plan, inventory, boots)
    calibration = check_calibration(disk["calibration"], disk["device"]["queue"])
    if volume is not None:
        captures = [read(folder, evidence.filename(block, phase))
                    for block in range(shared.ROUNDS) for phase in ("before", "after")]
        captures.append(read(folder, evidence.CALIBRATION))
        require(all(volume["live_observed_unix_ns"] < row["host_started_unix_ns"] <= row["host_finished_unix_ns"] <
                    volume["post_observed_unix_ns"] for row in captures),
                "host volume status checks do not bracket the disk observations and calibration")
    scratch, mounts = sibling_tmpfs.read_fields((folder / "go-scratch-boot.txt").read_text())
    require(disk["attachment"] == attachment and disk["device"]["boot"] == scratch["boot"] == boots["A"] and
            disk["device"]["dev"] == mounts["/"]["device"] and mounts["/"]["source"] == "/dev/vdb" and
            disk["device"]["block_bytes"] == 4096, "disk trial used the wrong backing device or cache geometry")
    run = paced.replay(folder)
    require(run["plan"] == plan and run["placements"] == signed.PLACEMENT and
            (run["boot"], run["peer_boot"]) == (boots["A"], boots["B"]), "disk trial plan, placement or boot changed during replay")
    paced.scheduler_identity(run["worker"], plan["worker_scheduler"])
    rows = check_work(run)
    require(len(disk["windows"]) == len(rows), "disk trial is missing a native device observation")
    for block, (window, disk_window) in enumerate(zip(rows, disk["windows"], strict=True)):
        wave = window["A"]
        require(disk_window["block"] == block and disk_window["guest_before_unix_ns"] < wave["scheduled_unix_ns"] and
                wave["scheduled_unix_ns"] + wave["last_completion_offset_ns"] < disk_window["guest_after_unix_ns"],
                "native device snapshots do not bracket all scheduled and drained calls")
    owner = Path(plan["scope"]).name
    launch = {arm: [[arg.replace(owner, "{scope}") for arg in job["create_argv"]] for job in inventory[arm]["jobs"]]
              for arm in shared.ENGINES}
    ids = {job["id"] for cohort in inventory.values() for job in cohort["jobs"]}
    require(len(ids) == 4 * paced.PAIRS, "disk trial reused a container across engines")
    receipt = {"archive": folder.name, "native_boot": boots["A"], "peer_boot": boots["B"], "attachment": attachment,
               "calibration": calibration, "device_windows": disk["windows"], "admission": admission,
               "windows": shared.wave_receipts(rows)}
    if volume is not None:
        receipt["host_volume"] = volume
    return {"run": run, "rows": rows, "admission": admission, "device": stable_device(disk["device"]),
            "launch_templates": launch, "ids": ids,
            "receipt": receipt}


def compare(folders):
    paths = [Path(folder).resolve() for folder in folders]
    require(len(paths) == len(set(paths)) == len(SEED_ORDER) * len(MODES), "disk trial requires four distinct archive directories")
    plans = {folder: read(folder, "plan.json") for folder in paths}
    strategies = {host_volume.volume_strategy(folder, plan) for folder, plan in plans.items()}
    require(len(strategies) == 1, "disk trial mixes ordinary and dedicated worker host volumes")
    strategy = strategies.pop()
    volumes = {}
    if strategy == host_volume.POLICY:
        volumes = {folder: host_volume.verify_volume(folder) for folder in paths}
        require(len({volume["volume_uuid"] for volume in volumes.values()}) == len(paths), "disk trial reused an APFS volume UUID")
    product, packaged = check_product()
    selected, scopes = {}, set()
    common_plan = common_settings = None
    for folder, plan in plans.items():
        key = check_plan(folder, plan)
        scope = Path(plan["scope"]).resolve()
        require(key not in selected and scope not in scopes, "duplicate disk trial seed, cache mode or worker scope")
        settings = signed.signed_settings(folder, plan, product)
        require(settings[0] == packaged, "disk trial archive does not match the signed product")
        protocol = workload_protocol(folder, plan)
        if common_plan is None:
            common_plan, common_settings = protocol, settings
        require(protocol == common_plan and settings == common_settings, "unmatched disk trial settings or signed launch")
        selected[key] = folder, plan
        scopes.add(scope)
    verified = {key: verified_run(folder, plan, volume=volumes.get(folder)) for key, (folder, plan) in selected.items()}
    observed = list(verified.values())
    reference = observed[0]
    devices = {mode: verified[next(iter(SEED_ORDER)), mode]["device"] for mode in MODES}
    require(all(row["device"] == devices[mode] for (_, mode), row in verified.items()) and
            device_geometry(devices["cached"]) == device_geometry(devices["uncached"]),
            "disk trial changed geometry, device or queue outside advertised cache features")
    require(all(row["launch_templates"] == reference["launch_templates"] and
                all(row["run"][key] == reference["run"][key] for key in ("worker", "images", "placements")) for row in observed),
            "disk trial changed tool images, worker or Docker launch arguments")
    require(all(len({tuple(row["rows"][index][arm]["build"]["products"]) for row in observed for arm in shared.ENGINES}) == 1
                for index in range(shared.ROUNDS)), "disk trial changed build outputs across seeds or modes")
    require(len({row["run"]["boot"] for row in observed}) == len(observed) and
            len({row["run"]["peer_boot"] for row in observed}) == 1 and
            len(set().union(*(row["ids"] for row in observed))) == len(observed) * 4 * paced.PAIRS,
            "disk trial reused a guest boot or container or changed the peer")
    intervals = sorted((docker_time_ns(row["admission"]["first_utc"]), docker_time_ns(row["admission"]["last_utc"]))
                       for row in observed)
    require(all(end < start for (_, end), (start, _) in zip(intervals, intervals[1:])), "disk trial scopes overlapped")
    slacks = {engine: {slack for r in observed for wave in r["rows"] for slack in wave[arm]["timer_slack_ns"]}
              for arm, engine in shared.ENGINES.items()}
    require(all(len(values) == 1 for values in slacks.values()), "disk trial changed issuing-thread timer slack")
    return {"sync_mode": "fsync", "host_worker_volume": strategy,
            "signed_product": product["current_product"], "worker": reference["run"]["worker"],
            "peer_boot": reference["run"]["peer_boot"], "kernel": reference["run"]["plan"]["pages"], "guest_devices": devices,
            "timer_slack_ns": {engine: values.pop() for engine, values in slacks.items()},
            "protocol_sha256": shared.fingerprint([common_plan, common_settings, reference["launch_templates"]]), **summarize(verified)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", nargs=4, type=Path)
    print(json.dumps(compare(parser.parse_args().folders), indent=2, allow_nan=False))
