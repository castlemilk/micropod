import hashlib
from pathlib import Path
import tempfile
import unittest

from bench_package_caches import MODULE, VERSION, Fixture, cold_build_input, empty_go_stores, stores


class FirstGoBuildTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.cache = stores(root / "caches")
        self.work = root / "work"
        self.work.mkdir()
        self.roots = empty_go_stores(self.cache)
        self.archive = self.cache["go-mod-cache"] / "cache/download" / MODULE / "@v" / (VERSION + ".zip")
        self.archive.parent.mkdir(parents=True)
        self.archive.write_bytes(b"module data")
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.env = {"GOCACHE": str(self.cache["go-build-cache"]), "GOMODCACHE": str(self.cache["go-mod-cache"]),
                    "GOPROXY": "off"}

    def evidence(self):
        return cold_build_input(self.env, self.roots, self.work, self.digest)

    def test_clean_input_and_seeded_module(self):
        self.assertEqual(self.evidence()["prebuild_module_sha256"], self.digest)
        self.assertEqual(self.evidence()["initial_empty_roots"]["go-build-cache"], self.roots["go-build-cache"])
        with self.assertRaisesRegex(ValueError, "empty first-build cache"):
            empty_go_stores(self.cache)

    def test_prepopulated_or_aliased_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = stores(Path(tmp) / "stores")
            cache["go-build-cache"].mkdir(parents=True)
            (cache["go-build-cache"] / "cached-action").touch()
            with self.assertRaisesRegex(ValueError, "empty first-build cache"):
                Fixture(Path(tmp)).prime(cache, "must-not-start")
            self.assertFalse((Path(tmp) / "checkouts").exists())
            (cache["go-build-cache"] / "cached-action").unlink()
            cache["go-build-cache"] = cache["go-mod-cache"]
            with self.assertRaisesRegex(ValueError, "share a directory"):
                empty_go_stores(cache)

    def test_replaced_or_seeded_build_store(self):
        path = self.cache["go-build-cache"]
        (path / "foreign-action").touch()
        with self.assertRaisesRegex(ValueError, "empty first-build cache"):
            self.evidence()
        path.rename(path.with_name("previous"))
        path.mkdir()
        with self.assertRaisesRegex(ValueError, "Build cache root changed"):
            self.evidence()

    def test_preexisting_output_even_if_dangling(self):
        (self.work / "app").symlink_to("removed")
        with self.assertRaisesRegex(ValueError, "already has an output"):
            self.evidence()

    def test_wrong_module(self):
        self.archive.write_bytes(b"unrelated")
        with self.assertRaisesRegex(ValueError, "differs from the fixture"):
            self.evidence()

    def test_build_environment_redirected(self):
        self.env["GOCACHEPROG"] = "external-cache"
        with self.assertRaisesRegex(ValueError, "offline Go with its local cache"):
            self.evidence()
        del self.env["GOCACHEPROG"]
        self.env["GOPROXY"] = "direct"
        with self.assertRaisesRegex(ValueError, "offline Go with its local cache"):
            self.evidence()
        self.env["GOPROXY"] = "off"
        self.env["GOCACHE"] = str(self.work)
        with self.assertRaisesRegex(ValueError, "Build cache root changed"):
            self.evidence()
