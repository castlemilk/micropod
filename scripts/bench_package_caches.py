#!/usr/bin/env python3
"""Measure offline npm and Go reuse across independent checkouts on the executing OS."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import base64
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time
from zipfile import ZipFile, ZipInfo

MODULE = "example.test/shared"
VERSION = "v1.0.0"
NPM_NAME = "micropod-cache-fixture"
TOKEN = "micropod-cache-ok"
COMPILER = re.compile(r'(?m)^(?:"?[^ \n"]*/(?:compile|asm)"?) (?!-V(?: |$))')
CACHE_NAMES = ("npm-cache", "go-mod-cache", "go-build-cache")


def command(argv, cwd, env, check=True):
    start = time.perf_counter()
    p = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=180)
    elapsed = time.perf_counter() - start
    if check and p.returncode:
        raise RuntimeError(f"{argv[0]} {argv[1:2]} exited {p.returncode}: {p.stderr[-1600:]}")
    return p, elapsed


def need(condition, message):
    if not condition:
        raise ValueError(message)


def stores(root):
    return {name: root / name for name in CACHE_NAMES}


def jsonfile(path, obj):
    path.write_text(json.dumps(obj, sort_keys=True) + "\n")


class Fixture:
    def __init__(self, root):
        self.root = root
        self.origin = root / "origin"
        self.origin.mkdir()
        self.source = self.origin / "package.tgz"
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w") as tar:
            files = {"package.json": json.dumps({"name": NPM_NAME, "version": "1.0.0", "main": "index.js"}),
                     "index.js": f"module.exports = '{TOKEN}';\n"}
            for name, data in files.items():
                raw = data.encode()
                item = tarfile.TarInfo("package/" + name)
                item.size = len(raw)
                tar.addfile(item, io.BytesIO(raw))
        data = gzip.compress(payload.getvalue(), mtime=0)
        self.source.write_bytes(data)
        sha = hashlib.sha512(data)
        self.npm_key = sha.hexdigest()
        self.sri = "sha512-" + base64.b64encode(sha.digest()).decode()

        proxy = self.origin / MODULE / "@v"
        proxy.mkdir(parents=True)
        mod = f"module {MODULE}\n\ngo 1.22\n"
        (proxy / (VERSION + ".mod")).write_text(mod)
        jsonfile(proxy / (VERSION + ".info"), {"Version": VERSION, "Time": "2020-01-01T00:00:00Z"})
        archive = proxy / (VERSION + ".zip")
        with ZipFile(archive, "w") as out:
            for name, value in {"go.mod": mod, "shared.go": f'package shared\nconst Message = "{TOKEN}"\n'}.items():
                out.writestr(ZipInfo(MODULE + "@" + VERSION + "/" + name), value)
        self.zip_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.go_sum = None

    def workspace(self, name):
        w = self.root / "checkouts" / name
        w.mkdir(parents=True)
        pkg = {"name": "micropod-cache-client", "version": "1.0.0", "dependencies": {NPM_NAME: "1.0.0"}}
        jsonfile(w / "package.json", pkg)
        jsonfile(w / "package-lock.json", {**pkg, "lockfileVersion": 3, "packages": {"": pkg,
                 "node_modules/" + NPM_NAME: {"version": "1.0.0", "integrity": self.sri,
                                              "resolved": "https://offline.invalid/cache-fixture.tgz"}}})
        (w / "go.mod").write_text(f"module example.test/client\n\ngo 1.22\n\nrequire {MODULE} {VERSION}\n")
        (w / "main.go").write_text(f'package main\nimport ("fmt"; "{MODULE}")\nfunc main() {{fmt.Println(shared.Message)}}\n')
        if self.go_sum:
            (w / "go.sum").write_bytes(self.go_sum)
        return w

    def environment(self, cache, seed=False):
        env = {k: v for k, v in os.environ.items() if not k.startswith("GO") and not k.lower().startswith("npm_config_")}
        return dict(env, GOENV="off", GOTOOLCHAIN="local", GOWORK="off", GOFLAGS="-p=2", GOMAXPROCS="2",
                    CGO_ENABLED="0", GOTELEMETRY="off", GOPROXY=self.origin.as_uri() if seed else "off", GOSUMDB="off",
                    GOMODCACHE=str(cache["go-mod-cache"]), GOCACHE=str(cache["go-build-cache"]),
                    npm_config_cache=str(cache["npm-cache"]), npm_config_offline="true", npm_config_audit="false",
                    npm_config_fund="false", npm_config_ignore_scripts="true", npm_config_userconfig=os.devnull,
                    npm_config_globalconfig=str(self.root / "empty-npmrc"), npm_config_update_notifier="false")

    def prime(self, cache, name):
        w = self.workspace(name)
        env = self.environment(cache, seed=True)
        _, npm = command(["npm", "cache", "add", str(self.source)], w, env)
        _, download = command(["go", "mod", "download", MODULE + "@" + VERSION], w, env)
        sums = (w / "go.sum").read_bytes()
        need(b" h1:" in sums and (self.go_sum is None or self.go_sum == sums), "Go module integrity changed")
        self.go_sum = sums
        response, build = command(self.argv("go"), w, env)
        count = len(COMPILER.findall(response.stderr))
        need(count > 0, "Cold Go build did not invoke a compiler")
        self.verify_output("go", w, env)
        return dict(npm_cache_add_seconds=npm, go_download_seconds=download, go_cold_build_seconds=build,
                    go_cold_compiler_or_assembler_invocations=count)

    def argv(self, tool):
        return ["npm", "ci"] if tool == "npm" else ["go", "build", "-x", "-trimpath", "-buildvcs=false", "-o", "app", "."]

    def verify_output(self, tool, w, env):
        argv = ["node", "-p", f"require('{NPM_NAME}')"] if tool == "npm" else [str(w / "app")]
        run, _ = command(argv, w, env)
        need(run.stdout.strip() == TOKEN, f"Unexpected {tool} product from {w.name}")

    def controls(self, empty):
        w = self.workspace("empty-stores")
        env = self.environment(empty)
        npm, _ = command(self.argv("npm"), w, env, check=False)
        go, _ = command(self.argv("go"), w, env, check=False)
        need(npm.returncode and "ENOTCACHED" in npm.stderr, "An empty npm store unexpectedly satisfied the offline lock")
        need(go.returncode and "GOPROXY=off" in go.stderr, "An empty Go module store unexpectedly supplied the dependency")

    def batch(self, cache, tool, workspaces):
        env = self.environment(cache)
        def work(w):
            p, seconds = command(self.argv(tool), w, env)
            if tool == "go":
                need(not COMPILER.search(p.stderr), "Warm checkout compiled or assembled a package")
            return round(seconds, 6)

        start = time.perf_counter()
        with ThreadPoolExecutor(max_workers=len(workspaces)) as pool:
            durations = list(pool.map(work, workspaces))
        elapsed = round(time.perf_counter() - start, 6)
        # Product execution is a correctness check outside the timing boundary.
        for w in workspaces:
            self.verify_output(tool, w, env)
        return dict(clients=len(workspaces), seconds=elapsed, client_seconds=durations)

    def payloads(self, cache):
        key = self.npm_key
        content = cache["npm-cache"] / "_cacache/content-v2/sha512"
        blob = content / key[:2] / key[2:4] / key[4:]
        archive = cache["go-mod-cache"] / "cache/download" / MODULE / "@v" / (VERSION + ".zip")
        need(hashlib.sha512(blob.read_bytes()).hexdigest() == key, "npm content integrity failed")
        need(hashlib.sha256(archive.read_bytes()).hexdigest() == self.zip_digest, "Go module zip integrity failed")
        need(sum(p.is_file() for p in content.rglob("*")) == 1, "npm stored a second content blob for this fixture")
        need(len(list(cache["go-mod-cache"].rglob("*.zip"))) == 1, "Go stored a second module zip")
        return (blob, archive)


def snapshot(cache):
    def sizes(p):
        paths = [f for f in p.rglob("*") if f.is_file()]
        return dict(files=len(paths), logical_bytes=sum(f.stat().st_size for f in paths))
    # npm debug logs and Go trim metadata are outside these payload counts.
    return {"npm_content": sizes(cache["npm-cache"] / "_cacache/content-v2"),
            "go_modules": sizes(cache["go-mod-cache"]), "go_build": sizes(cache["go-build-cache"])}


def run(root, clients, rounds, record):
    fixture = Fixture(root)
    shared = stores(root / "shared")
    control = stores(root / "independent-control")
    record["seed"] = fixture.prime(shared, "seed")
    record["independent_seed"] = fixture.prime(control, "independent")
    shared_payloads = fixture.payloads(shared)
    for a, b in zip(shared_payloads, fixture.payloads(control)):
        need(not a.samefile(b), "Independent control reused an active store file")
    record["independent_store"] = snapshot(control)
    record["before"] = snapshot(shared)
    ids = [(p.stat().st_dev, p.stat().st_ino) for p in shared_payloads]
    # Remove all source tarballs, proxy metadata and module archives before timing.
    shutil.rmtree(fixture.origin)
    fixture.controls(stores(root / "empty"))
    rows = record["batches"] = []
    for block in range(rounds):
        offset = block % len(clients)
        for n in clients[offset:] + clients[:offset]:
            for tool in (("npm", "go") if block % 2 == 0 else ("go", "npm")):
                work = [fixture.workspace(f"{block}-{tool}-{n}-{i}") for i in range(n)]
                rows.append(dict(round=block + 1, tool=tool, **fixture.batch(shared, tool, work)))
    need(ids == [(p.stat().st_dev, p.stat().st_ino) for p in fixture.payloads(shared)], "Shared payload identities changed")
    record.update(after=snapshot(shared), offline_negative_controls=["npm", "go"], npm_integrity=fixture.sri,
                  go_sum=fixture.go_sum.decode().splitlines(), go_zip_sha256=fixture.zip_digest,
                  warm_compiler_or_assembler_invocations=0)
    record["median_seconds"] = {t: {n: round(statistics.median(i["seconds"] for i in rows if i["tool"] == t
                                                               and i["clients"] == n), 6) for n in clients} for t in ("npm", "go")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clients", type=int, nargs="+", default=[1, 4, 8, 16])
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--parent", type=Path, help="Existing directory in which to allocate fresh private stores")
    parser.add_argument("--bind-binary", type=Path, help="Measure the Micropod shared filesystem bind path with this compiled driver")
    parser.add_argument("--transport", choices=("unix", "direct"), default="unix")
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()
    if not (1 <= args.rounds <= 50 and len(set(args.clients)) == len(args.clients) and all(1 <= n <= 64 for n in args.clients)):
        parser.error("Supply 1..50 rounds and unique concurrency levels from 1..64")
    record = dict(system=platform.system(), machine=platform.machine(), release=platform.release(), cpus=os.cpu_count(),
                  load_before=os.getloadavg(), rounds=args.rounds, profile="package-manager-offline",
                  measured_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    try:
        with tempfile.TemporaryDirectory(dir=args.parent, prefix="micropod-pkg-") as tmp:
            root = Path(tmp).resolve()
            env = {**os.environ, "GOENV": "off", "GOTOOLCHAIN": "local", "GOWORK": "off", "GOTELEMETRY": "off",
                   "npm_config_cache": str(root / "version-cache"), "npm_config_update_notifier": "false"}
            record["versions"] = {t: command([t, f], root, env)[0].stdout.strip() for t, f in
                                  (("go", "version"), ("npm", "--version"), ("node", "--version"))}
            if args.bind_binary:
                fixture = Fixture(root)
                cache = stores(root / "shared")
                record["profile"] = "micropod-shared-cache-bind"
                record["seed"] = fixture.prime(cache, "seed")
                record["cache_sizes"] = snapshot(cache)
                output = root / "bind.json"
                command([str(args.bind_binary.resolve()), args.transport, str(root / "shared"),
                         str(root / "daemon"), str(output), str(args.rounds)], root, env)
                result = json.loads(output.read_text())
                need(result["passed"], "The benchmark failed to release all shared views")
                record.update(result)
                levels = sorted({s["clients"] for s in result["batches"]})
                record["median_seconds"] = {mode: {n: round(statistics.median(s["seconds"] for s in result["batches"]
                                               if s["mode"] == mode and s["clients"] == n), 9) for n in levels}
                                            for mode in ("size-and-bind", "bind")}
            else:
                run(root, args.clients, args.rounds, record)
        record["passed"] = True
    except Exception as e:
        record.update(passed=False, error=str(e))
    record["load_after"] = os.getloadavg()
    args.json.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({k: v for k, v in record.items() if k in {"passed", "error", "seed", "median_seconds", "before", "after"}}))
    return 0 if record["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
