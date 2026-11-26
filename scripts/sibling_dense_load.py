"""Measure successful compilations and cgroup counters beside sibling TCP."""

from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
import hashlib
import json
import math
import os
import re
import subprocess
import time
import uuid


CONTAINERS = 32
CONCURRENCY = 8
CPU_PERIOD_US = 100_000
CPU_DENOMINATOR = 16
CPU_GROUP_LABEL = "io.micropod.ci.cpu-group"
MEMORY_BYTES = 128 << 20
UPTIME_RESOLUTION_NS = 10_000_000
SOURCE = "package dense\n\n" + "\n".join(
    f"func Step{i}(value int) int {{\n"
    "    for j := 0; j < 64; j++ {\n"
    f"        value = (value*131 + j + {i}) ^ (value >> 3)\n"
    "    }\n    return value\n}\n"
    for i in range(64)
)

# /proc/uptime is guest CLOCK_BOOTTIME at centisecond resolution. Record the
# boot identity and time namespace offset so clocks from different jobs align.
CLOCK_SCRIPT = r"""
clock_scope() {
    read -r boot_id < /proc/sys/kernel/random/boot_id
    offset_s=0
    offset_ns=0
    if [ -r /proc/self/timens_offsets ]; then
        while read -r clock seconds nanos; do
            if [ "$clock" = boottime ]; then
                offset_s=$seconds
                offset_ns=$nanos
                break
            fi
        done < /proc/self/timens_offsets
    fi
    printf '%s %s %s\n' "$boot_id" "$offset_s" "$offset_ns"
}
"""

CGROUP_SCRIPT = r"""
cgroup_paths() {
    root=/sys/fs/cgroup
    if [ -r "$root/cpu.max" ]; then
        version=2
        stats="$root/cpu.stat"
    else
        version=1
        cpu="$root/cpu"
        acct="$root/cpuacct"
        [ -r "$cpu/cpu.stat" ] || cpu="$root/cpu,cpuacct"
        [ -r "$acct/cpuacct.usage" ] || acct="$cpu"
        stats="$cpu/cpu.stat"
    fi
}

sample() {
    read -r observed _ < /proc/uptime
    usage=
    periods=
    nr_throttled=
    throttled=
    while read -r key value _; do
        case "$key" in
            usage_usec) usage=$value ;;
            nr_periods) periods=$value ;;
            nr_throttled) nr_throttled=$value ;;
            throttled_usec|throttled_time) throttled=$value ;;
        esac
    done < "$stats"
    if [ "$version" = 1 ]; then
        read -r usage < "$acct/cpuacct.usage"
    fi
    : "${usage:?missing CPU usage}" "${periods:?missing CPU periods}" \
        "${nr_throttled:?missing throttled periods}" "${throttled:?missing throttle time}"
    read -r sampled _ < /proc/uptime
    printf '%s %s %s %s %s %s %s %s\n' \
        "$1" "$2" "$observed" "$sampled" "$usage" "$periods" "$nr_throttled" "$throttled"
}
"""

COMPILE_SCRIPT = CLOCK_SCRIPT + CGROUP_SCRIPT + r"""
set -eu
export GOMAXPROCS=1
work=/tmp/micropod-dense
mkdir -p "$work"
printf '%s' "$1" > "$work/source.go"
cgroup_paths
if [ "$version" = 2 ]; then
    read -r quota period < "$root/cpu.max"
    read -r memory < "$root/memory.max"
else
    read -r quota < "$cpu/cpu.cfs_quota_us"
    read -r period < "$cpu/cpu.cfs_period_us"
    read -r memory < "$root/memory/memory.limit_in_bytes"
fi
affinity=$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/1/status)
scope=$(clock_scope)
{
    printf 'limits %s %s %s %s %s %s\n' "$version" "$quota" "$period" "$memory" "$affinity" "$scope"
    sha256sum /mpw/compile "$work/source.go"
} > "$work/identity"
exec 3>"$work/samples"
completed=0
sample "$completed" - >&3
while :; do
    read -r compile_start _ < /proc/uptime
    /mpw/compile -c 1 -p micropod/dense -o "$work/dense.o" "$work/source.go"
    completed=$((completed + 1))
    sample "$completed" "$compile_start" >&3
done
"""

READBACK_SCRIPT = r"""
set -eu
work=/tmp/micropod-dense
[ -s "$work/samples" ] || exit 75
cat "$work/identity"
tail -n 2 "$work/samples"
"""

TRACE_SCRIPT = CGROUP_SCRIPT + r"""
set -eu
work=/tmp/micropod-dense
cat "$work/identity" "$work/samples"
# Put the later CPU-only sample on its own line even if cat saw a partial append.
printf '\n'
cgroup_paths
sample - -
"""

FOREGROUND_SCRIPT = CLOCK_SCRIPT + r"""
set -eu
scope=$(clock_scope)
read -r before _ < /proc/uptime
"$@"
read -r after _ < /proc/uptime
printf 'micropod-dense-clock %s %s %s\n' "$scope" "$before" "$after" >&2
"""

# Record the current compiler supervisor mask alongside the initial identity.
# The compiler inherits this mask, and no measured command changes affinity.
SPREAD_AFFINITY_SCRIPT = r"""
set -eu
while read -r key value _; do
    if [ "$key" = Cpus_allowed_list: ]; then
        printf 'affinity %s\n' "$value"
        break
    fi
done < /proc/1/status
"""

NATIVE_GROUP_NETWORK_SCRIPT = r"""
eth0=absent
while read -r field _; do
    case "$field" in eth0:*) eth0=present ;; esac
done < /proc/1/net/dev
printf 'eth0 %s\n' "$eth0"
"""


def parse_compiler_spread_cpus(value):
    if value is None:
        return ()
    cpus = tuple(cpu.strip() for cpu in value.split(",")) if isinstance(value, str) else ()
    if (not 1 <= len(cpus) <= CONTAINERS or len(set(cpus)) != len(cpus)
            or any(not re.fullmatch(r"0|[1-9][0-9]*", cpu) for cpu in cpus)):
        raise ValueError(f"compiler spread requires 1 to {CONTAINERS} distinct comma-separated CPU IDs")
    return cpus


def validate_native_compiler_groups(spread):
    if not spread or CONTAINERS % len(spread):
        raise ValueError(f"native compiler groups require a spread CPU count that evenly divides {CONTAINERS}")


def compiler_quota_us(period_us):
    if type(period_us) is not int or not 16_000 <= period_us <= 1_000_000 or period_us % CPU_DENOMINATOR:
        raise ValueError("compiler period must be a multiple of 16 µs between 16000 and 1000000 µs")
    return period_us // CPU_DENOMINATOR


@dataclass(frozen=True)
class GuestClock:
    boot_id: str
    offset_ns: int

    @classmethod
    def parse(cls, boot_id, seconds, nanos):
        offset_nanos = int(nanos)
        if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", boot_id):
            raise ValueError("invalid guest boot ID")
        if not 0 <= offset_nanos < 10**9:
            raise ValueError("invalid guest clock offset")
        return cls(boot_id, int(seconds) * 10**9 + offset_nanos)

    def uptime_ns(self, text):
        if not re.fullmatch(r"[0-9]+\.[0-9]{2}", text):
            raise ValueError("expected guest uptime in centiseconds")
        seconds, cents = map(int, text.split("."))
        ns = seconds * 10**9 + cents * UPTIME_RESOLUTION_NS - self.offset_ns
        if ns < 0:
            raise ValueError("negative normalized guest uptime")
        return ns


def foreground_window(output, elapsed_s, host_start_ns, host_end_ns):
    """Bracket netbench's measured interval using its legacy elapsed_s."""
    markers = [line.split()[1:] for line in output.splitlines() if line.startswith("micropod-dense-clock ")]
    if len(markers) != 1 or len(markers[0]) != 5:
        raise ValueError("expected one guest TCP clock bracket")
    if type(elapsed_s) not in (int, float) or not math.isfinite(elapsed_s) or elapsed_s <= 0:
        raise ValueError("invalid measured TCP elapsed time")
    boot_id, seconds, nanos, start, end = markers[0]
    clock = GuestClock.parse(boot_id, seconds, nanos)
    lower = clock.uptime_ns(start)
    end_floor = clock.uptime_ns(end)
    upper = end_floor + UPTIME_RESOLUTION_NS
    # Round the reported duration down by one ns to preserve a conservative core.
    duration = math.floor(elapsed_s * 10**9) - 1
    if end_floor < lower or duration <= 0 or duration > upper - lower:
        raise ValueError("measured TCP elapsed time does not fit the guest clock bracket")
    latest_start, earliest_end = upper - duration, lower + duration
    return {
        "guest_boot_id": clock.boot_id,
        "namespace_boottime_offset_ns": clock.offset_ns,
        "guest_outer_window_ns": [lower, upper],
        "guest_inner_window_ns": [latest_start, earliest_end] if latest_start < earliest_end else None,
        "host_exec_window_ns": [host_start_ns, host_end_ns],
        "netbench_elapsed_s": elapsed_s,
    }


@dataclass(frozen=True)
class Sample:
    completed_compiles: int | None
    compile_start_ns: int | None
    observed_ns: int
    sample_end_ns: int
    cpu_usage_ns: int
    nr_periods: int
    nr_throttled: int
    throttled_ns: int

    @classmethod
    def parse(cls, line, clock, version):
        count, start, observed, end, usage, periods, nr_throttled, throttled = line.split()
        completed = None if count == "-" else int(count)
        compile_start = None if start == "-" else clock.uptime_ns(start)
        observed_ns = clock.uptime_ns(observed)
        end_ns = clock.uptime_ns(end) + UPTIME_RESOLUTION_NS
        usage, periods, nr_throttled, throttled = map(int, (usage, periods, nr_throttled, throttled))
        if (min(usage, periods, nr_throttled, throttled) < 0 or end_ns <= observed_ns
                or nr_throttled > periods or completed is not None and completed < 0
                or (completed is not None and completed > 0) != (compile_start is not None)
                or compile_start is not None and compile_start > observed_ns):
            raise ValueError("invalid sample counters or event time")
        scale = 1000 if version == 2 else 1
        return cls(completed, compile_start, observed_ns, end_ns, usage * scale, periods,
                   nr_throttled, throttled * scale)


COUNTERS = ("cpu_usage_ns", "nr_periods", "nr_throttled", "throttled_ns")


def validate_samples(samples):
    """Validate complete event counts and cumulative cgroup accounting."""
    if len(samples) < 3 or samples[0].completed_compiles != 0 or samples[-1].completed_compiles is not None:
        raise ValueError("missing initial worker, completion, or final CPU sample")
    for index, sample in enumerate(samples[:-1]):
        if sample.completed_compiles != index:
            raise ValueError("lost or duplicated compile completion record")
    for left, right in zip(samples, samples[1:]):
        if (left.observed_ns > right.observed_ns or left.sample_end_ns > right.sample_end_ns
                or right.compile_start_ns is not None
                and right.compile_start_ns < left.sample_end_ns - UPTIME_RESOLUTION_NS
                or any(getattr(left, counter) > getattr(right, counter) for counter in COUNTERS)):
            raise ValueError("non-monotonic worker measurements")


def align_worker(samples, window):
    outer_start, outer_end = window["guest_outer_window_ns"]
    inner = window["guest_inner_window_ns"]
    before = next((i for i in reversed(range(len(samples)))
                   if samples[i].sample_end_ns <= outer_start), None)
    after = next((i for i, sample in enumerate(samples) if sample.observed_ns >= outer_end), None)
    inside = [sample for sample in samples if inner is not None
              and sample.observed_ns >= inner[0] and sample.sample_end_ns <= inner[1]]

    def counter_bounds(counter):
        lower = getattr(inside[-1], counter) - getattr(inside[0], counter) if inside else 0
        upper = (getattr(samples[after], counter) - getattr(samples[before], counter)
                 if before is not None and after is not None else None)
        return [lower, upper]

    completed = [sample for sample in samples if sample.compile_start_ns is not None]
    # Count completed compiles that must fit entirely in the TCP window, and
    # those whose start-to-observation interval could have contained completion.
    confirmed = sum(inner is not None and sample.compile_start_ns >= inner[0]
                    and sample.observed_ns + UPTIME_RESOLUTION_NS <= inner[1] for sample in completed)
    possible = sum(sample.compile_start_ns < outer_end
                   and sample.observed_ns + UPTIME_RESOLUTION_NS > outer_start for sample in completed)
    # One still-unreported iteration may be in flight when collection starts.
    if not completed or completed[-1].sample_end_ns - UPTIME_RESOLUTION_NS < outer_end:
        possible += 1
    delivered = sum(inner is not None and sample.observed_ns >= inner[0]
                    and sample.observed_ns + UPTIME_RESOLUTION_NS <= inner[1] for sample in completed)
    possible_delivered = sum(sample.observed_ns < outer_end
                             and sample.observed_ns + UPTIME_RESOLUTION_NS > outer_start
                             for sample in completed)
    # No post-window timestamp from the compiler itself can bound a report
    # pending while the last trace line was being appended.
    if not completed or completed[-1].observed_ns < outer_end:
        possible_delivered += 1
    return {
        "cpu_sample_indices_before_after": [before, after],
        "cpu_sample_gaps_ns": [
            outer_start - samples[before].sample_end_ns if before is not None else None,
            samples[after].observed_ns - outer_end if after is not None else None,
        ],
        "completed_compiles_bounds": [confirmed, possible],
        "reported_completions_bounds": [delivered, possible_delivered],
        **{counter + "_bounds": counter_bounds(counter) for counter in COUNTERS},
    }


class DenseCompileLoad:
    def __init__(self, docker, workspace, *, compiler_cpus=None, image=None, compiler_period_us=CPU_PERIOD_US,
                 compiler_spread_cpus=None, native_compiler_groups=False):
        if compiler_cpus is not None and compiler_spread_cpus is not None:
            raise ValueError("compiler_cpus and compiler_spread_cpus are mutually exclusive")
        self.docker = docker
        self.workspace = workspace
        self.compiler_cpus = compiler_cpus
        self.compiler_spread_cpus = parse_compiler_spread_cpus(compiler_spread_cpus)
        spread = self.compiler_spread_cpus
        if native_compiler_groups:
            validate_native_compiler_groups(spread)
        self.native_compiler_groups = native_compiler_groups
        self.worker_masks = [spread[i % len(spread)] if spread else compiler_cpus for i in range(CONTAINERS)]
        self.image = image
        self.period_us = compiler_period_us
        self.quota_us = compiler_quota_us(self.period_us)
        compiler = workspace / "compile"
        if not compiler.is_file() or not os.access(compiler, os.X_OK):
            raise ValueError(f"dense compile requires an executable Linux ARM64 compiler at {compiler}")
        self.compiler_sha256 = hashlib.sha256(compiler.read_bytes()).hexdigest()
        self.source_sha256 = hashlib.sha256(SOURCE.encode()).hexdigest()

    def _owned_ids(self, sock, label):
        result = self.docker(sock, "ps", "--all", "--no-trunc", "--filter", f"label={label}",
                             "--format", "{{.ID}}", timeout=20)
        ids = result.stdout.splitlines()
        if any(not re.fullmatch("[0-9a-f]{64}", identifier) for identifier in ids):
            raise RuntimeError("unexpected container identity in dense compile scope")
        return ids

    def _start(self, sock, label, prefix, groups):
        toolchain = [self.image] if self.image else ["-v", f"{self.workspace}:/mpw:ro", "alpine:3.23"]

        def start(i):
            mask = self.worker_masks[i]
            placement = ["--cpuset-cpus", mask] if mask else []
            if groups:
                placement = ["--label", f"{CPU_GROUP_LABEL}={groups[i]}"]
            result = self.docker(
                sock, "run", "--detach", "--rm", "--pull=never", "--network", "none",
                "--label", label, "--name", f"{prefix}-{i:02d}", "--memory", "128m",
                "--cpu-quota", str(self.quota_us), "--cpu-period", str(self.period_us), *placement,
                *toolchain, "sh", "-c", COMPILE_SCRIPT, "dense", SOURCE,
                timeout=45,
            )
            return result.stdout.strip()

        with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
            ids = list(pool.map(start, range(CONTAINERS)))
        self._verify_scope(sock, label, ids)
        return ids

    def _verify_scope(self, sock, label, ids):
        owned = self._owned_ids(sock, label)
        if len(owned) != CONTAINERS or len(set(ids)) != CONTAINERS or set(ids) != set(owned):
            raise RuntimeError("dense compile scope does not match the 32 launched containers")

    def _inspect_groups(self, sock, ids, label, prefix, groups):
        response = self.docker(sock, "inspect", "--type", "container", *ids, timeout=30)
        owner_key, owner_value = label.split("=", 1)
        records = []
        try:
            rows = json.loads(response.stdout)
            indexed = {row["Id"]: row for row in rows}
            if len(rows) != CONTAINERS or set(indexed) != set(ids):
                raise ValueError("inspection does not match the launched IDs")
            for index, (identifier, group) in enumerate(zip(ids, groups)):
                row = indexed[identifier]
                labels = row["Config"]["Labels"]
                host, state = row["HostConfig"], row["State"]
                started, cpuset = state["StartedAt"], host["CpusetCpus"]
                if (row["Name"] != f"/{prefix}-{index:02d}" or labels.get(owner_key) != owner_value
                        or labels.get(CPU_GROUP_LABEL) != group or host["NetworkMode"] != "none"
                        or state["Running"] is not True or not isinstance(started, str)
                        or not started or started.startswith("0001-") or cpuset not in self.compiler_spread_cpus):
                    raise ValueError(f"worker {identifier} did not report its owned offline CPU group and singleton mask")
                records.append({"cpu_group": group, "engine_assigned_cpu": int(cpuset), "started_at": started})
        except (AttributeError, KeyError, TypeError, ValueError) as exc:
            raise RuntimeError(f"invalid native compile group inspection: {exc}") from exc
        actual = Counter(record["engine_assigned_cpu"] for record in records)
        expected = dict.fromkeys(map(int, self.compiler_spread_cpus), CONTAINERS // len(self.compiler_spread_cpus))
        if dict(actual) != expected:
            raise RuntimeError(f"native compiler groups are unbalanced: observed {dict(actual)}, expected {expected}")
        return records

    def _read_worker(self, sock, identifier, expected_mask, *, trace=False):
        short = identifier[:12]
        script = TRACE_SCRIPT if trace else READBACK_SCRIPT
        if self.native_compiler_groups:
            script = NATIVE_GROUP_NETWORK_SCRIPT + script
        if self.compiler_spread_cpus:
            script = SPREAD_AFFINITY_SCRIPT + script
        result = self.docker(sock, "exec", identifier, "sh", "-c", script,
                             timeout=20, check=False)
        if not trace and result.returncode == 75:
            return 0
        if result.returncode:
            raise RuntimeError(f"dense compiler {short} readback failed: {result.stderr.strip()}")
        try:
            lines = iter(result.stdout.splitlines())
            live_mask = None
            if self.compiler_spread_cpus:
                kind, live_mask = next(lines).split()
                if kind != "affinity":
                    raise ValueError("missing live CPU mask")
            if self.native_compiler_groups and next(lines) != "eth0 absent":
                raise ValueError("offline native compiler has eth0 or missing network evidence")
            header, compiler, source, *rows = lines
            kind, version, quota, period, memory, allowed_cpus, *clock_fields = header.split()
            version, quota, period, memory = map(int, (version, quota, period, memory))
            if kind != "limits" or version not in (1, 2):
                raise ValueError("invalid cgroup version or limit record")
            clock = GuestClock.parse(*clock_fields)
        except (StopIteration, TypeError, ValueError) as exc:
            raise RuntimeError(f"invalid dense compile identity from {short}: {exc}") from exc
        if (quota, period) != (self.quota_us, self.period_us):
            raise RuntimeError(f"dense compiler {short} quota is {quota} {period}")
        if memory != MEMORY_BYTES:
            raise RuntimeError(f"dense compiler {short} memory limit is {memory}")
        if expected_mask and allowed_cpus != expected_mask:
            raise RuntimeError(f"dense compiler {short} can run on CPUs {allowed_cpus}, expected {expected_mask}")
        if live_mask is not None and live_mask != expected_mask:
            raise RuntimeError(f"dense compiler {short} live CPU mask is {live_mask}, expected {expected_mask}")
        if (compiler != f"{self.compiler_sha256}  /mpw/compile"
                or source != f"{self.source_sha256}  /tmp/micropod-dense/source.go"):
            raise RuntimeError(f"dense compiler {short} used unexpected inputs")
        try:
            if trace:
                # TRACE_SCRIPT inserts a newline before the final CPU sample.
                # The final event row may have been in the middle of its write.
                event_rows, final_row = rows[:-2], rows[-1]
                samples = [Sample.parse(line, clock, version) for line in [*event_rows, final_row]]
                validate_samples(samples)
                record = {
                    "id": identifier,
                    "cgroup_version": version,
                    "cpu_quota_us": quota,
                    "cpu_period_us": period,
                    "memory_limit_bytes": memory,
                    "allowed_cpus": allowed_cpus,
                    "guest_boot_id": clock.boot_id,
                    "namespace_boottime_offset_ns": clock.offset_ns,
                }
                if self.native_compiler_groups:
                    record.update({"eth0_present": False, "live_allowed_cpus": live_mask})
                elif self.compiler_spread_cpus:
                    record["requested_cpu"] = int(expected_mask)
                return record, samples
            # tail can race one append. Its previous complete row still attests progress.
            if not result.stdout.endswith("\n"):
                rows.pop()
            return Sample.parse(rows[-1], clock, version).completed_compiles if rows else 0
        except (IndexError, ValueError) as exc:
            raise RuntimeError(f"invalid dense compile samples from {short}: {exc}") from exc

    def _snapshot(self, sock, ids, masks, *, trace=False):
        with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
            return list(pool.map(lambda identifier, mask: self._read_worker(sock, identifier, mask, trace=trace),
                                 ids, masks))

    def _await_progress(self, sock, ids, masks, previous):
        deadline = time.monotonic() + 45
        while True:
            started = time.monotonic_ns()
            counts = self._snapshot(sock, ids, masks)
            if all(current > old for current, old in zip(counts, previous)):
                return counts, (started, time.monotonic_ns())
            if time.monotonic() >= deadline:
                stalled = [identifier[:12] for identifier, current, old in zip(ids, counts, previous) if current <= old]
                raise RuntimeError(f"dense compile counters stalled for {', '.join(stalled)}")
            time.sleep(0.15)

    def _cleanup(self, sock, label):
        def remove(identifier):
            try:
                result = self.docker(sock, "rm", "-f", identifier, timeout=25, check=False)
                return result.stderr.strip() if result.returncode else ""
            except (OSError, subprocess.TimeoutExpired) as exc:
                return str(exc)

        with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
            errors = [error for error in pool.map(remove, self._owned_ids(sock, label)) if error]
        if remaining := self._owned_ids(sock, label):
            raise RuntimeError(f"dense compile scope {label} left containers {remaining}. {'; '.join(errors)}")

    def measure(self, sock, benchmark):
        token = uuid.uuid4().hex
        label = f"com.micropod.benchmark.dense={token}"
        prefix = f"mpb-dense-{token[:10]}"
        groups = [f"{token}-{i:02d}" for i in range(CONTAINERS)] if self.native_compiler_groups else []
        try:
            ids = self._start(sock, label, prefix, groups)
            group_records = self._inspect_groups(sock, ids, label, prefix, groups) if groups else []
            masks = [str(record["engine_assigned_cpu"]) for record in group_records] if groups else self.worker_masks
            ready, _ = self._await_progress(sock, ids, masks, [0] * CONTAINERS)
            before, first = self._await_progress(sock, ids, masks, ready)
            suite_start = time.monotonic_ns()
            result = benchmark()
            suite_end = time.monotonic_ns()
            traces = self._snapshot(sock, ids, masks, trace=True)
            trace_end = time.monotonic_ns()
            after = [samples[-2].completed_compiles for _, samples in traces]
            tail = self._snapshot(sock, ids, masks)
            if self.compiler_spread_cpus:
                self._verify_scope(sock, label, ids)
            if groups and self._inspect_groups(sock, ids, label, prefix, groups) != group_records:
                raise RuntimeError("native compiler group identity or process generation changed during the benchmark")
            windows = result.get("raw", {}).get("bulk_guest_windows", [])
            workers = []
            for (record, samples), r, b, a, t in zip(traces, ready, before, after, tail):
                if t < a or a < b:
                    raise RuntimeError(f"dense compiler {record['id']} reset its counters")
                if any(window["guest_boot_id"] != record["guest_boot_id"] for window in windows):
                    raise RuntimeError(f"dense compiler {record['id']} used a different guest clock than TCP")
                workers.append({
                    **record, "ready": r, "before": b, "after": a, "tail": t,
                    "samples": [asdict(sample) for sample in samples],
                    "foreground": [align_worker(samples, window) for window in windows],
                })
            for worker, record in zip(workers, group_records):
                worker.update(record)
            foreground = []
            for i, window in enumerate(windows):
                aligned = [worker["foreground"][i] for worker in workers]
                totals = {}
                for field in ("completed_compiles", "reported_completions", *COUNTERS):
                    key = field + "_bounds"
                    lower, upper = zip(*(worker[key] for worker in aligned))
                    totals[key] = [sum(lower), None if None in upper else sum(upper)]
                foreground.append({
                    **window, **totals,
                    "workers_with_confirmed_completions": sum(w["completed_compiles_bounds"][0] > 0 for w in aligned),
                    "workers_with_no_possible_completion": sum(w["completed_compiles_bounds"][1] == 0 for w in aligned),
                    "workers_with_confirmed_reported_progress": sum(w["reported_completions_bounds"][0] > 0 for w in aligned),
                    "workers_with_no_possible_reported_completion": sum(w["reported_completions_bounds"][1] == 0 for w in aligned),
                    "workers_with_cpu_brackets": sum(None not in w["cpu_sample_indices_before_after"] for w in aligned),
                })
            completed = sum(after) - sum(before)
            elapsed_min = (suite_end - first[1]) / 1e9
            elapsed_max = (trace_end - first[0]) / 1e9
            result["dense_compile"] = {
                "scope": label,
                "compiler_sha256": self.compiler_sha256,
                "source_sha256": self.source_sha256,
                "launch_concurrency": CONCURRENCY,
                "requested_compiler_cpus": self.compiler_cpus,
                "compiler_image": self.image,
                "cpu_quota_us": self.quota_us,
                "cpu_period_us": self.period_us,
                "memory_limit_bytes": MEMORY_BYTES,
                "guest_clock": "linux-boottime",
                "guest_clock_resolution_ns": UPTIME_RESOLUTION_NS,
                "sample_trigger": "successful compile and final readback",
                "suite_host_window_ns": [suite_start, suite_end],
                "counter_window_s": [round(elapsed_min, 5), round(elapsed_max, 5)],
                "compile_count_delta": completed,
                "compiles_per_second_bounds": [round(completed / elapsed_max, 2), round(completed / elapsed_min, 2)],
                "foreground": foreground,
                "workers": workers,
            }
            if self.compiler_spread_cpus:
                result["dense_compile"].update({
                    "compiler_placement": "native-cpu-group" if groups else "explicit-cpuset",
                    "compiler_network": "none",
                    "requested_compiler_spread_cpus": [int(cpu) for cpu in self.compiler_spread_cpus],
                    "compiler_workers_per_cpu": dict(Counter(worker["allowed_cpus"] for worker in workers)),
                })
            return result
        finally:
            self._cleanup(sock, label)
