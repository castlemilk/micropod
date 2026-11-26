"""Reproduce the isolated Darwin ACK-policy screen on loopback."""
import argparse
import hashlib
import json
import platform
import random
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
SEED = 202611242311
FLOOR = 60 * 1024**3

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(path, result):
    temp = path.with_suffix(".partial")
    temp.write_text(json.dumps(result, indent=2)+"\n")
    temp.replace(path)

def run(path):
    with path.open("x"):
        pass
    order = [[0,1], [1,0]] * 6
    random.Random(SEED).shuffle(order)
    rec = dict(study_revision=subprocess.check_output(["git","-C",HERE,"rev-parse","HEAD"],text=True).strip(),
               source_sha256=digest(HERE/"observe.c"), runner_sha256=digest(Path(__file__)),
               timestamp=datetime.now(timezone.utc).isoformat(), host=platform.node(), darwin=platform.release(),
               arch=platform.machine(), workload="one-way 256 MiB per connection, verified at receiver", order=order,
               order_seed=SEED, status="started", first_attempts=[])
    save(path,rec)
    try:
        with tempfile.TemporaryDirectory() as work:
            binary = Path(work)/"probe"
            flags = ["-std=gnu11","-O2","-Wall","-Wextra","-Werror"]
            subprocess.run(["xcrun","clang",*flags,HERE/"observe.c","-o",binary],check=True)
            rec.update(binary_sha256=digest(binary), flags=flags,
                       compiler=subprocess.check_output(["xcrun","clang","--version"],text=True).splitlines()[0])
            for i, arms in enumerate(order,1):
                for policy in arms:
                    free = shutil.disk_usage(HERE).free
                    if free<FLOOR:
                        raise ValueError("local disk below 60 GiB")
                    row = dict(block=i, policy=policy, started=datetime.now(timezone.utc).isoformat(),disk_free_bytes=free)
                    rec["first_attempts"].append(row)
                    save(path,rec)
                    p = subprocess.run([binary,str(policy),"256"],capture_output=True,text=True,timeout=15)
                    row.update(exit=p.returncode,stdout=p.stdout,stderr=p.stderr)
                    save(path,rec)
                    p.check_returncode()
                    raw = json.loads(p.stdout)
                    if raw["verified_bytes"]!=256*1024**2 or raw["readback"]!=policy or raw["sender_bytes_outstanding"]:
                        raise ValueError("option, payload or drain mismatch")
                    row["observed"]=raw
                    save(path,rec)
        rec["status"]="completed"
    except BaseException as exc:
        rec.update(status="interrupted",error=str(exc))
        raise
    finally:
        save(path,rec)

if __name__ == "__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("new_output",type=Path)
    run(p.parse_args().new_output.resolve())
