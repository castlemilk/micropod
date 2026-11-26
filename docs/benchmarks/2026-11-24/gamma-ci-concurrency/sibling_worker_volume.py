"""Provide the writable VM disk on an unindexed private APFS volume."""
from contextlib import contextmanager
from functools import partial
from pathlib import Path
import shutil
from unittest.mock import patch

from qualify import terminal
import local_worker_drive
import sibling_tmpfs
import worker_apfs_drive


@contextmanager
def mounted_worker_volume():
    base_stage = sibling_tmpfs.stage

    def stage(oci, work, folder, mode):
        result = base_stage(oci, work, folder, mode)
        sources = {"host_volume_driver_sha256": Path(__file__),
                   "host_volume_helper_sha256": Path(worker_apfs_drive.__file__),
                   "host_volume_provider_sha256": Path(local_worker_drive.__file__)}
        for key, source in sources.items():
            archived = folder / source.name
            shutil.copyfile(source, archived)
            result[key] = terminal.digest(archived)
        return {**result, "host_worker_volume": local_worker_drive.POLICY,
                "host_worker_volume_gib": local_worker_drive.VOLUME_GIB,
                "host_worker_volume_final_history": True}

    drive = local_worker_drive.WorkerDrive(worker_apfs_drive, terminal.save)
    with patch.object(terminal, "Run", partial(terminal.Run, worker_drive=drive)), \
            patch.object(sibling_tmpfs, "stage", stage):
        yield
