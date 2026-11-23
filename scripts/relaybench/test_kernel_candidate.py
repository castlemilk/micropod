import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import kernel_candidate as kernels


def write_bundle(directory, *, granule=4, header_granule=None, config_extra="", big_endian=False, payload=b"test"):
    directory.mkdir(exist_ok=True)
    config = ("# Builder fixture\nCONFIG_ARM64=y\nCONFIG_SECCOMP=y\n" + "".join(
        f"{key}=y\n" if size == granule else f"# {key} is not set\n"
        for key, size in kernels.PAGE_OPTIONS.items()) + config_extra).encode()
    image = bytearray(64)
    image[56:60] = bytes.fromhex("41 52 4d 64")
    image[16:24] = (0xA000).to_bytes(8, "little")
    code = {0: 0, 4: 1, 16: 2, 64: 3}[granule if header_granule is None else header_granule]
    image[24:32] = ((code << 1) | big_endian | 8).to_bytes(8, "little")
    data = bytes(image) + payload
    (directory / "Image").write_bytes(data)
    (directory / "config").write_bytes(config)
    (directory / "SHA256SUMS").write_text(f"{hashlib.sha256(data).hexdigest()}  Image\n"
                                         f"{hashlib.sha256(config).hexdigest()}  config\n")


class KernelCandidateTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.control = Path(temp.name) / "control"
        self.trial = Path(temp.name) / "candidate"
        write_bundle(self.control)
        write_bundle(self.trial, granule=16)

    def run_cli(self):
        return subprocess.run([sys.executable, "-B", kernels.__file__, str(self.control), str(self.trial)],
                              capture_output=True, text=True)

    def test_reads_builder_outputs_and_all_known_granules(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["control"]["page_kib"], 4)
        self.assertEqual(report["candidate"]["page_kib"], 16)
        self.assertEqual(report["config_changes"], {"CONFIG_ARM64_4K_PAGES": ["y", "n"],
                                                   "CONFIG_ARM64_16K_PAGES": ["n", "y"]})
        self.assertGreater(report["candidate"]["image_memory_bytes"], report["candidate"]["image_bytes"])
        write_bundle(self.trial, granule=64)
        self.assertEqual(kernels.compare(self.control, self.trial, 4, 64)["candidate"]["page_kib"], 64)

    def test_manifest_cannot_hide_wrong_binary_page_size_or_endianness(self):
        for granule, endian in [(4, False), (0, False), (16, True)]:
            with self.subTest(granule=granule, endian=endian):
                write_bundle(self.trial, granule=16, header_granule=granule, big_endian=endian)
                with self.assertRaisesRegex(ValueError, "Image header"):
                    kernels.inspect(self.trial, 16)
        write_bundle(self.trial, granule=16, payload=b"")
        self.assertEqual(self.run_cli().returncode, 2)

    def test_integrity_checked_on_both_inputs_and_duplicate_manifest_rows(self):
        for path, filename in [(self.control, "Image"), (self.trial, "config")]:
            with self.subTest(path=path.name, filename=filename):
                original = (path / filename).read_bytes()
                (path / filename).write_bytes(original + b" extra")
                with self.assertRaisesRegex(ValueError, "digest"):
                    kernels.compare(self.control, self.trial, 4, 16)
                (path / filename).write_bytes(original)
        manifest = self.trial / "SHA256SUMS"
        manifest.write_text(manifest.read_text() * 2)
        with self.assertRaisesRegex(ValueError, "unique"):
            kernels.inspect(self.trial, 16)

    def test_embedded_image_config_binds_the_sidecar(self):
        option = "CONFIG_IKCONFIG=y\n"
        write_bundle(self.trial, granule=16, config_extra=option)
        config = (self.trial / "config").read_bytes()
        payload = b"IKCFG_ST" + gzip.compress(config, mtime=0) + b"IKCFG_ED"
        write_bundle(self.trial, granule=16, config_extra=option, payload=payload)
        self.assertTrue(kernels.inspect(self.trial, 16)[0]["embedded_config_verified"])
        write_bundle(self.trial, granule=16, config_extra=option + "CONFIG_PREEMPT=y\n", payload=payload)
        with self.assertRaisesRegex(ValueError, "differs from sidecar"):
            kernels.inspect(self.trial, 16)
        for broken in (b"absent", payload[:-8], payload + payload, payload[:-9] + b"IKCFG_ED"):
            with self.subTest(payload=broken):
                write_bundle(self.trial, granule=16, config_extra=option, payload=broken)
                with self.assertRaises(ValueError):
                    kernels.inspect(self.trial, 16)
        write_bundle(self.trial, granule=16, config_extra="CONFIG_IKCONFIG=m\n")
        self.assertFalse(kernels.inspect(self.trial, 16)[0]["embedded_config_verified"])

    def test_effective_config_drift_reports_page_shift_and_protection_options(self):
        write_bundle(self.control, config_extra="CONFIG_SECURITY=y\nCONFIG_PAGE_SHIFT=12\n")
        write_bundle(self.trial, granule=16, config_extra="# CONFIG_SECURITY is not set\nCONFIG_PAGE_SHIFT=14\n")
        result = self.run_cli()
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["additional_config_changes"], ["CONFIG_PAGE_SHIFT", "CONFIG_SECURITY"])
        self.assertEqual(report["config_changes"]["CONFIG_SECURITY"], ["y", "n"])

    def test_conflicting_config_and_same_size_rejected(self):
        write_bundle(self.trial, granule=16, config_extra="CONFIG_ARM64_4K_PAGES=y\n")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            kernels.inspect(self.trial, 16)
        config = self.trial / "config"
        write_bundle(self.trial, granule=16)
        data = config.read_bytes().replace(b"# CONFIG_ARM64_4K_PAGES is not set", b"CONFIG_ARM64_4K_PAGES=m")
        manifest = self.trial / "SHA256SUMS"
        manifest.write_text(manifest.read_text().replace(hashlib.sha256(config.read_bytes()).hexdigest(),
                                                        hashlib.sha256(data).hexdigest()))
        config.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "invalid arm64 page selector"):
            kernels.inspect(self.trial, 16)
        with self.assertRaisesRegex(ValueError, "distinct"):
            kernels.compare(self.control, self.control, 4, 4)


if __name__ == "__main__":
    unittest.main()
