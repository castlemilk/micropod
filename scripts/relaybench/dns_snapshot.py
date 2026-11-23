"""Replay a service-directory revision against the worktree without guest network access."""
import argparse
import hashlib
import json
import os
import platform
import re
import statistics
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUEST = Path("guest/runner")
FIXTURE = Path(__file__).with_name("dns_snapshot") / "fixture_test.go"
BASE = "405d7c7982268a9df95d56e5bb7b36e5c606639c"
BLOCKS = 8
ITERATIONS = 50_000
BENCH = re.compile(r"^BenchmarkSnapshot/(\S+)\s+(\d+)\s+([\d.]+) ns/op\s+(\d+) B/op\s+(\d+) allocs/op$", re.M)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def compile_arm(go, arm, work, env):
    dest = work / arm
    dest.mkdir()
    digests = {}
    for name in ("go.mod", "go.sum", "docker_dns_answer.go", "docker_dns_directory.go", "docker_dns_linux.go",
                 "docker_network_metrics_linux.go"):
        path = GUEST / name
        data = (subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT) if arm == "base"
                else (ROOT / path).read_bytes())
        digests[str(path)] = sha(data)
        if name == "docker_dns_linux.go":
            # Drop the Linux socket setup while keeping the exact DNS entry point and its callees.
            text = data.decode()
            body = text[text.index("func readDNS("):]
            imports = [pkg for pkg in re.findall(r'^\s*"([^"]+)"$', text.split("type networkDNS", 1)[0], re.M)
                       if re.search(r"\b" + re.escape(pkg.split("/")[-1]) + r"\.", body)]
            data = ('package main\nimport (\n' + ''.join(f'"{pkg}"\n' for pkg in imports) + ')\n' + body).encode()
        (dest / name.replace("_linux.go", "_host.go")).write_bytes(data)
    (dest / "fixture_test.go").write_bytes(FIXTURE.read_bytes())
    exe = dest / "dns.test"
    subprocess.run([go, "test", "-mod=readonly", "-p", "2", "-c", "-o", exe], cwd=dest, env=env, check=True)
    check = subprocess.check_output([exe, "-test.v", "-test.run", "^TestReplies$"], env=env, text=True)
    parity = re.search(r"verified (60) responses ([0-9a-f]{64})", check)
    if not parity:
        raise ValueError(check)
    return exe, dict(files=digests, binary=sha(exe.read_bytes()), verified_response_sha256=parity[2])


def run(exe, env):
    output = subprocess.check_output([exe, "-test.run", "^$", "-test.bench", "^BenchmarkSnapshot$",
                                      "-test.benchmem", "-test.benchtime", f"{ITERATIONS}x", "-test.cpu", "1"],
                                     env=env, text=True)
    rows = {}
    for name, n, ns, size, allocations in BENCH.findall(output):
        if int(n) != ITERATIONS or name in rows:
            raise ValueError(name)
        rows[name] = [float(ns), int(size), int(allocations)]
    expected = {f"lookup/{n}/{kind}" for n in (0, 1, 8, 256) for kind in ("A", "AAAA", "alternating")}
    expected.update(f"publish/{n}" for n in (1, 8, 256))
    if set(rows) != expected:
        raise ValueError(output)
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mp-dns-snapshot-") as scratch:
        directory = Path(scratch)
        env = dict(os.environ, GOENV="off", GOTOOLCHAIN="local", GOWORK="off", GOPROXY="off", GOSUMDB="off",
                   CGO_ENABLED="0", GOFLAGS="-trimpath", GOTELEMETRY="off", GOMAXPROCS="1",
                   GOCACHE=os.environ.get("GOCACHE", str(directory / "cache")))
        env.pop("GOROOT", None)
        source, binaries = {}, {}
        for arm in ("base", "candidate"):
            binaries[arm], source[arm] = compile_arm(args.go, arm, directory, env)
        if source["base"]["verified_response_sha256"] != source["candidate"]["verified_response_sha256"]:
            raise ValueError("reply bytes differ")
        blocks = []
        for i in range(BLOCKS):
            order = ("base", "candidate") if i % 2 == 0 else ("candidate", "base")
            blocks.append(dict(order=order, rows={arm: run(binaries[arm], env) for arm in order}))
        report = {}
        for cell in blocks[0]["rows"]["base"]:
            a, b = ([block["rows"][arm][cell] for block in blocks] for arm in ("base", "candidate"))
            ratios = [y[0] / x[0] for x, y in zip(a, b)]
            report[cell] = dict(base=[statistics.median(col) for col in zip(*a)],
                                candidate=[statistics.median(col) for col in zip(*b)],
                                median_paired_change_pct=round(100 * (statistics.median(ratios) - 1), 2),
                                faster_pairs=sum(r < 1 for r in ratios))
        print(json.dumps(dict(scope="Native Go DNS parser, directory, encoder and metrics; empty upstream, "
                                    "internal network. Per-op means within fixed-work blocks, with setup excluded.",
                              base_commit=BASE, host=platform.platform(), arch=platform.machine(),
                              go=subprocess.check_output([args.go, "version"], env=env, text=True).strip(),
                              gomaxprocs=1, iterations_per_cell=ITERATIONS, pairs=BLOCKS,
                              read_work="A, AAAA or alternating A/AAAA; UDP, legacy 512-byte cap, mixed-case IN name. "
                                        "The 256-record A response is truncated.",
                              publish_work="One remove then add of the middle member, with its unique name and one "
                                           "shared alias. At count 1, removal empties the alias.",
                              verification="Each binary verified 60 mixed-case A/AAAA/ANY replies on UDP and TCP "
                                           "across publication, withdrawal and re-addition. Checked ordered "
                                           "addresses, truncation, authority, per-directory counters and wire digest.",
                              row_units=["ns/op", "B/op", "allocs/op"], fixture_sha256=sha(FIXTURE.read_bytes()),
                              driver_sha256=sha(Path(__file__).read_bytes()), source=source,
                              summary=report, blocks=blocks), indent=2))


if __name__ == "__main__":
    main()
