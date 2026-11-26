"""Replay the archived pair, including every raw callback, without sending traffic."""
import collections
import hashlib
import json
from pathlib import Path
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(folder):
    raw = folder / "raw.json"
    report = json.loads(raw.read_text())
    assert report["direction"] == "228.04" and report["build"]["revision"] == "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
    assert report["planned_pair_order"] == ["01","01","10","10"]
    assert len(report["attempts"]) == 2 and "stop_reason" in report
    output = {"raw_sha256":digest(raw), "arms":[]}
    for idx, a in enumerate(report["attempts"]):
        assert (a["pair"],a["position"],a["arm"]) == (1,idx+1,idx)
        assert a["verified_turns"] == 16 and a["eof_both"] == 2 and a["delivery_clean"] and not a["server_error"]
        assert a["verified_echo_bytes"] == a["verified_request_bytes"] == 65536
        events = folder/f"pair-1-{idx}"/"callbacks.jsonl"
        assert digest(events) == a["callbacks_sha256"]
        rows = list(map(json.loads,events.read_text().splitlines()))
        assert sorted(s["invocation"] for s in rows) == list(range(1,37))
        assert collections.Counter(s["owner"] for s in rows) == {"io.0":18,"io.1":18}
        for s in rows:
            assert s["set_status"] == s["restore_status"] == (0 if idx else -1)
            assert s["stable_thread"] == s["restored"] == 1
            for event in ("before", "entered", "leaving", "restored_state"):
                assert s[event]["tid"] == s["before"]["tid"]
                assert tuple(s[event][k] for k in ("timeshare","basic_policy","qos","base","current")) == (1,1,25,31,31)
        owner_threads = {k:sorted({s["before"]["tid"] for s in rows if s["owner"] == k}) for k in ("io.0","io.1")}
        assert owner_threads == a["threads_by_owner"]
        output["arms"].append({"arm":idx, "attempted_pairs":1, "verified_bytes_each_direction":65536,
                               "verified_turns":16, "both_fins":2, "callbacks":len(rows),
                               "fixed_callback_observations":0, "owner_threads":owner_threads,
                               "callback_sha256":digest(events)})
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
