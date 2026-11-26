import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
TREE = HERE.parents[3]
REV = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def build(harness, dest):
    dest.mkdir(exist_ok=False)
    previous = json.loads((HERE.parent / "batch11-handshake-tcp/post-restart-build.json").read_text())
    reused = ["suite.py", "fixed", "server", "meter.dylib", "relay-0.o", "PublishedTCP.h"]
    for name in reused:
        if sha(harness/name) != previous["files"][name]: raise ValueError("fixture differs: "+name)
        shutil.copy2(harness/name, dest/name)
    native = "Sources/MicropodRuntime/NativeLoopbackRelay.swift"
    original = subprocess.check_output(["git","-C",TREE,"show",REV+":"+native]).decode()
    if hashlib.sha256(original.encode()).hexdigest()!=previous["files"]["NativeLoopbackRelay.swift"]:
        raise ValueError("unexpected native source")
    edits = [("    private let profile: Bool","    private let benchmarkActivity = ListenerActivity()\n    private let profile: Bool"),
             ("            listeners[selected] = lease","            listeners[selected] = lease\n            if !workers.isEmpty && listeners.count == 1 { benchmarkActivity.firstListener() }"),
             ("        let (stats, owners) = lease.release(profile: profile)","        let (stats, owners) = lease.release(profile: profile)\n        if !workers.isEmpty && listeners.isEmpty { benchmarkActivity.lastListener() }")]
    source=original
    for old,new in edits:
        if source.count(old)!=1: raise ValueError("ambiguous source hook")
        source=source.replace(old,new)
    (dest/"NativeLoopbackRelay.swift").write_text(source+"\n"+(HERE/"OwnerQoS.swiftfrag").read_text())
    for name in ("queue_probe.h","queue_probe.c"):
        shutil.copy2(HERE.parent/"batch06-trace"/name,dest/name)
    shutil.copy2(HERE/"Probe.swift",dest)
    shutil.copy2(HERE/"energy.c",dest)
    (dest/"module.modulemap").write_text('module CPublishedTCP { header "PublishedTCP.h" header "queue_probe.h" export * }\n')
    commands=[["xcrun","clang","-O2","-Wall","-Wextra","-Werror","-c","queue_probe.c","-o","qos.o"],
              ["xcrun","clang","-O2","-Wall","-Wextra","-Werror","-dynamiclib","energy.c","-o","energy.dylib"],
              ["xcrun","swiftc","-O","-swift-version","6","-module-cache-path",str(dest/"modules"),"-I.",
               "NativeLoopbackRelay.swift","Probe.swift","relay-0.o","qos.o","-o","relay"]]
    for cmd in commands: subprocess.run(cmd,check=True,cwd=dest)
    manifests={p.name:sha(p) for p in dest.iterdir() if p.is_file()}
    return {"revision":REV,"unmodified_native":hashlib.sha256(original.encode()).hexdigest(),
            "unchanged_c_hash":previous["files"]["PublishedTCP.c"],"commands":commands,"files":manifests,
            "shared_reference":"batch11-handshake-tcp/post-restart-build.json",
            "proposal":"host-queue-controls.md, Foundation activity on first parallel listener through last release"}

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("existing_harness",type=Path);p.add_argument("new_destination",type=Path)
    o=p.parse_args(); print(json.dumps(build(o.existing_harness.resolve(),o.new_destination.resolve()),indent=2))
