"""Replay the admission, lifecycle, failure and pairing contracts without contacting a VM."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import profile_warm_edit as p


class WarmEditTests(unittest.TestCase):
    def test_accounting_and_daemon_clock(self):
        self.assertEqual(p.cgroup_delta({"io.stat": None}, {"io.stat": "8:0 rbytes=1"}), {})
        self.assertEqual(p.cgroup_delta({"io.stat": ""}, {"io.stat": "8:0 rbytes=1"}), {"io.stat/8:0/rbytes": 1})
        fields = {"cpu.pressure": "some avg10=0.00 total=20", "cpu.stat": "usage_usec 9"}
        self.assertEqual(p.cgroup_delta(fields, {**fields, "cpu.stat": "usage_usec 18"})["cpu.stat/usage_usec"], 9)
        rows = [
            dict(Type="container", Action=op, Actor=dict(ID="c", Attributes=dict(name="j")), timeNano=ns)
            for op, ns in (("create", 2000000), ("start", 5500000), ("die", 6500000))
        ]
        spans = p.event_spans("\n".join(map(json.dumps, rows)))["c"]
        self.assertEqual(spans["create_to_start_ms"], 3.5)
        self.assertIsNone(spans["die_to_destroy_ms"])
        self.assertEqual(p.spread([4, 5, 3])["p95"], 5)

    def test_divergent_pair_preserves_attempts(self):
        def batch(storage, product):
            guest = {
                "go_sha256": product,
                "node_output": "hello",
                "npm_hit_at_seed": False,
                "npm_payload_bytes": 0,
            }
            return dict(
                block=1,
                clients=1,
                phase="cold",
                storage=storage,
                jobs=[dict(ok=True, client_s=1, guest=guest)],
                failed=0,
                idle_pct=99,
                batch_s=1,
            )

        record = dict(
            batches=[batch("overlay", "a"), batch("volume", "b")],
            schedule=[(1, 1, "overlay"), (1, 1, "volume")],
            launches=[],
        )
        summary = p.summarize(record)
        self.assertEqual(summary["attempted"], 2)
        self.assertEqual(summary["pairs"], [])
        self.assertEqual(len(summary["comparison_failures"]), 1)
        self.assertEqual(
            p.kernel_delta({"disk": {"vdb": {"write_sectors": 1}}}, {"disk": {"vdb": {"write_sectors": 3}}})[
                "block_devices"
            ]["vdb"]["write_bytes"],
            1024,
        )

    def replay(self, root, fault):
        home = root / "worker"
        home.mkdir()
        sock = home / "docker.sock"
        sock.touch()
        (home / "session.json").write_text('{"owner":{"pid":42}}')
        exe = root / "docker"
        exe.touch()
        args = SimpleNamespace(
            slot_released=True,
            worker_home=home,
            docker=str(exe),
            micropod="mp",
            build_receipt=None,
            npm_tarball=None,
            image=p.TOOL_IMAGE,
            clients=[1, 16],
            storage_probes=False,
        )
        config = dict(cpus=4, memoryMiB=4096, worker="worker")
        run = dict(
            run="offline",
            schedule=[(1, w, s) for w in args.clients for s in ("overlay", "volume")],
            local=dict(micropod_config=config),
            launches=[],
            batches=[],
        )
        vols = set()
        observer = []
        populated = set()

        def fake(argv, input=None, **kwargs):
            def out(obj, code=0):
                data = obj if isinstance(obj, str) else json.dumps(obj)
                return subprocess.CompletedProcess(argv, code, data.encode(), b"")

            if argv[0] == "mp":
                return out(
                    dict(daemon="d", worker="worker", endpoint="unix://" + str(sock), boot="b", engine="docker")
                )
            self.assertEqual(argv[:3], [str(exe), "--host", "unix://" + str(sock)])
            opts = argv[3:]
            if opts[0] == "info":
                if ".ID" in opts[-1]:
                    return out('"d"')
                return out(dict(ID="d", NCPU=4, MemTotal=4118708224, Architecture="aarch64", CgroupVersion="2"))
            if opts[0] == "version":
                return out(dict(Client={}, Server={}))
            if opts[0] == "image":
                return out([dict(Architecture="arm64", Os="linux", Id=opts[-1], RepoDigests=[p.launch.IMAGE])])
            if opts[0] == "ps":
                return out(
                    "\n".join(observer)
                    if "--filter" not in opts or opts[-1].startswith("label=io.micropod.edit-research=")
                    else ""
                )
            if opts[0] == "rm":
                observer.clear()
                return out("")
            if opts[0] == "volume":
                if opts[1] == "create":
                    vols.add(opts[-1])
                    return out(opts[-1])
                if opts[1] == "ls":
                    return out("\n".join(vols))
                vols.difference_update(opts[2:])
                return out("")
            if opts[0] == "exec":
                return out(dict(boot="b") if opts[-1] == "kernel" else dict(go="tool"))
            if opts[0] == "events":
                return out("")
            self.assertEqual(opts[0], "run")
            if opts[-1] == "14400":
                observer.append("observer")
                return out("observer")
            if "-i" in opts:
                return out("")
            if opts[-1] == "/cache":
                cohort = next(x for x in opts if "dst=/cache" in x)
                return out(
                    dict(stores={"go_build": {"files": int(cohort.split(",")[1] in populated)}}, objects={})
                )
            if opts[-2] == "sh":
                token = opts[-1]
                return subprocess.CompletedProcess(
                    argv, 23, ("OUT-" + token + "\n").encode(), ("ERR-" + token + "\n").encode()
                )
            if opts[-2] == "job":
                cohort = next(x for x in opts if "dst=/cache" in x)
                populated.add(cohort.split(",")[1])
                if fault and "CONTROL_STORAGE=volume" in opts and opts[-1] == "edit-1-16":
                    return out("failure", 1)
                return out(
                    dict(
                        go_sha256=opts[-1],
                        node_output=opts[-1],
                        go_import_refs=[],
                        cgroup_before={},
                        cgroup_after={},
                        npm_hit_at_seed=opts[-1] != "base",
                        npm_payload_bytes=2625,
                    )
                )
            raise ValueError(opts)

        with (
            patch.object(Path, "is_socket", return_value=True),
            patch.object(p.launch, "cpu_idle", return_value=97),
            patch.object(p.launch, "stock_client", return_value={}),
            patch.object(p, "inputs", return_value={k: b"x" for k in p.FILES}),
            patch.object(p, "host_io", return_value=None),
            patch.object(p.subprocess, "run", side_effect=fake),
            patch.object(
                p,
                "exported_config_digest",
                side_effect=lambda _, i, *a: p.launch.CONFIG if i == p.launch.IMAGE else p.TOOL_CONFIG,
            ),
            patch.object(p.launch.platform, "system", return_value="Darwin"),
            patch.object(p.launch.platform, "machine", return_value="arm64"),
        ):
            if fault:
                with self.assertRaisesRegex(ValueError, "Edit-build failed"):
                    p.run(args, run, lambda: None)
            else:
                p.run(args, run, lambda: None)
        self.assertFalse(vols or observer)
        return p.summarize(run)

    def test_complete_schedule_and_first_failures(self):
        for fault in (False, True):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as tmp:
                r = self.replay(Path(tmp).resolve(), fault)
                self.assertEqual(r["alpine_attempted"], 34)
                self.assertEqual(r["alpine_failed"], 0)
                self.assertEqual(r["failed"], 16 if fault else 0)
                self.assertEqual(r["unattempted"], 16 if fault else 0)
                self.assertEqual(len(r["pairs"]), 4 if fault else 6)


if __name__ == "__main__":
    unittest.main()
