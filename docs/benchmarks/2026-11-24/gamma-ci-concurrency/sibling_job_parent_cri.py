"""Corroborate native worker cgroup membership against its recorded CRI lifecycle."""

import argparse
from collections import defaultdict
from datetime import UTC, datetime
from hashlib import sha256
import json
from pathlib import Path
import re


ID = r"[a-f0-9]{64}"
TIME = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?Z")
LOG = re.compile(r'^time="([^"]+)" level=info msg=("(?:[^"\\]|\\.)*")')
LEAF = re.compile(rf"/k8s\.io/(?:micropod-job-{ID}/)?({ID})")
PATTERNS = {name: re.compile(message) for name, message in {
    "sandbox": rf'RunPodSandbox for name:"mp-(?P<owner>[a-f0-9]{{32}})"\s+uid:"(?P=owner)"\s+'
               rf'namespace:"micropod-ci" returns sandbox id "(?P<id>{ID})"',
    "create": rf'CreateContainer within sandbox "(?P<id>{ID})" for container name:"job"',
    "created": rf'CreateContainer within sandbox "(?P<sandbox>{ID})" for name:"job" returns container id "(?P<id>{ID})"',
    "start": rf'StartContainer for "(?P<id>{ID})"',
    "started": rf'StartContainer for "(?P<id>{ID})" returns successfully',
    "stop": rf'StopContainer for "(?P<id>{ID})" with timeout \d+ \(s\)',
    "stopped": rf'StopContainer for "(?P<id>{ID})" returns successfully',
    "exit": rf'received container exit event container_id:"(?P<id>{ID})"\s+id:"(?P=id)"\s+pid:(?P<pid>\d+)'
            r'(?:\s+exit_status:(?P<code>\d+))?\s+exited_at:\{seconds:(?P<seconds>\d+)(?:\s+nanos:(?P<nanos>\d+))?\}',
    "stop_sandbox": rf'StopPodSandbox for "(?P<id>{ID})"',
    "sandbox_stopped": rf'StopPodSandbox for "(?P<id>{ID})" returns successfully',
    "remove_sandbox": rf'RemovePodSandbox for "(?P<id>{ID})"',
    "sandbox_removed": rf'RemovePodSandbox "(?P<id>{ID})" returns successfully',
}.items()}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def timestamp(value):
    match = TIME.fullmatch(value)
    require(match is not None, f"invalid native guest timestamp {value!r}")
    epoch = int(datetime.fromisoformat(match[1]).replace(tzinfo=UTC).timestamp())
    return epoch * 10**9 + int((match[2] or "").ljust(9, "0"))


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def event_index(log):
    events = defaultdict(list)
    for line in log.decode().splitlines():
        message = LOG.match(line)
        if message is None:
            continue
        text = json.loads(message[2])
        for kind, pattern in PATTERNS.items():
            match = pattern.fullmatch(text)
            if match:
                events[kind, match["id"]].append({"time": message[1], **match.groupdict()})
                break
    return events


def observed_memberships(folder, boot, jobs):
    if (folder / "job-parent-before.json").is_file():
        states = [read(folder, f"job-parent-{phase}.json")["arms"]["A"] for phase in ("before", "after")]
        expected = [{"Id": j["id"], "Name": "/" + j["name"], "Running": True,
                     "StartedAt": j["docker_inspect"]["State"]["StartedAt"]} for j in jobs]
        require(all(state["starts"] == expected for state in states), "measured Docker generation changed")
        trees = [state["worker"] for state in states]
    else:
        expected = [{"id": j["id"], "running": True, "started": j["docker_inspect"]["State"]["StartedAt"]}
                    for j in jobs]
        require(read(folder, "cgroup-hierarchy-starts.json") == expected, "measured Docker generation changed")
        trees = [read(folder, "cgroup-hierarchy-tree.json")]
    require(all(tree["boot"] == boot and all(row["id"] == cid for cid, row in tree["memberships"].items())
                for tree in trees), "hierarchy rows do not belong to the archived native worker")
    members = [{cid: (row["path"], row["resident"]["pid"]) for cid, row in tree["memberships"].items()}
               for tree in trees]
    require(all(current == members[0] for current in members), "measured native leaves or resident PIDs changed")
    return members[0]


def verify(folder, native_paths=None):
    """Return the recorded startup and teardown timestamps for each measured native leaf."""
    folder = Path(folder)
    require(read(folder, "status.json").get("complete") is True, "native worker archive did not complete")
    boot, = re.findall(r"(?m)^boot=([a-f0-9-]+)$", (folder / "a/guest-facts.txt").read_text())
    inventory = read(folder, "grouped-inventory.json")
    jobs = inventory["A"]["jobs"]
    ids = {j["id"] for j in jobs}
    require(len(jobs) == len(ids) == 64 and all(re.fullmatch(ID, cid) for cid in ids),
            "expected 64 distinct native Docker IDs")
    archived = observed_memberships(folder, boot, jobs)
    require(archived.keys() == ids and len({pid for path, pid in archived.values()}) == 64
            and (native_paths is None or native_paths == {cid: path for cid, (path, pid) in archived.items()}),
            "inspected Docker and worker leaf coverage disagree")
    raw = (folder / "a/service.stderr").read_bytes()
    events = event_index(raw)
    public_ids = {job["id"] for arm in inventory.values() for job in arm["jobs"]}
    sandbox_ids = {id_ for kind, id_ in events if kind in ("sandbox", "create")}

    def one(kind, id_):
        entries = events[kind, id_]
        require(len(entries) == 1, f"expected one CRI {kind} event for {id_}, found {len(entries)}")
        return entries[0]

    result, runtime_ids, used_sandboxes = [], set(), set()
    for job in jobs:
        cid = job["id"]
        path, pid = archived[cid]
        match = LEAF.fullmatch(path)
        require(match is not None, f"unexpected native OCI path {path}")
        rid = match[1]
        require(rid not in public_ids | sandbox_ids | runtime_ids, f"non-unique or incorrect runtime ID {rid}")
        create = one("created", rid)
        sandbox = create["sandbox"]
        require(sandbox not in used_sandboxes | public_ids, f"unexpected sandbox reuse for {job['name']}")
        row = job["docker_inspect"]
        require(row["Id"] == cid and row["State"]["Running"] is True, "wrong inspected container")
        exit_event = one("exit", rid)
        require(int(exit_event["pid"]) == pid > 0, f"CRI exit PID differs from the live resident for {job['name']}")
        nanos = int(exit_event["nanos"] or 0)
        require(0 <= nanos < 10**9, "invalid CRI task exit nanoseconds")
        exit_ns = int(exit_event["seconds"]) * 10**9 + nanos
        times = {"sandbox_ready": one("sandbox", sandbox)["time"], "create_request": one("create", sandbox)["time"],
                 "created": create["time"], "start_request": one("start", rid)["time"],
                 "started": one("started", rid)["time"], "docker_started": row["State"]["StartedAt"],
                 "stop_request": one("stop", rid)["time"], "stopped": one("stopped", rid)["time"],
                 "exit_observed": exit_event["time"],
                 "sandbox_stop_request": one("stop_sandbox", sandbox)["time"],
                 "sandbox_stopped": one("sandbox_stopped", sandbox)["time"],
                 "sandbox_remove_request": one("remove_sandbox", sandbox)["time"],
                 "sandbox_removed": one("sandbox_removed", sandbox)["time"]}
        ns = {name: timestamp(value) for name, value in times.items()}
        require(ns["sandbox_ready"] <= ns["create_request"] <= ns["created"] <= ns["start_request"] <= ns["started"]
                <= ns["docker_started"] < ns["stop_request"] <= ns["stopped"] <= ns["sandbox_removed"]
                and ns["stop_request"] <= exit_ns <= ns["exit_observed"] <= ns["sandbox_removed"]
                and timestamp(row["Created"]) <= ns["create_request"] and
                ns["stop_request"] <= ns["sandbox_stop_request"] <= ns["sandbox_stopped"]
                <= ns["sandbox_remove_request"] <= ns["sandbox_removed"],
                f"CRI or Docker lifecycle is out of order for {job['name']}")
        runtime_ids.add(rid)
        used_sandboxes.add(sandbox)
        result.append({"docker_id": cid, "runtime_id": rid, "sandbox_id": sandbox, "path": path,
                       "task_pid": pid, "exit_code": int(exit_event["code"] or 0), "exit_unix_ns": exit_ns, **times})
    return {"boot": boot, "service_log_sha256": sha256(raw).hexdigest(),
            "verified_starts": len(result), "verified_sandbox_removals": len(result), "containers": result}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    print(json.dumps(verify(parser.parse_args().folder), indent=2))
