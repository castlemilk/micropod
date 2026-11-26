from pathlib import Path
import subprocess
import sys
import unittest

from kernel_compiler import audit, gamma_stock


class KernelCompilerTests(unittest.TestCase):
    def test_archived_gamma_stock(self):
        report = gamma_stock()
        self.assertEqual(report["config_sha256"], "a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c")
        self.assertEqual(report["recorded_image_sha256"], "7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd")
        self.assertEqual(report["compiler"], "GCC")
        self.assertEqual(report["lto_mode"], "none")
        self.assertEqual(report["mitigation_build_options"]["CONFIG_CPU_MITIGATIONS"], "y")
        self.assertEqual(report["mitigation_build_options"]["CONFIG_MITIGATE_SPECTRE_BRANCH_HISTORY"], "n")
        self.assertIsNone(report["profile_options"]["CONFIG_AUTOFDO_CLANG"])
        self.assertFalse(report["runtime_mitigations_verified"])

    def test_profile_options_do_not_prove_profile_apply(self):
        sample = b"""CONFIG_ARM64=y
CONFIG_CC_IS_CLANG=y
CONFIG_LTO_CLANG_THIN=y
CONFIG_AUTOFDO_CLANG=y
# CONFIG_PROPELLER_CLANG is not set
"""
        report = audit(sample)
        self.assertEqual(report["lto_mode"], "Clang ThinLTO")
        self.assertEqual(report["profile_options"], {"CONFIG_AUTOFDO_CLANG": "y", "CONFIG_PROPELLER_CLANG": "n"})
        self.assertFalse(report["profile_use_verified"])
        self.assertIsNone(report["mitigation_build_options"]["CONFIG_CPU_MITIGATIONS"])

    def test_command_refuses_silently_reverted_lto(self):
        cli = [sys.executable, "-B", str(Path(__file__).with_name("kernel_compiler.py")), "--gamma-stock", "--require-lto"]
        control = subprocess.run([*cli, "CONFIG_LTO_NONE"], capture_output=True, text=True)
        self.assertEqual(control.returncode, 0, control.stderr)
        candidate = subprocess.run([*cli, "CONFIG_LTO_CLANG_THIN"], capture_output=True, text=True)
        self.assertEqual(candidate.returncode, 2)
        self.assertIn("expected CONFIG_LTO_CLANG_THIN=y, resolved LTO mode: none", candidate.stderr)

    def test_distributed_thinlto_is_a_distinct_choice(self):
        options = b"CONFIG_ARM64=y\nCONFIG_CC_IS_CLANG=y\nCONFIG_LTO_CLANG_THIN_DIST=y\n"
        self.assertEqual(audit(options)["lto_mode"], "Clang distributed ThinLTO")
        with self.assertRaisesRegex(ValueError, "multiple selections"):
            audit(options + b"CONFIG_LTO_CLANG_THIN=y\n")
        with self.assertRaisesRegex(ValueError, "GCC config"):
            audit(options.replace(b"CONFIG_CC_IS_CLANG", b"CONFIG_CC_IS_GCC"))

    def test_support_symbols_alone_leave_selection_unknown(self):
        report = audit(b"CONFIG_ARM64=y\nCONFIG_ARCH_SUPPORTS_LTO_CLANG_THIN=y\n")
        self.assertIsNone(report["compiler"])
        self.assertIsNone(report["lto_mode"])

    def test_reject_invalid_or_conflicting_configs(self):
        for options in (b"CONFIG_CC_IS_GCC=y\nCONFIG_CC_IS_CLANG=y", b"CONFIG_LTO_NONE=y\nCONFIG_LTO_CLANG_FULL=y",
                        b"CONFIG_CC_IS_GCC=y\nCONFIG_AUTOFDO_CLANG=y", b"CONFIG_CPU_MITIGATIONS=m",
                        b"CONFIG_CC_IS_CLANG=y\nCONFIG_CC_IS_CLANG=y"):
            with self.subTest(options=options), self.assertRaises(ValueError):
                audit(b"CONFIG_ARM64=y\n" + options)
        with self.assertRaises(ValueError):
            audit(b"CONFIG_X86=y\nCONFIG_CC_IS_CLANG=y\n")
