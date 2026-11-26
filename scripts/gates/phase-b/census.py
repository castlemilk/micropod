#!/usr/bin/env python3
"""census.py ROOT OUT: an inode-level census of the cache stores under ROOT.

Runs inside the gate's census container (python:alpine, io.micropod.cache=off,
--network none). Every directory ROOT/<scope>.<kind> is one read-only legacy
alias volume (micropod-ci-scoped-<scope>-<kind>:ro): a bind of the store's own
directory on the cache disk, the same inodes the engine reads, never an
overlay view. The census proves that from /proc/self/mountinfo for each
store (mount root /scopes/<scope>/<kind>, its device, fstype and options) and
records, per entry: type, mode, uid, gid, size, inode, nlink, mtime_ns,
ctime_ns, sha256 of a regular file's bytes, a symlink's target and the
extended attributes (name and sha256 of the value; POSIX ACLs included).
atime is not recorded: reading a file is not writing the store.

A store that is not there is an empty private directory of the container's
(the engine creates nothing for a reader): its mount root is not below
/scopes/, and it is recorded as real=false with no entries.

OUT gets one JSON document; nothing else is written anywhere.
"""
import hashlib
import json
import os
import stat
import sys


def mounts():
    out = {}
    with open("/proc/self/mountinfo") as f:
        for line in f:
            parts = line.split()
            sep = parts.index("-")
            point = parts[4].replace("\\040", " ")
            out[point] = {
                "root": parts[3].replace("\\040", " "),
                "options": parts[5],
                "fstype": parts[sep + 1],
                "source": parts[sep + 2],
                "superOptions": parts[sep + 3] if len(parts) > sep + 3 else "",
            }
    return out


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb", buffering=0) as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def xattrs(path):
    try:
        names = sorted(os.listxattr(path, follow_symlinks=False))
    except OSError:
        return []
    out = []
    for n in names:
        try:
            v = os.getxattr(path, n, follow_symlinks=False)
            out.append(f"{n}={hashlib.sha256(v).hexdigest()[:16]}")
        except OSError as e:
            out.append(f"{n}=?{e.errno}")
    return out


def entry(top, rel):
    p = os.path.join(top, rel) if rel else top
    st = os.lstat(p)
    m = st.st_mode
    if stat.S_ISREG(m):
        kind = "f"
    elif stat.S_ISDIR(m):
        kind = "d"
    elif stat.S_ISLNK(m):
        kind = "l"
    else:
        kind = "o"
    e = {
        "path": rel or ".",
        "type": kind,
        "mode": stat.S_IMODE(m),
        "uid": st.st_uid,
        "gid": st.st_gid,
        "size": st.st_size if kind == "f" else 0,
        "ino": st.st_ino,
        "nlink": st.st_nlink,
        "mtime_ns": st.st_mtime_ns,
        "ctime_ns": st.st_ctime_ns,
        "xattrs": xattrs(p),
    }
    if kind == "f":
        try:
            e["sha256"] = sha256_file(p)
        except OSError as err:
            e["sha256"] = f"unreadable:{err.errno}"
    elif kind == "l":
        e["link"] = os.readlink(p)
    return e


def walk(top):
    entries = [entry(top, "")]
    errors = []

    def onerror(err):
        errors.append(f"{err.filename}: {err.strerror}")

    for dirpath, dirnames, filenames in os.walk(top, onerror=onerror, followlinks=False):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, top)
        rel_dir = "" if rel_dir == "." else rel_dir
        for name in sorted(dirnames) + sorted(filenames):
            rel = os.path.join(rel_dir, name) if rel_dir else name
            try:
                entries.append(entry(top, rel))
            except OSError as err:
                errors.append(f"{rel}: {err.strerror}")
    return entries, errors


def main():
    root, out_path = sys.argv[1], sys.argv[2]
    mi = mounts()
    doc = {"root": root, "stores": {}}
    for name in sorted(os.listdir(root)):
        top = os.path.join(root, name)
        if not os.path.isdir(top) or "." not in name:
            continue
        scope, kind = name.split(".", 1)
        m = mi.get(top, {})
        real = m.get("root", "").startswith(f"/scopes/{scope}/{kind}") and m.get("fstype") == "ext4"
        rec = {"scope": scope, "kind": kind, "mount": m, "real": real, "readOnlyMount": "ro" in m.get("options", "").split(",")}
        if real:
            entries, errors = walk(top)
        else:
            entries, errors = [], []
            # Still look: a private stand-in must be empty.
            try:
                rec["standInEntries"] = len(os.listdir(top))
            except OSError as e:
                rec["standInEntries"] = f"?{e.errno}"
        rec["entries"] = entries
        rec["errors"] = errors
        rec["files"] = sum(1 for e in entries if e["type"] == "f")
        rec["bytes"] = sum(e["size"] for e in entries)
        doc["stores"][name] = rec
    tmp = out_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, sort_keys=True)
    os.rename(tmp, out_path)


if __name__ == "__main__":
    main()
