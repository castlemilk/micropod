"""Read the worker's real IPv4 routes while 32 private CI job networks are live."""

import json
import re
import shutil
import time
from pathlib import Path

from qualify import require, terminal


def stage(oci, work, folder, product, env, seed):
    product = product.resolve()
    build = json.loads(product.read_bytes())
    root = product.parent / "src"
    sources = {name: sha for name, sha in build["compiled_sources"].items() if name.startswith("guest/runner/")}
    require(sources and all(terminal.digest(root / name) == sha for name, sha in sources.items()),
            "IPAM benchmark source differs from its product")
    binary = work / "probe/ipam.test"
    terminal.invoke("go", "-C", root / "guest/runner", "test", "-c", "-trimpath", "-buildvcs=false",
                    "-o", binary, ".", timeout=240, env={**env, "GOPROXY": "off"})
    directory = work / "ipam"
    directory.mkdir()
    orders = ["old-first", "new-first"] if seed % 4 == 1 else ["new-first", "old-first"]
    script = """
(
    d="$MICROPOD_ENGINE_WORKSPACE/ipam"
    bin="$MICROPOD_ENGINE_WORKSPACE/probe/ipam.test"
    while [ ! -e "$d/go" ]; do sleep 1; done
    run_ipam() {
        "$bin" -test.v -test.run '^TestDockerAutoIPAM' >"$d/tests.log" 2>&1 || return 1
        export MICROPOD_BENCH_DOCKER_IPAM=1
        for order in ORDERS; do
            MICROPOD_BENCH_DOCKER_IPAM_ORDER="$order" "$bin" -test.run '^$' -test.bench '^BenchmarkDockerAutoIPAM$' -test.benchmem -test.benchtime=250ms >"$d/$order.log" 2>&1 || return 1
        done
    }
    if run_ipam; then echo 0 >"$d/status.tmp"; else echo 1 >"$d/status.tmp"; fi
    mv "$d/status.tmp" "$d/status"
) </dev/null >/dev/null 2>&1 &
""".replace("ORDERS", " ".join(orders))
    with (oci / "runner/fixture-facts.sh").open("a") as target:
        target.write(script)
    shutil.copyfile(product, folder / "ipam-probe-product.json")
    shutil.copyfile(__file__, folder / "ipam-probe-driver.py")
    return {"ipam_route_probe": True, "ipam_product_sha256": terminal.digest(product),
            "ipam_driver_sha256": terminal.digest(folder / "ipam-probe-driver.py"),
            "ipam_test_sha256": terminal.digest(binary), "ipam_orders": orders}


def parse(folder, orders):
    tests = (folder / "ipam-tests.log").read_text()
    require(tests.rstrip().endswith("PASS") and re.search(r"^--- PASS: TestDockerAutoIPAM", tests, re.M),
            "guest did not pass the IPAM correctness tests")
    result = {}
    for order in orders:
        raw = (folder / ("ipam-" + order + ".log")).read_text()
        require(raw.rstrip().endswith("PASS"), "guest IPAM benchmark failed")
        rows = {}
        for name, iters, metrics in re.findall(r"^BenchmarkDockerAutoIPAM/(per-candidate|snapshot)(?:-\d+)?\s+(\d+)\s+(.+)$", raw, re.M):
            values = {unit: float(value) for value, unit in re.findall(r"(\S+)\s+(\S+)", metrics)}
            require(name not in rows and int(iters) > 0 and values["ns/op"] > 0 and
                    values["route-dumps/op"] == (33 if name == "per-candidate" else 1), "wrong route dump count")
            rows[name] = {"iterations": int(iters), **values}
        expected = ["per-candidate", "snapshot"] if order == "old-first" else ["snapshot", "per-candidate"]
        require(list(rows) == expected, "wrong IPAM measurement order")
        result[order] = rows
    return result


def collect(work, folder, proof, orders, guard):
    subnets = [job["network"]["IPAM"]["Config"][0]["Subnet"] for job in proof["jobs"]]
    require(subnets == [f"10.90.{i}.0/24" for i in range(32)], "live job networks do not occupy the first 32 subnets")
    directory = work / "ipam"
    (directory / "go").touch(exist_ok=False)
    deadline = time.monotonic() + 90
    while not (directory / "status").exists() and time.monotonic() < deadline:
        guard()
        time.sleep(.5)
    for log in directory.glob("*.log"):
        shutil.copyfile(log, folder / ("ipam-" + log.name))
    require((directory / "status").is_file() and (directory / "status").read_text().strip() == "0",
            "guest route test failed or timed out, see ipam logs")
    terminal.save(folder / "ipam-routes.json", {"network_ids": [j["network"]["Id"] for j in proof["jobs"]],
                  "first_free": "10.90.32.0/24", "samples": parse(folder, orders)})
