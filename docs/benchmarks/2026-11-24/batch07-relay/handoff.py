"""Test pending-handoff coalescing on the real Darwin serial dispatch primitive."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REVISION = "a60d203b16b24abd857e1b5c9e817636b241f850"
TARGET = "Sources/MicropodRuntime/NativeLoopbackRelay.swift"
CANDIDATE = """private let lock = NSLock()
    private var pending: [(Int32,UInt64)] = []
    func adopt(_ fd: Int32, accepted: UInt64) {
        lock.lock()
        let schedule = pending.isEmpty
        pending.append((fd,accepted))
        lock.unlock()
        if schedule {
            owner.queue.async {
                self.lock.lock()
                let batch = self.pending
                self.pending = []
                self.lock.unlock()
                for (fd, stamp) in batch { mp_tcp_adopt(self.handle, fd, stamp) }
            }
        }
    }"""

def sha(value):
    return hashlib.sha256(value).hexdigest()

def main(out):
    with Path(out).open("x") as result, tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        original = subprocess.check_output(["git","show",f"{REVISION}:{TARGET}"],cwd=ROOT)
        text = original.decode()
        start = text.index("func adopt(_ fd: Int32, accepted: UInt64)")
        control = text[start:text.index("\n        }",start)+len("\n        }")]
        assert "owner.queue.async { mp_tcp_adopt(self.handle, fd, accepted) }" in control
        template = (HERE/"handoff.swift.in").read_bytes()
        raw = dict(revision=REVISION,target=TARGET,target_sha256=sha(original),control_method_sha256=sha(control.encode()),
                   candidate_method_sha256=sha(CANDIDATE.encode()),fixture_sha256=sha(template),
                   driver_sha256=sha(Path(__file__).read_bytes()),darwin=platform.release(),
                   compiler=subprocess.check_output(["swiftc","--version"],text=True).strip(),attempts=[])
        for arm, code in (("control",control),("candidate",CANDIDATE)):
            (root/"main.swift").write_text(template.decode().replace("__ADOPT_METHOD__",code))
            subprocess.run(["swiftc","-O",str(root/"main.swift"),"-o",str(root/arm)],check=True)
        for arm in ("control","candidate","candidate","control"):
            p = subprocess.run([str(root/arm)],capture_output=True,text=True,timeout=20)
            raw["attempts"].append(dict(arm=arm,returncode=p.returncode,stderr=p.stderr,
                                        rows=[json.loads(line) for line in p.stdout.splitlines()]))
            if p.returncode: break
        json.dump(raw,result,indent=2); print(file=result)
        assert len(raw["attempts"])==4 and all(len(a["rows"])==12 for a in raw["attempts"])
if __name__=="__main__":
    main(sys.argv[1])
