"""Execute the pinned single-queue Linux get_rps_cpu and set_rps_cpu paths."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
HERE=Path(__file__).resolve().parent
BASE="a60d203b16b24abd857e1b5c9e817636b241f850"
DEV="8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274"
def digest(b):return hashlib.sha256(b).hexdigest()
def extract(path):
    b=path.read_bytes()
    assert digest(b)==DEV
    text=b.decode()
    funcs=[]
    for sig in ["static struct rps_dev_flow *\nset_rps_cpu(", "static int get_rps_cpu("]:
        i=text.index(sig)
        funcs.append(text[i:text.index("\n}",i)+2])
    return ("/* SPDX-License-Identifier: GPL-2.0 */\n"+"\n".join(funcs)+"\n").encode()
if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--verify-source",type=Path)
    args=parser.parse_args()
    if args.verify_source: assert extract(args.verify_source)==(HERE/"rfs_flow.inc").read_bytes()
    with tempfile.TemporaryDirectory() as td:
        out=Path(td)/"rfs"
        subprocess.run(["clang","-std=gnu11","-O2","-Wall","-Werror",str(HERE/"rfs_flow.c"),"-o",out],check=True)
        rows=[json.loads(line) for line in subprocess.check_output([out],text=True).splitlines()]
    assert len(rows)==36
    print(json.dumps(dict(direction="237.05",base=BASE,linux="7.3.5",dev_c_sha256=DEV,compiler=subprocess.check_output(["clang","--version"],text=True).splitlines()[0],fixture_sha256={s:digest((HERE/s).read_bytes()) for s in ["rfs_flow.c","rfs_flow.inc","rfs_flow.py"]},constants=dict(online_cpus=[0,1,2,3],one_rx_queue=True,hash_map_cpus=[0,1,2,3],flow_hash="0x11223344",new_reader_cpu=3,post_migration_arrivals=64,hardware_steering=False),attempts=rows),indent=2))
