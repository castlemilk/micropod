import json
import unittest

import sibling_compiler_slice_evidence as evidence


class CompilerSliceEvidenceTests(unittest.TestCase):
    def setUp(self):
        link = {"kind": "ipvlan", "mode": "l2", "mtu": 1500, "ipv4": ["10.90.0.2"], "default_route": False}
        self.job = {"id": "sample", "ip": "10.90.0.2", "home_cpu": "2",
                    "cgroup": {"cpuset.cpus.effective": "0-3", "cpu.max": "100000 100000"}, "endpoint": link}
        self.probe = "b" * 64
        identities = {"taskset": "/bin/taskset", "compiler-runtime": evidence.RUNTIME, "dispatcher": "/bin/busybox",
                      "go": "/usr/local/go/bin/go", "compile": "/usr/local/go/pkg/tool/linux_arm64/compile"}
        lines = ["boot sample-boot", "limits 0-3 100000 100000", "cgroup_inode 35:107",
                 "link " + json.dumps(link), f"object 1024 {'a' * 64}"]
        for role, path in identities.items():
            lines.append(f"file {role} {path} {self.probe}")
        for role, pid in (("dispatcher", 11), ("go", 12), ("compile", 13)):
            ppid = 0 if role == "dispatcher" else pid - 1
            lines.append(f"process {role} {pid} {ppid} {identities[role]} 0::/ net:[21] cgroup:[22]")
            threads = [{"tid": pid, "cpus_allowed_list": "2", "policy": 0, "nice": 0, "priority": 0, "slice_ns": 2100000}]
            if role == "compile":
                threads.append({**threads[0], "tid": 14})
            lines.append(f"threads {role} " + json.dumps(threads))
        self.raw = "\n".join(lines)

    def test_actual_process_threads_require_exact_slice_and_namespace(self):
        result, network, cgroup = evidence.read_witness(self.raw, self.job, "sample-boot", 2100000, self.probe)
        self.assertEqual((result["compile"]["sha256"], network, cgroup), (self.probe, "net:[21]", "35:107"))
        mutations = (
            (self.raw.replace('"tid": 14, "cpus_allowed_list": "2"', '"tid": 14, "cpus_allowed_list": "0-3"'),
             "unexpected CPU affinity"),
            (self.raw.replace('"slice_ns": 2100000}]', '"slice_ns": 250000}]', 1), "real dispatcher threads"),
            (self.raw.replace("go 12 11", "go 12 0"), "invalid real go process identity"),
            (self.raw.replace("compile 13 12", "compile 13 15"), "not a real descendant"),
            (self.raw.replace("net:[21] cgroup:[22]", "net:[21] cgroup:[23]", 1), "not a real descendant"),
        )
        for raw, error in mutations:
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                evidence.read_witness(raw, self.job, "sample-boot", 2100000, self.probe)

    def test_peer_retains_inherited_slice_in_both_modes(self):
        for arm, mode, requested, expected in (("A", "inherit", 0, 250000), ("A", "long", 2100, 2100000),
                                               ("B", "inherit", 0, 2100000), ("B", "long", 0, 2100000)):
            self.assertEqual(evidence.expected_ns(arm, mode), expected)
            self.assertEqual(evidence.launcher(self.job, arm, mode)[-3], requested)


if __name__ == "__main__":
    unittest.main()
