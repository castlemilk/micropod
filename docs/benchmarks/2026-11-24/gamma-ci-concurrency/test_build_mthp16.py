"""Exercise the actual pre-build Kconfig guard without a kernel build."""

import hashlib
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import build_mthp16


class ResolvedConfigGuardTest(unittest.TestCase):
    def test_shell_and_python_normalize_full_lines_in_the_same_order(self):
        baseline = (b'CONFIG_ARCH_THUNDER=y\nCONFIG_ARCH_THUNDER2=y\n'
                    b'# CONFIG_TRANSPARENT_HUGEPAGE is not set\n')
        parent = b'set -eu\nmake() { [ "$1" = olddefconfig ]; }\nmake olddefconfig\necho ready-to-build\n'
        if not shutil.which("sha256sum"):
            parent = parent.replace(b"set -eu\n", b"set -eu\nsha256sum() { shasum -a 256; }\n", 1)

        with TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / "builder.sh"
            original.write_bytes(parent)
            (root / "scripts").mkdir()
            config_tool = root / "scripts/config"
            config_tool.write_text("#!/bin/sh\nexit 0\n")
            config_tool.chmod(0o700)
            with patch.object(build_mthp16, "PARENT_BUILDER", hashlib.sha256(parent).hexdigest()), \
                    patch.object(build_mthp16, "PARENT_CONFIG", hashlib.sha256(baseline).hexdigest()):
                script = build_mthp16.matched_builder(original, baseline)
                expected = build_mthp16.expected_options(baseline)
            expected_lines = [f"# {key} is not set" if value == "n" else f"{key}={value}"
                              for key, value in sorted(expected.items())]
            resolved = "\n".join(expected_lines) + "\n"
            for changed in (False, True):
                with self.subTest(unreviewed_symbol=changed):
                    (root / ".config").write_text(resolved + ("CONFIG_UNREVIEWED=y\n" if changed else ""))
                    proc = subprocess.run(["/bin/sh", "-es"], input=script, cwd=root, capture_output=True)
                    if changed:
                        self.assertNotEqual(proc.returncode, 0)
                        self.assertIn(b"Resolved Kconfig differs", proc.stderr)
                        self.assertNotIn(b"ready-to-build", proc.stdout)
                    else:
                        self.assertEqual(proc.returncode, 0, proc.stderr)
                        self.assertIn(b"ready-to-build", proc.stdout)


if __name__ == "__main__":
    unittest.main()
