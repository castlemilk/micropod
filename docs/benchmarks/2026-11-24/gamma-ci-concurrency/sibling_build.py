"""Run eight verified CI builds inside the dependency clients during a socket wave."""
import json
import re
import shutil
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from qualify import CONFIG, IMAGE, LABEL, ROOT, ci_image_identity, cli, fanout, peer, require, terminal
from sibling_group import check_threads


DISPATCH = """set -eu
gate=$1
revision=$2
slot=$3
nice_value=$(awk '{print $19}' "/proc/$$/stat")
[ "$nice_value" = "$4" ]
printf ready > "/gate/$gate.go.$slot.ready"
i=0
while [ ! -f "/gate/$gate.go" ]; do
    i=$((i+1))
    [ "$i" -lt 1000 ] || exit 75
    sleep .02
done
date +%s%N > "/gate/$gate.go.$slot.tmp"
mv "/gate/$gate.go.$slot.tmp" "/gate/$gate.go.$slot.start"
sh /mpcheck/job.sh "$revision-a"
sh /mpcheck/job.sh "$revision-b"
echo "end $(date +%s%N) $nice_value"
"""

BUILD_POLICIES = {"normal": 0, "batch": 3}
BUILD_SLICES = (0, 250)
POLICY_PROBE = "/mpcheck/build-policy"
POLICY_SOURCE = "sibling_build_policy_linux.go"
POLICY_DISPATCH_FILE = "go-dispatch-policy.sh"
POLICY_DISPATCH = DISPATCH.replace(
    'printf ready > "/gate/$gate.go.$slot.ready"',
    '''policy_file="/gate/$gate.go.$slot.policy"
/mpcheck/build-policy -dispatcher "$$" > "$policy_file.tmp"
mv "$policy_file.tmp" "$policy_file"
printf ready > "/gate/$gate.go.$slot.ready"''',
    1,
)
AFFINITY_DISPATCH_FILE = "go-dispatch-affinity.sh"
AFFINITY_DISPATCH = POLICY_DISPATCH.replace(
    'date +%s%N > "/gate/$gate.go.$slot.tmp"',
    '[ ! -f "/gate/$gate.go.abort" ] || exit 75\ndate +%s%N > "/gate/$gate.go.$slot.tmp"',
    1,
)


def compiler_mask(job, mode):
    require(mode in ("home", "pool") and job["mask"] == "0-3" and job["home_cpu"] in ("0", "1", "2", "3"),
            "compiler needs the verified broad builder cgroup and a home CPU")
    return job["mask"] if mode == "pool" else job["home_cpu"]


def check_http_policy(threads, pid, mask):
    check_threads(threads, pid, mask)
    require(all(t["policy"] == BUILD_POLICIES["normal"] and t["nice"] == t["priority"] == 0
                and t["slice_ns"] > 0 for t in threads), "HTTP process lost ordinary scheduling")


def inherited_http_slice(builds, jobs, http):
    inherited = {row["policy"]["slice"]["inherited_ns"] for row in builds}
    services = {t["slice_ns"] for job in jobs for t in job["http_policy_threads"]}
    clients = {t["slice_ns"] for row in http for t in row["receipt"]["window"]["threads"]}
    require(len(inherited) == 1 and services == clients == inherited, "HTTP or inherited build slice changed")
    return inherited.pop()


def check_slice_option(build_policy, build_slice_us):
    require(build_slice_us is None or (build_policy == "normal" and type(build_slice_us) is int
                                       and build_slice_us in BUILD_SLICES),
            "build slice must be 0 or 250 microseconds with verified normal scheduling")


def check_dispatch_policy(proof, policy, nice_value, mask, *, build_slice_us=None, slot=None):
    where = "build" if slot is None else f"build slot {slot}"
    require(isinstance(proof, dict), f"{where} lacks dispatcher and child policy evidence")
    dispatcher, child = proof["dispatcher"], proof["child"]
    require(dispatcher["tid"] == proof["child_parent_pid"] > 0 and child["tid"] > 0
            and child["tid"] != dispatcher["tid"], f"{where} policy probe was not an ordinary child of the dispatcher")
    require(all(row["policy"] == BUILD_POLICIES[policy] and row["nice"] == nice_value and row["priority"] == 0
                and row["cpus_allowed_list"] == mask for row in (dispatcher, child))
            and dispatcher["slice_ns"] == child["slice_ns"] > 0,
            f"{where} dispatcher or child did not inherit {policy} scheduling, nice {nice_value}, CPUs {mask}: {proof}")
    if build_slice_us is None:
        require("slice" not in proof, f"{where} recorded an unrequested build slice")
        return
    slice_proof = proof.get("slice")
    require(isinstance(slice_proof, dict) and type(slice_proof.get("requested_us")) is int
            and slice_proof["requested_us"] == build_slice_us and type(slice_proof.get("inherited_ns")) is int
            and slice_proof["inherited_ns"] > 0 and slice_proof.get("dispatcher_pid") == dispatcher["tid"],
            f"{where} lacks the dispatcher slice evidence for {build_slice_us} microseconds: {proof}")
    expected_ns = slice_proof["inherited_ns"] if build_slice_us == 0 else build_slice_us * 1000
    require(dispatcher["slice_ns"] == expected_ns,
            f"{where} dispatcher and child need slice {expected_ns} ns, observed {dispatcher['slice_ns']} ns")


def stage(folder, runner, work, engine, archive, *, build_policy=None, build_slice_us=None, env=None):
    check_slice_option(build_policy, build_slice_us)
    require(build_policy is None or build_policy in BUILD_POLICIES and env is not None, "invalid build policy setup")
    if not archive:
        archive = runner.root / "go.tar"
        cli(peer.DOCKER, "image", "save", "-o", archive, IMAGE, timeout=240)
    expected = ci_image_identity(archive)
    runner.waited([*engine, "load", "-i", archive], "go-image", 360)
    images = {}
    for arm, docker in (("A", engine), ("B", peer.DOCKER)):
        img, = json.loads(cli(docker, "image", "inspect", IMAGE))
        require(img["Id"] == ("sha256:" + CONFIG if arm == "A" else expected["manifest_id"])
                and img["Architecture"] == "arm64" and img["Os"] == "linux"
                and ("RootFS" not in img or img["RootFS"]["Layers"] == expected["layer_ids"]), "unexpected Go image")
        images[arm] = img
    terminal.save(folder / "go-image.json", {"expected": expected, "inspected": images})
    for name, source in (("job.sh", fanout.JOB), ("go-dispatch.sh", DISPATCH)):
        (work / "probe" / name).write_text(source)
        (folder / name).write_text(source)
    if build_policy is None:
        return {}
    source = Path(__file__).with_name(POLICY_SOURCE)
    archived = folder / POLICY_SOURCE
    shutil.copy2(source, archived)
    binary = work / "probe" / Path(POLICY_PROBE).name
    terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false", "-o", binary,
                    archived, env={**env, "GOPROXY": "off"})
    (work / "probe" / POLICY_DISPATCH_FILE).write_text(POLICY_DISPATCH)
    dispatch = folder / POLICY_DISPATCH_FILE
    dispatch.write_text(POLICY_DISPATCH)
    fields = {"build_policy": build_policy, "build_policy_source_sha256": terminal.digest(archived),
              "build_policy_probe_sha256": terminal.digest(binary), "build_policy_dispatch_sha256": terminal.digest(dispatch)}
    if build_slice_us is not None:
        fields["build_slice_us"] = build_slice_us
    return fields


def volume(cohort, create):
    name = cohort.network + "-go"
    if create:
        require(name not in cohort.cmd("volume", "ls", "-q").splitlines(), "Go cache name collision")
        require(cohort.cmd("volume", "create", "--label", f"{LABEL}={cohort.owner}", name) == name,
                "could not create private Go cache")
    elif name in cohort.cmd("volume", "ls", "-q").splitlines():
        v, = json.loads(cohort.cmd("volume", "inspect", name))
        require(v["Name"] == name and v["Labels"].get(LABEL) == cohort.owner, "ambiguous Go volume ownership")
        cohort.cmd("volume", "rm", name)
        require(name not in cohort.cmd("volume", "ls", "-q").splitlines(), "Go volume remains")


def options(cohort, name):
    return ["--mount", f"type=volume,src={cohort.network}-go,dst=/cache,volume-nocopy",
            "-e", "GOFLAGS=-trimpath -p=1", "-e", "GOMODCACHE=/cache/mod", "-e", "GOCACHE=/cache/build",
            "-e", f"MP_RAW_ID={name}"]


def check_revision(line, revision, name):
    r = fanout.parse_job(line, 0)
    require(r["revision"] == revision and r["container"] == name and r["tests"] == 8 and r["cpu_s"] > 0
            and min(r[k] for k in ("compile", "vet", "link")) > 0 and re.fullmatch("[a-f0-9]{64}", r["product"]),
            f"unverified build of {revision} in {name}")
    return r


def prime(cohort):
    client = cohort.jobs[cohort.count]
    prefix = ["taskset", "-c", client["home_cpu"]] if getattr(cohort, "compiler_affinity", None) else []
    out = cohort.cmd("exec", client["id"], *prefix, "sh", "/mpcheck/job.sh", "sib-prime", timeout=220)
    check_revision(out, "sib-prime", client["name"])
    return out


def await_marks(paths, futures):
    until = time.monotonic() + 20
    while not all(p.is_file() and p.stat().st_size > 0 for p in paths):
        for i, f in enumerate(futures):
            if f.done():
                raise ValueError(f"build slot {i} exited before all jobs reached their gate: {f.result()}")
        require(time.monotonic() < until, "timed out synchronizing CI builds")
        time.sleep(.008)


class BuildWave:
    def __init__(self, cohort, tag, block, folder, *, build_policy=None, build_slice_us=None):
        check_slice_option(build_policy, build_slice_us)
        self.cohort, self.tag, self.block = cohort, tag, block
        self.build_policy = build_policy
        self.build_slice_us = build_slice_us
        self.compiler_affinity = getattr(cohort, "compiler_affinity", None)
        self.released = False
        self.base = cohort.work / "gate"
        self.output = folder / (tag + "-go.json")
        self.pool = ThreadPoolExecutor(max_workers=cohort.builders)
        self.futures = []

    def run(self, i):
        job = self.cohort.jobs[self.cohort.count + i]
        rev = f"sibling-{self.block}-{i}"
        dispatcher = ["sh", "/mpcheck/go-dispatch.sh"]
        if self.build_policy is not None:
            dispatcher = [POLICY_PROBE, "-policy", self.build_policy]
            if self.build_slice_us is not None:
                dispatcher.extend(("-build-slice-us", self.build_slice_us))
            dispatcher.extend(("/bin/sh", "/mpcheck/" + POLICY_DISPATCH_FILE))
        if self.compiler_affinity:
            dispatcher = ["taskset", "-c", compiler_mask(job, self.compiler_affinity),
                          "/bin/sh", "/mpcheck/" + AFFINITY_DISPATCH_FILE]
        argv = ["exec", job["id"], "nice", "-n", self.cohort.build_nice,
                *dispatcher, self.tag, rev, i, self.cohort.build_nice]
        result = terminal.invoke(*self.cohort.engine, *argv, timeout=120, check=False)
        row = {"id": job["id"], "revision": rev, "code": result.returncode, "stdout": result.stdout,
               "stderr": result.stderr[-1500:]}
        if self.compiler_affinity:
            row["exec_argv"] = argv
        return row

    def start(self):
        require(self.build_policy is None or self.build_policy in BUILD_POLICIES and self.cohort.builders == 8,
                "explicit build policy needs eight build slots")
        self.futures = [self.pool.submit(self.run, i) for i in range(self.cohort.builders)]
        await_marks([self.base / f"{self.tag}.go.{i}.ready" for i in range(len(self.futures))], self.futures)
        verify_policy = self.build_policy or ("normal" if self.compiler_affinity else None)
        if verify_policy is not None:
            self.policies = []
            for i in range(self.cohort.builders):
                client = self.cohort.jobs[self.cohort.count + i]
                try:
                    proof = json.loads((self.base / f"{self.tag}.go.{i}.policy").read_bytes())
                except (OSError, ValueError) as e:
                    raise ValueError(f"build slot {i} could not read dispatcher policy evidence") from e
                mask = compiler_mask(client, self.compiler_affinity) if self.compiler_affinity else client["mask"]
                check_dispatch_policy(proof, verify_policy, self.cohort.build_nice, mask,
                                      build_slice_us=self.build_slice_us, slot=i)
                self.policies.append(proof)
        (self.base / (self.tag + ".go")).touch(exist_ok=False)
        self.released = True
        paths = [self.base / f"{self.tag}.go.{i}.start" for i in range(len(self.futures))]
        await_marks(paths, self.futures)
        self.started = [int(p.read_text()) for p in paths]
        return max(self.started)

    def finish(self):
        rows = [f.result() for f in self.futures]
        self.pool.shutdown()
        for row, when in zip(rows, self.started):
            row["started_unix_ns"] = when
        field = "compiler_affinity" if self.compiler_affinity else ("policy" if self.build_policy is not None else None)
        if field:
            for row, proof in zip(rows, self.policies, strict=True):
                row[field] = proof
        terminal.save(self.output, rows)
        return rows

    def close(self):
        if self.compiler_affinity and not self.released:
            (self.base / (self.tag + ".go.abort")).touch(exist_ok=True)
        (self.base / (self.tag + ".go")).touch(exist_ok=True)
        self.pool.shutdown()


def score(rows, http, clients, block, nice_value, *, build_policy=None, build_slice_us=None):
    check_slice_option(build_policy, build_slice_us)
    start = min(r["receipt"]["window"]["started_unix_ns"] for r in http)
    end = max(r["receipt"]["window"]["finished_unix_ns"] for r in http)
    require(len(rows) == len(clients) and rows, "missing CI build slots")
    require(build_policy is None or build_policy in BUILD_POLICIES and len(rows) == 8,
            "explicit build policy needs eight verified build slots")
    finished, products, completions = [], [], []
    for i, (r, client) in enumerate(zip(rows, clients)):
        revision = f"sibling-{block}-{i}"
        require(r["code"] == 0 and r["revision"] == revision and r["id"] == client["id"],
                f"failed CI job in slot {i}: {r['stderr']} {r['stdout'][-300:]}")
        if build_policy is not None:
            check_dispatch_policy(r.get("policy"), build_policy, nice_value, client["mask"],
                                  build_slice_us=build_slice_us, slot=i)
        a, b, when = r["stdout"].strip().splitlines()
        label, ns, actual_nice = when.split()
        ns = int(ns)
        require(label == "end" and int(actual_nice) == nice_value and r["started_unix_ns"] <= start < end <= ns,
                "CI build priority differed or build did not cover the HTTP window")
        pair = [check_revision(line, revision + suffix, client["name"]) for line, suffix in ((a, "-a"), (b, "-b"))]
        require(pair[0]["product"] != pair[1]["product"], "successive build outputs match")
        products.extend(x["product"] for x in pair)
        completions.append((ns - r["started_unix_ns"]) / 1e9)
        finished.append(ns)
    require(len(set(products)) == len(products), "duplicate revision build outputs")
    result = {"jobs": len(rows), "revisions": len(products), "test_passes": len(products) * 8, "products": products,
              "makespan_s": (max(finished) - min(r["started_unix_ns"] for r in rows)) / 1e9,
              "slowest_job_s": max(completions), "http_covered_ns": end - start}
    if build_policy is not None:
        result["build_policy"] = build_policy
    if build_slice_us is not None:
        result["build_slice_us"] = build_slice_us
    return result
