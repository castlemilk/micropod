"""Compile both relay policies from the pinned source; supply an unused output file."""
import argparse
import hashlib
import json
import platform
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REV = "a60d203b16b24abd857e1b5c9e817636b241f850"
FILES = ["Sources/CPublishedTCP/PublishedTCP.c", "Sources/CPublishedTCP/include/PublishedTCP.h",
         "scripts/relaybench/filter_work.c"]

def sha(value):
    return hashlib.sha256(value).hexdigest()

def run(output):
    with output.open("x") as f, tempfile.TemporaryDirectory() as temp:
        wd = Path(temp)
        inputs = [subprocess.check_output(["git","show",f"{REV}:{p}"],cwd=ROOT) for p in FILES]
        ctrl, header, support = inputs
        old = b'filter_change(&dst->watch, EVFILT_WRITE, EV_ADD | EV_ENABLE) };\n            if (update_stream_filters'
        new = old.replace(b'\n            if', b'\n            changes[1].fflags = NOTE_LOWAT;\n            changes[1].data = remaining < 32768 ? (intptr_t)remaining : 32768;\n            if')
        assert ctrl.count(old)==1
        cand = ctrl.replace(old,new)
        (wd/"PublishedTCP.h").write_bytes(header)
        (wd/"filter_work.c").write_bytes(support)
        for name, data in (("control",ctrl),("candidate",cand)):
            source = wd/(name+".c")
            source.write_bytes(data)
            subprocess.run(["clang","-std=gnu11","-Wall","-Wextra","-Werror","-O2",f'-DRELAY_SOURCE="{source}"',
                            "-I",temp,str(HERE/"write_lowat.c"),"-o",str(wd/name)],check=True)
        result = dict(revision=REV,source_paths=FILES,source_sha256=[sha(x) for x in inputs],
                      candidate_sha256=sha(cand), fixture_sha256=sha((HERE/"write_lowat.c").read_bytes()),
                      driver_sha256=sha(Path(__file__).read_bytes()),darwin=platform.release(),
                      compiler=subprocess.check_output(["clang","--version"],text=True).splitlines()[0],attempts=[])
        for name in ["control","candidate","candidate","control"]:
            p = subprocess.run([str(wd/name)],text=True,capture_output=True,timeout=20)
            result["attempts"].append(dict(arm=name,returncode=p.returncode,stdout=p.stdout.splitlines(),stderr=p.stderr))
            if p.returncode: break
        json.dump(result,f,indent=2)
        print(file=f)
        assert len(result["attempts"])==4 and all(x["returncode"]==0 for x in result["attempts"])
if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("output",type=Path)
    run(parser.parse_args().output)
