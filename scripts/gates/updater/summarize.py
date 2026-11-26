#!/usr/bin/env python3
"""Turn an updater-gate receipt directory into result.json and a summary.

  summarize.py RECEIPT_DIR --complete 0|1 [--abort-line N --abort-command CMD]

Inputs, all written by scripts/gates/updater.sh:
  checks.tsv          n, section, id, ok (1/0), label, got, want  (one per check)
  measurements.jsonl  {"key": ..., "value": ...}                  (one per line)
  meta.json           run parameters and versions
Output: RECEIPT_DIR/result.json. Exit status 0 only when the run completed
and every check passed.
"""

import argparse
import json
import os
import statistics
import sys


def load_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("receipt")
    ap.add_argument("--complete", type=int, default=0)
    ap.add_argument("--abort-line", default="")
    ap.add_argument("--abort-command", default="")
    a = ap.parse_args()
    r = a.receipt

    checks = []
    try:
        with open(os.path.join(r, "checks.tsv"), encoding="utf-8") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 7:
                    continue
                n, section, cid, ok, label, got, want = parts[:7]
                checks.append({"n": int(n), "section": section, "id": cid, "ok": ok == "1", "label": label,
                               "got": got, "want": want})
    except OSError:
        pass

    measurements = {}
    try:
        with open(os.path.join(r, "measurements.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                key, value = rec.get("key"), rec.get("value")
                if key.endswith("[]"):
                    measurements.setdefault(key[:-2], []).append(value)
                else:
                    measurements[key] = value
    except OSError:
        pass

    meta = load_json(os.path.join(r, "meta.json"), {})
    target = meta.get("switchoverTargetMs")
    acts = measurements.get("activations") or []
    ext = [x["switchoverExternalMs"] for x in acts if isinstance(x.get("switchoverExternalMs"), (int, float))]
    prod = [x["switchoverProductMs"] for x in acts if isinstance(x.get("switchoverProductMs"), (int, float))]
    tot = [x["stageToHealthyMs"] for x in acts if isinstance(x.get("stageToHealthyMs"), (int, float))]

    def stats(xs):
        if not xs:
            return None
        return {"n": len(xs), "min": min(xs), "median": statistics.median(xs), "max": max(xs)}

    activation = {
        "targetSwitchoverMs": target,
        "targetSource": meta.get("switchoverTargetSource"),
        "switchoverExternalMs": stats(ext),
        "switchoverProductMs": stats(prod),
        "stageToProbedHealthyMs": stats(tot),
        "meetsTarget": (statistics.median(ext) <= target) if ext and target else None,
    }

    sections = {}
    for c in checks:
        s = sections.setdefault(c["section"], {"passed": 0, "failed": 0})
        s["passed" if c["ok"] else "failed"] += 1
    failed = [c for c in checks if not c["ok"]]
    passed = len(checks) - len(failed)
    result = {
        "gate": "micropod updater (backlog B26)",
        "receipt": r,
        "complete": bool(a.complete),
        "abort": None if a.complete else {"line": a.abort_line, "command": a.abort_command},
        "result": "pass" if a.complete and not failed and checks else "fail",
        "total": len(checks),
        "passed": passed,
        "failed": len(failed),
        "failedChecks": [f"{c['id']}: {c['label']} (got {c['got']!r}, want {c['want']!r})" for c in failed],
        "sections": sections,
        "activation": activation,
        "measurements": measurements,
        "meta": meta,
        "checks": checks,
    }
    with open(os.path.join(r, "result.json"), "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, sort_keys=True)

    print(f"updater gate: {passed}/{len(checks)} checks passed"
          + ("" if a.complete else f" — ABORTED at line {a.abort_line}: {a.abort_command}"))
    if ext:
        print(f"  switchover (old VMM exit -> new guest _ping), measured outside: median {statistics.median(ext)} ms "
              f"(min {min(ext)}, max {max(ext)}, n={len(ext)}) vs plan target {target} ms")
    if prod:
        print(f"  switchover as the product reports it: median {statistics.median(prod)} ms")
    if tot:
        print(f"  stage -> apply -> probed healthy: median {statistics.median(tot)} ms")
    for c in failed:
        print(f"  FAILED {c['id']} [{c['section']}] {c['label']}: got {c['got']!r}, want {c['want']!r}")
    print(f"  receipt: {os.path.join(r, 'result.json')}")
    return 0 if result["result"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
