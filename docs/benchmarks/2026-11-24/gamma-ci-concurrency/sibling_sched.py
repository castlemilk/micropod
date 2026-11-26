"""Set one Linux fair-scheduler feature inside a disposable Micropod guest and verify its readback."""
import shutil

from qualify import require, terminal


FEATURES = {"inherit": (None, None), "bounded-buddy": ("BOUNDED_BUDDY", None),
            "hrtick": ("HRTICK", None), "no-run-to-parity": ("NO_RUN_TO_PARITY", None),
            "no-delay-dequeue": ("NO_DELAY_DEQUEUE", None), "no-place-lag": ("NO_PLACE_LAG", None),
            "next-buddy": ("NEXT_BUDDY", None), "no-hrtick": ("NO_HRTICK", None),
            "base-500us": (None, 500000), "base-250us": (None, 250000),
            "base-125us": (None, 125000), "base-100us": (None, 100000), "base-62500ns": (None, 62500),
            "hrtick-1000us": ("HRTICK", 1000000), "hrtick-500us": ("HRTICK", 500000)}
WORKER = {"inherit": 2100000, "hrtick": 2100000, "hrtick-1ms": 1000000, "hrtick-500us": 500000,
          "hrtick-250us": 250000, "hrtick-125us": 125000}


def stage(oci, folder, feature):
    token, base = FEATURES[feature]
    script = r'''
(
    dir="$MICROPOD_ENGINE_WORKSPACE/fair-scheduler"
    mkdir -p "$dir"
    debug=/sys/kernel/debug
    sched="$debug/sched"
    grep -q " $debug debugfs " /proc/mounts || mount -t debugfs debugfs "$debug" 2>"$dir/mount.err" || :
    if [ -r "$sched/features" ]; then
        cat "$sched/features" > "$dir/before"
        cat "$sched/base_slice_ns" > "$dir/base-before"
        if [ -n 'SELECTED' ]; then printf '%s' 'SELECTED' > "$sched/features" || exit 1; fi
        if [ -n 'BASE_NS' ]; then printf '%s' 'BASE_NS' > "$sched/base_slice_ns" || exit 1; fi
        cat "$sched/features" > "$dir/after"
        cat "$sched/base_slice_ns" > "$dir/base-slice"
    else
        ls "$debug" > "$dir/debug-files"
    fi
    cat /proc/self/schedstat > "$dir/boot-thread-schedstat"
    cat /proc/sys/kernel/task_delayacct > "$dir/task-delayacct" 2>/dev/null || :
    grep -E 'arch_timer|timer' /proc/interrupts > "$dir/timer-interrupts" || :
    cat /sys/devices/system/clocksource/clocksource0/current_clocksource > "$dir/clocksource"
    cat /proc/cmdline > "$dir/cmdline"
)
'''.replace("SELECTED", token or "").replace("BASE_NS", str(base) if base else "")
    with (oci / "runner/fixture-facts.sh").open("a") as f:
        f.write(script)
    (folder / "fair-scheduler.sh").write_text(script)


def read(directory, feature, worker=None, next_buddy=False):
    require((directory / "before").is_file(), "the guest kernel does not expose scheduler features in debugfs")
    before = sorted((directory / "before").read_text().split())
    after = sorted((directory / "after").read_text().split())
    base = int((directory / "base-slice").read_text())
    token, requested_base = FEATURES[feature]
    expected = set(before)
    if token:
        other = token.removeprefix("NO_") if token.startswith("NO_") else "NO_" + token
        require(other in expected and token not in expected, f"{feature} is already selected")
        expected.remove(other)
        expected.add(token)
    baseline = int((directory / "base-before").read_text()) if (directory / "base-before").exists() else base
    inherited = WORKER[worker] if worker else 2100000
    require(len(before) == len(after) == len(expected) and set(after) == expected and baseline == inherited
            and base == (requested_base or baseline),
            "unexpected scheduler feature or base slice")
    if worker:
        cmdline = (directory / "cmdline").read_text().split()
        tokens = [v for v in cmdline if v.startswith("micropod.ci_sched=")]
        wake = [v for v in cmdline if v.startswith("micropod.ci_wakeup=")]
        require(("HRTICK" in before) == (worker != "inherit") and
                ("NEXT_BUDDY" in before) == next_buddy and "PICK_BUDDY" in before and
                wake == (["micropod.ci_wakeup=next-buddy"] if next_buddy else []) and
                tokens == ([] if worker == "inherit" else ["micropod.ci_sched=" + worker]),
                "production guest boot argument or effective tick selection differs")
    return {"setting": feature, "before": before, "after": after, "base_slice_ns": base,
            "clocksource": (directory / "clocksource").read_text().strip()}


def verify(work, folder, feature, worker=None, next_buddy=False):
    directory = folder / "fair-scheduler"
    shutil.copytree(work / "fair-scheduler", directory)
    receipt = read(directory, feature, worker, next_buddy)
    terminal.save(folder / "fair-scheduler.json", receipt)
    return receipt
