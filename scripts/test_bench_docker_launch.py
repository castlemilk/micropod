"""Offline contracts for the Apple stock-Docker control. Never opens an engine socket."""
from contextlib import closing, ExitStack
import itertools
import json
from pathlib import Path
from types import SimpleNamespace
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

import bench_docker_launch as bench
from ci_benchmark_store import store


class LaunchControlTests(unittest.TestCase):
    def test_same_stock_binary_and_guest_arguments(self):
        sockets = {bench.MIC: "/mic/pinned.sock", bench.ORB: "/orb/pinned.sock"}
        def argv(arm):
            return bench.argv(arm, "/pinned/docker", "/pinned/micropod", sockets, "label", "one")
        mic, orb, native = map(argv, bench.ARMS)
        self.assertEqual(mic[:5], ["/pinned/docker", "--host", "unix:///mic/pinned.sock", "run", "--rm"])
        self.assertEqual(orb[:5], ["/pinned/docker", "--host", "unix:///orb/pinned.sock", "run", "--rm"])
        self.assertEqual(native[:4], ["/pinned/micropod", "ci", "run", "--existing-worker-only"])
        self.assertEqual(mic[5:], orb[5:])
        self.assertEqual(mic[5:], native[4:])
        self.assertEqual(mic[5:mic.index("--label")],
                         ["--platform", "linux/arm64", "--pull=never", "--network", "none",
                          "--cpus", "1", "--memory", "256m"])
        for width in (1, 16):
            orders = [tuple(g["order"]) for g in bench.schedule(23, 1) if g["clients"] == width]
            self.assertCountEqual(orders, itertools.permutations(bench.ARMS))

    def test_shell_checks_limits_network_boot_and_both_streams(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            net = root / "net"
            net.mkdir()
            (net/"lo").touch()
            paths = {bench.BOOT: root/"boot", "/sys/fs/cgroup/cpu.max": root/"cpu",
                     "/sys/fs/cgroup/memory.max": root/"memory", "/sys/class/net": net}
            script = bench.FIXTURE
            for source, local in paths.items():
                script = script.replace(source, str(local))
            (root/"boot").write_text("pinned\n")
            (root/"cpu").write_text("100000 100000\n")
            (root/"memory").write_text("268435456\n")
            def run():
                return subprocess.run(["/bin/sh", "-c", script, "sh", "test"], env={"CONTROL_BOOT": "pinned"},
                                      capture_output=True)
            p = run()
            self.assertEqual((p.returncode, p.stdout, p.stderr), (23, b"OUT-test\n", b"ERR-test\n"))
            for filename, bad, code in (("boot", "other", 70), ("cpu", "max 100000", 71), ("memory", "max", 72)):
                file = root/filename
                prior = file.read_text()
                file.write_text(bad + "\n")
                self.assertEqual(run().returncode, code)
                file.write_text(prior)
            (net/"eth0").touch()
            self.assertEqual(run().returncode, 73)

    def simulate(self, tmp, fault=None):
        # Real orchestration, timer, fan-out, stream assertions and SQLite writer with in-process daemon doubles.
        root = Path(tmp)
        home = root/"worker"
        home.mkdir()
        sockets = {bench.MIC: home/"docker.sock", bench.ORB: root/"orb.sock"}
        for path in (*sockets.values(), root/"docker", root/"micropod"):
            path.touch(mode=0o700)
        (root/"docker").write_bytes(b"path\tgithub.com/docker/cli/cmd/docker\n")
        arms = {f"unix://{path}": arm for arm, path in sockets.items()}
        boots = {arm: str(uuid.uuid4()) for arm in arms.values()}
        config = dict(worker="worker", cpus=4, memoryMiB=4096)
        r = dict(run="offline", schedule=bench.schedule(2, 1), local={"micropod_config": config},
                 warmups=[], groups=[], probes=[])
        calls = []
        def command(args, env):
            calls.append(tuple(args))
            if args[-2:] == ["ci", "help"]:
                return "micropod dev (fixture)\n--existing-worker-only"
            if args[-2:] == ["ci", "status"]:
                return json.dumps(dict(engine="docker", endpoint=f"unix://{sockets[bench.MIC]}", instance="test",
                                       worker="worker", daemon=bench.MIC, boot=boots[bench.MIC]))
            if args[1] != "--host":
                return {"cpu":"4", "memory_mib":"4096"}.get(args[-1], "offline")
            arm, options = arms[args[2]], args[3:]
            if options[0] == "ps":
                return "foreign" if fault == "busy" else ""
            if options[0] == "info":
                return json.dumps(dict(Name=arm, OperatingSystem="Linux", ID=arm, NCPU=4, CgroupVersion="2",
                                       MemTotal=4100000000, ServerVersion="1", KernelVersion="6", Architecture="aarch64"))
            if options[:2] == ["image", "inspect"]:
                return json.dumps([dict(Id="config", Os="linux", Architecture="arm64", RepoDigests=[bench.IMAGE])])
            if options[0] == "version":
                return '{"Client":{"Version":"1","GitCommit":"a","Os":"darwin","Arch":"arm64"},"Server":{"Version":"1"}}'
            self.assertEqual(options[-3:], [bench.IMAGE, "cat", bench.BOOT])
            return boots[arm]
        def client(args, env, **_):
            token = args[-1]
            area = arms[args[2]] if args[1] == "--host" else bench.MIC
            self.assertEqual(boots[area], env["CONTROL_BOOT"])
            stderr = ("ERR-" + token + "\n").encode()
            if fault == "streams" and args[1] == "ci" and token.startswith("b1-16-") and token.endswith(("-1", "-2")):
                stderr += b"unexpected\n"
            return subprocess.CompletedProcess(args, 23, ("OUT-" + token + "\n").encode(), stderr)
        with ExitStack() as s:
            def stub(where, **kwargs):
                return s.enter_context(patch(where, **kwargs))
            stub("bench_docker_launch.command", side_effect=command)
            stub("bench_docker_launch.subprocess.run", side_effect=client)
            stub("bench_docker_launch.exported_config_digest", return_value="wrong" if fault == "digest" else bench.CONFIG)
            stub("bench_docker_launch.cpu_idle", return_value=97)
            stub("bench_docker_launch.host_model", return_value="Mac-test")
            stub("bench_docker_launch.platform.system", return_value="Darwin")
            stub("bench_docker_launch.platform.machine", return_value="arm64")
            stub("bench_docker_launch.platform.mac_ver", return_value=("26", (), ""))
            stub("pathlib.Path.is_socket", return_value=True)
            stub("bench_docker_launch.shutil.which", side_effect=lambda exe, **_: str(root/Path(exe).name))
            args = SimpleNamespace(docker=str(root/"docker"), micropod=str(root/"micropod"))
            if fault in ("busy", "digest"):
                with self.assertRaises(ValueError):
                    bench.live(args, r, home, sockets, lambda: None)
                r["state"] = "failed"
            else:
                bench.live(args, r, home, sockets, lambda: None)
                r["state"] = "complete-with-exclusions" if fault else "complete"
        r["summary"] = bench.summarize(r)
        return r

    def test_complete_and_failed_first_attempts(self):
        for fault in (None, "streams", "busy", "digest"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as tmp:
                r = self.simulate(tmp, fault)
                counts = r["summary"]["counts"]
                db = Path(tmp)/"test.sqlite"
                store(db, r["run"], "apple-stock-docker-launch", r)
                with closing(sqlite3.connect(db)) as sql:
                    self.assertEqual(sql.execute("SELECT count(*) FROM docker_launch_pairs").fetchone()[0],
                                     0 if fault in ("busy", "digest") else (23 if fault else 24))
                if fault in ("busy", "digest"):
                    self.assertEqual(counts["warmup"]["attempted"] + counts["timed"]["attempted"], 0)
                    self.assertFalse(r["probes"])
                else:
                    self.assertEqual(counts["warmup"]["attempted"], 34)
                    self.assertEqual(counts["boot_probes"]["failed"], 0)
                    self.assertEqual(counts["timed"]["attempted"], 306)
                    self.assertEqual(counts["timed"]["failed"], 2 if fault else 0)
                    self.assertEqual(counts["timed"]["unattempted"], 0)
                    pairs = r["summary"]["widths"]["16"]
                    self.assertEqual(len(pairs["stock_docker"]["pairs"]), 6)
                    self.assertEqual(len(pairs["native_ci"]["pairs"]), 5 if fault else 6)

    def test_paired_spread_uses_within_block_differences(self):
        rows = []
        for block, times in enumerate(((10, 20, 12), (40, 25, 60), (42, 125, 58)), 1):
            rows.append(dict(clients=1, finished=True, block=block,
                             batches=[dict(arm=a, batch_ms=t, jobs=[], idle_before_pct=96) for a,t in zip(bench.ARMS, times)]))
        output = bench.summarize(dict(schedule=[dict(clients=1)]*3, groups=rows, warmups=[], probes=[]))
        self.assertEqual(output["widths"]["1"]["stock_docker"]["spread"]["delta_ms"],
                         dict(n=3, median=10, min=-15, max=83))
        self.assertEqual(output["widths"]["16"]["stock_docker"]["spread"]["delta_ms"]["n"], 0)
        rows[0]["batches"][1]["idle_before_pct"] = 90
        self.assertEqual(len(bench.paired(rows, bench.ORB)["pairs"]), 2)
        self.assertEqual(len(bench.paired(rows, bench.NATIVE)["pairs"]), 3)
        with self.assertRaises(ValueError):
            bench.resources(4, 8192, {})


if __name__ == "__main__":
    unittest.main()
