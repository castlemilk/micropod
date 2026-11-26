#!/usr/bin/env python3
"""compare.py — compares the gate's store censuses (census.py) and engine reads
(archive_manifest.py). Host side; reads JSON, prints one summary line, and
writes the full comparison as JSON when --out is given.

  compare.py diff A.json B.json --scope S [--kinds k,k] [--fields F] [--out X]
      F: content (type mode uid gid size sha256 link), identity (ino
      mtime_ns), meta (nlink ctime_ns xattrs), or a comma list of them;
      strict = all three. Exit 0 when equal, 1 when not; also 1 ("EMPTY")
      when fewer than --min-stores real stores or no file were compared, and
      when either census could not read part of a store.
  compare.py digest A.json --scope S [--kinds k,k]
      the per-group digests and totals of one census.
  compare.py cross A.json ARCHIVE.json --store S.K
      the engine's read of one store (tar) against the census's read: path,
      type, size, sha256 and symlink target of every entry.
  compare.py inventory A.json B.json --scope S
      the engine's own unit inventory (GET /micropod/caches): (kind, unit,
      files, bytes) of every unit of the scope.
"""
import argparse
import hashlib
import json
import sys

GROUPS = {
    "content": ["type", "mode", "uid", "gid", "size", "sha256", "link"],
    "identity": ["ino", "mtime_ns"],
    "meta": ["nlink", "ctime_ns", "xattrs"],
}


def fields_of(spec):
    names = []
    for g in spec.split(","):
        if g == "strict":
            for v in GROUPS.values():
                names += v
        else:
            names += GROUPS[g]
    return names


def stores_of(doc, scope, kinds):
    out = {}
    for name, rec in doc["stores"].items():
        if rec["scope"] != scope:
            continue
        if kinds and rec["kind"] not in kinds:
            continue
        out[name] = rec
    return out


def index(rec):
    return {e["path"]: e for e in rec["entries"]}


def digest(rows, fields):
    h = hashlib.sha256()
    for e in sorted(rows, key=lambda e: e["path"]):
        h.update(("\t".join([e["path"]] + [json.dumps(e.get(f)) for f in fields]) + "\n").encode())
    return h.hexdigest()


def cmd_digest(a):
    doc = json.load(open(a.census))
    kinds = set(a.kinds.split(",")) if a.kinds else None
    res = {}
    for name, rec in sorted(stores_of(doc, a.scope, kinds).items()):
        res[name] = {
            "real": rec["real"],
            "entries": len(rec["entries"]),
            "files": rec["files"],
            "bytes": rec["bytes"],
            **{g: digest(rec["entries"], f) for g, f in GROUPS.items()},
        }
    print(json.dumps(res, sort_keys=True))
    return 0


def cmd_diff(a):
    A = json.load(open(a.a))
    B = json.load(open(a.b))
    kinds = set(a.kinds.split(",")) if a.kinds else None
    fields = fields_of(a.fields)
    sa, sb = stores_of(A, a.scope, kinds), stores_of(B, a.scope, kinds)
    report = {"fields": fields, "scope": a.scope, "stores": {}, "added": [], "removed": [], "changed": []}
    totals = {"entries": 0, "files": 0, "bytes": 0, "stores": 0}
    for name in sorted(set(sa) | set(sb)):
        ra, rb = sa.get(name), sb.get(name)
        if ra is None or rb is None:
            report["changed"].append({"path": f"{name}:", "fields": ["census-coverage"]})
            continue
        if ra["real"] != rb["real"]:
            report["changed"].append({"path": f"{name}:", "fields": [f"real {ra['real']}->{rb['real']}"]})
        # A census that could not read part of a store compares nothing there:
        # an unreadable subtree or file is a difference, never "equal".
        for side, rec in (("before", ra), ("after", rb)):
            unread = [e["path"] for e in rec["entries"] if str(e.get("sha256", "")).startswith("unreadable:")]
            if rec.get("errors") or unread:
                report["changed"].append({"path": f"{name}:", "fields": [
                    f"census-{side}-incomplete ({len(rec.get('errors') or [])} walk errors, {len(unread)} unreadable files)"]})
        ia, ib = index(ra), index(rb)
        for p in sorted(set(ib) - set(ia)):
            report["added"].append(f"{name}:{p}")
        for p in sorted(set(ia) - set(ib)):
            report["removed"].append(f"{name}:{p}")
        for p in sorted(set(ia) & set(ib)):
            diff = [f for f in fields if ia[p].get(f) != ib[p].get(f)]
            if diff:
                report["changed"].append({"path": f"{name}:{p}", "fields": diff})
        report["stores"][name] = {
            "realBefore": ra["real"], "realAfter": rb["real"],
            "entriesBefore": len(ra["entries"]), "entriesAfter": len(rb["entries"]),
            "digestBefore": digest(ra["entries"], fields), "digestAfter": digest(rb["entries"], fields),
        }
        if ra["real"]:
            totals["stores"] += 1
            totals["entries"] += len(ra["entries"])
            totals["files"] += ra["files"]
            totals["bytes"] += ra["bytes"]
    report["totals"] = totals
    equal = not (report["added"] or report["removed"] or report["changed"])
    report["equal"] = equal
    # Nothing compared is not "equal": two censuses that both saw no real
    # store of the scope (or no entry beyond the store roots) measured nothing.
    empty = equal and (totals["stores"] < a.min_stores or totals["files"] == 0)
    report["empty"] = empty
    if a.out:
        json.dump(report, open(a.out, "w"), indent=1, sort_keys=True)
    if empty:
        print(f"EMPTY: {totals['stores']} real stores (need {a.min_stores}), {totals['files']} files compared")
        return 1
    if equal:
        print(f"equal: {totals['entries']} entries, {totals['files']} files, {totals['bytes']} bytes in {totals['stores']} real stores")
        return 0
    ex = []
    ex += [f"+{p}" for p in report["added"][:2]]
    ex += [f"-{p}" for p in report["removed"][:2]]
    ex += [f"~{c['path']}({','.join(c['fields'])})" for c in report["changed"][:3]]
    print(f"DIFFERS: +{len(report['added'])} -{len(report['removed'])} ~{len(report['changed'])} of "
          f"{totals['entries']} entries; e.g. {' '.join(ex)}")
    return 1


def cmd_cross(a):
    doc = json.load(open(a.census))
    arc = json.load(open(a.archive))
    rec = doc["stores"].get(a.store)
    if rec is None or not rec["real"]:
        print(f"no real store {a.store} in the census")
        return 1
    core = ["type", "size", "sha256", "link"]
    ci = {e["path"]: tuple(e.get(f) for f in core) for e in rec["entries"]}
    ai = {e["path"]: tuple(e.get(f) for f in core) for e in arc["entries"]}
    only_c = sorted(set(ci) - set(ai))
    only_a = sorted(set(ai) - set(ci))
    diff = sorted(p for p in set(ci) & set(ai) if ci[p] != ai[p])
    if not (only_c or only_a or diff):
        print(f"same: {len(ci)} entries, {rec['files']} files, {rec['bytes']} bytes")
        return 0
    print(f"DIFFERS: census-only {len(only_c)} {only_c[:2]} engine-only {len(only_a)} {only_a[:2]} changed {len(diff)} {diff[:2]}")
    return 1


def cmd_inventory(a):
    def units(path):
        d = json.load(open(path))
        return sorted((u["kind"], u["unit"], u["files"], u["bytes"]) for u in d.get("units") or [] if u["scope"] == a.scope)

    ua, ub = units(a.a), units(a.b)
    if not ua:
        print(f"EMPTY: the engine listed no unit of {a.scope} before")
        return 1
    if ua == ub:
        print(f"equal: {len(ua)} units, {sum(u[2] for u in ua)} files, {sum(u[3] for u in ua)} bytes")
        return 0
    sa, sb = set(ua), set(ub)
    print(f"DIFFERS: before-only {sorted(sa - sb)[:3]} after-only {sorted(sb - sa)[:3]}")
    return 1


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("diff")
    d.add_argument("a")
    d.add_argument("b")
    d.add_argument("--scope", required=True)
    d.add_argument("--kinds", default="")
    d.add_argument("--fields", default="content")
    d.add_argument("--out", default="")
    d.add_argument("--min-stores", type=int, default=1)
    g = sub.add_parser("digest")
    g.add_argument("census")
    g.add_argument("--scope", required=True)
    g.add_argument("--kinds", default="")
    c = sub.add_parser("cross")
    c.add_argument("census")
    c.add_argument("archive")
    c.add_argument("--store", required=True)
    i = sub.add_parser("inventory")
    i.add_argument("a")
    i.add_argument("b")
    i.add_argument("--scope", required=True)
    a = p.parse_args()
    return {"diff": cmd_diff, "digest": cmd_digest, "cross": cmd_cross, "inventory": cmd_inventory}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
