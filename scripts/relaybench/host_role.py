"""Measurements specific to the equal-size Standard/Interactive launchd experiment."""
import hashlib
import json
import math
import plistlib
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from statistics import median, quantiles
from uuid import UUID

from gamma_fleet import GAMMA_LINUX, GAMMA_MAC, hosted_export


# These spellings and numbers appear in Gamma's archived role-control launchctl output.
SPAWN_TYPES = {"Standard": "daemon (3)", "Interactive": "interactive (4)"}
LEGACY_P50_CLIENT_SHA256 = "bf306205c4b1a196868abdf9d14e6eb15540593f4420701d183a670925af812b"
CLIENT_SHA256 = "4f6877088bf57a659e59249437aadd782b121a96fa3e600cf83ad981d170ca53"
GUEST_PROBE_SHA256 = "67f097898d66e4d79a34d634687acad83a16d37549b5628ca0c96ee4f91d1605"
LINK_ERRORS = ("rx_dropped", "tx_dropped", "rx_errors", "tx_errors", "tx_queue_timeouts")
FAULT_COUNTERS = ("rx_errors", "tx_errors", "rx_dropped", "tx_dropped", "tcp_out_resets",
                  "tcp_established_resets") + tuple("parent_" + name for name in LINK_ERRORS)


def timestamp(value):
    # The macOS system Python accepts microseconds. Fleet receipts can carry nanoseconds.
    value = re.sub(r"(\.\d{6})\d+", r"\1", value)
    instant = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if instant.tzinfo is None:
        raise ValueError("handoff and fleet timestamps need a time zone")
    return instant.timestamp()


def check_window(fleet_path, release_path, scopes, now, mode="host-role"):
    """Use the same fleet export and owner handoff schema as the shared stock pilot."""
    fleet = json.loads(fleet_path.read_text())
    if "rigs" in fleet or "serverTime" in fleet:
        fleet = hosted_export(fleet)
    release = json.loads(release_path.read_text())
    scope_paths = [str(path.resolve()) for path in scopes]
    if not (release["owner"].strip() and release["reservation"].strip() and release["host"] == GAMMA_MAC
            and release["exclusive"] is True and isinstance(release["modes"], list) and mode in release["modes"]
            and timestamp(release["starts_at"]) <= now < timestamp(release["expires_at"])
            and len(set(scope_paths)) == len(scope_paths) == 2 and isinstance(release["scopes"], list)
            and set(scope_paths) <= set(release["scopes"])):
        raise ValueError(f"no current owner handoff for these {mode} fixtures")
    clearance = release.get("effective_disk_gate") or {}
    if (clearance.get("passed") is not True or not isinstance(clearance.get("source"), str)
            or not clearance["source"].strip()
            or not timestamp(clearance["checked_at"]) <= now < timestamp(clearance["expires_at"])):
        raise ValueError("missing or expired effective disk clearance from the owner")
    if not 0 <= now - timestamp(fleet["generatedAt"]) <= 90:
        raise ValueError("stale Gamma fleet receipt")
    expiry = min(timestamp(release["expires_at"]), timestamp(clearance["expires_at"]),
                 timestamp(fleet["generatedAt"]) + 90)
    for name in (GAMMA_MAC, GAMMA_LINUX):
        matches = [r for r in fleet["runners"] if r["runner"]["displayName"] == name]
        if len(matches) != 1:
            raise ValueError(f"missing or ambiguous Gamma runner: {name}")
        info = matches[0]["runner"]
        if (matches[0]["connection"] != "online" or info["active"] is not True
                or type(info["activeLeases"]) is not int or info["activeLeases"] != 0
                or type(info["capacity"]) is not int or info["capacity"] < 1
                or not 0 <= now - timestamp(info["lastSeenAt"]) <= 90
                or (name == GAMMA_LINUX and info["capacity"] != 1)):
            raise ValueError(f"Gamma runner is unavailable or has a lease: {name}")
        expiry = min(expiry, timestamp(info["lastSeenAt"]) + 90)
    return {"reservation": release["reservation"], "owner": release["owner"], "mode": mode,
            "scopes": scope_paths, "starts_at": release["starts_at"], "expires_at": release["expires_at"],
            "observed_at": datetime.fromtimestamp(now, timezone.utc).isoformat(timespec="microseconds"),
            "valid_until_epoch": expiry, "fleet_time": fleet["generatedAt"], "effective_disk_gate": clearance}


def verify_job(job, live, pid, home, expected, *, read_kib=None, worker_count=None, vcpus=None):
    pids = re.findall(r"(?m)^[ \t]*pid = (\d+)[ \t]*$", live)
    types = re.findall(r"(?m)^[ \t]*spawn type = ([^\n]+)$", live)
    if (job.get("ProcessType", "Standard") != expected or pids != [str(pid)]
            or types != [SPAWN_TYPES[expected]]):
        raise ValueError(f"expected live {expected} job for supervisor {pid}")
    env = job["EnvironmentVariables"]
    if (job["ProgramArguments"][1:] != ["ci", "serve"]
            or Path(env["MICROPOD_CI_HOME"]).resolve() != home.resolve()
            or env.get("MICROPOD_CI_PORT_RELAY") != "kqueue-interactive"):
        raise ValueError("job does not describe the scoped native relay")
    for key, value in env.items():
        values = re.findall(rf"(?m)^[ \t]*{re.escape(key)} => ([^\n]*)$", live)
        if set(values) != {value}:
            raise ValueError(f"loaded job differs from the saved job in {key}")

    # Scope identity and log destinations necessarily differ between two live jobs.
    controls = {key: value for key, value in job.items()
                if key not in ("Label", "ProcessType", "StandardOutPath", "StandardErrorPath")}
    excluded_env = {"MICROPOD_CI_HOME"}
    if read_kib is not None:
        selector = "MICROPOD_BENCH_RELAY_READ_KIB"
        if env.get(selector) != str(read_kib):
            raise ValueError("launchd read-size selector differs from the planned arm")
        excluded_env.add(selector)
    if worker_count is not None:
        selector = "MICROPOD_CI_PORT_RELAY_WORKERS"
        # Interactive defaults to two workers. Accept the unset control only
        # when the loaded job also omits it. The runtime count is checked separately.
        if (env.get(selector, "2") != str(worker_count) or
                (selector not in env and re.search(rf"(?m)^[ \t]*{selector} =>", live))):
            raise ValueError("launchd worker selector differs from the planned arm")
        excluded_env.add(selector)
    if vcpus is not None:
        # The running CPU count comes from the engine. A loaded fixed selector
        # must agree. Auto and inherited/manifest defaults are valid methods.
        selector = "MICROPOD_CI_CPUS"
        values = set(re.findall(rf"(?m)^[ \t]*{selector} => ([^\n]*)$", live))
        if len(values) > 1 or any(v != "auto" and (not re.fullmatch(r"[+]?[0-9]+", v) or int(v) != vcpus)
                                  for v in values):
            raise ValueError("launchd vCPU selector differs from observed VM size")
        excluded_env.add(selector)
    if read_kib is not None or worker_count is not None or vcpus is not None:
        # The pilot separately matches the mapped executable digests across jobs.
        controls["ProgramArguments"] = controls["ProgramArguments"][1:]
    controls["EnvironmentVariables"] = {key: value for key, value in env.items() if key not in excluded_env}
    controls["loaded_micropod_environment"] = sorted(
        [key, value] for key, value in re.findall(r"(?m)^[ \t]*(MICROPOD_[A-Z0-9_]+) => ([^\n]*)$", live)
        if key not in excluded_env)
    return {"process_type": expected, "spawn_type": types[0],
            "job_controls_sha256": hashlib.sha256(plistlib.dumps(controls)).hexdigest()}


def numeric_irqs(raw):
    """Linux can mask /proc/interrupts in a container. Preserve unknown coverage."""
    lines = raw.splitlines()
    if not lines:
        return None
    cpus = lines[0].split()
    if not cpus or any(not re.fullmatch(r"CPU\d+", name) for name in cpus):
        return None
    total = 0
    found = False
    for line in lines[1:]:
        name, _, fields = line.partition(":")
        if name.strip().isdigit():
            counts = fields.split()[:len(cpus)]
            if len(counts) != len(cpus) or any(not n.isdecimal() for n in counts):
                raise ValueError("incomplete numeric IRQ counters")
            total += sum(map(int, counts))
            found = True
    return total if found else None


def guest_counters(files, parent):
    boot = str(UUID(files["/proc/sys/kernel/random/boot_id"]))
    rows = [line.split(":", 1)[1].split() for line in files["/proc/net/dev"].splitlines()
            if line.strip().startswith("mppub0:")]
    if len(rows) != 1 or len(rows[0]) != 16:
        raise ValueError("missing service publication interface counters")
    fields = ("rx_bytes", "rx_packets", "rx_errors", "rx_dropped",
              "tx_bytes", "tx_packets", "tx_errors", "tx_dropped")
    counters = dict(zip(fields, (int(rows[0][i]) for i in (0, 1, 2, 3, 8, 9, 10, 11))))
    header, values = [line.split()[1:] for line in files["/proc/net/snmp"].splitlines() if line.startswith("Tcp:")]
    if len(header) != len(values) or len(set(header)) != len(header):
        raise ValueError("incomplete TCP counters")
    tcp = dict(zip(header, values))
    counters.update(tcp_out_resets=int(tcp["OutRsts"]), tcp_established_resets=int(tcp["EstabResets"]),
                    tcp_retransmits=int(tcp["RetransSegs"]))
    for key in LINK_ERRORS:
        counters["parent_" + key] = parent[key]
    for name in ("NET_RX", "NET_TX"):
        match = re.search(rf"(?m)^[ \t]*{name}:[ \t]*(\d+(?:[ \t]+\d+)*)[ \t]*$", files.get("/proc/softirqs", ""))
        counters[name.lower() + "_softirqs"] = sum(map(int, match[1].split())) if match else None
    counters["numeric_irqs"] = numeric_irqs(files.get("/proc/interrupts", ""))
    total_irqs = re.search(r"(?m)^intr[ \t]+(\d+)(?:[ \t].*)?$", files.get("/proc/stat", ""))
    counters["total_irqs"] = int(total_irqs[1]) if total_irqs else None
    for key, value in counters.items():
        if value is None and key.endswith("irqs"):
            continue
        if type(value) is not int or value < 0:
            raise ValueError(f"invalid guest counter {key}")
    return {"boot": boot, "monotonic_ns": time.monotonic_ns(), "counters": counters}


def guest_sample(command, fixture):
    sock = fixture["docker_socket"]
    files = json.loads(command("docker", "--host", "unix://" + sock, "exec", fixture["id"],
                               "/mpcheck/netbench", "-net-info"))
    metrics = json.loads(command("curl", "--noproxy", "*", "-fsS", "--max-time", "4", "--unix-socket", sock,
                                 "http://localhost/micropod/metrics"))
    return guest_counters(files, metrics["network"]["published_link"])


def guest_delta(first, last):
    elapsed = (last["monotonic_ns"] - first["monotonic_ns"]) / 1e9
    if first["boot"] != last["boot"] or elapsed <= 0:
        raise ValueError("guest boot or sample clock changed")
    delta = {}
    for key, before in first["counters"].items():
        after = last["counters"][key]
        if before is None or after is None:
            delta[key] = None
        elif after < before:
            raise ValueError(f"guest counter decreased: {key}")
        else:
            delta[key] = after - before
    return {"elapsed_s": elapsed, "delta": delta,
            "per_second": {key: None if delta[key] is None else delta[key] / elapsed
                           for key in ("rx_packets", "tx_packets", "net_rx_softirqs", "net_tx_softirqs",
                                       "numeric_irqs", "total_irqs")}}


def distribution(values):
    quartiles = quantiles(values, n=4, method="inclusive")
    return {"median": median(values), "q1": quartiles[0], "q3": quartiles[2]}


def decision(rows, pairs):
    """Assess all first attempts. Ratios of surviving pairs cannot hide a dirty round."""
    if pairs < 4 or set(rows) != {(n, arm) for n in range(1, pairs + 1) for arm in "AB"}:
        raise ValueError("incomplete host-role comparison")
    reasons = set()
    metrics = {}
    for key, row in rows.items():
        arm = key[1]
        if not row["clean"] or row.get("fresh_failed") != 0 or row.get("reopened") != 0:
            reasons.add(f"{arm} has a failed or unaccounted request or stream")
            continue
        p50, p95, p99 = (row.get(f"fresh_p{p}_us") for p in (50, 95, 99))
        if not all(type(v) is int for v in (p50, p95, p99)) or not (0 < p50 <= p95 <= p99):
            raise ValueError("missing or unordered scheduled-arrival percentiles")
        if arm == "B" and p95 > 75000:
            reasons.add("Interactive fresh p95 exceeded 75 ms")
        link = row["guest"]["delta"]
        if min(link["rx_packets"], link["tx_packets"], link["tx_bytes"]) <= 0:
            raise ValueError("service traffic missing from the publication interface")
        if any(link[k] for k in FAULT_COUNTERS):
            reasons.add(f"{arm} had interface loss, errors, queue timeouts or TCP resets")
        vmm, relay = row["host"]["vmm"], row["host"]["relay"]
        values = dict(mib_s=row["mib_s"], p50_ms=p50 / 1000, p95_ms=p95 / 1000, p99_ms=p99 / 1000,
                      vmm_wait_s_per_s=vmm["wait_s_per_s"], relay_wait_s_per_s=relay["wait_s_per_s"],
                      total_wait_s_per_s=vmm["wait_s_per_s"] + relay["wait_s_per_s"],
                      cpu_s_per_gib=vmm["cpu_s_per_gib"] + relay["cpu_s_per_gib"])
        if "invocation_cpu_s_per_bulk_gib" in vmm and "invocation_cpu_s_per_bulk_gib" in relay:
            values["invocation_cpu_s_per_bulk_gib"] = (vmm["invocation_cpu_s_per_bulk_gib"]
                                                       + relay["invocation_cpu_s_per_bulk_gib"])
        if not all(math.isfinite(v) and v >= 0 for v in values.values()) or values["mib_s"] <= 0:
            raise ValueError("invalid host-role measurements")
        metrics[key] = values
    if len(metrics) < pairs * 2:
        return {"verdict": "reject", "reasons": sorted(reasons)}
    # /proc/stat can supply a guest-wide interrupt rate when the OCI runtime masks /proc/interrupts.
    # Keep each source separate and aggregate only rates available on every measured arm.
    rates = ["rx_packets", "tx_packets", "net_rx_softirqs", "net_tx_softirqs", "numeric_irqs", "total_irqs"]
    common_rates = {rate for rate in rates if all(row["guest"]["per_second"][rate] is not None for row in rows.values())}
    for key, values in metrics.items():
        for rate in sorted(common_rates):
            values[rate + "_per_s"] = rows[key]["guest"]["per_second"][rate]
    by_arm = {arm: {k: distribution([m[k] for (_, a), m in metrics.items() if a == arm])
                    for k in metrics[1, arm]} for arm in "AB"}
    changes = {k: median([metrics[n, "B"][k] - metrics[n, "A"][k] for n in range(1, pairs + 1)])
               for k in metrics[1, "A"]}
    paired_percent = 100 * (median([metrics[n, "B"]["mib_s"] / metrics[n, "A"]["mib_s"]
                                    for n in range(1, pairs + 1)]) - 1)
    if paired_percent <= 0:
        reasons.add("no paired throughput improvement")
    if changes["vmm_wait_s_per_s"] >= 0 or changes["total_wait_s_per_s"] > 0:
        reasons.add("VMM wait did not fall or combined host wait rose")
    verdict = "reject" if reasons else "eligible for confirmation"
    if not {"net_rx_softirqs", "net_tx_softirqs"} <= common_rates or not {"numeric_irqs", "total_irqs"} & common_rates:
        if not reasons:
            verdict = "inconclusive"
        reasons.add("guest IRQ or NET_RX/NET_TX softirq coverage is incomplete")
    return {"verdict": verdict, "reasons": sorted(reasons), "arms": by_arm, "median_paired_change": changes,
            "median_paired_throughput_change_pct": paired_percent}
