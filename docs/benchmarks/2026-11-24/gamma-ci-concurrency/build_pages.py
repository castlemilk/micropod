"""Verify matched arm64 page-size builds, OCI mappings and per-command Linux resource usage."""

import gzip
import hashlib
import json
import re
import shutil
from statistics import median
from math import ceil

from qualify import HERE, IMAGE, ROOT, fanout, require, terminal
import kernel_candidate


PHASES = ("vet", "test", "build", "list")
TOTALS = ("user_usec", "system_usec", "minor_faults", "major_faults", "voluntary_switches",
          "involuntary_switches", "input_blocks", "output_blocks")
PAGE_PROBE = ROOT / "scripts/netbench/pagecompat/main.go"
PROFILES = {4: "full", 16: "full-16k"}
SOURCE_SHA = "8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990"
BASE_CONFIG = "a5dfc1ee37dcd4bc6d727e4de617bc45a40cf32e7ebc52fb6f0472c8fbf60c21"
# Kconfig dependencies resolved by Linux 7.3.5 from the two ARM64_*K_PAGES selectors.
PAGE_CHANGES = {
    "ARCH_FORCE_MAX_ORDER": ("10", "11"), "ARCH_MMAP_RND_BITS_MAX": ("33", "31"),
    "ARCH_MMAP_RND_BITS_MIN": ("18", "16"), "ARCH_MMAP_RND_COMPAT_BITS_MIN": ("11", "9"),
    "ARCH_WANTS_THP_SWAP": ("y", None), "ARM64_16K_PAGES": ("n", "y"), "ARM64_4K_PAGES": ("y", "n"),
    "ARM64_CONT_PMD_SHIFT": ("4", "5"), "ARM64_CONT_PTE_SHIFT": ("4", "7"),
    "ARM64_VA_BITS_36": (None, "n"), "ARM64_VA_BITS_39": ("n", None), "ARM64_VA_BITS_47": (None, "n"),
    "HAVE_PAGE_SIZE_16KB": (None, "y"), "HAVE_PAGE_SIZE_4KB": ("y", None), "PAGE_SHIFT": ("12", "14"),
    "PAGE_SIZE_16KB": (None, "y"), "PAGE_SIZE_4KB": ("y", None),
}


def stage(work, sources, env, *, pages, accounting):
    extra = {}
    tools = {}
    if pages:
        tools["pagecompat"] = PAGE_PROBE
        sources.extend((ROOT / "ci/build-worker-kernel.sh", ROOT / "scripts/relaybench/kernel_candidate.py"))
    if accounting:
        tools["build-usage"] = HERE / "build_usage_linux.go"
        body = fanout.JOB
        for phase in PHASES:
            call = f"go {phase} "
            require(body.count(call) == 1, "unrecognized Go workload")
            body = body.replace(call, "/mpcheck/build-usage " + call)
        (work / "job-accounted.sh").write_text(body)
        extra["accounted_job_sha256"] = terminal.digest(work / "job-accounted.sh")
    for name, source in tools.items():
        sources.append(source)
        terminal.invoke("go", "build", "-trimpath", "-o", work / name, source, env=env, timeout=180)
        extra[name.replace("-", "_") + "_sha256"] = terminal.digest(work / name)
    return extra


def validate_usage(rows, revision):
    expected = [(f"{revision}-{suffix}", phase) for suffix in "ab" for phase in PHASES]
    require([(r["revision"], r["stage"]) for r in rows] == expected, "missing or reordered Go commands")
    for row in rows:
        require(all(type(row[k]) is int and row[k] >= 0 for k in TOTALS)
                and row["wall_usec"] > 0 and row["max_rss_kib"] > 0
                and row["user_usec"] + row["system_usec"] > 0, "invalid Go command usage")


def archive_builder(directory, inputs, folder):
    frozen = directory / "build-worker-kernel.sh"
    source = frozen if frozen.is_file() else ROOT / "ci/build-worker-kernel.sh"
    require(terminal.digest(source) == inputs["builder_sha256"], "kernel builder source differs")
    shutil.copy2(source, folder / "kernel-builder.sh")


def builder_digest(folder, plan):
    saved = folder / "kernel-builder.sh"
    return terminal.digest(saved) if saved.is_file() else plan["sources"]["ci/build-worker-kernel.sh"]


def select(directory, kib, files, folder):
    directory = directory.resolve()
    inputs = json.loads((directory / "build-inputs.json").read_bytes())
    require(inputs["profile_order"] == list(PROFILES.values()) and inputs["source_sha256"] == SOURCE_SHA
            and inputs["config_sha256"] == BASE_CONFIG,
            "kernel build inputs differ")
    archive_builder(directory, inputs, folder)
    builder = json.loads((directory / "build-container.json").read_bytes())
    require(builder["image"] == inputs["alpine_image"] and builder["env"]["JOBS"] == str(inputs["jobs"])
            and all(builder["env"].get("KBUILD_BUILD_" + k) for k in ("USER", "HOST", "VERSION", "TIMESTAMP")),
            "kernel build environment differs")
    pair = kernel_candidate.compare(directory / "full", directory / "full-16k", 4, 16)
    expected = {"CONFIG_" + key: list(vals) for key, vals in PAGE_CHANGES.items()}
    require(pair["config_changes"] == expected, f"unexpected Kconfig changes: {pair['config_changes']}")
    for size, profile in PROFILES.items():
        require((directory / profile / "release").read_text().strip() == "7.3.5-micropod", "wrong kernel release")
        desc = pair["control" if size == 4 else "candidate"]
        require(desc["embedded_config_verified"], "kernel lacks a verified embedded config")
        config = (directory / profile / "config").read_bytes()
        (folder / f"kernel-config-{size}k.gz").write_bytes(gzip.compress(config, mtime=0))
    shutil.copyfile(directory / "toolchain.txt", folder / "kernel-toolchain.txt")
    pair.update(inputs=inputs, build_container=builder,
                host_page_bytes=int(terminal.invoke("sysctl", "-n", "hw.pagesize").stdout),
                toolchain_sha256=terminal.digest(folder / "kernel-toolchain.txt"))
    terminal.save(folder / "kernel-page-pair.json", pair)
    selected = pair["control" if kib == 4 else "candidate"]
    files.update(kernel=directory / PROFILES[kib] / "Image", kernel_config=directory / PROFILES[kib] / "config")
    return {"kernel_page_kib": kib, "kernel_image_sha256": selected["image_sha256"],
            "kernel_config_sha256": selected["config_sha256"]}


def validate_mappings(result, kib):
    page = kib * 1024
    require(result["os"] == "linux" and result["arch"] == "arm64"
            and result["runtime_page_bytes"] == result["linux_at_pagesz"] == page, "wrong live userspace page size")
    require(result["temporary_file_bytes"] == 16384 + page + 17 and result["windows"] == [
        {"offset": offset, "raw_mmap": "matched" if offset % page == 0 else "EINVAL",
         "aligned_base": offset // page * page, "verified_window_bytes": page + 17}
        for offset in (4096, 8192, 12288, 16384)], "wrong offset or private mapping result")


def probe(cohort, kib):
    name = cohort.prefix + "pagecompat"
    scratch = cohort.workspace / ("pagecompat-" + cohort.arm.lower())
    scratch.mkdir()
    cohort.register(name)
    script = '''
        getconf PAGESIZE
        cat /proc/sys/kernel/random/boot_id
        for dst in /tmp /cache /page-fixture; do
            stat -f -c '%T' "$dst"
            /mpcheck/pagecompat -dir "$dst" -expect-page "$1"
        done
    '''
    cid = cohort.cmd("run", "-d", *cohort.job_flags(name), "--network", "none", "--mount",
                     f"type=bind,src={scratch},dst=/page-fixture", "--entrypoint", "/bin/sh",
                     IMAGE, "-ec", script, "sh", str(kib * 1024))
    require(re.fullmatch(r"[0-9a-f]{64}", cid), "invalid page probe container ID")
    exit_code = cohort.cmd("wait", cid)
    log = terminal.invoke(*cohort.engine, "logs", cid)
    require(exit_code == "0", f"page probe exited {exit_code}: {log.stdout} {log.stderr}")
    size, boot, *lines = log.stdout.strip().splitlines()
    require(int(size) == kib * 1024 and len(lines) == 6 and not list(scratch.iterdir()), "incomplete page probe")
    mounts = {}
    for index, dst in enumerate(("/tmp", "/cache", "/page-fixture")):
        actual = json.loads(lines[2*index+1])
        validate_mappings(actual, kib)
        mounts[dst] = {"filesystem": lines[2*index], "mapping": actual}
    terminal.save(cohort.folder / f"kernel-pages-{cohort.arm}.json", {
        "container": cid, "boot": boot, "getconf_page_bytes": int(size), "mounts": mounts})
    cohort.cmd("rm", cid)


def verify_run(folder, plan, fixtures):
    kib = plan["kernel_page_kib"]
    require(kib in PROFILES, "unknown page target")
    pair = json.loads((folder / "kernel-page-pair.json").read_bytes())
    configs = []
    for page, key in ((4, "control"), (16, "candidate")):
        data = gzip.decompress((folder / f"kernel-config-{page}k.gz").read_bytes())
        desc = pair[key]
        require(hashlib.sha256(data).hexdigest() == desc["config_sha256"] and desc["page_kib"] == page
                and desc["embedded_config_verified"], "archived or embedded config differs")
        configs.append(kernel_candidate.config_options(data))
    keys = configs[0].keys() | configs[1].keys()
    diffs = {s: [c.get(s) for c in configs] for s in keys if configs[0].get(s) != configs[1].get(s)}
    require(diffs == pair["config_changes"] == {"CONFIG_" + k: list(v) for k, v in PAGE_CHANGES.items()}
            and pair["inputs"]["source_sha256"] == SOURCE_SHA and pair["inputs"]["config_sha256"] == BASE_CONFIG
            and pair["inputs"]["builder_sha256"] == builder_digest(folder, plan)
            and terminal.digest(folder / "kernel-toolchain.txt") == pair["toolchain_sha256"],
            "kernel provenance or configuration differs")
    selected = pair["control" if kib == 4 else "candidate"]
    return verify_live_kernel(folder, plan, fixtures, kib, selected)


def verify_live_kernel(folder, plan, fixtures, kib, selected):
    facts = (folder / "a/guest-facts.txt").read_text().splitlines()
    require("config_sha256=" + selected["config_sha256"] in facts and "release=7.3.5-micropod" in facts
            and "boot=" + fixtures["A"]["guest_boot"] in facts and plan["kernel_config_sha256"] == selected["config_sha256"]
            and fixtures["A"]["kernel_image_sha256"] == plan["kernel_image_sha256"] == selected["image_sha256"],
            "running Micropod kernel differs from selected build")
    for arm, size in (("A", kib), ("B", 4)):
        row = json.loads((folder / f"kernel-pages-{arm}.json").read_bytes())
        require(row["getconf_page_bytes"] == size * 1024 and row["boot"] == json.loads((folder / f"prime-{arm}.json").read_bytes())["boot"]
                and set(row["mounts"]) == {"/tmp", "/cache", "/page-fixture"}, "wrong live guest mappings")
        for mount in row["mounts"].values():
            require(mount["filesystem"], "missing OCI filesystem")
            validate_mappings(mount["mapping"], size)
    return selected["image_sha256"]


def usage_window(window):
    samples = {phase: [] for phase in PHASES}
    for job in window["jobs"]:
        if job["kind"] == "pass":
            validate_usage(job["go_phases"], job["revision"])
            require(job["memory_peak_bytes"] > 0 and job["memory_oom_events"] == {"oom": 0, "oom_kill": 0},
                    "job memory receipt differs")
            for sample in job["go_phases"]:
                samples[sample["stage"]].append(sample)
        else:
            require("go_phases" not in job, "unsuccessful build has healthy phase measurements")
    require(all(len(rows) == 60 for rows in samples.values()), "expected two revisions in each of 30 healthy jobs")
    return {stage: {**{k: sum(r[k] for r in rows) for k in TOTALS},
                    "median_wall_usec": median(r["wall_usec"] for r in rows),
                    "max_rss_kib": max(r["max_rss_kib"] for r in rows)}
            for stage, rows in samples.items()}


def summarize_usage(rows):
    windows = [usage_window(row) for row in rows]
    peaks = sorted(j["memory_peak_bytes"] for row in rows for j in row["jobs"] if j["kind"] == "pass")
    return {"commands": len(windows) * 60 * len(PHASES), "windows": len(windows),
            "job_memory_peak_bytes": {"median": median(peaks), "p95": peaks[ceil(.95 * len(peaks)) - 1], "max": peaks[-1]},
            "median_per_window": {
                phase: {k: median(w[phase][k] for w in windows) for k in windows[0][phase]} for phase in PHASES}}


def compare_usage(control, candidate, arm):
    windows = [[usage_window(json.loads((d / f"churn-{i}-{arm}.json").read_bytes())) for i in range(8)]
               for d in (control, candidate)]
    result = {}
    for phase in PHASES:
        changes = {}
        for field in windows[0][0][phase]:
            before, after = [[w[phase][field] for w in run] for run in windows]
            differences = [b - a for a, b in zip(before, after, strict=True)]
            changes[field] = {"control": median(before), "candidate": median(after),
                              "median_delta": median(differences), "higher": sum(d > 0 for d in differences),
                              "pairs": len(differences)}
            if all(before):
                changes[field]["median_ratio"] = median(b / a for a, b in zip(before, after, strict=True))
        result[phase] = changes
    return result


def snapshot_vm(cohort, phase):
    """Read guest-wide THP and memory counters outside the timed build and traffic windows."""
    service = cohort.jobs[0]
    script = '''
        cat /proc/sys/kernel/random/boot_id
        thp=/sys/kernel/mm/transparent_hugepage
        if test -r "$thp/enabled"; then cat "$thp/enabled"; else echo unavailable; fi
        awk '$1 ~ /^thp_/ || $1=="pgfault" || $1=="pgmajfault" {print "vmstat",$1,$2}' /proc/vmstat
        awk '$1 ~ /^(AnonHugePages|FilePmdMapped|ShmemPmdMapped|PageTables|KernelStack|MemAvailable|Slab):$/ {
            print "meminfo",substr($1,1,length($1)-1),$2}' /proc/meminfo
        for size in "$thp"/hugepages-*; do
            test -r "$size/enabled" || continue
            echo size "${size##*/}" "$(cat "$size/enabled")"
            for field in anon_fault_alloc shmem_alloc; do
                test -r "$size/stats/$field" || continue
                echo vmstat "${size##*/}:$field" "$(cat "$size/stats/$field")"
            done
        done
    '''
    boot, policy, *lines = cohort.cmd("exec", service["id"], "sh", "-ec", script).splitlines()
    record = {"boot": boot, "service": service["id"], "thp_policy": policy, "sizes": {}, "vmstat": {}, "meminfo_kib": {}}
    for line in lines:
        source, key, value = line.split(maxsplit=2)
        if source == "size":
            record["sizes"][key] = value
        else:
            record["vmstat" if source == "vmstat" else "meminfo_kib"][key] = int(value)
    require(boot == service["identity"]["boot"] and "pgfault" in record["vmstat"]
            and "PageTables" in record["meminfo_kib"], "wrong VM counter source")
    terminal.save(cohort.folder / f"kernel-vm-{cohort.arm}-{phase}.json", record)


def vm_changes(folder, arm):
    before, after = [json.loads((folder / f"kernel-vm-{arm}-{s}.json").read_bytes()) for s in ("before", "after")]
    for key in ("boot", "service", "thp_policy", "sizes"):
        require(before[key] == after[key], "THP source or policy changed during the run")
    require(before["vmstat"].keys() == after["vmstat"].keys(), "guest memory counters changed shape")
    return {"thp_policy": before["thp_policy"], "sizes": before["sizes"],
            "vmstat_delta": {k: after["vmstat"][k] - value for k, value in before["vmstat"].items()},
            "meminfo_before_kib": before["meminfo_kib"], "meminfo_after_kib": after["meminfo_kib"]}
