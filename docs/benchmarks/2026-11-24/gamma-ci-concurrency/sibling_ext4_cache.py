"""Compare only the loop-backed native Go cache's ext4 block size on a 16 KiB guest."""

import argparse
import hashlib
import json
import re
import shutil
import signal
import struct
import tarfile
import tempfile
import time
from contextlib import ExitStack, nullcontext
from datetime import UTC, datetime
from pathlib import Path
from statistics import median
from unittest.mock import patch

import sibling_build
import sibling_ci
import sibling_group
import sibling_tmpfs
from qualify import HERE, LABEL, fanout, require, terminal


TOOL_INDEX = "73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8"
TOOL_MANIFEST = "c92376659a7f14cc1f51615d73c9f4b7d8e18d59f370e02b4ed683ab4485c66c"
TOOL_CONFIG = "50ec654248113cf5966e8fcbde7acd5a49a943c9ee9d92512f3a20b6be54b5d7"
TOOL_LAYER = "0c72064db2470cf0efa5fa1935125d317d0c2f6d95855143ae6a816ce4b20b56"
STORE = Path.home() / "Library/Application Support/com.apple.container/content/blobs/sha256"
PROGRAMS = ("usr/bin/fallocate", "usr/bin/getconf", "usr/bin/sync", "usr/sbin/mke2fs", "usr/sbin/dumpe2fs",
            "usr/sbin/e2fsck", "usr/sbin/losetup")
LIBRARIES = ("ld-linux-aarch64.so.1", "libc.so.6", "libext2fs.so.2", "libcom_err.so.2", "libblkid.so.1",
             "libuuid.so.1", "libe2p.so.2", "libsmartcols.so.1")
TOOLS = {**{f"bin/{Path(name).name}": name for name in PROGRAMS},
         **{f"lib/{name}": f"usr/lib/aarch64-linux-gnu/{name}" for name in LIBRARIES},
         "mke2fs.conf": "etc/mke2fs.conf"}
FILESYSTEM_BYTES = 512 << 20
GROUP_BYTES = 128 << 20
INODES = 16384
FEATURES = set(("has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file "
                "huge_file dir_nlink extra_isize metadata_csum").split())
MOUNT_OPTIONS = {"rw", "data=ordered", "barrier", "commit=5", "max_batch_time=15000"}
CACHE_DEVICE = re.compile(r"7:[0-9]+")
CACHE_OBJECT = re.compile(r"[a-f0-9]{64}-d")
VOLUME_PREFIX = "/var/lib/micropod/engine/volumes/"
OVERLAY_PROFILE = "125us-overlay"
TMPFS_PROFILE = "250us-tmpfs"
PROFILES = {OVERLAY_PROFILE: ("hrtick-125us", None), TMPFS_PROFILE: ("hrtick-250us", "tmpfs")}
OBSERVER = r'''
printf 'boot=%s\npage_bytes=%s\nuid=%s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$(getconf PAGESIZE)" "$(id -u)"
printf 'block_bytes=%s\ncache_inode=%s\n' "$(stat -f -c %S /cache)" "$(stat -c %d:%i /cache)"
printf 'gocache=%s\ngomodcache=%s\nscratch=%s\n' "$GOCACHE" "$GOMODCACHE" "${TMPDIR:-/tmp}"
awk '$5 == "/" || $5 == "/cache" || $5 == "/tmp" {print "mount " $0}' /proc/self/mountinfo
awk '{print "cpu." $1 "=" $2}' /sys/fs/cgroup/cpu.stat
if [ -n "$1" ]; then
    printf 'loop_stat=%s\n' "$(cat "/sys/dev/block/$1/stat")"
fi
if [ "$2" = tmpfs ]; then
    printf 'memory_max=%s\n' "$(cat /sys/fs/cgroup/memory.max)"
    if [ "$3" = A ]; then
        printf 'scratch_geometry=%s\n' "$(stat -f -c '%S %b' /tmp)"
        printf 'scratch_mode=%s\n' "$(stat -c '%a' /tmp)"
    fi
fi
'''
CACHE_PROBE = r'''
archive="/cache/build/$1/$2"
module=/cache/mod/cache/download/github.com/opencontainers/runtime-spec/@v/v1.3.0.zip
test -f "$archive" && test -f "$module"
printf 'archive_inode=%s\nmodule_inode=%s\n' "$(stat -c %d:%i "$archive")" "$(stat -c %d:%i "$module")"
printf 'archive_sha256=%s\nmodule_sha256=%s\n' "$(sha256sum "$archive" | cut -d ' ' -f1)" "$(sha256sum "$module" | cut -d ' ' -f1)"
find /cache/build -type f -name '*-d' -exec stat -c '%n %s' {} +
'''


def require_native_elf(data):
    require(data[:6] == b"\x7fELF\x02\x01" and struct.unpack_from("<H", data, 18)[0] == 183,
            "tool is not little-endian arm64 ELF")
    offset, = struct.unpack_from("<Q", data, 32)
    length, count = struct.unpack_from("<HH", data, 54)
    headers = [struct.unpack_from("<IIQQQQQQ", data, offset + i * length) for i in range(count)]
    loads = [row for row in headers if row[0] == 1]
    require(loads and all(row[-1] >= 16384 and (row[2] - row[3]) % 16384 == 0 for row in loads),
            "tool has segments incompatible with the 16 KiB guest")
    dynamic, = (row for row in headers if row[0] == 2)
    entries = list(struct.iter_unpack("<QQ", data[dynamic[2]:dynamic[2] + dynamic[5]]))
    string_address, = (value for tag, value in entries if tag == 5)
    segment, = (row for row in loads if row[3] <= string_address < row[3] + row[5])
    string_offset = segment[2] + string_address - segment[3]
    dependencies = {data[string_offset + value:].partition(b"\0")[0].decode("ascii")
                    for tag, value in entries if tag == 1}
    require(dependencies <= set(LIBRARIES), f"unpinned tool libraries: {dependencies - set(LIBRARIES)}")


def stage_tools(destination=None, store=STORE):
    def verify(sha, descriptor=None):
        blob = store / sha
        require(blob.is_file() and terminal.digest(blob) == sha, f"missing or corrupt pinned tool blob {sha}")
        if descriptor is not None:
            require(descriptor["digest"] == "sha256:" + sha and blob.stat().st_size == descriptor["size"],
                    "unexpected OCI tool descriptor")
        return blob

    index = json.loads(verify(TOOL_INDEX).read_bytes())
    arm, = [m for m in index["manifests"] if m.get("platform", {}).get("os") == "linux"
            and m["platform"]["architecture"] == "arm64"]
    manifest = json.loads(verify(TOOL_MANIFEST, arm).read_bytes())
    config = json.loads(verify(TOOL_CONFIG, manifest["config"]).read_bytes())
    require(config["architecture"] == "arm64" and config["os"] == "linux", "pinned tool platform differs")
    descriptor, = manifest["layers"]
    blob = verify(TOOL_LAYER, descriptor)
    result = {"index": TOOL_INDEX, "manifest": TOOL_MANIFEST, "config": TOOL_CONFIG, "layer": TOOL_LAYER, "files": {}}
    with tarfile.open(blob, "r:gz") as layer:
        for output, source in TOOLS.items():
            member = layer.getmember(source)
            if member.issym():
                require(output.startswith("lib/") and re.fullmatch(r"[a-zA-Z0-9_.-]+", member.linkname),
                        "unexpected tool library link")
                member = layer.getmember(str(Path(source).with_name(member.linkname)))
            require(member.isfile(), "unexpected tool archive entry")
            data = layer.extractfile(member).read()
            if output != "mke2fs.conf":
                require_native_elf(data)
            result["files"][output] = {"tar_path": member.name, "sha256": hashlib.sha256(data).hexdigest()}
            if destination is not None:
                path = destination / output
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                path.chmod(0o644 if output == "mke2fs.conf" else 0o755)
    return result


def parse_superblock(raw, block):
    fields = dict(line.split(":", 1) for line in raw.splitlines() if ":" in line)
    fields = {name: value.strip() for name, value in fields.items()}
    require(int(fields["Block size"]) == block and int(fields["Block count"]) * block == FILESYSTEM_BYTES
            and int(fields["Blocks per group"]) * block == GROUP_BYTES and int(fields["Inode count"]) == INODES
            and fields["Inode size"] == "256" and fields["Reserved block count"] == "0"
            and fields["Filesystem state"] == "clean" and set(fields["Filesystem features"].split()) == FEATURES
            and fields["Default mount options"].split() == ["user_xattr", "acl"]
            and fields["Total journal size"] == "16M" and re.fullmatch(sibling_tmpfs.BOOT_ID, fields["Filesystem UUID"]),
            "offline ext4 capacity, journal, geometry or feature set differs")
    return {"uuid": fields["Filesystem UUID"], "used_bytes": FILESYSTEM_BYTES - int(fields["Free blocks"]) * block,
            "used_inodes": INODES - int(fields["Free inodes"])}


def block_io(raw):
    stats = [int(field) for field in raw.split()]
    require(len(stats) >= 17 and min(stats) >= 0, "incomplete loop block statistics")
    return {"reads": stats[0], "read_bytes": stats[2] * 512, "writes": stats[4],
            "write_bytes": stats[6] * 512, "flushes": stats[15]}


def deltas(before, after):
    require(set(before) == set(after), "readback counters differ")
    result = {key: after[key] - before[key] for key in before}
    require(all(v >= 0 for v in result.values()), "readback counter moved backward")
    return result


def validate_volume(inspect, owner, name):
    require(name == owner + "-a-grouped-go" and inspect["Name"] == name and inspect["Driver"] == "local"
            and inspect["Labels"].get(LABEL) == owner and inspect["Mountpoint"] == VOLUME_PREFIX + name,
            "did not create the intended labeled native cache volume")


def validate_mounted(raw, block, owner, boot):
    values, mounts = sibling_tmpfs.read_fields(raw)
    target = VOLUME_PREFIX + owner + "-a-grouped-go"
    require(set(mounts) == {target}, "wrong guest cache mountpoint")
    mount = mounts[target]
    require(values["boot"] == boot and values["page_bytes"] == "16384" and int(values["block_bytes"]) == block
            and values["image"] == f"/var/lib/micropod/engine/{owner}-ext4-cache/cache.img"
            and int(values["image_bytes"]) == FILESYSTEM_BYTES and int(values["image_sectors"]) * 512 >= FILESYSTEM_BYTES
            and int(values["logical_sector_bytes"]) == 512 and values["loop_direct_io"] == "0"
            and CACHE_DEVICE.fullmatch(mount["device"])
            and mount["fs"] == "ext4" and mount["root"] == "/" and mount["source"] == values["loop"]
            and values["loop"] == "/dev/loop" + mount["device"].split(":")[1]
            and {"rw", "nosuid", "nodev"} <= set(mount["options"]) and "rw" in mount["super_options"],
            "guest loop backing file, device, or ext4 mount does not match the treatment")
    block_io(values["loop_stat"])
    return values, mount


def validate_mount_options(text):
    options = set(text.splitlines())
    require(MOUNT_OPTIONS <= options and not {"nobarrier", "dioread_nolock", "discard"} & options,
            "unexpected ext4 journal, direct I/O or discard settings")
    return sorted(options)


def validate_ready(raw):
    values, mounts = sibling_tmpfs.read_fields(raw)
    require(not mounts and values["page_bytes"] == "16384" and values["loop_control"] == "a:ed",
            "guest page size or loop-control device differs")
    return values["boot"]


def validate_retirement(retired, release, owner, boot):
    result, mounts = sibling_tmpfs.read_fields(retired)
    accepted, release_mounts = sibling_tmpfs.read_fields(release)
    controller = owner + "-ext4-cache-retire"
    require(accepted == {"boot": boot, "controller": controller} and not release_mounts
            and result["boot"] == boot and result["controller"] == controller
            and result["clean"] == "true" and not mounts, "loop mount or its retirement controller did not retire cleanly")
    return result


def check_profile(settings, plan):
    profile = settings.get("profile", OVERLAY_PROFILE)
    require(profile in PROFILES, "unknown ext4 cache profile")
    require(("profile" in settings) == ("ext4_cache_profile" in plan)
            and plan.get("ext4_cache_profile", OVERLAY_PROFILE) == profile,
            "ext4 cache profile differs from the workload plan")
    scheduler, scratch = PROFILES[profile]
    require(plan["worker_scheduler"] == scheduler and plan.get("build_scratch") == scratch,
            "ext4 cache profile has different worker scheduling or compiler scratch")
    return profile


def check_loop_scratch_jobs(check, active, rows, inventory, work, arm, mode, boot, worker_mounts):
    if arm != "A":
        return check(rows, inventory, work, arm, mode, boot, worker_mounts)
    guest, loop = active()
    require(guest["boot"] == boot and worker_mounts["/"]["device"] != loop["device"],
            "scratch proof has a different boot or uses the guest root as cache")
    # The shared scratch verifier takes the expected backing mount at "/".
    # Its separate boot check still reads the real guest root mount.
    results = check(rows, inventory, work, arm, mode, boot, {"/": loop})
    require(all(row["cache_inode"] == guest["cache_inode"] and row["cache_root"] == "/" for row in results),
            "scratch builders do not share the verified ext4 loop cache")
    return results


def scratch_proof(profile, active):
    if profile != TMPFS_PROFILE:
        return nullcontext()
    original = sibling_tmpfs.check_jobs
    return patch.object(sibling_tmpfs, "check_jobs", lambda *args: check_loop_scratch_jobs(original, active, *args))


def check_sample(rows, jobs, arm, boot, active=None, profile=OVERLAY_PROFILE):
    require(len(rows) == len(jobs) == 8, "missing builder samples")
    with_tmpfs = arm == "A" and profile == TMPFS_PROFILE
    expected_mounts = {"/", "/cache", "/tmp"} if with_tmpfs else {"/", "/cache"}
    cpu = []
    io = None
    caches = set()
    scratch_devices = set()
    for slot, (row, job) in enumerate(zip(rows, jobs, strict=True)):
        values, mounts = sibling_tmpfs.read_fields(row["raw"])
        mount = mounts["/cache"]
        require(row["id"] == job["id"] and values["boot"] == boot and values["uid"] == "0"
                and values["page_bytes"] == ("16384" if arm == "A" else "4096") and values["scratch"] == "/tmp"
                and values["gocache"] == "/cache/build" and values["gomodcache"] == "/cache/mod"
                and set(mounts) == expected_mounts and mounts["/"]["fs"] == "overlay" and "rw" in mount["options"],
                "builder changed boot, scratch mount, or Go cache")
        if profile == TMPFS_PROFILE:
            require(values["memory_max"] == str(512 << 20), "builder memory limit differs")
        if with_tmpfs:
            tmp = mounts["/tmp"]
            sibling_tmpfs.check_tmpfs(tmp)
            page, blocks = map(int, values["scratch_geometry"].split())
            require(page * blocks == sibling_tmpfs.SIZE_KIB * 1024 and values["scratch_mode"] == "1777"
                    and "rw" in tmp["super_options"] and "ro" not in tmp["super_options"]
                    and tmp["device"] not in {mount["device"], mounts["/"]["device"]},
                    "wrong private scratch capacity, mode, or device")
            scratch_devices.add(tmp["device"])
        else:
            require("noexec" not in mounts["/"]["options"], "overlay scratch must allow executable builds")
        caches.add((values["cache_inode"], mount["device"]))
        if arm == "A":
            guest, native = active
            require(values["cache_inode"] == guest["cache_inode"] and values["block_bytes"] == guest["block_bytes"]
                    and mount["device"] == native["device"] and mount["fs"] == "ext4" and mount["root"] == "/"
                    and mount["super_options"] == native["super_options"] and mounts["/"]["device"] != mount["device"],
                    "builder is not using the private ext4 loop filesystem")
        else:
            require(mount["fs"] == "btrfs", "OrbStack reference must retain its standard cache")
        require(("loop_stat" in values) == (arm == "A" and slot == 0), "unexpected loop I/O sampling scope")
        if "loop_stat" in values:
            io = block_io(values["loop_stat"])
        cpu.append({key: int(values["cpu." + key]) for key in ("usage_usec", "user_usec", "system_usec")})
    require(len(caches) == 1, "builders do not share one cache inode")
    require(not with_tmpfs or len(scratch_devices) == len(jobs), "builder scratch devices are not private")
    return cpu, io


def check_cache(raw, prime):
    lines = raw.splitlines()
    values = dict(line.split("=", 1) for line in lines[:4])
    require(values["archive_inode"] == prime["dependency_inode"] and values["module_inode"] == prime["module_inode"]
            and all(re.fullmatch(r"[0-9a-f]{64}", values[name]) for name in ("archive_sha256", "module_sha256")),
            "primed artifacts were not reused")
    objects = {}
    for line in lines[4:]:
        path, size = line.split()
        name = Path(path).name
        require(CACHE_OBJECT.fullmatch(name) and path == f"/cache/build/{name[:2]}/{name}" and name not in objects,
                "unexpected Go cache data object")
        objects[name] = int(size)
    require(prime["dependency"] in objects and len(objects) >= 100 and min(objects.values()) >= 0,
            "compiler cache was not primed")
    return {**values, "objects": dict(sorted(objects.items())), "data_bytes": sum(objects.values())}


class CacheStudy:
    def __init__(self, folder, block, tools, profile=OVERLAY_PROFILE):
        self.folder, self.block, self.tools = folder, block, tools
        self.profile = profile
        self.volume_ready = False
        self.active = None
        self.primes = {}

    def stage(self, stage, root, files):
        work, oci, clients = stage(root, files)
        self.records = work / "ext4-cache-records"
        self.control = work / "ext4-cache-control"
        for directory in (self.records, self.control):
            directory.mkdir(mode=0o700)
        selected = stage_tools(oci / "runner/ext4-cache-tools")
        require(selected == self.tools, "pinned tool bytes changed during staging")
        source = Path(__file__).with_name("sibling_ext4_cache_guest.sh")
        shutil.copyfile(source, oci / "runner/ext4-cache.sh")
        shutil.copyfile(source, self.folder / source.name)
        shutil.copyfile(__file__, self.folder / Path(__file__).name)
        with (oci / "runner/fixture-facts.sh").open("a") as hook:
            hook.write(f'\nsh /opt/micropod-oci/runner/ext4-cache.sh "$MICROPOD_ENGINE_WORKSPACE" {root.name} {self.block}'
                       ' </dev/null >"$MICROPOD_ENGINE_WORKSPACE/ext4-cache-records/helper.log" 2>&1 &\n')
        terminal.save(self.folder / "ext4-cache-plan.json",
                      {"block_bytes": self.block, "worker_page_bytes": 16384, "image_bytes": FILESYSTEM_BYTES,
                       "profile": self.profile,
                       "tools": selected, "guest_helper_sha256": terminal.digest(source),
                       "driver_sha256": terminal.digest(Path(__file__))})
        return work, oci, clients

    def wait(self, name):
        deadline = time.monotonic() + 60
        while not (self.records / name).is_file():
            if (self.records / "error").exists() or time.monotonic() >= deadline:
                for source in self.records.iterdir():
                    if source.is_file():
                        shutil.copyfile(source, self.folder / ("ext4-cache-" + source.name))
                log = self.records / "helper.log"
                raise ValueError(f"private ext4 cache helper did not reach {name}: {log.read_text()[-1600:] if log.exists() else ''}")
            time.sleep(.1)
        target = self.folder / ("ext4-cache-" + name)
        shutil.copyfile(self.records / name, target)
        return target.read_text()

    def request(self, cohort, action):
        label = cohort.owner + "-ext4-cache-" + action
        try:
            cohort.cmd("run", "--rm", "--pull=never", "--name", label, "--network", "none",
                       "--memory", "64m", "--pids-limit", "24", "--cpus", "1", "--label", f"{LABEL}={cohort.owner}",
                       "--mount", f"type=bind,src={self.control},dst=/control", "--entrypoint", "/bin/sh",
                       sibling_build.IMAGE, "-ec", 'test -p /control/request; printf "%s\\n" "$1" >/control/request',
                       "ext4-cache", action, timeout=20)
        finally:
            rows = json.loads(terminal.invoke(*cohort.engine, "inspect", label, check=False, timeout=8).stdout or "[]")
            if rows:
                row, = rows
                require(row["Name"].lstrip("/") == label and row["Config"]["Labels"].get(LABEL) == cohort.owner,
                        "ambiguous cache controller cleanup")
                terminal.invoke(*cohort.engine, "rm", "-f", row["Id"], check=False, timeout=10)
            require(not cohort.cmd("ps", "-aq", "--no-trunc", "--filter", f"name={label}", timeout=8),
                    "retirement controller still holds its control mount")
        return label

    def retire(self, cohort):
        controller = self.request(cohort, "retire")
        # The acknowledgment lives outside the controller's bind mount.
        release = self.records / "control-release"
        temp = release.with_suffix(".tmp")
        with temp.open("x") as handoff:
            handoff.write(f"boot={self.boot}\ncontroller={controller}\n")
        temp.replace(release)
        validate_retirement(self.wait("retired"), self.wait("control-release"), cohort.owner, self.boot)

    def volume(self, original, cohort, create):
        if cohort.arm == "B":
            return original(cohort, create)
        name = cohort.network + "-go"
        if create:
            self.boot = validate_ready(self.wait("ready"))
            original(cohort, create)
            row, = json.loads(cohort.cmd("volume", "inspect", name))
            validate_volume(row, cohort.owner, name)
            terminal.save(self.folder / "ext4-cache-volume.json", row)
            self.request(cohort, "prepare")
            mounted = self.wait("mounted")
            self.volume_ready = True
            self.active = validate_mounted(mounted, self.block, cohort.owner, self.boot)
            parse_superblock(self.wait("initial-superblock.txt"), self.block)
            validate_mount_options(self.wait("mount-options.txt"))
            self.wait("mkfs.log")
        elif self.volume_ready:
            self.retire(cohort)
            self.wait("final-superblock.txt")
            self.wait("fsck.txt")
            original(cohort, create)
            terminal.save(self.folder / "ext4-cache-removed.json", {"name": name, "removed": True})

    def prime(self, original, cohort):
        raw = original(cohort)
        row = fanout.parse_job(raw, 0)
        self.primes[cohort.arm] = row
        self.cache(cohort, "prime")
        return raw

    def cache(self, cohort, phase):
        job = self.builders(cohort)[0]
        prime = self.primes[cohort.arm]
        name = prime["dependency"]
        require(CACHE_OBJECT.fullmatch(name), "bad primed dependency cache object name")
        raw = cohort.cmd("exec", job["id"], "/bin/sh", "-ec", CACHE_PROBE, "cache", name[:2], name)
        check_cache(raw, prime)
        (self.folder / f"ext4-cache-{phase}-{cohort.arm}.txt").write_text(raw + "\n")

    def builders(self, cohort):
        return cohort.jobs[cohort.count:cohort.count + cohort.builders]

    def sample(self, cohort):
        device = self.active[1]["device"] if cohort.arm == "A" else ""
        _, scratch = PROFILES[self.profile]
        jobs = self.builders(cohort)

        def observe(slot_job):
            slot, job = slot_job
            raw = cohort.cmd("exec", job["id"], "/bin/sh", "-ec", OBSERVER, "observation",
                             device if slot == 0 else "", scratch or "", cohort.arm)
            return {"id": job["id"], "raw": raw}

        rows = sibling_ci.parallel(8, observe, enumerate(jobs))
        check_sample(rows, jobs, cohort.arm, self.primes[cohort.arm]["boot"], self.active, self.profile)
        return rows

    def wave(self, original, cohort, folder, block, indices, requests, dense_ms, offered_rps=None):
        if len(indices) == 1:
            return original(cohort, folder, block, indices, requests, dense_ms, offered_rps)
        before = self.sample(cohort)
        result = original(cohort, folder, block, indices, requests, dense_ms, offered_rps)
        after = self.sample(cohort)
        terminal.save(folder / f"ext4-cache-wave-{block}-{cohort.arm}.json", {"before": before, "after": after})
        return result

    def clean(self, original, cohort):
        try:
            if cohort.arm in self.primes:
                self.cache(cohort, "final")
        finally:
            original(cohort)


def reserve_in_order(original, width, fn, items):
    if width != 8 or fn.__qualname__ != "Siblings.create.<locals>.start":
        return original(width, fn, items)
    batch = list(items)
    # Creation is outside the timing. Deterministic native reservations keep
    # every job and the paced send order on the same vCPU across fresh boots.
    servers = [item for item in batch if item[0] < 32]
    clients = [item for item in batch if item[0] >= 32]
    return [fn(item) for item in servers] + original(width, fn, clients)


def live(args):
    tools = stage_tools()
    sources = [args.product, args.page_kernel_pair, args.ipvlan_kernel, args.quiet_source]
    if args.image_archive:
        sources.append(args.image_archive)
    for source in sources:
        require(source.exists(), f"missing pinned fixture input {source}")
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-sibling-ext4-"), dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    run = CacheStudy(folder, args.block_kib * 1024, tools, args.profile)
    scheduler, scratch = PROFILES[args.profile]
    profile = argparse.Namespace(
        product=args.product.resolve(), page_kernel_pair=args.page_kernel_pair.resolve(),
        ipvlan_kernel=args.ipvlan_kernel.resolve(), quiet_source=args.quiet_source.resolve(),
        image_archive=args.image_archive.resolve() if args.image_archive else None,
        seed=args.seed, rounds=args.rounds, layouts=["grouped"],
        page_kib=16, tick_kernel=None, mthp_kernel=None, mthp_64k=None, buddy_kernel=None,
        process_type="Standard", worker_scheduler=scheduler, worker_next_buddy=True, guest_fair=None,
        network_driver="ipvlan", network_topology="per-job", cpu_groups=True, pairs=32, requests=200,
        builders=8, build_nice=0, build_slice_us=None, build_policy=None, build_scratch=scratch,
        dense_ms=1500, offered_rps=64_000, slice_us=None, slice_target="all", builder_shares=None,
        timer_counters=False, trace_sockets=False, job_network_smoke=False, ipam_route_product=None,
    )
    stage, volume, prime = terminal.stage, sibling_build.volume, sibling_build.prime
    stage_build = sibling_build.stage
    wave, clean, parallel, create = sibling_ci.Siblings.run_wave, sibling_ci.Siblings.clean, sibling_ci.parallel, sibling_ci.Siblings.create

    def create_fixed(cohort):
        if cohort.arm != "A":
            return create(cohort)
        with patch.object(sibling_ci, "parallel", lambda *a: reserve_in_order(parallel, *a)):
            result = create(cohort)
        require(result["placement"]["groups"] == {sibling_group.group_name(i): str(i % 4) for i in range(32)},
                "native job placement differs from the fixed cache experiment")
        return result

    status = {"complete": False}
    try:
        with terminal.terminal_lock():
            with ExitStack() as hooks:
                hooks.enter_context(patch.object(terminal, "stage", lambda *a: run.stage(stage, *a)))
                hooks.enter_context(patch.object(sibling_build, "volume", lambda *a: run.volume(volume, *a)))
                hooks.enter_context(patch.object(sibling_build, "prime", lambda *a: run.prime(prime, *a)))
                hooks.enter_context(patch.object(sibling_build, "stage", lambda *a, **kw: {
                    **stage_build(*a, **kw), "ext4_cache_profile": args.profile,
                }))
                hooks.enter_context(patch.object(sibling_ci.Siblings, "create", create_fixed))
                hooks.enter_context(patch.object(sibling_ci.Siblings, "run_wave", lambda *a: run.wave(wave, *a)))
                hooks.enter_context(patch.object(sibling_ci.Siblings, "clean", lambda *a: run.clean(clean, *a)))
                hooks.enter_context(scratch_proof(args.profile, lambda: run.active))
                sibling_ci.study(folder, profile)
            verify_archive(folder)
        status["complete"] = True
    except BaseException as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", status)


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def verify_archive(folder):
    settings = read(folder, "ext4-cache-plan.json")
    plan = read(folder, "plan.json")
    profile = check_profile(settings, plan)
    block = settings["block_bytes"]
    require(block in (4096, 16384) and settings["image_bytes"] == FILESYSTEM_BYTES and settings["worker_page_bytes"] == 16384
            and settings["tools"] == stage_tools() and plan["network_topology"] == "per-job"
            and plan["pages"]["kernel_page_kib"] == 16 and plan["builders"] == 8 and plan["layouts"] == ["grouped"]
            and plan["offered_rps"] == 64_000 and plan["worker_next_buddy"] and plan["build_nice"] == 0,
            "cache experiment inputs differ")
    for name, field in (("sibling_ext4_cache.py", "driver_sha256"), ("sibling_ext4_cache_guest.sh", "guest_helper_sha256")):
        require(terminal.digest(folder / name) == settings[field], "archived cache driver or guest helper differs")
    owner = Path(plan["scope"]).name
    name = owner + "-a-grouped-go"
    validate_volume(read(folder, "ext4-cache-volume.json"), owner, name)
    require(read(folder, "ext4-cache-removed.json") == {"name": name, "removed": True}, "native cache volume remains")
    boots = {arm: fanout.parse_job(line, 0) for arm, line in read(folder, "grouped-prime.json").items()}
    boot = boots["A"]["boot"]
    require("boot=" + boot in (folder / "a/guest-facts.txt").read_text().splitlines()
            and boot == validate_ready((folder / "ext4-cache-ready").read_text()), "wrong guest boot for the cache")
    initial = parse_superblock((folder / "ext4-cache-initial-superblock.txt").read_text(), block)
    final = parse_superblock((folder / "ext4-cache-final-superblock.txt").read_text(), block)
    check = (folder / "ext4-cache-fsck.txt").read_text()
    require(initial["uuid"] == final["uuid"] and initial["used_bytes"] < final["used_bytes"]
            and initial["used_inodes"] < final["used_inodes"] and all("Pass " + str(i) in check for i in range(1, 6)),
            "cache bytes and inodes were not committed to the retired volume")
    active = validate_mounted((folder / "ext4-cache-mounted").read_text(), block, owner, boot)
    options = validate_mount_options((folder / "ext4-cache-mount-options.txt").read_text())
    retired = validate_retirement((folder / "ext4-cache-retired").read_text(),
                                  (folder / "ext4-cache-control-release").read_text(), owner, boot)
    inventory = read(folder, "grouped-inventory.json")
    if profile == TMPFS_PROFILE:
        with scratch_proof(profile, lambda: active):
            sibling_tmpfs.verify_archived(folder, plan, inventory)
    jobs = {arm: inventory[arm]["jobs"][32:40] for arm in "AB"}
    raw_windows = read(folder, "windows.json")
    windows = []
    for arm in "AB":
        prime = boots[arm]
        cache = {phase: check_cache((folder / f"ext4-cache-{phase}-{arm}.txt").read_text(), prime)
                 for phase in ("prime", "final")}
        require(all(cache["prime"][name] == cache["final"][name] for name in ("archive_sha256", "module_sha256"))
                and set(cache["prime"]["objects"].items()) <= set(cache["final"]["objects"].items()),
                "compiler cache data changed or disappeared")
        boots[arm]["data"] = cache
    for i in range(plan["rounds"]):
        window = raw_windows[f"grouped-{i}-all"]
        output = {"order": window["order"]}
        for arm in "AB":
            build = window[arm]["build"]
            rows = read(folder, f"grouped-{i}-all-{arm}-go.json")
            revisions = [fanout.parse_job(line, 0) for row in rows for line in row["stdout"].splitlines()[:2]]
            require(len(revisions) == 16 and build["jobs"] == len(rows) == 8 and build["test_passes"] == 128
                    and build["products"] == [r["product"] for r in revisions]
                    and all(all(r[key] == boots[arm][key] for key in ("dependency_inode", "module_inode", "dependency", "boot"))
                            for r in revisions), "timed jobs did not reuse the primed compiler cache")
            sample = read(folder, f"ext4-cache-wave-{i}-{arm}.json")
            before, after = [check_sample(sample[phase], jobs[arm], arm, boots[arm]["boot"], active, profile)
                             for phase in ("before", "after")]
            cpu = [deltas(x, y) for x, y in zip(before[0], after[0], strict=True)]
            output[arm] = {**{key: window[arm][key] for key in ("requests", "p95_us", "p99_us", "service_p95_us", "service_p99_us")},
                           "makespan_s": build["makespan_s"], "products": build["products"],
                           "go_actions": {key: sum(row[key] for row in revisions) for key in ("compile", "vet", "link")},
                           "builder_container_cpu_us": {key: sum(job[key] for job in cpu) for key in cpu[0]}}
            if arm == "A":
                output["A"]["loop"] = deltas(before[1], after[1])
                if i + 1 == plan["rounds"]:
                    sync = block_io(retired["sync_stat"])
                    output["after_last_window_to_sync_loop"] = deltas(after[1], sync)
                    output["unmount_loop"] = deltas(sync, block_io(retired["unmount_stat"]))
        require(output["A"]["products"] == output["B"]["products"] and
                output["A"]["requests"] == output["B"]["requests"] == 96_000, "engine work differs")
        windows.append(output)
    return {"block_bytes": block, "profile": profile, "boot": boot, "peer_boot": boots["B"]["boot"], "mount_options": options,
            "active_cache": active,
            "experiment": {k: v for k, v in settings.items() if k != "block_bytes"},
            "outer_root_block_bytes": int(active[0]["root_block_bytes"]),
            "committed": {"initial": initial, "final": final},
            "cache": {arm: boots[arm]["data"] for arm in "AB"}, "windows": windows, "plan": plan}


def compare(folders):
    import sibling_paced_results

    runs_to_replay = [(folder, verify_archive(folder)) for folder in folders]
    profiles = {run["profile"] for _, run in runs_to_replay}
    require(len(profiles) == 1, "ext4 cache comparison requires a single workload profile")
    profile = profiles.pop()
    grouped = {}
    identity = None
    for folder, run in runs_to_replay:
        with scratch_proof(profile, lambda: run["active_cache"]):
            scored = sibling_paced_results.replay(folder)
        require(scored["boot"] == run["boot"] and scored["peer_boot"] == run["peer_boot"], "paced replay boot identity differs")
        inputs = {k: scored[k] for k in ("worker", "images", "placements", "peer_boot")}
        inputs["plan"] = {k: v for k, v in run["plan"].items() if k not in ("scope", "seed")}
        require(identity is None or identity == inputs, "ext4 cache comparison changed worker, peer, placement, or workload")
        identity = inputs
        runs = grouped.setdefault(run["plan"]["seed"], {})
        require(run["block_bytes"] not in runs, "duplicate ext4 block size and seed")
        run.update(worker=scored["worker"], images=scored["images"], placement=scored["placements"])
        runs[run["block_bytes"]] = run
    comparisons = []
    for seed, runs in sorted(grouped.items()):
        require(set(runs) == {4096, 16384}, "each seed needs a fresh 4 KiB and 16 KiB volume")
        control, candidate = runs[4096], runs[16384]
        require(control["boot"] != candidate["boot"] and control["peer_boot"] == candidate["peer_boot"]
                and control["committed"]["final"]["uuid"] != candidate["committed"]["final"]["uuid"]
                and all(control[key] == candidate[key] for key in
                        ("worker", "images", "placement", "mount_options", "experiment", "outer_root_block_bytes"))
                and {k: v for k, v in control["plan"].items() if k != "scope"}
                == {k: v for k, v in candidate["plan"].items() if k != "scope"}, "paired firmware, profile, images or placement differ")
        for arm in "AB":
            for phase in ("prime", "final"):
                c, n = (r["cache"][arm][phase] for r in (control, candidate))
                require(all(c[key] == n[key] for key in ("archive_sha256", "module_sha256", "objects")),
                        "cache contents or apparent bytes differ across block-size treatments")
        pairs = []
        for c, n in zip(control["windows"], candidate["windows"], strict=True):
            require(c["order"] == n["order"] and c["A"]["products"] == n["A"]["products"], "paired build work or order differs")
            pairs.append({"control": c, "candidate": n})
        comparisons.append({"seed": seed, "control_boot": control["boot"], "candidate_boot": candidate["boot"],
                            "committed_4k": control["committed"], "committed_16k": candidate["committed"], "pairs": pairs})
    pairs = [pair for group in comparisons for pair in group["pairs"]]
    keys = ("makespan_s", "p95_us", "p99_us", "service_p95_us", "service_p99_us")
    ratios = {arm: {key: median(p["candidate"][arm][key] / p["control"][arm][key] for p in pairs)
                    for key in keys} for arm in "AB"}
    for arm in "AB":
        cpu = "builder_container_cpu_us"
        ratios[arm][cpu] = {key: median(p["candidate"][arm][cpu][key] / p["control"][arm][cpu][key] for p in pairs)
                            for key in ("usage_usec", "user_usec", "system_usec")}
    peer_relative = median((p["candidate"]["A"]["makespan_s"] / p["candidate"]["B"]["makespan_s"]) /
                           (p["control"]["A"]["makespan_s"] / p["control"]["B"]["makespan_s"]) for p in pairs)
    return {"profile": profile, "median_candidate_over_control": ratios, "median_peer_relative_build_makespan_ratio": peer_relative,
            "comparisons": comparisons}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("tools", help="verify arm64 e2fsprogs closure from the local OCI content store")
    score = commands.add_parser("compare", help="replay archived trials without booting")
    score.add_argument("folders", nargs="+", type=Path)
    trial = commands.add_parser("run", help="run one privately scoped Gamma trial")
    trial.add_argument("--profile", choices=tuple(PROFILES), default=OVERLAY_PROFILE,
                       help="native worker slice and scratch profile (default: %(default)s)")
    trial.add_argument("--block-kib", required=True, type=int, choices=(4, 16))
    trial.add_argument("--seed", required=True, type=int)
    trial.add_argument("--rounds", type=int, choices=(1, 4, 8), default=4)
    for name in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        trial.add_argument("--" + name, required=True, type=Path)
    trial.add_argument("--image-archive", type=Path,
                       help="reuse an existing pinned Go image export; otherwise read the peer's retained local image")
    args = parser.parse_args()
    if args.command == "run":
        live(args)
    else:
        print(json.dumps(stage_tools() if args.command == "tools" else compare(args.folders), indent=2))


if __name__ == "__main__":
    main()
