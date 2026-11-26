import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import sibling_ext4_cache as cache


BOOT = "639003cb-daf8-4022-8738-e34d1f42810b"
OWNER = "mp-t-fixture"
SECTORS = "1 0 4 0 2 0 8 0 0 0 0 0 0 0 0 3 0"


def superblock(block):
    return "\n".join((
        f"Block size: {block}", f"Block count: {cache.FILESYSTEM_BYTES // block}",
        f"Blocks per group: {cache.GROUP_BYTES // block}", "Inode count: 16384", "Inode size: 256",
        "Reserved block count: 0", "Filesystem state: clean", "Default mount options: user_xattr acl",
        "Filesystem features: " + " ".join(sorted(cache.FEATURES)), "Total journal size: 16M",
        "Filesystem UUID: " + BOOT, "Free blocks: 8192", "Free inodes: 15000",
    ))


class Ext4CacheTest(unittest.TestCase):
    def test_only_mkfs_geometry_changes(self):
        source = Path(cache.__file__).with_name("sibling_ext4_cache_guest.sh").read_text()
        command, = (line.split(" > ", 1)[0] for line in source.replace("\\\n", "").splitlines()
                    if line.startswith("run mke2fs "))
        argv = []
        for block in (4096, 16384):
            script = f'block={block}; group_bytes={cache.GROUP_BYTES}; image=disposable.img\n'
            script += "run() { printf '%s\\n' \"$@\"; }\n" + command
            argv.append(subprocess.check_output(["/bin/sh", "-eu", "-c", script], text=True).splitlines())
        expected = ["mke2fs", "-F", "-t", "ext4", "-b", "4096", "-g", "32768", "-I", "256", "-N", "16384", "-m",
                    "0", "-J", "size=16", "-E", "nodiscard,lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0",
                    "disposable.img"]
        self.assertEqual(argv[0], expected)
        expected[5], expected[7] = "16384", "8192"
        self.assertEqual(argv[1], expected)

    def test_superblocks_require_same_byte_geometry_and_features(self):
        for block in (4096, 16384):
            raw = superblock(block)
            self.assertEqual(cache.parse_superblock(raw, block)["used_inodes"], 1384)
            for bad in (raw.replace("16M", "4M"), raw.replace("Inode size: 256", "Inode size: 128"),
                        raw.replace("has_journal", "fast_commit"), raw.replace("clean", "not clean")):
                with self.assertRaises(ValueError):
                    cache.parse_superblock(bad, block)

    def test_effective_policy_is_read_separately_from_mountinfo(self):
        cache.validate_mount_options("rw\nbarrier\ncommit=5\nmax_batch_time=15000\ndata=ordered\n")
        with self.assertRaises(ValueError):
            cache.validate_mount_options("rw\nbarrier\ncommit=5\nmax_batch_time=15000\ndata=writeback\n")
        with self.assertRaises(ValueError):
            cache.validate_ready(f"boot={BOOT}\npage_bytes=4096\nloop_control=a:ed\n")
        target = cache.VOLUME_PREFIX + OWNER + "-a-grouped-go"
        values = f"""boot={BOOT}
page_bytes=16384
block_bytes=16384
loop=/dev/loop3
image=/var/lib/micropod/engine/{OWNER}-ext4-cache/cache.img
image_bytes=536870912
image_sectors=1048584
logical_sector_bytes=512
loop_direct_io=0
root_block_bytes=4096
cache_inode=1795:2
loop_stat={SECTORS}
mount 133 1 7:3 / {target} rw,nosuid,nodev,relatime - ext4 /dev/loop3 rw
"""
        parsed = cache.validate_mounted(values, 16384, OWNER, BOOT)
        self.assertEqual(parsed[1]["device"], "7:3")
        with self.assertRaises(ValueError):
            cache.validate_mounted(values.replace("loop3", "loop4"), 16384, OWNER, BOOT)

    def test_job_sample_uses_only_the_confirmed_loop_device(self):
        stat = f"""boot={BOOT}
page_bytes=16384
uid=0
block_bytes=16384
cache_inode=1795:2
gocache=/cache/build
gomodcache=/cache/mod
scratch=/tmp
mount 12 2 0:81 / / rw,relatime - overlay overlay rw
mount 13 12 7:3 / /cache rw,nosuid,nodev,relatime - ext4 /dev/loop3 rw
cpu.usage_usec=60
cpu.user_usec=40
cpu.system_usec=20
"""
        jobs = [{"id": f"job-{i}"} for i in range(8)]
        rows = [{**job, "raw": stat} for job in jobs]
        rows[0]["raw"] += f"loop_stat={SECTORS}\n"
        active = ({"cache_inode": "1795:2", "block_bytes": "16384"}, {"device": "7:3", "super_options": ["rw"]})
        cpu, io = cache.check_sample(rows, jobs, "A", BOOT, active)
        self.assertEqual([sample["system_usec"] for sample in cpu], [20] * 8)
        self.assertEqual(io, {"reads": 1, "read_bytes": 2048, "writes": 2, "write_bytes": 4096, "flushes": 3})
        rows[1]["raw"] = rows[1]["raw"].replace("7:3", "254:16")
        with self.assertRaises(ValueError):
            cache.check_sample(rows, jobs, "A", BOOT, active)

    def test_tmpfs_sample_proves_private_capacity_and_peer_overlay(self):
        fields = f"""boot={BOOT}
page_bytes=16384
uid=0
block_bytes=16384
cache_inode=1795:2
gocache=/cache/build
gomodcache=/cache/mod
scratch=/tmp
memory_max=536870912
mount 12 2 0:81 / / rw,relatime - overlay overlay rw
mount 13 12 7:3 / /cache rw,nosuid,nodev,relatime - ext4 /dev/loop3 rw
cpu.usage_usec=60
cpu.user_usec=40
cpu.system_usec=20
"""
        jobs = [{"id": f"job-{i}"} for i in range(8)]
        active = ({"cache_inode": "1795:2", "block_bytes": "16384"}, {"device": "7:3", "super_options": ["rw"]})
        geometry = "scratch_geometry=16384 8192\nscratch_mode=1777\n"
        tmpfs = "mount 14 12 0:{} / /tmp rw,nosuid,nodev,relatime - tmpfs tmpfs rw,size=131072k\n"
        native = [{**job, "raw": fields + geometry + tmpfs.format(slot + 50)} for slot, job in enumerate(jobs)]
        native[0]["raw"] += f"loop_stat={SECTORS}\n"
        peer_fields = fields.replace("page_bytes=16384", "page_bytes=4096").replace("- ext4 /dev/loop3", "- btrfs /dev/vda")
        peer = [{**job, "raw": peer_fields} for job in jobs]
        for arm, rows in (("A", native), ("B", peer)):
            cache.check_sample(rows, jobs, arm, BOOT, active, cache.TMPFS_PROFILE)
        changes = (("16384 8192", "16384 8191"), ("0:51 / /tmp", "0:50 / /tmp"),
                   ("536870912", "268435456"), ("nosuid,nodev,relatime - tmpfs", "nosuid,nodev,noexec - tmpfs"),
                   ("rw,size=131072k", "ro,size=131072k"))
        for original, bad in changes:
            rows = native[:]
            rows[1] = {**rows[1], "raw": rows[1]["raw"].replace(original, bad)}
            with self.assertRaises(ValueError):
                cache.check_sample(rows, jobs, "A", BOOT, active, cache.TMPFS_PROFILE)
        peer[0]["raw"] += geometry + tmpfs.format(51)
        with self.assertRaises(ValueError):
            cache.check_sample(peer, jobs, "B", BOOT, active, cache.TMPFS_PROFILE)

    def test_distinct_profiles_are_not_pooled(self):
        settings = {"profile": cache.TMPFS_PROFILE}
        plan = {"ext4_cache_profile": cache.TMPFS_PROFILE, "build_scratch": "tmpfs",
                "worker_scheduler": "hrtick-250us"}
        self.assertEqual(cache.check_profile(settings, plan), cache.TMPFS_PROFILE)
        self.assertEqual(cache.check_profile({}, {"worker_scheduler": "hrtick-125us"}), cache.OVERLAY_PROFILE)
        for invalid in ({**plan, "worker_scheduler": "hrtick-125us"}, {**plan, "build_scratch": "overlay"},
                        {**plan, "ext4_cache_profile": cache.OVERLAY_PROFILE}):
            with self.assertRaises(ValueError):
                cache.check_profile(settings, invalid)
        runs = ({"profile": cache.OVERLAY_PROFILE}, {"profile": cache.TMPFS_PROFILE})
        with patch.object(cache, "verify_archive", side_effect=runs), self.assertRaises(ValueError):
            cache.compare([Path("overlay"), Path("tmpfs")])

    def test_scratch_proof_uses_the_verified_loop_without_replacing_guest_root(self):
        root_mounts = {"/": {"device": "254:16", "fs": "ext4"}}
        loop_mount = {"device": "7:3", "fs": "ext4"}
        active = ({"boot": BOOT, "cache_inode": "1795:2"}, loop_mount)
        proof = [{"cache_inode": "1795:2", "cache_root": "/"}]
        original = Mock(return_value=proof)
        with patch.object(cache.sibling_tmpfs, "check_jobs", original):
            with cache.scratch_proof(cache.TMPFS_PROFILE, lambda: active):
                verify = cache.sibling_tmpfs.check_jobs
                self.assertEqual(verify([], {}, None, "A", "tmpfs", BOOT, root_mounts), proof)
                original.assert_called_with([], {}, None, "A", "tmpfs", BOOT, {"/": loop_mount})
                verify([], {}, None, "B", "tmpfs", BOOT, root_mounts)
                original.assert_called_with([], {}, None, "B", "tmpfs", BOOT, root_mounts)
                with self.assertRaises(ValueError):
                    verify([], {}, None, "A", "tmpfs", BOOT, {"/": loop_mount})
            self.assertIs(cache.sibling_tmpfs.check_jobs, original)
        self.assertEqual(root_mounts["/"]["device"], "254:16")

    def test_reservations_stay_ordered_outside_timing(self):
        calls = []

        def start(item):
            calls.append(item[0])
            return item[1]

        start.__qualname__ = "Siblings.create.<locals>.start"

        def clients(width, fn, items):
            self.assertEqual(calls, [29, 30, 31])
            self.assertEqual(width, 8)
            return [fn(i) for i in items]

        self.assertEqual(cache.reserve_in_order(clients, 8, start, [(i, str(i)) for i in range(29, 35)]),
                         ["29", "30", "31", "32", "33", "34"])
        self.assertEqual(calls, list(range(29, 35)))

    def test_acknowledge_only_after_controller_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            study = cache.CacheStudy(Path(directory), 16384, {})
            study.records = Path(directory)
            study.boot = BOOT
            cohort = SimpleNamespace(owner=OWNER)
            release = study.records / "control-release"
            study.request = Mock(side_effect=ValueError("controller still present"))
            with self.assertRaises(ValueError):
                study.retire(cohort)
            self.assertFalse(release.exists())

            controller = OWNER + "-ext4-cache-retire"
            acknowledgment = f"boot={BOOT}\ncontroller={controller}\n"
            retired = acknowledgment + f"sync_stat={SECTORS}\nunmount_stat={SECTORS}\nclean=true\n"
            study.request = Mock(return_value=controller)
            study.wait = Mock(side_effect=lambda name: retired if name == "retired" else release.read_text())
            study.retire(cohort)
            self.assertEqual(release.read_text(), acknowledgment)
            study.request.assert_called_once_with(cohort, "retire")
            with self.assertRaises(ValueError):
                cache.validate_retirement(retired, acknowledgment.replace(OWNER, "mp-t-alien"), OWNER, BOOT)

    def test_control_unmount_checks_identity_and_actual_disappearance(self):
        source = Path(cache.__file__).with_name("sibling_ext4_cache_guest.sh").read_text()
        definition = source[source.index("unmount_owned()"):source.index("\ndetach_owned()")]
        calls = """
mount_row() { [ "$mounted" = no ] || printf '%s\n' original; }
umount() { printf 'unmounted\n'; mounted=$release; }
mounted=yes
unmount_owned /scoped replacement && exit 9
release=yes
unmount_owned /scoped original && exit 10
release=no
unmount_owned /scoped original
"""
        got = subprocess.check_output(["/bin/sh", "-eu", "-c", definition + calls], text=True)
        self.assertEqual(got.splitlines(), ["unmounted", "unmounted"])


if __name__ == "__main__":
    unittest.main()
