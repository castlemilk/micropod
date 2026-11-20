"""Offline package-manager workloads for the already-qualified warm Docker engine."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import statistics
import time
import uuid


def measure_packages(command, image_ref, architecture, boot, fingerprint, clients, rounds, result, warm_bytecode=False):
    script = Path(__file__).with_name("bench_package_caches.py").read_text()
    image = json.loads(command(["image", "inspect", image_ref]).stdout)[0]
    if image["Architecture"] != architecture or image.get("Os") != "linux":
        raise ValueError("The package toolchain must run natively on the measured Linux engine")
    result.update(workload="offline-npm-go-oci-v1", architecture=architecture, image_id=image["Id"],
                  script_sha256=hashlib.sha256(script.encode()).hexdigest(), resource_contract="1 CPU / 1 GiB",
                  clients=clients, blocks=[])
    if warm_bytecode:
        result["workload"] = "offline-npm-go-oci-warm-bytecode-v1"
    cohort = "mp-cache-" + uuid.uuid4().hex
    label = "io.micropod.cache-bench=" + cohort

    def run(op, lock, mounts):
        name = cohort + "-" + uuid.uuid4().hex
        argv = ["run", "--rm", "--pull=never", "--label", label, "--name", name, "--cpus", "1", "--memory", "1g",
                "--network", "none", *mounts, image["Id"], "python3", "-c", script, "container", op, json.dumps(lock)]
        try:
            row = json.loads(command(argv).stdout)
            if row.get("verified") != op or fingerprint(row["boot"]) != boot:
                raise ValueError("Package job failed the product or kernel identity check")
            return row
        except Exception:
            command(["rm", "-f", name], check=False)
            raise

    for block in range(rounds):
        # One fresh store per tool per block. Different engines and independent repetitions get separate stores.
        names, mounts = [], []
        record = {"batches": [], "round": block + 1}
        result["blocks"].append(record)
        try:
            stores = ["npm-cache", "go-mod-cache", "go-build-cache"]
            if warm_bytecode:
                stores.append("python-bytecode")
            for kind in stores:
                name = f"{cohort}-{block}-{kind}"
                if command(["volume", "create", "--label", label, name]).stdout.strip() != name:
                    raise ValueError(f"Docker did not create the requested {kind} volume")
                names.append(name)
                mounts.extend(["--mount", f"type=volume,src={name},dst=/caches/{kind}"])
            if warm_bytecode:
                mounts.extend(["-e", "PYTHONPYCACHEPREFIX=/caches/python-bytecode"])
            seed = run("seed", None, mounts)
            lock = seed["lock"]
            record.update(cold=seed["cold"], versions=seed["versions"], before=seed["cache_sizes"], lock=lock)
            run("empty", lock, ["--tmpfs", "/caches"])
            if warm_bytecode:
                # Populate lazy imports once on each engine, outside the client clock.
                for op in ("go", "npm", "audit"):
                    run(op, lock, mounts)

                def bytecode_inventory():
                    audit = """from pathlib import Path
import hashlib, json
root = Path('/caches/python-bytecode')
files = sorted((str(p.relative_to(root)), p.stat().st_ino, p.stat().st_size) for p in root.rglob('*.pyc'))
assert files
print(json.dumps(dict(files=len(files), bytes=sum(f[2] for f in files),
    fingerprint=hashlib.sha256(json.dumps(files).encode()).hexdigest())))"""
                    argv = ["run", "--rm", "--pull=never", "--network", "none", "--label", label,
                            "--mount", f"type=volume,src={names[-1]},dst=/caches/python-bytecode,readonly",
                            image["Id"], "python3", "-B", "-c", audit]
                    return json.loads(command(argv).stdout)
                record["bytecode_before"] = bytecode_inventory()
            for i in range(len(clients)):
                n = clients[(block + i) % len(clients)]
                tools = ("npm", "go") if (i + block) % 2 == 0 else ("go", "npm")
                for tool in tools:
                    start = time.perf_counter()
                    with ThreadPoolExecutor(max_workers=n) as pool:
                        checks = [pool.submit(run, tool, lock, mounts) for _ in range(n)]
                        errors = [str(e) for f in checks if (e := f.exception()) is not None]
                    record["batches"].append(dict(tool=tool, clients=n, seconds=round(time.perf_counter()-start, 6),
                                                  passed=n-len(errors), errors=errors))
                    if errors:
                        raise ValueError(f"{tool} failed at {n} clients: {errors[0]}")
            after = run("audit", lock, mounts)
            if after["payload_inodes"] != seed["payload_inodes"]:
                raise ValueError("The shared npm or Go module payload changed inode")
            if warm_bytecode:
                record["bytecode_after"] = bytecode_inventory()
                if record["bytecode_before"] != record["bytecode_after"]:
                    raise ValueError("Bytecode was replaced or duplicated during the warm jobs")
            record.update(after=after["cache_sizes"], same_payload_inodes=True, empty_offline_controls=True)
        finally:
            if names:
                command(["volume", "rm", *names])
        if command(["ps", "-aq", "--filter", "label=" + label]).stdout.strip() or command(
                ["volume", "ls", "-q", "--filter", "label=" + label]).stdout.strip():
            raise ValueError("Package containers or volumes remained after the run")
    result["median_seconds"] = {
        tool: {str(n): statistics.median(b["seconds"] for block in result["blocks"] for b in block["batches"]
                                        if b["tool"] == tool and b["clients"] == n) for n in clients}
        for tool in ("npm", "go")}
    result["passed"] = True
