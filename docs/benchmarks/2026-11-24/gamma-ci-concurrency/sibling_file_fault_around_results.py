"""Replay the matched native filemap fault-around crossover."""

import argparse
import json
import plistlib
import re
from hashlib import sha256
from pathlib import Path
from statistics import median
from types import SimpleNamespace
from unittest.mock import patch

import file_fault_around_common as native
import sibling_file_fault_around as fixture
import sibling_file_fault_around_evidence as evidence
import sibling_job_parent_cri as cri
import sibling_job_parent_evidence as hierarchy
import sibling_job_parent_results as shared
import sibling_paced_results as paced
import sibling_slice_350_results as signed
import sibling_tmpfs
import sibling_worker_volume_results as host_volume
from qualify import require, terminal
from sibling_results import container_startup, docker_time_ns, read


VALUES = (65_536, 1_048_576)
LABELS = ("64KiB", "1024KiB")
SEED_ORDER = {250251: VALUES, 250253: VALUES[::-1]}
PRODUCT = "sibling-file-fault-around-product.json"
PRODUCT_SOURCE = "ci/runner/start.sh"
TREATMENT = "file_fault_around_bytes"
TOKEN = "micropod.bench_file_fault_around="
KERNEL_ARGS = "MICROPOD_SANDBOX_KERNEL_ARGS"
READBACK_SCHEMA = "micropod-file-fault-around-v1"
MARKER = "file-fault-around.fixture"
MARKER_CONTENT = b"micropod-file-fault-around-fixture-v1\n"
NUMERIC_WRITE = r'''printf '%s' "$selected" > "$knob"'''
BOOT = "file-fault-around-boot.txt"
FINAL = "file-fault-around-final.txt"
USAGE_COUNTERS = ("user_usec", "system_usec", "minor_faults", "major_faults", "voluntary_switches",
                  "involuntary_switches", "input_blocks", "output_blocks", "max_rss_kib")
USAGE_TIMES = ("started_unix_ns", "child_started_unix_ns", "finished_unix_ns", "elapsed_ns", "publish_started_unix_ns")


def check_plan(folder, plan, orders=SEED_ORDER):
    seed, value = plan.get("seed"), plan.get(TREATMENT)
    pages = plan["pages"]
    require(type(seed) is type(value) is int and seed in orders and value in orders[seed] and
            read(folder, "status.json") == {"complete": True}, "unqualified file fault-around seed, value or boot")
    require(all(plan.get(key) == setting for key, setting in signed.WORKLOAD.items()) and
            plan["worker_next_buddy"] is plan["cpu_groups"] is True and type(plan["build_nice"]) is int and
            pages["kernel_page_kib"] == 16 and pages["kernel_ipvlan"] is True and
            not any(pages.get(key) for key in ("kernel_hz", "kernel_bounded_buddy")) and
            "guest_fair" not in plan and plan.get("slice_target", "all") == "all" and plan.get("job_parent") == "flat" and
            not any(plan.get(key) is not None for key in
                    ("fair_slice_us", "build_slice_us", "build_policy", "builder_shares", "compiler_affinity",
                     "compiler_runtime", "ext4_cache_profile", "mthp_64k", "worker_disk_cache", "worker_disk_sync_mode")) and
            not (folder / "ext4-cache-plan.json").exists() and
            host_volume.volume_strategy(folder, plan) == host_volume.POLICY and plan[host_volume.FINAL_HISTORY] is True,
            "file fault-around trial changed the ordinary flat/APFS worker workload")
    return seed, value


def check_product():
    folder = Path(__file__).resolve().parent
    manifest = read(folder, PRODUCT)
    prior_manifest = read(folder, shared.PRODUCT)
    current, previous = (Path(manifest[key]) for key in ("current_product", "previous_product"))
    require(previous == Path(prior_manifest["current_product"]), "wrong prior signed worker for fault-around repack")
    candidate, prior = (read(p.parent, p.name) for p in (current, previous))
    stable = {"worker_executable_sha256": prior_manifest["host_sha256"],
              "guest_runner_sha256": prior_manifest["new_guest_sha256"], "base_revision": prior_manifest["base_revision"],
              "entitlements": prior_manifest["entitlements"], "guest_publication_script_sha256": prior["guest_publication_script_sha256"]}
    require(all(record[key] == value for record in (candidate, prior) for key, value in stable.items()),
            "fault-around repack changed the signed host, guest runner or publication script")
    check_numeric_write(native.BOOTSTRAP)
    old, new = prior["compiled_sources"], candidate["compiled_sources"]
    changed = {name for name in old.keys() | new.keys() if old.get(name) != new.get(name)}
    require(changed == set(manifest["changed_packaged_inputs"]) == {PRODUCT_SOURCE} and
            manifest["sha256_by_changed_input"] == {PRODUCT_SOURCE: new[PRODUCT_SOURCE]} and
            prior["guest_start_sha256"] == old[PRODUCT_SOURCE] == prior_manifest["bootstrap_sha256"] == manifest["old_bootstrap_sha256"] and
            candidate["guest_start_sha256"] == new[PRODUCT_SOURCE] == manifest["new_bootstrap_sha256"] != old[PRODUCT_SOURCE] and
            manifest["host_sha256"] == manifest["old_host_sha256"] == stable["worker_executable_sha256"] and
            manifest["new_guest_sha256"] == stable["guest_runner_sha256"] and
            manifest["previous_product_sha256"] == terminal.digest(previous) and
            manifest["fragment_sha256"] == sha256(native.BOOTSTRAP.encode()).hexdigest(),
            "fault-around repack changed more than its guest bootstrap")
    runner = current.parent / "micropod-oci-tools" / "runner"
    stock = previous.parent / "micropod-oci-tools/runner/start.sh"
    require(terminal.digest(Path(candidate["worker_executable"])) == stable["worker_executable_sha256"] and
            terminal.digest(runner / "bin" / "job") == stable["guest_runner_sha256"] and
            terminal.digest(runner / "published-ports.sh") == stable["guest_publication_script_sha256"] and
            terminal.digest(runner / "start.sh") == terminal.digest(current.parent / "src" / PRODUCT_SOURCE) == new[PRODUCT_SOURCE] and
            terminal.digest(stock) == old[PRODUCT_SOURCE] and (runner / "start.sh").read_bytes() == native.patch_start(stock.read_bytes()) and
            terminal.digest(current.with_name("worker.patch")) == candidate["patch_sha256"] == manifest["patch_sha256"],
            "fault-around signed product bytes differ")
    kernel = manifest["kernel"]
    require(kernel["allowed_windows_bytes"] == list(VALUES) and kernel["default_window_bytes"] == VALUES[0] and
            kernel["debugfs_file"] == "fault_around_bytes" and kernel["page_size_bytes"] == 16_384 and
            kernel["ptes_per_page_table"] == 2048 and kernel["maximum_effective_window_bytes"] == 32 * 1024**2 and
            kernel["embedded_config_verified"] is True and kernel["kconfig"] == {
                "CONFIG_ARM64_16K_PAGES": "y", "CONFIG_DEBUG_FS": "y", "CONFIG_DEBUG_FS_ALLOW_ALL": "y",
                "CONFIG_IKCONFIG": "y", "CONFIG_IPVLAN": "y", "CONFIG_PAGE_SHIFT": "14", "CONFIG_PROC_PAGE_MONITOR": "y",
                "CONFIG_TRANSPARENT_HUGEPAGE": "n"}, "sealed fault-around kernel capability differs")
    product = {**manifest, "host_sha256": stable["worker_executable_sha256"], "new_guest_sha256": stable["guest_runner_sha256"],
               "new_bootstrap_sha256": new[PRODUCT_SOURCE], "base_revision": stable["base_revision"],
               "entitlements": stable["entitlements"]}
    return product, candidate


def check_numeric_write(fragment):
    before, write, after = (fragment.find(token) for token in ('before=$(cat "$knob")', NUMERIC_WRITE,
                                                               'effective=$(cat "$knob")'))
    require(fragment.count(NUMERIC_WRITE) == fragment.count('> "$knob"') == 1 and 0 <= before < write < after,
            "fault-around bootstrap must issue one numeric write between the two debugfs reads")


def effective_command_line(cmdline, value):
    args = cmdline.split()
    actual = [arg for arg in args if arg.startswith(TOKEN)]
    require(actual == [TOKEN + str(value)], "native kernel command line has the wrong or duplicate fault-around switch")
    return " ".join(arg for arg in args if not arg.startswith(TOKEN))


def checked_job_plist(raw, value):
    job = plistlib.loads(raw)
    environment = job["EnvironmentVariables"]
    require(effective_command_line(environment[KERNEL_ARGS], value) == signed.BOOT_ARGS and
            environment[KERNEL_ARGS].split() == [*signed.BOOT_ARGS.split(), TOKEN + str(value)],
            "native launch plist has unexpected scheduling or fault-around arguments")
    return {**job, "EnvironmentVariables": {**environment, KERNEL_ARGS: signed.BOOT_ARGS}}


def launch_view(value):
    # The generic reader only accepts the scheduler arguments. Validate this
    # experiment's extra argument before giving it the projected plist.
    return SimpleNamespace(loads=lambda raw: checked_job_plist(raw, value))


def kernel_readback(raw, boot, value, *, initial):
    pairs = [line.split("=", 1) for line in raw.splitlines()]
    expected = {"schema": READBACK_SCHEMA, "boot_id": boot, "page_size_bytes": "16384", "effective_bytes": str(value)}
    if initial:
        expected["before_bytes"] = str(VALUES[0])
    require(len(pairs) == len(expected) and all(len(pair) == 2 for pair in pairs) and dict(pairs) == expected,
            "wrong effective fault-around value, page size or guest boot")
    return expected


def verified_settings(folder, plan, product, candidate):
    value = plan[TREATMENT]
    with patch.object(signed, "plistlib", launch_view(value)):
        settings = signed.signed_settings(folder, plan, product)
    require(settings[0] == candidate, "fault-around archive did not use the exact signed repack")
    facts = settings[-1]
    cmdline = effective_command_line(facts["cmdline"], value)
    scheduler_cmdline = (folder / "fair-scheduler/cmdline").read_text().strip()
    require(scheduler_cmdline.split() == facts["cmdline"].split(), "fault-around boot witnesses disagree about the kernel command line")
    return (*settings[:-1], {**facts, "cmdline": cmdline})


def check_sources(folder, plan):
    inputs = (fixture.DRIVER, fixture.COMMON, MARKER, fixture.READBACK_SCRIPT)
    require(plan["file_fault_around_sources"] == {name: terminal.digest(folder / name) for name in inputs} and
            (folder / MARKER).read_bytes() == MARKER_CONTENT and
            (folder / fixture.READBACK_SCRIPT).read_text() == "set -eu\n" + native.FINAL_OBSERVER and
            (folder / hierarchy.BOOT_HOOK).read_text() == fixture.boot_hook(),
            "file fault-around bootstrap or read-only observer provenance differs")
    evidence.check_sources(folder, plan)


def check_mapping(folder, context, value, *, last_wave=None):
    job = context["inventory"]["A"]["jobs"][paced.PAIRS]
    rows = fixture.check_mmap(folder, job, context["boots"]["A"], value)
    archived = read(folder, evidence.CALIBRATION)
    tool = json.loads(archived["raw"])["tool"]
    if last_wave is None:
        last_wave = max(read(folder, evidence.snapshot_name(f"grouped-{block}-all-{arm}", "after"))["host_finished_unix_ns"]
                        for block in range(shared.ROUNDS) for arm in shared.ENGINES)
    after = read(folder, "job-parent-after.json")
    require({key: tool[key] for key in ("path", "sha256")} == context["compiler_executables"]["go"] and
            context["volume"]["live_observed_unix_ns"] < last_wave < archived["host_started_unix_ns"] <=
            archived["host_finished_unix_ns"] < after["host_started_unix_ns"] < context["volume"]["post_observed_unix_ns"],
            "Go-file mapping proof used a different executable or worker lifetime")
    return {"tool": tool, "touched_run_bytes": VALUES[-1], "page_bytes": native.PAGE_BYTES,
            "sample_orders": [row["order"] for row in rows],
            "ptes_after_first_read": [len(row["present_after_first_indices"]) for row in rows],
            "sample_minor_faults": [row["minor_faults"] for row in rows],
            "sample_major_faults": [row["major_faults"] for row in rows]}


def qualified_context(folder, plan):
    volume = host_volume.verify_volume(folder)
    require(volume["journal_observed_through"] == "read_only_remount", "fault-around trial requires verified APFS retirement history")
    inventory = read(folder, "grouped-inventory.json")
    require(inventory.keys() == shared.ENGINES.keys(), "fault-around trial lacks both engine cohorts")
    placement = shared.placement_view(inventory, plan, "grouped")
    require(placement == signed.PLACEMENT["grouped"], "fault-around trial changed the fixed per-job CPU map")
    admission = shared.check_admission(folder, inventory)
    boots = hierarchy.boots(folder)
    require(set(boots) == set(shared.ENGINES) and all(re.fullmatch(paced.BOOT_ID, b) for b in boots.values()) and
            boots["A"] != boots["B"], "fault-around trial lacks distinct measured Linux boots")
    value = plan[TREATMENT]
    knob_readback = {phase: kernel_readback((folder / name).read_text(), boots["A"], value, initial=phase == "before")
                     for phase, name in (("before", BOOT), ("after", FINAL))}
    scratch, mounts = sibling_tmpfs.read_fields((folder / "go-scratch-boot.txt").read_text())
    require(scratch["boot"] == boots["A"] and mounts["/"]["source"] == "/dev/vdb" and
            not mounts["/"]["device"].startswith("7:") and "micropod-bench-worker-disk " not in
            (folder / "a/service.stderr").read_text(), "fault-around trial did not use the ordinary native worker attachment")

    proof = hierarchy.verify(folder, plan, inventory, boots)
    parents = shared.check_parent_paths(inventory["A"], "flat", proof["native_paths"])
    lifecycle = cri.verify(folder, proof["native_paths"])
    require(lifecycle["boot"] == boots["A"] and lifecycle["verified_starts"] == lifecycle["verified_sandbox_removals"] == paced.PAIRS * 2,
            "fault-around trial lacks matched CRI create/start/shutdown evidence")
    before, after = [read(folder, f"job-parent-{phase}.json")["arms"] for phase in ("before", "after")]
    require(shared.check_ancestor_limits(before["A"]["worker"], parents) ==
            shared.check_ancestor_limits(after["A"]["worker"], parents), "fault-around trial changed native cgroup limits")
    before_native = min(row["inside"]["guest_unix_ns"] for row in before["A"]["containers"])
    after_native = max(row["inside"]["guest_unix_ns"] for row in after["A"]["containers"])
    require(all(docker_time_ns(row["docker_started"]) < before_native < after_native < docker_time_ns(row["stop_request"])
                for row in lifecycle["containers"]), "fault-around trial observed CRI activity outside the live measured cohort")
    probes = read(folder, "job-parent-probes.json")
    phase_limits = {}
    for arm in shared.ENGINES:
        before_capture = max(row["inside"]["guest_unix_ns"] for row in before[arm]["containers"])
        before_http = max(json.loads(row["stdout"])["window"]["finished_unix_ns"] for row in probes[arm] if row["role"] == "http")
        after_capture = min(row["inside"]["guest_unix_ns"] for row in after[arm]["containers"])
        phase_limits[arm] = max(before_capture, before_http), after_capture
    return {"inventory": inventory, "boots": boots, "admission": admission, "volume": volume,
            "phase_limits": phase_limits, "compiler_executables": proof["compiler_executables"],
            "fault_around_readback": knob_readback,
            "native_cri": {k: v for k, v in lifecycle.items() if k != "containers"}}


def run_receipts(folder, context, run, rows):
    return {"archive": folder.name, "native_boot": run["boot"], "peer_boot": run["peer_boot"],
            "native_volume": context["volume"], "native_cri": context["native_cri"], "admission": context["admission"],
            "fault_around_readback": context["fault_around_readback"],
            "startup": {engine: container_startup(context["inventory"][arm]["jobs"]) for arm, engine in shared.ENGINES.items()},
            "windows": shared.wave_receipts(rows)}


def reaped_child_usage(row, timed, job, tag, slot, boot, gate, last_completion):
    usage = row["usage"]
    revision = timed["revision"]
    argv = ["/bin/sh", "/mpcheck/file-fault-around-build-pair.sh", revision, "0"]
    require(row["id"] == timed["id"] == job["id"] and row["argv"] == evidence.build_argv(tag, slot, job["id"]) and
            usage["boot"] == boot and usage["tag"] == tag and
            type(usage["slot"]) is int and usage["slot"] == slot and usage["revision"] == revision and
            usage["container"] == job["name"] and usage["cgroup"] == "0::/" and usage["argv"] == argv and
            type(usage["child_pid"]) is int and usage["child_pid"] > 1 and usage["child_pid"] != job["affinity"]["pid"] and
            all(type(usage[key]) is int and usage[key] == 0 for key in ("exit_code", "wait_status")),
            f"wrong reaped build identity or status for {tag} slot {slot}")
    ending = timed["stdout"].strip().splitlines()[-1].split()
    require(len(ending) == 3 and ending[0] == "end" and ending[2] == "0", f"invalid ordinary dispatch result for {tag} slot {slot}")
    end = int(ending[1])
    require(all(type(usage[key]) is int and usage[key] > 0 for key in USAGE_TIMES) and
            0 < timed["started_unix_ns"] <= usage["started_unix_ns"] <= usage["child_started_unix_ns"] <
            gate <= last_completion <= end <= usage["finished_unix_ns"] <= usage["publish_started_unix_ns"] and
            abs(usage["finished_unix_ns"] - usage["started_unix_ns"] - usage["elapsed_ns"]) < 10_000_000,
            f"actual reaped build child did not span the complete HTTP cohort for {tag} slot {slot}")
    require(all(type(usage[key]) is int and usage[key] >= 0 for key in USAGE_COUNTERS) and
            usage["user_usec"] + usage["system_usec"] > 0 and usage["minor_faults"] > 0 and usage["max_rss_kib"] > 0,
            f"invalid Linux child resource accounting for {tag} slot {slot}")
    return {key: usage[key] for key in USAGE_COUNTERS}


def child_resources(folder, block, arm, wave, context):
    tag = f"grouped-{block}-all-{arm}"
    timed = read(folder, tag + "-go.json")
    child = read(folder, f"file-fault-around-{tag}-builds.json")
    jobs = context["inventory"][arm]["jobs"][paced.PAIRS:paced.PAIRS + paced.BUILDERS]
    require(len(timed) == len(child) == len(jobs) == paced.BUILDERS, f"missing reaped build receipts for {tag}")
    gate = wave["scheduled_unix_ns"]
    last = gate + wave["last_completion_offset_ns"]
    results = [reaped_child_usage(row, go, job, tag, slot, context["boots"][arm], gate, last)
               for slot, (row, go, job) in enumerate(zip(child, timed, jobs, strict=True))]
    first_publication = min(row["usage"]["publish_started_unix_ns"] for row in child)
    last_wait = max(row["usage"]["finished_unix_ns"] for row in child)
    require(first_publication >= max(last, last_wait), f"accounting sidecar could perturb timed work for {tag}")
    totals = {key: sum(row[key] for row in results) for key in USAGE_COUNTERS if key != "max_rss_kib"}
    totals["max_rss_kib"] = max(row["max_rss_kib"] for row in results)
    return {"totals": totals, "slots": results, "last_reaped_unix_ns": last_wait,
            "first_sidecar_publication_unix_ns": first_publication}


def wave_observations(folder, rows, context):
    observed = []
    phase_bounds = context["phase_limits"]
    previous_guest = {arm: bounds[0] for arm, bounds in phase_bounds.items()}
    previous_host = read(folder, "job-parent-before.json")["host_finished_unix_ns"]
    for block, window in enumerate(rows):
        result = {"block": block, "order": window["order"]}
        for arm in window["order"]:
            jobs = context["inventory"][arm]["jobs"][paced.PAIRS:paced.PAIRS + paced.BUILDERS]
            wave = window[arm]
            note = evidence.check_wave(folder, block, arm, jobs, context["boots"][arm], http=wave)
            child = child_resources(folder, block, arm, wave, context)
            before, after = (read(folder, evidence.snapshot_name(f"grouped-{block}-all-{arm}", phase))
                             for phase in ("before", "after"))
            require(context["volume"]["live_observed_unix_ns"] < previous_host < before["host_started_unix_ns"] <=
                    before["host_finished_unix_ns"] < after["host_started_unix_ns"] <= after["host_finished_unix_ns"] <
                    context["volume"]["post_observed_unix_ns"] and
                    previous_guest[arm] < note["memory_before"]["begin_ns"] <= note["memory_after"]["end_ns"] < phase_bounds[arm][1],
                    "wave snapshots fell outside the worker lifetime or disagreed with actual engine order")
            previous_host = after["host_finished_unix_ns"]
            previous_guest[arm] = note["memory_after"]["end_ns"]
            require(note["gate_unix_ns"] == wave["scheduled_unix_ns"] and note["last_completion_unix_ns"] ==
                    wave["scheduled_unix_ns"] + wave["last_completion_offset_ns"] and
                    child["slots"] == [{key: row[key] for key in USAGE_COUNTERS} for row in note["children"]],
                    "fault-around memory and build observations do not bind the raw scored wave")
            result[arm] = {"child_rusage": child, "guest_memory_before": note["memory_before"],
                           "guest_memory_after": note["memory_after"], "guest_vmstat_delta": note["vmstat_delta"]}
        observed.append(result)
    return observed


def validated_settings(folder, plan, product, candidate, orders):
    key = check_plan(folder, plan, orders)
    kernel = product["kernel"]
    require(all(plan["pages"][f"kernel_{key}"] == kernel[key] for key in ("image_sha256", "config_sha256")),
            "archive used a different kernel from the sealed fault-around experiment")
    settings = verified_settings(folder, plan, product, candidate)
    require(settings[-1]["release"] == kernel["release"], "archive kernel release disagrees with the sealed Image")
    protocol = {key: value for key, value in plan.items() if key not in ("seed", "scope", TREATMENT)}
    return key, settings, protocol


def validated_archive(folder, plan, product, candidate):
    result = validated_settings(folder, plan, product, candidate, SEED_ORDER)
    check_sources(folder, plan)
    return result


def replay_paced(folder, plan, context):
    with patch.object(paced, "plistlib", launch_view(plan[TREATMENT])):
        run = paced.replay(folder)
    require(run["plan"] == plan and run["placements"] == signed.PLACEMENT and
            (run["boot"], run["peer_boot"]) == (context["boots"]["A"], context["boots"]["B"]),
            "fault-around paced replay disagrees with placement, boot identity or plan")
    paced.scheduler_identity(run["worker"], plan["worker_scheduler"])
    return run, shared.check_waves(folder, run, context["phase_limits"])


def run_identity(folder, plan, context, run, rows):
    scope = Path(plan["scope"]).name
    inventory = context["inventory"]
    launch = {arm: [[argument.replace(scope, "{scope}") for argument in job["create_argv"]]
                    for job in inventory[arm]["jobs"]] for arm in shared.ENGINES}
    ids = {job["id"] for cohort in inventory.values() for job in cohort["jobs"]}
    require(len(ids) == 4 * paced.PAIRS, "fault-around trial reused Docker container IDs")
    return {"run": run, "rows": rows, "launch": launch, "ids": ids,
            "compiler_executables": context["compiler_executables"], "receipt": run_receipts(folder, context, run, rows)}


def verified_run(folder, plan):
    context = qualified_context(folder, plan)
    mapping = check_mapping(folder, context, plan[TREATMENT])
    run, rows = replay_paced(folder, plan, context)
    observations = wave_observations(folder, rows, context)
    result = run_identity(folder, plan, context, run, rows)
    result["receipt"].update(off_timing_go_mapping=mapping, wave_resources=observations)
    return {**result, "observations": observations}


def paired_counter_views(first, second, *, signed_difference=False):
    records = [*first, *second]
    keys = records[0].keys()
    require(all(row.keys() == keys for row in records), "fault-around counter availability changed within one engine")
    metrics = {}
    for name in sorted(keys):
        summary = paced.paired_summary([row[name] for row in first], [row[name] for row in second], name, LABELS)
        if signed_difference:
            summary["paired_ratio"] = None
        metrics[name] = summary
    return metrics


def comparisons(rows, observations=None):
    metrics = {"within_level": {}, "within_engine": {}}
    for index, value in enumerate(VALUES):
        group = rows[value]
        metrics["within_level"][LABELS[index]] = shared.outcomes([wave["B"] for wave in group], [wave["A"] for wave in group],
                                                               ("orbstack", "micropod"))
    for arm, engine in shared.ENGINES.items():
        timing = shared.outcomes(*([wave[arm] for wave in rows[value]] for value in VALUES), LABELS)
        metrics["within_engine"][engine] = {"timing": timing}
        if observations is None:
            continue
        first, second = ([wave[arm] for wave in observations[value]] for value in VALUES)
        memory = {checkpoint: paired_counter_views([row[key]["kib"] for row in first], [row[key]["kib"] for row in second])
                  for checkpoint, key in (("before", "guest_memory_before"), ("after", "guest_memory_after"))}
        metrics["within_engine"][engine] = {
            "timing": timing,
            "child_rusage": paired_counter_views([row["child_rusage"]["totals"] for row in first],
                                                [row["child_rusage"]["totals"] for row in second]),
            "guest_memory_kib": memory,
            "guest_vmstat_interval_delta": paired_counter_views([row["guest_vmstat_delta"] for row in first],
                                                               [row["guest_vmstat_delta"] for row in second], signed_difference=True),
        }
    relative_metrics = ("p95_us", "p99_us", "service_p95_us", "service_p99_us", "build_makespan_s")
    metrics["median_paired_native_to_peer_ratio_change"] = {
        metric: median((target["A"][metric] / target["B"][metric]) /
                       (baseline["A"][metric] / baseline["B"][metric])
                       for baseline, target in zip(*(rows[value] for value in VALUES), strict=True))
        for metric in relative_metrics
    }
    return metrics


def summarize(verified, orders=SEED_ORDER, *, include_resources=True):
    by_seed, pooled, observed = [], {level: [] for level in VALUES}, {level: [] for level in VALUES}
    for seed, order in orders.items():
        boots = {level: verified[seed, level] for level in VALUES}
        rows = {level: boot["rows"] for level, boot in boots.items()}
        observations = {level: boot["observations"] for level, boot in boots.items()} if include_resources else None
        first, second = (boots[level]["receipt"]["admission"] for level in order)
        require(docker_time_ns(first["last_utc"]) < docker_time_ns(second["first_utc"]), "wrong prespecified fault-around boot order")
        for baseline, target in zip(*rows.values(), strict=True):
            require(baseline["order"] == target["order"] and len({tuple(row[arm]["build"]["products"])
                    for row in (baseline, target) for arm in shared.ENGINES}) == 1,
                    "fault-around replay changed engine order or CI outputs within a seed")
        for level in VALUES:
            pooled[level].extend(rows[level])
            if observations is not None:
                observed[level].extend(observations[level])
        results = comparisons(rows, observations)
        joint_medians = {label: all(window["metrics"][metric]["micropod"] < window["metrics"][metric]["orbstack"]
                                    for metric in shared.WIN_METRICS)
                         for label, window in results["within_level"].items()}
        by_seed.append({"seed": seed, "boot_order_bytes": list(order),
                        "engine_order": [row["order"] for row in rows[VALUES[0]]],
                        "native_beats_peer_on_both_medians": joint_medians,
                        "boots": {LABELS[i]: boots[level]["receipt"] for i, level in enumerate(VALUES)}, **results})
    engine_windows = [wave[arm] for windows in pooled.values() for wave in windows for arm in shared.ENGINES]
    require(all(len({tuple(boot["rows"][block][arm]["build"]["products"]) for boot in verified.values()
                     for arm in shared.ENGINES}) == 1 for block in range(shared.ROUNDS)),
            "fault-around builds did not produce the same artifacts across both seeds")
    return {
        "matched_boot_pairs": len(by_seed), "native_boots": len(verified), "engine_windows": len(engine_windows),
        "rounds_per_boot": shared.ROUNDS, "paired_engine_windows": len(engine_windows) // 2,
        "fault_around_bytes": list(VALUES), "offered_rps": shared.RATE,
        "offer_duration_ns": paced.OFFER_NS, "offered_requests": sum(wave["offered_requests"] for wave in engine_windows),
        "completed_requests": sum(wave["requests"] for wave in engine_windows),
        "build_jobs": sum(wave["build"]["jobs"] for wave in engine_windows),
        "build_revisions": sum(wave["build"]["revisions"] for wave in engine_windows),
        "test_passes": sum(wave["build"]["test_passes"] for wave in engine_windows),
        "minimum_first_build_end_margin_ns": min(wave["first_build_end_margin_ns"] for wave in engine_windows),
        "native_beats_peer_on_both_medians_each_seed": {
            label: all(row["native_beats_peer_on_both_medians"][label] for row in by_seed) for label in LABELS},
        "by_seed": by_seed, **comparisons(pooled, observed if include_resources else None),
    }


def compare_boots(folders, orders, validate, replay):
    paths = [Path(folder).resolve() for folder in folders]
    require(len(paths) == len(set(paths)) == sum(map(len, orders.values())),
            "fault-around comparison needs four distinct completed archive directories")
    product, candidate = check_product()
    archives, scopes = {}, set()
    common = None
    for folder in paths:
        plan = read(folder, "plan.json")
        key, settings, protocol = validate(folder, plan, product, candidate)
        scope = Path(plan["scope"]).resolve()
        require(key not in archives and scope not in scopes, "duplicate fault-around seed, level or scope")
        context = settings, protocol
        if common is None:
            common = context
        require(context == common, "fault-around trials changed signed launch or measurement inputs")
        archives[key] = folder, plan
        scopes.add(scope)

    require(archives.keys() == {(seed, value) for seed, order in orders.items() for value in order},
            "fault-around cohort is missing a preselected seed or treatment")
    verified = {key: replay(folder, plan) for key, (folder, plan) in archives.items()}
    runs = [row["run"] for row in verified.values()]
    first = next(iter(verified.values()))
    require(len({run["boot"] for run in runs}) == len(runs) and len({run["peer_boot"] for run in runs}) == 1 and
            all((run["worker"], run["images"]) == (first["run"]["worker"], first["run"]["images"]) for run in runs),
            "fault-around trial reused a native boot or changed peer boot, worker, scheduler or images")
    require(len(set().union(*(row["ids"] for row in verified.values()))) == len(runs) * 4 * paced.PAIRS and
            len({row["receipt"]["native_volume"]["volume_uuid"] for row in verified.values()}) == len(runs),
            "fault-around trial reused Docker containers or a host APFS volume")
    compiler, launch = first["compiler_executables"], first["launch"]
    require(all((row["compiler_executables"], row["launch"]) == (compiler, launch) for row in verified.values()),
            "fault-around trial changed the observed Go toolchain or Docker admission arguments")
    intervals = sorted((docker_time_ns(row["receipt"]["admission"]["first_utc"]),
                        docker_time_ns(row["receipt"]["admission"]["last_utc"])) for row in verified.values())
    require(all(end < start for (_, end), (start, _) in zip(intervals, intervals[1:])), "fault-around boot scopes overlapped")
    slack = {engine: {ns for result in verified.values() for row in result["rows"] for ns in row[arm]["timer_slack_ns"]}
             for arm, engine in shared.ENGINES.items()}
    require(all(len(values) == 1 for values in slack.values()), "fault-around trial changed issuing-thread timer slack")
    settings, protocol = common
    metadata = {"signed_product": product["current_product"], "protocol_sha256": shared.fingerprint([protocol, launch]),
            "signed_settings_sha256": shared.fingerprint(settings), "kernel": product["kernel"],
            "worker": first["run"]["worker"], "images": first["run"]["images"], "placements": signed.PLACEMENT,
            "compiler_executables": compiler, "issuing_timer_slack_ns": {engine: values.pop() for engine, values in slack.items()}}
    return metadata, verified


def compare(folders):
    """Replay all four fresh boots and compare matched engine windows by seed."""
    metadata, verified = compare_boots(folders, SEED_ORDER, validated_archive, verified_run)
    return {**metadata, **summarize(verified)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", nargs=4, type=Path)
    print(json.dumps(compare(parser.parse_args().folders), indent=2, allow_nan=False))
