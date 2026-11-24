"""Compile and observe the pinned C relay on private fixed-work Darwin threads."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
BASE="a60d203b16b24abd857e1b5c9e817636b241f850"
files=["scripts/relaybench/filter_work.c","Sources/CPublishedTCP/PublishedTCP.c","Sources/CPublishedTCP/include/PublishedTCP.h","Sources/MicropodRuntime/NativeLoopbackRelay.swift"]
def digest(b): return hashlib.sha256(b).hexdigest()
with tempfile.TemporaryDirectory() as tmp:
    work=Path(tmp)
    pinned={p:subprocess.check_output(["git","show",f"{BASE}:{p}"],cwd=ROOT) for p in files}
    assert b'qos: .userInitiated' in pinned[files[-1]]
    for p,src in pinned.items(): (work/Path(p).name).write_bytes(src)
    subprocess.run(["clang","-std=gnu11","-O2","-Wall","-Werror",'-DRELAY_SOURCE="PublishedTCP.c"',"-I",str(work),str(HERE/"fixed_owner.c"),"-o",str(work/"owner")],check=True)
    rows=[json.loads(s) for s in subprocess.check_output([work/"owner"],text=True).splitlines()]
print(json.dumps(dict(direction="228.04",base=BASE,darwin=platform.release(),machine=platform.machine(),compiler=subprocess.check_output(["clang","--version"],text=True).splitlines()[0],source_sha256={p:digest(s) for p,s in pinned.items()},fixture_sha256={n:digest((HERE/n).read_bytes()) for n in ["fixed_owner.c","fixed_owner.py"]},attempts=rows),indent=2))
