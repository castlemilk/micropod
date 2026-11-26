"""Verify a short fair slice on paced Micropod HTTP clients at a coarse worker base slice."""

import hashlib
import shutil
from pathlib import Path

import sibling_build
from qualify import require


TARGET = "native-clients"
SLICE_US = (0, 250)
INTERMEDIATE_SLICE_US = (500, 750)
ALLOWED_SLICE_US = SLICE_US + INTERMEDIATE_SLICE_US
BASE_NS = 2_100_000
PROBE_SHA256 = "5635d4bcae1b780d2a3cdf9523231300f843657d099d74044d98d217cf21bda2"
DRIVER = "sibling-client-slice.py"

# Keep the pinned pacer's transport, arrival loop and clock calibration intact.
# Bind its already locked measurement to an observed TID before the ready gate.
PACE_FIELD = b'\tTimerSlackNS       int64          `json:"timer_slack_ns,omitempty"`\n'
ISSUING_FIELD = b'\tIssuingTID         int            `json:"issuing_tid,omitempty"`\n'
THREAD_PROBE = b'\t\tif gate.threadProbe != "" {\n'
ISSUING_PROOF = b'''\t\tif result.Pace != nil && runtime.GOOS == "linux" {
\t\t\truntime.LockOSThread()
\t\t\tdefer runtime.UnlockOSThread()
\t\t\tthread, err := os.Readlink("/proc/thread-self")
\t\t\tif err != nil {
\t\t\t\tw.Error = fmt.Sprintf("read paced issuing thread: %v", err)
\t\t\t\treturn result
\t\t\t}
\t\t\tname, ok := strings.CutPrefix(thread, strconv.Itoa(os.Getpid())+"/task/")
\t\t\ttid, err := strconv.Atoi(name)
\t\t\tif !ok || err != nil || tid <= 0 {
\t\t\t\tw.Error = fmt.Sprintf("invalid paced issuing thread: %q", thread)
\t\t\t\treturn result
\t\t\t}
\t\t\tresult.Pace.IssuingTID = tid
\t\t}
'''


def rewrite_probe(source, *, restore=False):
    for original, observed in ((PACE_FIELD, PACE_FIELD + ISSUING_FIELD), (THREAD_PROBE, ISSUING_PROOF + THREAD_PROBE)):
        before, after = (observed, original) if restore else (original, observed)
        require(source.count(before) == 1, "paced issuing-thread source marker differs")
        source = source.replace(before, after, 1)
    return source


def stage(source, target, folder):
    original = source.read_bytes()
    require(hashlib.sha256(original).hexdigest() == PROBE_SHA256, "client slice needs the pinned paced HTTP source")
    target.write_bytes(rewrite_probe(original))
    archived = folder / DRIVER
    shutil.copyfile(__file__, archived)
    return {"client_slice_driver_sha256": hashlib.sha256(archived.read_bytes()).hexdigest()}


def check_probe(folder, plan):
    source = (folder / "quiet-http.go").read_bytes()
    require(hashlib.sha256(source).hexdigest() == plan["quiet_source_sha256"] and
            hashlib.sha256(rewrite_probe(source, restore=True)).hexdigest() == PROBE_SHA256 and
            hashlib.sha256((folder / DRIVER).read_bytes()).hexdigest() == plan["client_slice_driver_sha256"],
            "client slice observer differs from its pinned sources")


def check_plan(plan):
    require(plan.get("slice_target") == TARGET and type(plan.get("fair_slice_us")) is int
            and plan["fair_slice_us"] in ALLOWED_SLICE_US and plan["worker_scheduler"] == "hrtick"
            and plan.get("worker_next_buddy") is True and plan.get("guest_fair", "inherit") == "inherit"
            and plan.get("offered_rps") and plan["dense_ms"] == 1500 and plan["healthy_pairs"] == 32
            and plan.get("cpu_groups") is True and plan["builders"] == 8
            and type(plan.get("build_nice")) is int and plan["build_nice"] == 0
            and plan["build_policy"] == "normal" and plan.get("build_slice_us") is None,
            "native client slices require paired offers, ordinary builders and the coarse HRTICK/NEXT_BUDDY profile")


def check_scheduler(receipt):
    features = {"HRTICK", "NEXT_BUDDY", "PICK_BUDDY", "RUN_TO_PARITY", "PREEMPT_SHORT", "WAKEUP_PREEMPTION"}
    require(receipt["base_slice_ns"] == BASE_NS and receipt["before"] == receipt["after"]
            and features.issubset(receipt["after"]), "native client slices require the inherited 2.1 ms wakeup profile")


def requested_ns(arm, slice_ns):
    return slice_ns if arm == "A" else 0


def check_service(job):
    pid = job["server_pid"]
    require(job["requested_slice_ns"] == 0 and pid == job["affinity"]["pid"],
            f"unexpected service or holder slice request in {job['name']}")
    threads = job["http_policy_threads"]
    sibling_build.check_http_policy(threads, pid, job["mask"])
    slice_threads = job["threads"]
    require(slice_threads and all(row["slice_ns"] == BASE_NS for row in threads + slice_threads),
            f"service or holder in {job['name']} did not keep its {BASE_NS} ns slice")


def check_client(receipt, job, arm, slice_ns, *, paced):
    requested = requested_ns(arm, slice_ns)
    require(job["client_slice_ns"] == requested, f"wrong client slice request in {job['name']}")
    window = receipt.get("window") or {}
    threads = window.get("threads")
    require(threads, f"missing client scheduling readback in {job['name']}: {window.get('error', '')}")
    sibling_build.check_http_policy(threads, window["pid"], job["mask"])
    effective = requested or BASE_NS
    require(all(row["slice_ns"] == effective for row in threads),
            f"client in {job['name']} did not receive its {effective} ns slice")
    if paced:
        tid = (receipt.get("pace") or {}).get("issuing_tid")
        require(type(tid) is int and any(row["tid"] == tid for row in threads),
                f"issuing thread lacks matching scheduling readback in {job['name']}")


def check_builds(rows):
    for slot, row in enumerate(rows):
        proof = row["policy"]
        require(proof["dispatcher"]["slice_ns"] == proof["child"]["slice_ns"] == BASE_NS,
                f"build slot {slot} did not keep its {BASE_NS} ns dispatcher and child slice")
