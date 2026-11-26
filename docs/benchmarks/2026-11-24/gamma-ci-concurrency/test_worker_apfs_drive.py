import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import worker_apfs_drive as drive


class PublishImageTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.mount = self.root / "a"
        self.mount.mkdir()
        self.image = self.root / "worker.sparseimage"

    def imageinfo(self, *_argv):
        return {"Format": "SPRS"}

    def test_concurrent_destination_is_never_adopted(self):
        def hdiutil_create(*argv):
            self.assertEqual(argv[:2], (drive.HDI, "create"))
            staged = Path(argv[-1])
            self.assertEqual(staged.parent.parent, self.root)
            self.assertNotEqual(staged, self.image)
            staged.write_bytes(b"our newly staged image")
            self.image.write_bytes(b"concurrent image")

        with (patch.object(drive, "_checked", side_effect=hdiutil_create),
              patch.object(drive, "_plist", side_effect=self.imageinfo),
              patch.object(drive, "_attach") as attach,
              patch.object(drive, "_rollback") as rollback):
            with self.assertRaises(FileExistsError):
                drive.create(self.image, self.mount)
            attach.assert_not_called()
            rollback.assert_not_called()
        self.assertEqual(self.image.read_bytes(), b"concurrent image")
        self.assertEqual(set(self.root.iterdir()), {self.image, self.mount})

    def test_published_inode_precedes_attachment(self):
        staged_ids = []

        def hdiutil_create(*argv):
            staged = Path(argv[-1])
            staged.write_bytes(b"our newly staged image")
            staged_ids.append(drive._image_identity(staged))

        def inspect_attachment(record):
            self.assertEqual(set(self.root.iterdir()), {self.image, self.mount})
            self.assertEqual(record["image_identity"], {**staged_ids[0], "format": "SPRS"})
            self.assertEqual(drive._image_identity(self.image), staged_ids[0])
            return {}

        with (patch.object(drive, "_checked", side_effect=hdiutil_create),
              patch.object(drive, "_plist", side_effect=self.imageinfo),
              patch.object(drive, "_attach", side_effect=inspect_attachment),
              patch.object(drive, "_observe", side_effect=lambda record, _actual: record)):
            receipt = drive.create(self.image, self.mount, disabled=False)
        self.assertEqual(receipt["image_identity"]["ino"], self.image.stat().st_ino)


class DetachedPolicyTest(unittest.TestCase):
    def test_ready_time_disk_replacement_preserves_the_detached_image(self):
        with tempfile.TemporaryDirectory() as stage:
            root = Path(stage)
            image = root / "canary.sparseimage"
            image.touch()
            actual = {"volume": {"dev": 1}, "container": {}, "backing": {"image_device": "/dev/disk99"}}
            receipt = {**actual, "image": str(image), "mount": str(root / "a"), "disabled": True}
            history = {"raw_disk": {"ino": 9, "size": 100},
                       "journal_unchanged": True, "markers_unchanged": True, "raw_disk_unchanged": True}
            with (patch.object(drive, "_validate_image"), patch.object(drive, "_read_volume", return_value=actual),
                  patch.object(drive, "_file_record"), patch.object(drive, "_release") as release,
                  patch.object(drive, "_inspect_history", return_value=history)):
                with self.assertRaisesRegex(RuntimeError, "since readiness"):
                    drive.detach(receipt, expected_raw_identity=(8, 100))
            release.assert_called_once()
            self.assertTrue(image.exists())

    def test_protected_drive_rejects_an_initial_journal_even_when_empty(self):
        with tempfile.TemporaryDirectory() as stage:
            mount = Path(stage)
            device = mount.stat().st_dev
            drive._seed(mount, device)
            actual = {"volume": {"dev": device}}
            (mount / ".fseventsd" / "0000000000000001").touch()
            with patch.object(drive, "_spotlight", return_value={"disabled": True}):
                with self.assertRaisesRegex(RuntimeError, "FSEvents journal"):
                    drive._observe({"mount": str(mount), "disabled": True}, actual)
                control = drive._observe({"mount": str(mount), "disabled": False}, actual)
            self.assertEqual(control["fsevents"]["journal_files"], 1)
            self.assertEqual(control["fsevents"]["journal_bytes"], 0)

    def test_changed_disabled_history_is_rejected_before_unlink(self):
        with tempfile.TemporaryDirectory() as stage:
            root = Path(stage)
            image = root / "canary.sparseimage"
            image.write_bytes(b"owned attached image")
            receipt = {
                "image": str(image), "mount": str(root / "a"), "disabled": True,
                "volume": {"dev": 1}, "container": {}, "backing": {"image_device": "/dev/disk99"},
            }
            actual = {key: receipt[key] for key in ("volume", "container", "backing")}
            for field in ("journal_unchanged", "markers_unchanged", "raw_disk_unchanged"):
                with self.subTest(field=field):
                    history = {"journal_unchanged": True, "markers_unchanged": True, "raw_disk_unchanged": True}
                    history[field] = False
                    with (patch.object(drive, "_validate_image"),
                          patch.object(drive, "_read_volume", return_value=actual),
                          patch.object(drive, "_file_record", return_value=None),
                          patch.object(drive, "_release") as detach,
                          patch.object(drive, "_inspect_history", return_value=history)):
                        with self.assertRaisesRegex(RuntimeError, field):
                            drive.detach(receipt)
                        detach.assert_called_once_with(receipt, "/dev/disk99")
                    self.assertTrue(image.exists())


if __name__ == "__main__":
    unittest.main()
