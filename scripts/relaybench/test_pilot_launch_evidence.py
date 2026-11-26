"""Exercise the normal Gamma preflight against two offline, already-serving fixture descriptions."""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

import gamma_pilot as pilot
from test_host_role import make_window


def observe(mode, change):
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp).resolve()
        scopes = []
        hosts, jobs, engines, names = {}, {}, {}, {}
        for arm, n in (("A", 1), ("B", 2)):
            home = root / f"worker-{arm}"
            scope = root / "data" / arm
            owner = scope.parent / home.name
            scope.mkdir(parents=True)
            home.mkdir()
            owner.mkdir()
            scopes.append(scope)
            sock = home / "oci.sock"
            sock.touch()
            vmm, relay = 100 + n, 200 + n
            cpus = 6 if arm == "B" and mode == "size" else 4
            workers = 4 if arm == "B" and mode == "workers" else 2
            address = f"127.0.0.1:{9000+n}"
            for key, value in dict(base=home.name, id=arm, name=arm, addr=address, vmm=vmm, relay=relay).items():
                (scope / key).write_text(str(value))
            config = dict(worker=home.name, kernel="/same/Image", memoryMiB=4096, publishedPath="macvlan")
            session = dict(instance=arm, nativeOCI=True, started=True, owner={"pid": relay}, publishedRelayWorkers=workers,
                           publishedRelayCallbackEvents=128, publishedRelayReadBytes=262144,
                           readySocket=dict(worker=home.name, device=sock.stat().st_dev, inode=sock.stat().st_ino))
            for key, data in (("worker", config), ("session", session)):
                (home / (key + ".json")).write_text(json.dumps(data))
            env = dict(MICROPOD_CI_HOME=str(home), MICROPOD_CI_CPUS=str(cpus),
                       MICROPOD_CI_PORT_RELAY="kqueue-interactive", MICROPOD_CI_PORT_RELAY_WORKERS=str(workers))
            if arm == "B" and change == "auto":
                env["MICROPOD_CI_CPUS"] = "auto"
            if arm == "B" and change == "fixed CPU selector":
                env["MICROPOD_CI_CPUS"] = "4"
            job = dict(Label=home.name, ProcessType="Interactive", ProgramArguments=[str(home / "micropod"), "ci", "serve"],
                       EnvironmentVariables=env)
            if arm == "B" and change == "saved nice":
                job["Nice"] = 9
            (owner / "job.plist").write_bytes(plistlib.dumps(job))
            loaded = f"pid = {relay}\nspawn type = interactive (4)\n" + "\n".join(f"{k} => {v}" for k, v in env.items())
            if arm == "B" and change == "inherited env":
                loaded += "\nMICROPOD_CI_PORT_THROUGHPUT => 1"
            jobs[home.name] = loaded
            hosts[str(vmm)] = (
                "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
                "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine")
            if arm == "B" and change == "disk holder executable":
                hosts[str(vmm)] = "/usr/bin/du"
            if arm == "B" and change == "same executable basename":
                hosts[str(vmm)] = "/private/tmp/com.apple.Virtualization.VirtualMachine"
            hosts[str(relay)] = "9" if arm == "B" and change == "live nice" else "0"
            info = dict(ID=home.name, NCPU=cpus, MemTotal=4 << 30, Labels=["io.micropod.instance=" + arm],
                        ServerVersion="fixture")
            container = dict(Id=arm, Name="/" + arm, State={"Running": True}, Image=pilot.IMAGE,
                             Config={"Cmd": ["-listen", ":8080", "-marker", arm]},
                             NetworkSettings={"Ports": {"8080/tcp": ["binding"]}})
            state = {"cpu.max": "400000 100000", "cpuset.cpus.effective": "0-3", "memory.max": "1073741824",
                     "pids.max": "512", "interfaces": {"mppub0": {}}, "release": "7.3.5-micropod"}
            engines["unix://" + str(home / "docker.sock")] = dict(info=json.dumps(info), inspect=json.dumps(container),
                    port=address, state=json.dumps(state), routes=json.dumps({"mppub0": [pilot.DIRECT_ROUTE]}))
            names[address] = arm
            names[str(home / "worker.ext4")] = str(vmm)

        def command(*argv):
            if argv[0] == "docker":
                return engines[argv[2]][argv[-1] if argv[3] == "exec" else argv[3]]
            if argv[0] == "lsof":
                return names[argv[-1]]
            if argv[0] == "curl":
                return names[argv[-1].removeprefix("http://").removesuffix("/id")]
            if argv[0] == "ps":
                return hosts[argv[2]]
            if argv[0] == "launchctl":
                return jobs[Path(argv[-1]).name]
            if argv[0] == root / "rusage":
                return json.dumps({"tasks": [dict(pid=int(pid), birth_ticks=1) for pid in argv[1:]]})
            raise AssertionError(f"unexpected command {argv}")

        now = 1_795_385_000
        fleet, release = make_window(root, now, scopes)
        owner = json.loads(release.read_text())
        release.write_text(json.dumps(dict(owner, modes=[mode])))
        args = Namespace(mode=mode, a=scopes[0], b=scopes[1], tools=root, out=root / "out", seed=34202,
                         check=True, fleet=fleet, release=release)
        hashes = dict(pilot.HASHES, fixed=pilot.host_role.CLIENT_SHA256, Image=pilot.STOCK_KERNEL)
        with patch.object(pilot.platform, "node", return_value="Gamma-128GB"), patch.object(pilot.time, "time", return_value=now), \
                patch.object(pilot, "digest", side_effect=lambda path: hashes[path.name]), \
                patch.object(pilot, "mapped_digest", return_value="same-binary"), patch.object(pilot, "command", side_effect=command), \
                patch.object(pilot, "attempt", side_effect=AssertionError("fixture must never time a client")):
            try:
                pilot.run(args, pilot.plan(args.seed))
            except ValueError as exc:
                return {"admitted": False, "reason": str(exc)}
        return {"admitted": True}


CASES = {"workers": ("unchanged", "disk holder executable", "same executable basename"),
         "size": ("unchanged", "auto", "saved nice", "live nice", "inherited env", "fixed CPU selector")}


class PilotLaunchEvidenceTests(unittest.TestCase):
    def test_worker_process_and_vcpu_controls(self):
        for mode, changes in CASES.items():
            for change in changes:
                with self.subTest(mode=mode, change=change):
                    self.assertEqual(observe(mode, change)["admitted"], change in ("unchanged", "auto"))


def compare(base):
    fixture = Path(__file__).resolve()
    directory = fixture.parent
    root = directory.parents[1]
    sources = ["gamma_pilot.py", "host_role.py"]
    digest = lambda data: hashlib.sha256(data).hexdigest()
    base = subprocess.check_output(["git", "rev-parse", "--verify", "--end-of-options", base + "^{commit}"],
                                   cwd=root, text=True).strip()
    revisions = {}
    with tempfile.TemporaryDirectory() as tmp:
        for label in ("control", "candidate"):
            dest = Path(tmp) / label
            dest.mkdir()
            shutil.copyfile(fixture, dest / fixture.name)
            hashes = {}
            # Freeze the helper modules on the control revision on both sides.
            for name in (*sources, "gamma_contrasts.py", "gamma_fleet.py", "test_host_role.py"):
                path = directory / name
                data = (path.read_bytes() if label == "candidate" and name in sources else
                        subprocess.check_output(["git", "show", f"{base}:{path.relative_to(root)}"], cwd=root))
                (dest / name).write_bytes(data)
                hashes[name] = digest(data)
            raw = subprocess.check_output([sys.executable, "-B", str(dest / fixture.name), "--observe"],
                                          cwd=dest, env=dict(os.environ, PYTHONPATH=""))
            revisions[label] = dict(sources=hashes, observations=json.loads(raw))
    return dict(date="2026-11-24", control_commit=base, directions=["230.02", "237.03"],
                evidence="Source/fixture, two synthetic already-serving scope descriptions. "
                         "Command and mapped-binary evidence supplied in memory. No client or socket opened.",
                cases="Change only the named field in arm B. Worker count is two vs four at four vCPUs. "
                      "For size it is four vs six vCPUs, with two relay workers in both arms.",
                guardrails="Preflight only. No delivered bytes, drops, CPU time, request latency or rate measured.",
                fixture_sha256=digest(fixture.read_bytes()), **revisions)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--compare":
        print(json.dumps(compare(sys.argv[2]), indent=2))
    elif sys.argv[1:] == ["--observe"]:
        print(json.dumps({mode: {change: observe(mode, change) for change in changes}
                          for mode, changes in CASES.items()}, indent=2))
    else:
        unittest.main()
