"""Replay #230.11's historical Darwin ACK trials with a fixed receive-window request."""
import argparse
import hashlib
import json
import math
import plistlib
from pathlib import Path
from statistics import median

from gamma_contrasts import IMAGE, ROOT, VM, clean_client, read_receipt

STOCK = "fix-window-512"
ACK = "fix-ack-512"
ARCHIVE_SHA = "066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4"
FIXTURE_SHA = "733991064cd7dc4556739d5092f72bd7fdf6be5d4594d645ee3e25800a242e45"
FIXTURE = ROOT / "docs/benchmarks/2026-11-24/darwin-ack-fixture.json.gz"
BASE_REV = "b30c57f8c97d112fb57dfd5588b6e8da9601e583"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def classify(client):
    errors = client["errors"] or []
    id_errors = sum('/id"' in e for e in errors)
    body_errors = sum('/data"' in e or e.startswith("stream ") for e in errors)
    assert id_errors + body_errors == len(errors)
    # Only the warm-up and fresh GETs use /id. A positive scored byte
    # count for every stream proves all 32 warm-up identities succeeded.
    if id_errors:
        assert all(x > 0 for x in client["per_stream_bytes"])
    assert len(client["per_stream_bytes"]) == client["streams"] == 32
    assert sum(client["per_stream_bytes"]) == client["bytes"]
    assert client["arrivals"] == 240 and client["period_us"] == 25000
    assert math.isclose(client["bytes"] / (1 << 20) / client["window_s"], client["mib_s"])
    clean = clean_client(client)
    return dict(delivery_clean=clean, guardrail_pass=clean and client["fresh_p95_us"] <= 75000,
                offered=240, fresh_failed=id_errors, bulk_errors=body_errors,
                reopens=client["reopened"], progressing_streams=sum(x > 0 for x in client["per_stream_bytes"]),
                mib_s=client["mib_s"], window_s=client["window_s"], scored_bytes=client["bytes"],
                fresh_p95_ms=client["fresh_p95_us"]/1000, fresh_p99_ms=client["fresh_p99_us"]/1000)


def run(owner):
    archive = read_receipt(VM, ARCHIVE_SHA)
    files = read_receipt(FIXTURE, FIXTURE_SHA)
    assert BASE_REV.startswith(archive["baseline_commit"])
    assert "TCP_SENDMOREACKS" not in files["build-window.py"]
    assert "setsockopt(fd, IPPROTO_TCP, TCP_SENDMOREACKS, &ack, sizeof(ack)) < 0 || (window && setsockopt" in files["ack-trials.sh"]
    assert "setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &window, sizeof(window)) < 0" in files["build-window.py"]
    if owner:
        for name, content in files.items():
            assert (owner/name).read_bytes() == content.encode(), name
        assert sha((owner/"fixed").read_bytes()) == archive["binaries"]["client"]
        assert (owner/"screen.py").read_text() == archive["sources"]["screen.py"]
    phase = archive["phases"]["ack-trials"]
    orders = [o.split() for o in phase["orders"]]
    assert len(orders) == 5 and all(sorted(o) == sorted([STOCK, ACK, "fix-ack-768"]) for o in orders)
    reports, scopes, environments = {}, {}, []
    for arm, binary_dir in [(STOCK, "window-pack"), (ACK, "ack-pack")]:
        assert set(phase["runs"][arm]) == {str(i+1) for i in range(len(orders))}
        scope = archive["scopes"][arm]
        job = plistlib.loads(files[f"data/{arm}/job.plist"].encode())
        env = job["EnvironmentVariables"].copy()
        assert Path(env.pop("MICROPOD_CI_HOME")).name == arm
        environments.append(env)
        assert job["ProcessType"] == "Interactive" and "spawn type = interactive" in scope["role"]
        assert scope["image"] == IMAGE and scope["controller"] == "reno" and scope["proven"]
        assert env["MP_QA_TCP_RCVBUF"] == "524288"
        assert job["ProgramArguments"][1:] == ["ci", "serve"]
        assert Path(job["ProgramArguments"][0]).parent.name == binary_dir
        assert env["MICROPOD_CI_CPUS"] == "4" and env["MICROPOD_CI_MEMORY_MIB"] == "4096"
        assert scope["state"]["cpu.max"] == "400000 100000" and scope["state"]["cpuset.cpus.effective"] == "0-3"
        assert scope["state"]["release"] == "7.3.5-micropod" and scope["boot.json"]["cpus"] == 4
        if owner:
            assert sha((owner/binary_dir/"micropod").read_bytes()) == scope["host_sha256"]
        scopes[arm] = dict(host_sha256=scope["host_sha256"], boot=scope["boot.json"]["boot"])
        rows = []
        for number, order in enumerate(orders, 1):
            record = phase["runs"][arm][str(number)]
            client = record["client"]
            if owner:
                data = owner/"data/ack-trials"
                assert (data/f"{number}.order").read_text().split() == order
                assert (data/f"{number}-{arm}.done").is_file()
                assert json.loads((data/f"{number}-{arm}.json").read_bytes()) == client
            row = classify(client)
            assert row["delivery_clean"] == record["clean"]
            rows.append(dict(round=number, position=order.index(arm)+1, **row))
        clean_rows = [r for r in rows if r["guardrail_pass"]]
        reports[arm] = dict(attempts=rows, attempted=len(rows), qualifying=len(clean_rows),
                            offered=sum(r["offered"] for r in rows),
                            fresh_failed=sum(r["fresh_failed"] for r in rows),
                            bulk_errors=sum(r["bulk_errors"] for r in rows),
                            reopens=sum(r["reopens"] for r in rows),
                            clean_median_p95_ms=median(r["fresh_p95_ms"] for r in clean_rows),
                            clean_median_p99_ms=median(r["fresh_p99_ms"] for r in clean_rows))
    assert environments[0] == environments[1]
    assert scopes[STOCK]["boot"] != scopes[ACK]["boot"]
    paired = []
    for s, a in zip(reports[STOCK]["attempts"], reports[ACK]["attempts"]):
        if s["guardrail_pass"] and a["guardrail_pass"]:
            paired.append(dict(round=s["round"], candidate_first=a["position"] < s["position"],
                               rate_change_pct=100*(a["mib_s"]/s["mib_s"]-1),
                               fresh_p95_change_ms=a["fresh_p95_ms"]-s["fresh_p95_ms"],
                               fresh_p99_change_ms=a["fresh_p99_ms"]-s["fresh_p99_ms"]))
    return dict(date="2026-11-24", direction="230.11", tier="archived VM; offline replay",
                archive=VM.name, archive_sha256=ARCHIVE_SHA, archive_source=BASE_REV,
                replay_base="2ccda8507355b8220258db2ce8160f3113d3e1ff",
                fixture=FIXTURE.name, fixture_sha256=FIXTURE_SHA,
                source_sha256={name:sha(contents.encode()) for name,contents in files.items()},
                workload="32 ongoing 8-MiB downloads, 240 fresh identity GETs at 25 ms over 6 s",
                control="Darwin guest-facing TCP socket requests SO_RCVBUF=524288",
                candidate="Same receive-window request, additionally sets TCP_SENDMOREACKS=1 before connect",
                scopes=scopes, orders=orders, arms=reports, jointly_qualifying=paired,
                guardrail="Zero errors, zero reopens, all 32 streams deliver and fresh p95 <=75 ms",
                caveats=["Separate VM boots per arm. Third 768-KiB arm interleaved and excluded.",
                         "Socket option requested and fail-on-error. No wire ACK count or effective SO_RCVBUF readback.",
                         "Failed fresh requests occupy zero latency slots in the archived client; dirty percentiles are diagnostic only.",
                         "No per-attempt NIC drop counters or individual fresh timings. Two eligible pairs cannot establish repeatability."],
                verdict="Do not advance. Extra ACKs missed the delivery guardrail twice, including a zero-byte window.",
                next_check="Require a delivery-clean production-path control before testing supported ACK cadence with packet-level readback.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner-root", type=Path, help="Additionally cross-check original local binaries, launch files and raw client receipts")
    args = parser.parse_args()
    print(json.dumps(run(args.owner_root), indent=2))
