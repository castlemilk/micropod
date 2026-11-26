#!/usr/bin/env python3
"""Hand-wired cache stores for scripts/e2e_hvf_caches.sh.

Runs as root in a python container. It lays out what P1-GE-CACHE's ensureStore
is specified to make, inside named volumes the harness mounts:

  /s          the scope volume (bound at /micropod/cache): root 0755, no ACL
  /s/<kind>   env-mode units: gomod gobuild npm pnpm pip pip/u0 pip/u1000 uv corepack
  /p/<unit>   path-mode volumes: yarn-u0 yarn-u1000 yarnberry cargo-registry cargo-git

  python3 qprep.py <name> acl|noacl [pnpm-index|no-pnpm-index]

acl   : every unit root-owned, chmod 0777 (no sticky), system.posix_acl_access
        and system.posix_acl_default set to the 28-byte u::rwx,g::rwx,o::rwx
        value, and <pnpm>/v11/index.db created 0666 (unless no-pnpm-index).
noacl : the pre-ACL engine layout (cacheDirectory): units 1777 and no default
        ACL. Only the negative controls use it.
The result goes to /qr/<name>.res with the harness sentinel.
"""
import os
import stat
import sys

ACL = bytes.fromhex("02000000" "01000700ffffffff" "04000700ffffffff" "20000700ffffffff")
ENV_UNITS = ["gomod", "gobuild", "npm", "pnpm", "pip", "pip/u0", "pip/u1000", "uv", "corepack"]
PATH_UNITS = ["yarn-u0", "yarn-u1000", "yarnberry", "cargo-registry", "cargo-git"]


def unit(path, mode):
    os.makedirs(path, exist_ok=True)
    os.chown(path, 0, 0)
    if mode == "acl":
        os.chmod(path, 0o777)
        os.setxattr(path, "system.posix_acl_access", ACL)
        os.setxattr(path, "system.posix_acl_default", ACL)
    else:
        os.chmod(path, 0o1777)
        try:
            os.removexattr(path, "system.posix_acl_default")
        except OSError:
            pass


def main():
    name, mode = sys.argv[1], sys.argv[2]
    pnpm_index = len(sys.argv) < 4 or sys.argv[3] == "pnpm-index"
    lines = [f"name={name}", f"mode={mode}", f"pnpm_index={int(pnpm_index)}"]
    os.chmod("/s", 0o755)
    for u in ENV_UNITS:
        unit(os.path.join("/s", u), mode)
    for u in PATH_UNITS:
        if os.path.isdir(os.path.join("/p", u)):
            unit(os.path.join("/p", u), mode)
    if mode == "acl" and pnpm_index:
        os.makedirs("/s/pnpm/v11", exist_ok=True)
        db = "/s/pnpm/v11/index.db"
        if not os.path.exists(db):
            os.close(os.open(db, os.O_CREAT | os.O_WRONLY, 0o666))
        os.chmod(db, 0o666)
        lines.append(f"pnpm_index_db_mode={oct(stat.S_IMODE(os.stat(db).st_mode))[2:]}")
    for root in ["/s"] + [os.path.join("/s", u) for u in ENV_UNITS] + [os.path.join("/p", u) for u in PATH_UNITS]:
        if not os.path.isdir(root):
            continue
        try:
            acl = os.getxattr(root, "system.posix_acl_default").hex()
        except OSError:
            acl = "none"
        lines.append(f"unit.{root}={oct(stat.S_IMODE(os.stat(root).st_mode))[2:]} acl_default={acl}")
    lines.append(f"QUAL-SENTINEL {name}")
    tmp = f"/qr/.{name}.res.{os.getpid()}"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.rename(tmp, f"/qr/{name}.res")


if __name__ == "__main__":
    main()
