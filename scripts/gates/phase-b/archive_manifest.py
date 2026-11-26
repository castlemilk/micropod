#!/usr/bin/env python3
"""archive_manifest.py OUT < tar: the manifest of a store as the engine read it.

The host runs `docker cp <census>:/c/<scope>.<kind> -` against the census
container: the guest engine opens the store through its own descriptor of the
bind source (docker_archive_linux.go), reads every file in its own mount
namespace and streams a tar. This turns that stream into the same per-entry
fields the in-container census records for content (path, type, size, sha256,
symlink target), plus what a tar header carries (mode, uid, gid, mtime), so
the harness can check that the engine's read and the census's read of the
store are the same bytes.
"""
import hashlib
import json
import sys
import tarfile


def main():
    out_path = sys.argv[1]
    entries = {}
    hard = []
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as tar:
        for m in tar:
            name = m.name.lstrip("./")
            first, _, rest = name.partition("/")
            rel = rest or "."
            if m.isreg():
                h = hashlib.sha256()
                f = tar.extractfile(m)
                while True:
                    b = f.read(1 << 20)
                    if not b:
                        break
                    h.update(b)
                e = {"type": "f", "size": m.size, "sha256": h.hexdigest()}
            elif m.isdir():
                e = {"type": "d", "size": 0}
            elif m.issym():
                e = {"type": "l", "size": 0, "link": m.linkname}
            elif m.islnk():
                target = m.linkname.lstrip("./").partition("/")[2] or "."
                e = {"type": "f", "size": 0, "hardlinkTo": target}
                hard.append(rel)
            else:
                e = {"type": "o", "size": 0}
            e.update({"path": rel, "mode": m.mode & 0o7777, "uid": m.uid, "gid": m.gid, "mtime": m.mtime})
            entries[rel] = e
    for rel in hard:
        t = entries.get(entries[rel]["hardlinkTo"], {})
        entries[rel]["size"] = t.get("size", 0)
        entries[rel]["sha256"] = t.get("sha256", "missing-hardlink-target")
    rows = sorted(entries.values(), key=lambda e: e["path"])
    core = "\n".join(
        f"{e['path']}\t{e['type']}\t{e['size']}\t{e.get('sha256', '')}\t{e.get('link', '')}" for e in rows
    )
    doc = {
        "entries": rows,
        "files": sum(1 for e in rows if e["type"] == "f"),
        "bytes": sum(e["size"] for e in rows),
        "coreDigest": hashlib.sha256(core.encode()).hexdigest(),
    }
    with open(out_path, "w") as f:
        json.dump(doc, f, sort_keys=True)
    print(f"{len(rows)} entries, {doc['files']} files, {doc['bytes']} bytes, core {doc['coreDigest'][:16]}")


if __name__ == "__main__":
    main()
