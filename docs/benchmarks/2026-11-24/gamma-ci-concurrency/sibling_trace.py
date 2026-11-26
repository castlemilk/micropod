"""Coordinate a private guest trace around two warmed pairs and retain its kernel receipts."""
import hashlib
import io
import json
import os
import shutil
import tarfile
import time
from pathlib import Path

from qualify import HERE, require, terminal


def stage(oci, work, folder, env, archive):
    # Distinct Linux comm names identify each role across guest PID namespaces.
    names = work / "probe/trace-names"
    names.mkdir()
    service = names / "msvc00"
    with tarfile.open(archive) as oci_tar:
        layer = oci_tar.extractfile("blobs/sha256/" + terminal.LAYER).read()
    require(hashlib.sha256(layer).hexdigest() == terminal.LAYER, "wrong historical service layer")
    with tarfile.open(fileobj=io.BytesIO(layer), mode="r:gz") as rootfs:
        elf, = [f for f in rootfs.getmembers() if f.isfile() and f.name.lstrip("./") == "netbench"]
        service.write_bytes(rootfs.extractfile(elf).read())
    require(terminal.digest(service) == terminal.SERVER, "wrong traced service executable")
    service.chmod(0o755)
    for index in range(32):
        if index:
            os.link(service, names / f"msvc{index:02}")
        os.link(work / "probe/quiet-http", names / f"mcli{index:02}")
    src = HERE / "sibling_trace_linux.go"
    binary = work / "probe/sibling-trace"
    terminal.invoke("go", "build", "-trimpath", "-buildvcs=false", "-o", binary, src, env=env)
    shutil.copy2(src, folder / src.name)
    shutil.copy2(__file__, folder / "trace-driver.py")
    (work / "sibling-traces").mkdir(mode=0o700)
    with (oci / "runner/fixture-facts.sh").open("a") as hook:
        hook.write('''
trace_dir="$MICROPOD_ENGINE_WORKSPACE/sibling-traces"
"$MICROPOD_ENGINE_WORKSPACE/probe/sibling-trace" -dir "$trace_dir" >"$trace_dir/helper.log" 2>&1 </dev/null &
''')
    return {"socket_sched_trace": True, "trace_probe_sha256": terminal.digest(binary),
            "trace_source_sha256": terminal.digest(src), "trace_driver_sha256": terminal.digest(Path(__file__)),
            "trace_server_sha256": terminal.digest(service), "trace_client_sha256": terminal.digest(names / "mcli00")}


def wait(directory, name, seconds):
    until = time.monotonic() + seconds
    while not (directory / name).is_file():
        if (directory / "error").is_file():
            raise ValueError("private socket trace: " + (directory / "error").read_text())
        require(time.monotonic() < until, "timed out waiting for private socket trace " + name)
        time.sleep(.01)
    return json.loads((directory / name).read_bytes())


def start(cohort, folder, block, tag):
    directory = cohort.work / "sibling-traces"
    wait(directory, "ready", 3)
    pairs = []
    for index in (block % 8, 8 + (block + 1) % 8):
        server, client = cohort.jobs[index], cohort.jobs[cohort.count + index]
        pairs.append({"index": index, "marker": server["name"], "server_ip": server["ip"], "client_ip": client["ip"]})
    tmp = directory / (tag + ".command-tmp")
    tmp.write_text(json.dumps({"tag": tag, "pairs": pairs}))
    tmp.replace(directory / "command")
    receipt = wait(directory, tag + ".armed", 7)
    require([r["index"] for r in receipt] == [p["index"] for p in pairs], "wrong traced pairs")
    terminal.save(folder / (tag + "-actors.json"), receipt)


def stop(cohort, folder, tag):
    directory = cohort.work / "sibling-traces"
    (directory / (tag + ".stop")).touch(exist_ok=False)
    stats = wait(directory, tag + ".done", 15)
    terminal.save(folder / (tag + "-trace-stats.json"), stats)
    shutil.copyfile(directory / (tag + ".trace.gz"), folder / (tag + ".ftrace.gz"))
    check_stats(stats)


def check_stats(stats):
    require(set(stats) == {f"cpu{i}" for i in range(4)}, "missing per-vCPU trace buffers")
    entries = 0
    for text in stats.values():
        values = dict(line.split(":", 1) for line in text.splitlines() if ":" in line)
        require(all(int(values[k]) == 0 for k in ("overrun", "commit overrun", "dropped events")), "kernel trace overflow")
        entries += int(values["entries"])
    require(entries > 0, "empty kernel trace")
    return entries
