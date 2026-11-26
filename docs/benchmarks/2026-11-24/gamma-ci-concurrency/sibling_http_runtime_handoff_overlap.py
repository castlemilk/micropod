"""Associate verified Go wait chains with unique possible HTTP phases."""

import argparse
from bisect import bisect_left, bisect_right
from collections import Counter
import json
from pathlib import Path
from statistics import median
from unittest.mock import patch

import sibling_http_runtime_handoff as sealed
from qualify import require, terminal


FUZZ = sealed.TRACE_FUZZ_NS
ROLES = {0: "builder", 9: "service_only"}


def unique_candidate(spans, starts, ends, wake, running, gate):
    """Both events must admit one common origin and there must be only one possible call."""
    earliest = max(wake, running) - FUZZ
    latest = min(wake, running) + FUZZ
    first = bisect_left(ends, earliest - gate[1])
    stop = bisect_right(starts, latest - gate[0])
    return [i for i in range(first, stop) if max(gate[0], earliest - spans[i][1]) <= min(gate[1], latest - spans[i][0])]


def classify_trace(record, receipt, events, boot):
    gate, marks, _ = sealed.bind_clock(record, receipt, events, boot)
    begin, end = marks["begin"], marks["end"]
    samples, arrivals = receipt["samples"], receipt["pace"]["arrivals"]
    table, spans = {kind: {} for kind in sealed.PHASES}, {}
    for kind in sealed.PHASES:
        keys = sealed.phase_fields(kind)
        edges = [(arrival["dispatch_offset_ns"] + sample[keys[0]], arrival["dispatch_offset_ns"] + sample[keys[1]])
                 for sample, arrival in zip(samples, arrivals, strict=True)]
        starts, ends = zip(*edges, strict=True)
        require(all(a <= b <= c for a, b, c in zip(starts, ends, (*starts[1:], ends[-1]), strict=True)),
                "application phases overlap across calls")
        spans[kind] = edges, starts, ends
    rejected = Counter()
    for park, reason, wake, running in sealed.cycles(events, begin.emitter):
        if not begin.time <= park.time < wake.time < running.time <= end.time:
            continue
        kind = sealed.classify(park, reason, wake)
        if kind is None:
            rejected["unclassified_" + reason] += 1
            continue
        edges, starts, ends = spans[kind]
        possible = unique_candidate(edges, starts, ends, wake.time, running.time, gate)
        if len(possible) != 1:
            rejected[("ambiguous_" if possible else "incompatible_") + kind] += 1
            continue
        index = possible[0]
        require(running.thread == begin.thread, "Go issuer moved OS thread")
        bounds = edges[index]
        table[kind].setdefault(index, []).append({
            "park_trace_ns": park.time, "ready_trace_ns": wake.time, "run_trace_ns": running.time,
            "blocked_ns_bounds": sealed.overlap(bounds, park.time, wake.time, gate),
            "runnable_ns_bounds": sealed.overlap(bounds, wake.time, running.time, gate),
            "return_minus_parsed_run_ns_at_gate_lower": bounds[1] + gate[0] - running.time,
        })
    require(all(len(rows) == 1 for kind in ("headers", "body_eof") for rows in table[kind].values()),
            "a warmed call was associated with repeated header or EOF handoffs")
    return table, rejected, gate


def summarize(receipt, table, indices):
    samples = receipt["samples"]
    results = {}
    for kind, calls in table.items():
        first, last = sealed.phase_fields(kind)
        phase = {i: samples[i][last] - samples[i][first] for i in indices}
        row = {"selected": len(indices), "matched": sum(i in calls for i in indices), "phase_ns": sum(phase.values())}
        for counter in ("blocked_ns_bounds", "runnable_ns_bounds"):
            row[counter] = [sum(min(phase[i], sum(x[counter][end] for x in calls.get(i, ()))) for i in indices)
                            for end in (0, 1)]
        results[kind] = row
    return results


def example(receipt, table, index):
    arrival, sample = receipt["pace"]["arrivals"][index], receipt["samples"][index]
    return {"arrival": arrival, "clock_boundaries_ns": {key: sample[key] for key in sealed.boundaries.TIMESTAMPS},
            "trace_cycles": {kind: calls.get(index, []) for kind, calls in table.items()}}


def p95(values):
    return values[(95 * len(values) + 99) // 100 - 1]


def replay(folder, strict_path):
    strict_saved = sealed.read(strict_path)
    inventory = sealed.read(folder / "grouped-inventory.json")
    timelines, per_wave = {}, {}
    original_decode, original_diagnose = sealed.decode, sealed.diagnose
    collector = sealed.boundaries.response_phases.TraceCollector
    original_read = collector.read_wire

    def snapshot(self, path, tag):
        rows = original_read(self, path, tag)
        dense = sealed.DENSE.fullmatch(tag)
        if dense:
            block, arm = int(dense[1]), dense[2]
            masks = [job["mask"] for job in inventory[arm]["jobs"][32:]]
            local = [p95(sorted(sample["total_ns"] for sample in row["receipt"]["samples"])) for row in rows]
            for slot in ROLES:
                siblings = [i for i, mask in enumerate(masks) if i != slot and mask == masks[slot] and (i < 8) == (slot < 8)]
                require(siblings, "missing same-role, same-vCPU observer controls")
                peer = median(local[i] for i in siblings)
                per_wave[f"{tag}.{slot}"] = {"post_dispatch_p95_ns": local[slot], "same_vcpu_role_slots": siblings,
                    "same_vcpu_role_median_p95_ns": peer, "ratio_to_sibling_median": local[slot] / peer,
                    "this_client_traced": sealed.SLOTS.get(block) == slot, "any_client_traced": block in sealed.SLOTS}
        return rows

    def inspect(path, record, receipt, boot, affinity, go):
        events = original_decode(path, go)
        with patch.object(sealed, "decode", lambda *_: events):
            verified = original_diagnose(path, record, receipt, boot, affinity, go)
        timelines[record["tag"]] = (receipt, *classify_trace(record, receipt, events, boot))
        return verified

    with patch.object(collector, "read_wire", snapshot), patch.object(sealed, "diagnose", inspect):
        strict = sealed.replay(folder)
    require(json.loads(json.dumps(strict)) == strict_saved and set(timelines) == set(strict["traces"]),
            "strict raw replay disagrees with the retained receipt")
    traces, same_offers = {}, {}
    for block, slot in sealed.SLOTS.items():
        names = [sealed.tag_for(block, arm) for arm in "AB"]
        a, b = (timelines[tag][0] for tag in names)
        require([r["due_offset_ns"] for r in a["pace"]["arrivals"]] == [r["due_offset_ns"] for r in b["pace"]["arrivals"]],
                "trace pair changed the exact offered offsets")
        ranks = {tag: sorted(range(len(receipt["samples"])), key=lambda i: (receipt["samples"][i]["total_ns"], i))
                 for tag, receipt in zip(names, (a, b), strict=True)}
        size = len(ranks[names[0]])
        rank95 = (95 * size + 99) // 100
        union = sorted(set(ranks[names[0]][rank95:]) | set(ranks[names[1]][rank95:]))
        views = {}
        for tag in names:
            receipt, table, rejected, gate = timelines[tag]
            band = ranks[tag][94 * size // 100:96 * size // 100]
            traces[tag] = {"origin_bounds_ns": gate, "unassigned_cycles": dict(rejected),
                "all_calls": summarize(receipt, table, range(size)), "own_p95_band": summarize(receipt, table, band),
                "median_return_minus_parsed_run_ns_at_gate_lower": {kind: median(
                    row["return_minus_parsed_run_ns_at_gate_lower"] for calls in rows.values() for row in calls)
                    for kind, rows in table.items() if rows}}
            views[tag] = summarize(receipt, table, union)
        examples = []
        for rank_tag in names:
            index = ranks[rank_tag][rank95 - 1]
            examples.append({"ranked_at_p95_in": rank_tag, "client_index": index, "global_offer_ordinal": slot + 32 * index,
                             "by_trace": {tag: example(*timelines[tag][:2], index) for tag in names}})
        same_offers[ROLES[slot]] = {"tail_union_size": len(union), "tail_union_by_trace": views, "examples": examples}
    return {"schema": "micropod-http-handoff-overlap-v1", "diagnostic_only": True, "archive": folder.name,
            "strict_replay_sha256": terminal.digest(strict_path), "decoder_tolerance_ns": FUZZ,
            "traces": traces, "same_offers": same_offers, "per_wave_observer_controls": per_wave}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("strict_results", type=Path)
    args = parser.parse_args()
    print(json.dumps(replay(args.archive.resolve(), args.strict_results), indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
