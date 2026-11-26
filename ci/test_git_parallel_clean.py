import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import git_parallel_clean as gate


class GitParallelCleanTests(unittest.TestCase):
    def setUp(self):
        scratch = TemporaryDirectory(prefix="mp-stock-git-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", LC_ALL="C",
                        GIT_AUTHOR_NAME="Micropod CI", GIT_AUTHOR_EMAIL="ci@example.invalid",
                        GIT_COMMITTER_NAME="Micropod CI", GIT_COMMITTER_EMAIL="ci@example.invalid")
        self.git("init", "--quiet", "--template=", "--initial-branch=main")
        self.names = ("--flag", ":(glob)*", "line\nbreak", "name\twith tab", "ordinary")
        for name in self.names:
            (self.root / name).write_bytes(b"binary\x00\xff\r\n")
        (self.root / ".gitignore").write_text("ignored*\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "initial")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], env=self.env,
                              check=True, capture_output=True).stdout

    def compare(self, expected_fast):
        expected = gate.git(self.root, self.env, *gate.STATUS)
        for count in (2, 4):
            result, fast = gate.status(self.root, count, self.env)
            self.assertEqual((result.returncode, result.stdout, result.stderr),
                             (expected.returncode, expected.stdout, expected.stderr))
            self.assertEqual(fast, expected_fast)

    def test_clean_literal_names_and_ignore_rules(self):
        (self.root / "ignored extra").write_text("throwaway")
        self.compare(True)
        source = self.root / ".git" / "index"
        with TemporaryDirectory() as other:
            dest = Path(other) / "index"
            self.assertIsNotNone(gate.snapshot_index(source, dest))
            self.assertEqual(source.read_bytes(), dest.read_bytes())
            self.assertEqual(source.stat().st_mtime_ns, dest.stat().st_mtime_ns)

    def test_replaced_binary_with_exact_stamp(self):
        source = self.root / self.names[1]
        original = source.stat()
        changed = self.root / "ignored replacement"
        changed.write_bytes(b"binAry\x00\xff\r\n")
        os.utime(changed, ns=(original.st_atime_ns, original.st_mtime_ns))
        changed.replace(source)
        self.assertNotEqual(source.stat().st_ino, original.st_ino)
        self.assertEqual(source.stat().st_mtime_ns, original.st_mtime_ns)
        self.compare(False)

    def test_staged_removal_and_untracked_files(self):
        self.git("rm", "--cached", "--", "ordinary")
        self.compare(False)
        self.git("add", "--", "ordinary")
        (self.root / "untracked\nfile").write_bytes(b"new")
        self.compare(False)

    def test_index_rewritten_after_workers(self):
        original = gate.clean_checks

        def change_after(*args):
            self.assertTrue(original(*args))
            index = self.root / ".git" / "index"
            before = index.stat()
            self.git("update-index", "--chmod=+x", "ordinary")
            os.utime(index, ns=(before.st_atime_ns, before.st_mtime_ns))
            return True

        with patch.object(gate, "clean_checks", change_after):
            result, fast = gate.status(self.root, 2, self.env)
        self.assertFalse(fast)
        self.assertEqual(result.stdout, gate.git(self.root, self.env, *gate.STATUS).stdout)

    def test_head_moved_after_workers(self):
        original = gate.clean_checks

        def change_after(*args):
            self.assertTrue(original(*args))
            self.git("commit", "--allow-empty", "-qm", "updated HEAD")
            return True

        with patch.object(gate, "clean_checks", change_after):
            result, fast = gate.status(self.root, 2, self.env)
        self.assertFalse(fast)
        self.assertEqual(result.stdout, b"")

    def test_cli_preserves_caller_index_and_command_configuration(self):
        with TemporaryDirectory(prefix="alternate-index-") as scratch:
            index = Path(scratch) / "index"
            self.assertIsNotNone(gate.snapshot_index(self.root / ".git" / "index", index))
            env = self.env | {"GIT_INDEX_FILE": str(index), "GIT_CONFIG_COUNT": "1",
                              "GIT_CONFIG_KEY_0": "status.showUntrackedFiles", "GIT_CONFIG_VALUE_0": "no"}
            subprocess.run(["git", "-C", str(self.root), "update-index", "--chmod=+x", "ordinary"],
                           env=env, check=True, capture_output=True)
            (self.root / "untracked").write_bytes(b"new")
            expected = gate.git(self.root, env, *gate.STATUS)
            observed = subprocess.run([sys.executable, "-B", str(Path(gate.__file__)), "--workers", "4", str(self.root)],
                                      env=env, check=False, capture_output=True)
            self.assertEqual((observed.returncode, observed.stdout, observed.stderr),
                             (expected.returncode, expected.stdout, expected.stderr))
            self.assertIn(b"?? untracked\0", observed.stdout)
            self.assertIn(b"ordinary\0", observed.stdout)

    def test_repository_config_changed_after_workers(self):
        original = gate.clean_checks

        def change_after(*args):
            self.assertTrue(original(*args))
            self.git("config", "core.preloadIndex", "false")
            return True

        with patch.object(gate, "clean_checks", change_after):
            result, fast = gate.status(self.root, 4, self.env)
        self.assertFalse(fast)
        self.assertEqual(result.stdout, gate.git(self.root, self.env, *gate.STATUS).stdout)


if __name__ == "__main__":
    unittest.main()
