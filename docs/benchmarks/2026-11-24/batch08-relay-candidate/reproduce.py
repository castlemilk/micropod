"""Compile the checked relay on Darwin and retain each bounded first attempt."""
import hashlib
import json
from pathlib import Path
import platform
import random
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BASE = "ad9d174eda5eb499e0e15675829e21a00d836f84"
PINS = {
    "Sources/CPublishedTCP/PublishedTCP.c": "f35e0245ebc1d394f748ea31ef03df180c70ad4a979925037ea063f7a2a08cee",
    "Sources/CPublishedTCP/include/PublishedTCP.h": "e1996e8123fe678ae460b2bd18fb5f4a5af7457e022c26731fb426146c60bdb9",
    "scripts/relaybench/filter_work.c": "d09459ebab854c706048e1b87c84a976405ebdce42e5758c7825cfa836698109",
    "scripts/relaybench/late_read_size.c": "c2e901035dd19675992a0fb7eeadcdc675fc07eba5bc1d5c8949f37b52b1a89e",
}
# Each tuple fixes active bulk flows, offered KiB per flow, the fresh byte's arrival
# at bulk write -1 (absent), 0 (co-ready) or 1 (while inside the callback), and
# the first callback budget. Subsequent callbacks use the two-worker stock budget.
CELLS = [(1,1024,-1,0), (1,1024,0,0), (1,1024,1,0), (1,512,1,0),
         (1,256,1,0), (2,1024,1,0), (4,1024,1,0), (1,1024,1,1)]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    out = Path(sys.argv[1])
    seed = 23003256
    rng = random.Random(seed)
    with tempfile.TemporaryDirectory() as tmp, out.open("x", buffering=1) as report:
        temp = Path(tmp)
        def emit(record):
            print(json.dumps(record), file=report)
        emit(dict(type="design", base=BASE, seed=seed, cells=CELLS, host=platform.system(),
                  machine=platform.machine(), kernel=platform.release(), pins=PINS,
                  fixture={p.name:sha(p.read_bytes()) for p in
                           (HERE/"single-bulk.patch", HERE/"fixed-work.patch", Path(__file__))},
                  compiler=subprocess.check_output(["clang","--version"],text=True).splitlines()[0]))
        for name, expected in PINS.items():
            data = subprocess.check_output(["git","show",BASE+":"+name],cwd=ROOT)
            assert sha(data) == expected
            (temp/Path(name).name).write_bytes(data)
        subprocess.run(["patch","-sp0","-i",str(HERE/"fixed-work.patch")],cwd=temp,check=True)
        for policy in ("stock","extra"):
            if policy == "extra":
                subprocess.run(["patch","-sp0","-i",str(HERE/"single-bulk.patch")],cwd=temp,check=True)
            emit(dict(type="relay",policy=policy,sha256=sha((temp/"PublishedTCP.c").read_bytes())))
            for width in sorted({c[0] for c in CELLS}):
                subprocess.run(["clang","-std=gnu11","-O2","-Wall","-Wextra","-Werror",
                                "-DFIXED_STREAMS="+str(width),'-DRELAY_SOURCE="PublishedTCP.c"',
                                "-I",str(temp),str(temp/"late_read_size.c"),"-o",str(temp/f"{policy}-{width}")],
                               check=True)
        cells = list(CELLS)
        rng.shuffle(cells)
        for width,kib,marker,budget in cells:
            first = rng.choice(("extra","stock"))
            second = "stock" if first=="extra" else "extra"
            for pair, order in enumerate(((first,second),(second,first)),start=1):
                for policy in order:
                    run = subprocess.run([str(temp/f"{policy}-{width}"),str(kib*1024),str(marker),str(budget)],
                                         capture_output=True,text=True)
                    row = dict(type="attempt",cell=[width,kib,marker,budget],pair=pair,
                               policy=policy,exit=run.returncode,stdout=run.stdout,stderr=run.stderr)
                    if run.returncode==0:
                        row["result"] = json.loads(run.stdout)
                    emit(row)
                    run.check_returncode()


if __name__=="__main__":
    main()
