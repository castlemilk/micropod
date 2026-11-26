import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

import sibling_compiler_affinity_evidence as evidence


class CompilerAffinityEvidenceTests(unittest.TestCase):
    def test_real_process_proof_rejects_wrong_parent_and_thread_mask(self):
        raw = f"""boot sample
requested 0-3
file taskset /bin/busybox {'a' * 64}
file go /usr/local/go/bin/go {'b' * 64}
file compile /usr/local/go/pkg/tool/linux_arm64/compile {'c' * 64}
process go 101 100 0 /usr/local/go/bin/go
thread go 101 0-3
process compile 110 101 0 /usr/local/go/pkg/tool/linux_arm64/compile
thread compile 110 0-3
thread compile 111 0-3
object_bytes 2200"""
        self.assertEqual(evidence.read_tool_proof(raw, "sample", "0-3")["compile"]["sha256"], "c" * 64)
        for actual in (raw.replace("110 101", "110 102"), raw.replace("111 0-3", "111 1")):
            with self.assertRaises(ValueError):
                evidence.read_tool_proof(actual, "sample", "0-3")

    def test_group_cpu_deltas_verify_boots_and_bracket(self):
        jobs = [{"id": str(i), "home_cpu": str(i % 4)} for i in range(64)]

        def sample(value, start):
            def record(job):
                cpu = "\n".join(f"{field} {value}" for field in evidence.CG_FIELDS)
                return {"id": job["id"], "boot": "sample", "cpu.stat": cpu,
                        "cpu.pressure": f"some avg10=0.00 total={value * 2}"}

            groups = [{"slot": i, "home_cpu": home, "dependency": record(dependency), "builder": record(builder)}
                      for i, home, dependency, builder in evidence.pairs(jobs)]
            raw = "\n".join(f"cpu{cpu} {value} 0 0 7 {100 - value} 0 0 0" for cpu in evidence.VCPUS)
            return {"host_start_ns": start, "host_end_ns": start + 1, "groups": groups, "vcpu_stat": raw}

        receipt = {"round": 1, "arm": "A", "before": sample(10, 1), "after": sample(12, 5),
                   "run_wave_host_ns": [2, 5]}
        with TemporaryDirectory() as directory:
            folder = Path(directory)
            path = folder / evidence.wave_name(1, "A")
            path.write_text(json.dumps(receipt))
            result = evidence.verify_wave(folder, 1, "A", jobs, "sample")
            self.assertEqual(result["groups"][0]["builder"]["nr_throttled"], 2)
            self.assertEqual(result["groups"][0]["dependency"]["psi_usec"], {"some": 4})
            self.assertEqual(result["guest_vcpu_delta_ticks"]["3"]["iowait"], -2)
            with self.assertRaisesRegex(ValueError, "changed container or guest identity"):
                evidence.verify_wave(folder, 1, "A", jobs, "other-boot")
            receipt["run_wave_host_ns"] = [2, 6]
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, "overlapped"):
                evidence.verify_wave(folder, 1, "A", jobs, "sample")


if __name__ == "__main__":
    unittest.main()
