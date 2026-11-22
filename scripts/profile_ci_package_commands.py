#!/usr/bin/env python3
"""Time identical cold and warm Go/npm commands using disposable private stores and local origins."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import uuid

from bench_package_caches import COMPILER, MODULE, VERSION, Fixture, command, snapshot, stores
from bench_postgres_fixture import distribution, require
from ci_benchmark_store import store


def run_round(root, result):
    fixture = Fixture(root)
    cache = stores(root / "cache")
    env = fixture.environment(cache, seed=True)
    env.update(GOMAXPROCS="1", GOFLAGS="-p=1")
    source = fixture.source.as_uri()
    ids = None
    for state in ("cold", "warm"):
        if state == "warm":
            shutil.rmtree(fixture.origin)
        work = fixture.workspace(state)
        lockfile = work / "package-lock.json"
        lock = json.loads(lockfile.read_text())
        lock["packages"]["node_modules/micropod-cache-fixture"]["resolved"] = source
        lockfile.write_text(json.dumps(lock, sort_keys=True) + "\n")
        record = result[state] = {"before": snapshot(cache), "commands": {}}
        for name, argv in (("npm_ci", fixture.argv("npm")), ("go_mod_download", ["go", "mod", "download", MODULE+"@"+VERSION]),
                           ("go_build", fixture.argv("go"))):
            proc, elapsed = command(argv, work, env, check=False)
            record["commands"][name] = {"seconds": elapsed, "exit": proc.returncode}
            require(proc.returncode == 0, f"{state} {name} failed: {proc.stderr[-400:]}")
            if name == "go_mod_download":
                fixture.go_sum = (work / "go.sum").read_bytes()
            if name == "go_build":
                record["compiler_or_assembler_calls"] = len(COMPILER.findall(proc.stderr))
        for tool in ("npm", "go"):
            fixture.verify_output(tool, work, env)
        require((record["compiler_or_assembler_calls"] == 0) == (state == "warm"), "Unexpected Go compile work")
        paths = fixture.payloads(cache)
        observed = [(p.stat().st_dev, p.stat().st_ino) for p in paths]
        require(ids is None or observed == ids, "Warm install duplicated fixture payloads")
        ids = observed
        record["after"] = snapshot(cache)
        record["lock_sha256"] = hashlib.sha256(lockfile.read_bytes()).hexdigest()
    require(result["cold"]["lock_sha256"] == result["warm"]["lock_sha256"], "npm lockfile changed")
    require(result["cold"]["after"] == result["warm"]["after"], "Warm cache footprint grew")
    # Both origins are gone. An empty independent store must now fail for each tool.
    empty = fixture.environment(stores(root/"empty"), seed=False)
    work = fixture.workspace("empty-control")
    (work/"package-lock.json").write_bytes(lockfile.read_bytes())
    for name, argv in (("npm", fixture.argv("npm")), ("go", fixture.argv("go"))):
        proc, _ = command(argv, work, empty, check=False)
        require(proc.returncode != 0 and any(s in proc.stderr for s in
                (("ENOENT", "ENOTCACHED") if name=="npm" else ("GOPROXY=off",))), f"{name} empty control was inconclusive")
    result.update(passed=True, verified_warm_reuses={"npm": 1, "go_module": 1, "go_build_without_compile": 1})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rounds", type=int, default=7, choices=range(1,51))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--database", type=Path, required=True)
    args = parser.parse_args()
    data = dict(run=uuid.uuid4().hex, started_utc=datetime.now(timezone.utc).isoformat(timespec="seconds"),
                host=platform.platform(), profile="local-package-command", ci_queue_s=None, clients=1,
                requested_rounds=args.rounds, results=[], limits={"GOMAXPROCS":1, "go_build_parallelism":1})
    with tempfile.TemporaryDirectory(prefix="mp-local-caches-") as directory:
        root = Path(directory)
        for i in range(args.rounds):
            sample = {"round":i+1, "passed":False}
            data["results"].append(sample)
            try:
                subdir = root/str(i)
                subdir.mkdir()
                run_round(subdir, sample)
            except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
                sample["error"] = str(exc)
                break
            finally:
                # Go caches can leave read-only directories. Own only this temporary round.
                for p in subdir.rglob("*"):
                    if p.is_dir(): p.chmod(0o700)
                shutil.rmtree(subdir)
    data["first_attempt_failures"] = sum(not v["passed"] for v in data["results"])
    data["passed"] = len(data["results"]) == args.rounds and data["first_attempt_failures"] == 0
    data["summary"] = {s:{cmd:distribution([r[s]["commands"][cmd]["seconds"] for r in data["results"] if r["passed"]])
                        for cmd in ("npm_ci","go_mod_download","go_build")} for s in ("cold","warm")}
    data["versions"] = {key:subprocess.check_output(argv,text=True).strip() for key,argv in
                        (("go",["go","version"]),("node",["node","--version"]),("npm",["npm","--version"]))}
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(data,indent=2)+"\n")
    store(args.database,data["run"],"package-command-profile",data)
    print(json.dumps({"passed":data["passed"],"first_attempt_failures":data["first_attempt_failures"],"summary":data["summary"]}))
    return 0 if data["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
