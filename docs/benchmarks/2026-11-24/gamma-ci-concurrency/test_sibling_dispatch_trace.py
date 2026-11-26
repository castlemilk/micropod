"""Exercise scoped ftrace parsing and monotonic dispatch overlap without a VM."""

import io
import unittest

import sibling_dispatch_trace as trace


class DispatchTraceTests(unittest.TestCase):
    def test_scheduler_states_and_bounds(self):
        raw = """root-12 [000] .... 1.000000: tracing_mark_write: micropod-dispatch-start
idle-0 [001] .... 1.001000: sched_switch: prev_comm=idle prev_pid=0 prev_prio=120 prev_state=R ==> next_comm=quiet-http next_pid=20 next_prio=120
<...>-20 [001] .... 1.002000: clock_nanosleep(which_clock: 0x1, flags: 0x1, rqtp: 0x20, rmtp: 0x0)
quiet-http-20 [001] .... 1.003000: sched_switch: prev_comm=quiet-http prev_pid=20 prev_prio=120 prev_state=S ==> next_comm=builder next_pid=21 next_prio=120
timer-20 [000] .... 1.005000: sched_wakeup: comm=quiet-http pid=20 prio=120 target_cpu=001
builder-21 [001] .... 1.009000: sched_switch: prev_comm=builder prev_pid=21 prev_prio=120 prev_state=R+ ==> next_comm=quiet-http next_pid=20 next_prio=120
quiet-http-20 [001] .... 1.010000: clock_nanosleep -> 0x0
root-12 [000] .... 1.013000: tracing_mark_write: micropod-dispatch-stop
"""
        stats = {f"cpu{i}": f"entries: {8 if i == 0 else 0}\noverrun: 0\ncommit overrun: 0\ndropped events: 0\n"
                 for i in range(4)}
        segments, markers, quantum, counts, ids = trace.state_segments(io.StringIO(raw), {"quiet-http": 1}, stats)
        self.assertEqual(quantum, 1000)
        self.assertEqual(markers, {"start": 1_000_000_000, "stop": 1_013_000_000})
        self.assertEqual(counts["switch"], 3)
        self.assertEqual(ids, {"quiet-http": 20})
        observed = trace.attribution(segments["quiet-http"], (1_003_999_900, 1_004_000_000), quantum, 0, 6_000_000)
        for field, expected in (("sleeping_in_clock_nanosleep", 1_000_000), ("runnable", 4_000_000), ("on_cpu", 1_000_000)):
            lower, upper = observed[field]
            self.assertLessEqual(lower, expected)
            self.assertGreaterEqual(upper, expected)
            self.assertLess(upper - lower, 5000)
        self.assertEqual(observed["unknown"], [0, 0])

        with self.assertRaisesRegex(ValueError, "wrong CPU"):
            trace.state_segments(io.StringIO(raw), {"quiet-http": 2}, stats)
        with self.assertRaisesRegex(ValueError, "expected issuer clock_nanosleep"):
            trace.state_segments(io.StringIO(raw.replace("flags: 0x1", "flags: 0x0")), {"quiet-http": 1}, stats)
        with self.assertRaisesRegex(ValueError, "trace PID changed or collided"):
            trace.state_segments(io.StringIO(raw.replace("comm=quiet-http pid=20", "comm=quiet-http pid=300")),
                                 {"quiet-http": 1}, stats)
        bad = dict(stats, cpu0=stats["cpu0"].replace("dropped events: 0", "dropped events: 1"))
        with self.assertRaisesRegex(ValueError, "trace overflow"):
            trace.state_segments(io.StringIO(raw), {"quiet-http": 1}, bad)

    def test_pinned_probe_transform_keeps_the_request_loop(self):
        original = (trace.BASE / "quiet-http-base.go").read_bytes()
        generated = trace.probe_source(original)
        self.assertEqual(original.split(b"func measurePaced(")[1].split(b"func waitDrain(")[0],
                         generated.split(b"func measurePaced(")[1].split(b"func waitDrain(")[0])
        self.assertIn(b"result.Pace.TraceIssuer", generated)
        self.assertIn(b"KernelOriginUpperNS = c.kernelOrigin", generated)
        with self.assertRaisesRegex(ValueError, "frozen paced"):
            trace.probe_source(original + b"\n")

    def test_derived_fixture_uses_diagnostic_archive_not_performance_receipt(self):
        original = (trace.BASE / "sibling_ci.py").read_bytes()
        derived = trace.diagnostic_driver(original)
        compile(derived, "derived-fixture", "exec")
        self.assertNotIn(b'folder / "windows.json"', derived)
        self.assertIn(b"dispatch-trace-workload.json", derived)

    def test_guest_and_container_thread_ids_stay_bound_through_capture(self):
        name = trace.issuing_name("mp-t-test", 8)
        target = {"slot": 8, "pid": 7, "tid": 11, "pidns": "pid:[6100]", "mask": "1", "comm": name}
        birth = "402"
        row = {"proc_pid": 40, "proc_tid": 44, "pidns": "pid:[6100]", "comm": name,
               "cmdline": f"/mpcheck/quiet-http\x00-ready-file\x00/gate/{trace.TAG}.8\x00-dispatch-trace\x00{name}\x00",
               "status": f"Name:\t{name}\nNStgid:\t40\t7\nNSpid:\t44\t11\nCpus_allowed_list:\t1\n",
               "stat": "44 (quiet-http) S " + "0 " * 18 + birth + " 0"}
        trace.verify_identity(target, row, row)
        with self.assertRaisesRegex(ValueError, "birth time changed"):
            trace.verify_identity(target, row, dict(row, stat=row["stat"].replace(birth, "403")))
        with self.assertRaisesRegex(ValueError, "PID namespaces"):
            trace.verify_identity(target, row, dict(row, pidns="pid:[6101]"))


if __name__ == "__main__":
    unittest.main()
