"""Verify raw trial coverage, socket readbacks and bytes before the marker."""
import collections
import json
import random
import statistics
import sys
from pathlib import Path

CAP = 65536
CHUNK = 262144
TOTAL = 2 * CHUNK

def verify(path):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    design, *events, exit_record = rows
    assert design["event"] == "design" and design["budget_bytes"] == CAP
    assert exit_record == {"event": "exit", "status": 0, "stderr": ""}
    order = list("AAAABBBB")
    random.Random(design["seed"]).shuffle(order)
    assert design["order"] == "".join(order)
    runs = collections.defaultdict(list)
    for event in events:
        runs[event["run"]].append(event)
    assert sorted(runs) == list(range(1, 17))
    offsets = {"budget": [], "eager": []}
    maxima = {"budget": [], "eager": []}
    count_above_cap = 0
    marker_deferred = 0
    for run_id, run in runs.items():
        attempt, options, *offers, result = run
        assert attempt["event"] == "attempt" and options["event"] == "options" and result["event"] == "result"
        pair, position = divmod(run_id - 1, 2)
        budgeted = (order[pair] == "B") ^ position
        arm = "budget" if budgeted else "eager"
        assert (attempt["pair"], attempt["position"], attempt["arm"]) == (pair + 1, position + 1, arm)
        assert options["tcp_nodelay"] and options["nonblocking"] and options["notsent_lowat"] == 0
        assert options["initial_snd_sbbytes"] == 0
        assert [x["phase"] for x in offers[:3]] == ["held-1", "held-2", "marker-held"]
        assert [x["offered"] for x in offers[:3]] == [CHUNK, CHUNK, 17]
        for x in offers:
            assert x["event"] == "offer" and 0 <= x["accepted"] <= x["permitted"] <= x["offered"]
            available = max(0, CAP - x["before"])
            assert x["permitted"] == (min(x["offered"], available) if budgeted else x["offered"])
            assert not x["errno"]
        assert sum(x["accepted"] for x in offers) == TOTAL + 17
        queued_bulk = sum(x["accepted"] for x in offers[:2])
        assert result["bulk_before_marker_at_receiver"] == queued_bulk
        assert result["verified_bulk"] == TOTAL and result["verified_marker"] == 17 and result["both_eof"]
        assert result["sender_retransmitted_packets"] == result["peer_retransmitted_packets"] == 0
        assert result["final_snd_sbbytes"] == 0
        offsets[arm].append(queued_bulk)
        maxima[arm].append(max(x["after"] for x in offers))
        if budgeted:
            count_above_cap += sum(x["after"] > CAP for x in offers)
            marker_deferred += offers[2]["accepted"] < 17
    for arm in offsets:
        print(arm, "receiver offsets, bytes", offsets[arm], "median", statistics.median(offsets[arm]),
              "per-run maximum recorded sender backlog", maxima[arm])
    print("budgeted post-offer snapshots above cap", count_above_cap,
          "marker deferred until receiver drain", marker_deferred)

if __name__ == "__main__":
    verify(Path(sys.argv[1]))
