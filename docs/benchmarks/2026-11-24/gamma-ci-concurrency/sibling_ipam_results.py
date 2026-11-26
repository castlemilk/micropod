"""Replay the Docker job-network IPAM pilot or the complete crossover."""

import argparse
import json
import math
import plistlib
import re
from functools import cache
from pathlib import Path
from statistics import median

import build_ipvlan
import sibling_ipam
import sibling_job_network
from qualify import require, terminal

SEEDS = (231201, 231203, 231205, 231207, 231209, 231211)
PILOT_PAIRS = 2
CONTROL_FIRST = {231201, 231207, 231209}
SCHEDULE = [(arm, seed) for seed in SEEDS for arm in (
    ("control", "candidate") if seed in CONTROL_FIRST else ("candidate", "control")
)]
SOURCE_DELTA = {"guest/runner/" + name for name in (
    "docker_links_linux.go", "docker_networks_linux.go", "docker_networks_linux_test.go",
)}
TESTS = {"TestDockerAutoIPAM" + name for name in ("ReadsRoutesOnce", "RouteOverlap", "RouteReadFailure", "ExplicitSubnet")}
SCOPE_ENV = {"MICROPOD_CI_HOME": "a", "MICROPOD_CI_WORKSPACE": "workspace", "MICROPOD_CI_OCI_TOOLS": "oci"}
PRODUCT_VARIABLES = {"arena", "worker_executable", "compiled_sources", "patch_sha256",
                     "guest_runner_sha256", "host_product", "guest_runner_product"}


def read(folder, name):
    return json.loads((folder / name).read_bytes())


@cache
def product(arena):
    build = read(arena, "product.json")
    require(Path(build["arena"]) == arena and Path(build["worker_executable"]) == arena / "micropod"
            and build["entitlements"] == {"com.apple.security.virtualization": True}, "wrong signed worker arena")
    files = {"micropod": "worker_executable_sha256", "worker.patch": "patch_sha256", "build.log": "build_log_sha256",
             "micropod-oci-tools/runner/bin/job": "guest_runner_sha256", "micropod-oci-tools/runner/start.sh": "guest_start_sha256",
             "micropod-oci-tools/runner/published-ports.sh": "guest_publication_script_sha256"}
    sources = build["compiled_sources"]
    require(all(terminal.digest(arena / name) == build[key] for name, key in files.items())
            and all(terminal.digest(arena / "src" / name) == sha for name, sha in sources.items())
            and build["guest_start_sha256"] == sources["ci/runner/start.sh"]
            and build["guest_publication_script_sha256"] == sources["ci/runner/published-ports.sh"],
            f"product bytes differ in {arena.name}")
    return build, terminal.digest(arena / "micropod-oci")


def boot(folder, plan, build):
    scope = Path(plan["scope"])
    job = plistlib.loads((folder / "a/job.plist").read_bytes())
    env = job["EnvironmentVariables"]
    worker = read(folder, "a/worker.json")
    session = read(folder, "a/session.json")
    owner, identity = session["owner"], read(folder, "worker-identity.json")
    launch = read(folder, "launch-role.json")
    role = plan["mac_process_type"]
    require(job["ProcessType"] == role and launch["spawn_type"] == {"Standard": "daemon (3)", "Interactive": "interactive (4)"}.get(role)
            and launch["job"].endswith("/" + job["Label"]) and launch["pid"] == owner["pid"] == identity["relay_pid"]
            and job["Label"] == f"dev.micropod.benchmark.{scope.name}.a"
            and job["ProgramArguments"] == [build["worker_executable"], "ci", "serve"]
            and identity["candidate_sha256"] == build["worker_executable_sha256"], "wrong live Mac worker identity")
    require(session["started"] is True and session["nativeOCI"] is True and session["cpuAllocation"] == {"source": "fixed", "count": 4}
            and (worker["cpus"], worker["memoryMiB"], worker["diskGiB"]) == (4, 4096, 6)
            and worker["image"].rsplit("@sha256:", 1)[-1] == terminal.ALPINE.rsplit("@sha256:", 1)[-1]
            and worker["worker"] == identity["worker"] == session["readySocket"]["worker"]
            and identity["instance"] == session["instance"] and worker["workspace"] == env["MICROPOD_CI_WORKSPACE"],
            "wrong live Linux worker resources or image")
    require(env["MICROPOD_CI_CPUS"] == "4" and env["MICROPOD_CI_MEMORY_MIB"] == "4096" and env["MICROPOD_CI_ENGINE"] == "containerd"
            and env["MICROPOD_CI_KERNEL"] == worker["kernel"]
            and all(Path(env[key]).resolve() == (scope / rel).resolve() for key, rel in SCOPE_ENV.items()), "wrong private worker launch settings")
    facts = dict(line.split("=", 1) for line in (folder / "a/guest-facts.txt").read_text().splitlines()
                 if line.startswith(("release=", "boot=", "machine=", "cmdline=", "config_sha256=")))
    kernel = build_ipvlan.verify_archived(folder, Path(worker["kernel"]))["candidate"]
    pages = plan["pages"]
    require(pages["kernel_ipvlan"] is True and pages["kernel_page_kib"] == kernel["page_kib"] == 16
            and kernel["embedded_config_verified"] is True and kernel["image_sha256"] == pages["kernel_image_sha256"]
            and kernel["config_sha256"] == pages["kernel_config_sha256"] == facts["config_sha256"]
            and facts["machine"] == "aarch64" and facts["release"] == build_ipvlan.RELEASE, "wrong live 16 KiB IPvlan Image")
    return {"boot_id": facts.pop("boot"), "worker": identity["worker"], "instance": identity["instance"],
            "started_us": owner["seconds"] * 1_000_000 + owner["microseconds"], "host_boot": owner["bootSession"],
            "bootstrap": {"guest_facts": facts, "worker": {k: v for k, v in worker.items() if k not in ("worker", "workspace")},
                          "env": {k: v for k, v in env.items() if k.startswith("MICROPOD_") and k not in SCOPE_ENV}}}


def image_identity(folder):
    images = read(folder, "images.json")
    proof = images["expected"]
    native, peer = (images["inspected"][arm] for arm in "AB")
    require(proof["manifest"] == terminal.MNF and proof["config"] == terminal.PINNED["image_config_sha256"]
            and proof["compressed_layer"] == terminal.LAYER and proof["diff_id"] == terminal.DIFF and proof["netbench"] == terminal.SERVER
            and proof["archive"] in (terminal.REEXPORT, terminal.PINNED["kernel_and_tools"]["netbench_image_tar"]["sha256"])
            and native["Id"] == "sha256:" + proof["config"] and peer["Id"] == "sha256:" + proof["manifest"]
            and peer["RootFS"]["Layers"] == ["sha256:" + proof["diff_id"]]
            and all(image["Architecture"] == "arm64" and image["Os"] == "linux" for image in (native, peer)),
            "guest workload image digests differ")
    return proof


def replay(folder, arm):
    checked = sibling_job_network.verify_archived(folder)
    plan = read(folder, "plan.json")
    seed = plan["seed"]
    require(seed in SEEDS and plan["ipam_route_probe"] is True and plan["healthy_pairs"] == 4 and plan["rounds"] == 1
            and plan["dense_ms"] == 0 and not plan.get("builders") and plan.get("network_driver", "bridge") == "bridge",
            "unexpected IPAM fixture workload")
    pins = {"sibling-driver.py": "harness_sha256", "quiet-http.go": "quiet_source_sha256",
            "ipam-probe-driver.py": "ipam_driver_sha256", "ipam-probe-product.json": "ipam_product_sha256"}
    require(all(terminal.digest(folder / name) == plan[key] for name, key in pins.items())
            and all(re.fullmatch(r"[0-9a-f]{64}", plan[key]) for key in ("quiet_sha256", "ipam_test_sha256")),
            "IPAM harness, workload or probe identities differ")
    build = read(folder, "worker-build.json")
    actual, guest_oci = product(Path(build["arena"]))
    require(build == actual, "archived worker build differs from its product")
    orders = ["old-first", "new-first"] if seed % 4 == 1 else ["new-first", "old-first"]
    require(plan["ipam_orders"] == orders, "unexpected route-test order")
    logs = (folder / "ipam-tests.log").read_text()
    require(TESTS <= set(re.findall(r"^--- PASS: (TestDockerAutoIPAM\w+)\b", logs, re.M)), "missing IPAM regression tests")
    raw = sibling_ipam.parse(folder, orders)
    smoke = read(folder, "job-network-smoke.json")
    networks = [job["network"] for job in smoke["jobs"]]
    ids = [network["Id"] for network in networks]
    routes = read(folder, "ipam-routes.json")
    require([network["IPAM"]["Config"][0]["Subnet"] for network in networks] == [f"10.90.{i}.0/24" for i in range(32)]
            and routes == {"network_ids": ids, "first_free": "10.90.32.0/24", "samples": raw}, "route probe and live network evidence differ")
    require(all(math.isfinite(row["ns/op"]) and math.isfinite(row["route-dumps/op"]) for variants in raw.values() for row in variants.values()),
            "nonfinite IPAM measurements")
    return {"run": str(folder), "arm": arm, "seed": seed, "plan": plan, "build": build, "guest_oci_sha256": guest_oci,
            "probe_product": read(folder, "ipam-probe-product.json"), "network_ids": ids, "routes": raw,
            "create_total_ns": checked["network_create_total_ns"], "image": image_identity(folder), **boot(folder, plan, build)}


def provisioning_summary(pairs):
    ratios = [row["candidate_over_control"] for row in pairs]
    return {"pairs": pairs, "candidate_wins": sum(ratio < 1 for ratio in ratios), "median_candidate_over_control": median(ratios)}


def route_summary(pairs):
    return {"pairs": pairs, "first_free": "10.90.32.0/24",
            **{metric: {"snapshot_wins": sum(row[metric] < 1 for row in pairs),
                        "median_snapshot_over_per_candidate": median(row[metric] for row in pairs)}
               for metric in ("ns_per_op_ratio", "route_dumps_per_op_ratio")}}


def paired(controls, candidates):
    count = len(controls)
    require(count == len(candidates) and count in (PILOT_PAIRS, len(SEEDS)),
            "provide both pilot pairs or all six planned IPAM pairs")
    boots = sorted([replay(path, arm) for arm, paths in (("control", controls), ("candidate", candidates)) for path in paths],
                   key=lambda row: row["started_us"])
    boot_count = 2 * count
    require([(row["arm"], row["seed"]) for row in boots] == SCHEDULE[:boot_count], "IPAM boots did not follow the prespecified order")
    first, new = boots[:2]
    old_build, new_build = first["build"], new["build"]
    require(all(len({row[key] for row in boots}) == boot_count for key in ("run", "boot_id", "worker", "instance", "started_us"))
            and len({row["plan"]["scope"] for row in boots}) == boot_count
            and len({nid for row in boots for nid in row["network_ids"]}) == sibling_job_network.JOBS * boot_count,
            "IPAM crossover reused a worker, scope or network")
    fingerprints = ("image", "bootstrap", "guest_oci_sha256", "host_boot")
    adaptive = {"seed", "scope", "ipam_orders"}
    for row in boots:
        require(all(row[key] == first[key] for key in fingerprints)
                and {k: v for k, v in row["plan"].items() if k not in adaptive} ==
                {k: v for k, v in first["plan"].items() if k not in adaptive}
                and row["build"] == (old_build if row["arm"] == "control" else new_build) and row["probe_product"] == new_build,
                "IPAM crossover changed a shared setting, fixture, or candidate probe")
    old_sources, new_sources = old_build["compiled_sources"], new_build["compiled_sources"]
    require(old_sources.keys() == new_sources.keys() and {key for key in old_sources if old_sources[key] != new_sources[key]} == SOURCE_DELTA
            and {k: v for k, v in old_build.items() if k not in PRODUCT_VARIABLES} ==
            {k: v for k, v in new_build.items() if k not in PRODUCT_VARIABLES}
            and old_build["guest_runner_sha256"] != new_build["guest_runner_sha256"], "guest allocator delta or shared product identity differs")

    provisioning = []
    for seed in SEEDS[:count]:
        control, = [row for row in boots if row["seed"] == seed and row["arm"] == "control"]
        candidate, = [row for row in boots if row["seed"] == seed and row["arm"] == "candidate"]
        a, b = control["create_total_ns"], candidate["create_total_ns"]
        provisioning.append({"seed": seed, "control_run": control["run"], "candidate_run": candidate["run"],
                             "control_ns": a, "candidate_ns": b, "candidate_over_control": b / a})
    route_pairs = []
    for row in boots:
        for order, variants in row["routes"].items():
            a, b = variants["per-candidate"], variants["snapshot"]
            route_pairs.append({"run": row["run"], "worker_arm": row["arm"], "seed": row["seed"], "order": order,
                                "per_candidate": a, "snapshot": b, "ns_per_op_ratio": b["ns/op"] / a["ns/op"],
                                "route_dumps_per_op_ratio": b["route-dumps/op"] / a["route-dumps/op"]})
    require(len(route_pairs) == 2 * boot_count, "expected two within-boot route comparisons per worker")
    result = {"host": first["plan"]["host"], "boots": [{key: row[key] for key in ("run", "arm", "seed", "boot_id", "create_total_ns")} for row in boots],
              "provisioning": provisioning_summary(provisioning), "route_probe": route_summary(route_pairs),
              "identities": {"worker_executable_sha256": old_build["worker_executable_sha256"], "guest_oci_sha256": first["guest_oci_sha256"],
                             "control_runner_sha256": old_build["guest_runner_sha256"], "candidate_runner_sha256": new_build["guest_runner_sha256"],
                             "kernel": first["plan"]["pages"], "service_image": first["image"],
                             "changed_sources": sorted(SOURCE_DELTA), **{key: first["plan"][key] for key in (
                                 "harness_sha256", "quiet_sha256", "quiet_source_sha256", "job_network_smoke_driver_sha256",
                                 "ipam_driver_sha256", "ipam_product_sha256", "ipam_test_sha256")}}}
    if count == len(SEEDS):
        result["subsets"] = {
            name: {"seeds": seeds, "provisioning": provisioning_summary([row for row in provisioning if row["seed"] in seeds]),
                   "route_probe": route_summary([row for row in route_pairs if row["seed"] in seeds])}
            for name, seeds in (("pilot", SEEDS[:PILOT_PAIRS]), ("holdout", SEEDS[PILOT_PAIRS:]))
        }
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control", type=Path, nargs="+", required=True, help="two pilot or six planned control run folders")
    parser.add_argument("--candidate", type=Path, nargs="+", required=True, help="two pilot or six planned candidate run folders")
    args = parser.parse_args()
    print(json.dumps(paired([path.resolve() for path in args.control], [path.resolve() for path in args.candidate]), indent=2, allow_nan=False))
