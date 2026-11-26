"""Compare two independent relay experiments at fixed work on local Darwin socketpairs."""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import tempfile

from compare import C_SOURCE, HEADER, git, sha

HERE = Path(__file__).resolve().parent
BASE = "a3b561c6a97320d4ca9aff60885ae6393ccaa613"
POLICIES = {
    "handshake_ready_only": {
        "direction": "230.14", "change": "Deferred client read after successful async connect to its first level-triggered readiness event",
        "workload": "One staged connection on two Darwin AF_UNIX streams. Four-byte request before/after connect, with/without immediate client FIN, free/full guest buffer. Real kevent polling one event at a time.",
        "guardrails": "Each arm verifies all four request bytes and reverse reply marker across both FINs in all eight cases, including a full guest socket. Each flow retires. Address and undefined-behavior sanitizer reruns cover identical cases.",
        "verdict": "A late request saves one empty read. An already-buffered request needs an extra poll. Keep the speculative read unless first-request state in the revised workload justifies delaying handoff.",
        "limits": "No TCP handshake, process scheduling, throughput or latency measurement. Poll index is fixed work, not an elapsed duration. A production callback may poll more than once.",
    },
    "spare_suffix": {
        "direction": "230.07", "change": "Cache at most one drained, exact-size suffix allocation up to 64 KiB per serial data owner",
        "workload": "Real Darwin nonblocking AF_UNIX streams, deterministic full/partial writes, bidirectional content and FIN checks. One, alternating and simultaneous flows, revoked suffix and cache re-use.",
        "guardrails": "Payload compared byte for byte on every offer and both FINs verified. A failed malloc and a lease revocation with pending bytes each retire safely. Independent malloc/free instrumentation verifies no retained storage after destroying the owner. Sanitizer reruns cover the same cases.",
        "verdict": "Exact-size reuse reduces repeated allocator calls for matching backpressure episodes. It retains bounded idle memory and cannot reduce the number of copied bytes. Measure repeated suffix sizes per owner before selecting it for a VM screen.",
        "limits": "Fixed work, no elapsed time, CPU/GiB or latency measurement. Pressure is forced. Allocation count denotes malloc calls; libmalloc may recycle storage internally.",
    },
}


def replay(policy):
    fixture = HERE / (policy + ".c")
    patch = HERE / (policy + ".patch")
    for helper in ("filter_work.c", "compare.py"):
        if (HERE/helper).read_bytes() != git("show", f"{BASE}:scripts/relaybench/{helper}"):
            raise ValueError(f"fixture helper differs from pinned revision: {helper}")
    result = dict(date="2026-11-24", base=BASE, tier="host-only, untimed Darwin socketpair source fixture",
                  **POLICIES[policy], platform=platform.platform(),
                  compiler=subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
                  input_sha256={p.name: sha(p.read_bytes()) for p in (fixture, patch, HERE/"filter_work.c", HERE/"compare.py", Path(__file__))},
                  arms={})
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name in (C_SOURCE, HEADER):
            dst = root/name
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(git("show", f"{BASE}:{name}"))
        for arm in ("control", "candidate"):
            if arm == "candidate":
                subprocess.run(["patch", "-s", "-p1", "-i", patch], cwd=root, check=True)
            runs = {}
            for sanitized in (False, True):
                flags = ["-Wall", "-Wextra", "-Werror", "-O2", "-fblocks"]
                if sanitized:
                    flags.extend(["-fsanitize=address,undefined", "-fno-sanitize-recover=all"])
                cmd = ["clang", *flags, "-I", (root/HEADER).parent, "-I", (root/C_SOURCE).parent,
                       '-DRELAY_SOURCE="PublishedTCP.c"', fixture, "-o", root/"fixture"]
                subprocess.run(cmd, check=True)
                out = subprocess.check_output([root/"fixture"], text=True, timeout=10)
                runs["sanitized" if sanitized else "optimized"] = [json.loads(line) for line in out.splitlines()]
            if runs["optimized"] != runs["sanitized"]:
                raise ValueError(f"fixed work differs under sanitizers for {arm}")
            result["arms"][arm] = dict(c_sha256=sha((root/C_SOURCE).read_bytes()), header_sha256=sha((root/HEADER).read_bytes()),
                                       rows=runs["optimized"], sanitizer_rows_verified=len(runs["sanitized"]))
    validate(policy, result["arms"])
    return result


def validate(policy, arms):
    control, candidate = (arms[key]["rows"] for key in ("control", "candidate"))
    if policy == "handshake_ready_only":
        assert len(control) == len(candidate) == 8
        for a, b in zip(control, candidate, strict=True):
            for key in ("request_before_connect", "request_and_fin", "pressured"):
                assert a[key] == b[key]
            assert a["eagain_at_connect"] == 1 - a["request_before_connect"] and b["eagain_at_connect"] == 0
            assert a["client_reads_at_connect"] == 1 and b["client_reads_at_connect"] == 0
            assert b["delivery_poll"] - a["delivery_poll"] == a["request_before_connect"]
    else:
        assert len(control) == len(candidate) == 7
        for a, b in zip(control, candidate, strict=True):
            assert a["case"] == b["case"] and a["copied_bytes"] == b["copied_bytes"]
            assert a["allocations"] >= b["allocations"]
            assert a["delivered_bytes"] == b["delivered_bytes"] and a["offers"] == b["offers"] == 8
            assert a["retained_after_destroy"] == b["retained_after_destroy"] == 0
            assert a["retained_idle_bytes"] == 0 and b["retained_idle_bytes"] <= 65536
            if a["case"] == "serial_64k":
                assert b["allocations"] == 1 and b["retained_idle_bytes"] == 65536
            if a["case"] == "serial_96k":
                assert b["allocations"] == a["allocations"] == 8 and b["retained_idle_bytes"] == 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("policy", choices=POLICIES)
    print(json.dumps(replay(parser.parse_args().policy), indent=2))
