import copy
import subprocess
import unittest

import file_fault_around_common as fault


BOOT = "3373364e-423e-4ddc-9863-e67992056660"


def sample_receipt(window):
    rows = []
    pages = window // fault.PAGE_BYTES
    for order in fault.SAMPLE_ORDERS:
        start = 0 if order == "forward" else 64 - pages
        rows.append({"order": order, "maps_line": "100000000-100100000 r--p 00100000 00:43 115 " + fault.GO_PATH,
                     "resident_before_pages": 64, "present_before_pages": 0,
                     "present_after_first_indices": list(range(start, start + pages)), "minor_faults": 64 // pages,
                     "major_faults": 0, "checksum": "e524a3f4ae4c312b", "expected_checksum": "e524a3f4ae4c312b"})
    return {"schema": fault.MMAP_SCHEMA, "boot_id": BOOT, "page_bytes": fault.PAGE_BYTES,
            "window_bytes": fault.WINDOWS[-1], "tool": {"path": fault.GO_PATH, "sha256": fault.GO_SHA256,
                 "inode": 115, "device": 67, "device_major": 0, "device_minor": 67, "size_bytes": 8192000,
                 "segment_offset": 0x10000, "segment_size_bytes": 0x300000, "window_offset": 0x100000},
            "samples": rows}


class FaultAroundTest(unittest.TestCase):
    def test_bootstrap_still_precedes_the_engine(self):
        base = b'#!/bin/sh\nconfigure_scheduler\n# Each containerd shim\n(umask 022; exec containerd xyz) &\n'
        updated = fault.patch_start(base)
        self.assertLess(updated.index(fault.BOOTSTRAP.encode()), updated.index(b"exec containerd"))
        subprocess.run(["/bin/sh", "-n"], input=updated, check=True)
        subprocess.run(["/bin/sh", "-n"], input=fault.FINAL_OBSERVER.encode(), check=True)
        with self.assertRaises(ValueError):
            fault.patch_start(updated)

    def test_readback_binds_untouched_stock_boot_default(self):
        raw = (f"schema={fault.SCHEMA}\nboot_id={BOOT}\npage_size_bytes=16384\nbefore_bytes=65536\n"
               "effective_bytes=1048576\n")
        self.assertEqual(fault.parse_readback(raw, 1048576, BOOT, before_work=True)["before_bytes"], 65536)
        for invalid in (raw.replace("65536", "1048576"), raw.replace("16384", "4096"),
                        raw + "effective_bytes=1048576\n", raw.replace(BOOT, BOOT[:-1] + "1")):
            with self.assertRaises(ValueError):
                fault.parse_readback(invalid, 1048576, BOOT, before_work=True)
        with self.assertRaises(ValueError):
            fault.parse_readback(raw, 393216, BOOT, before_work=True)

    def test_maps_bind_both_window_footprints(self):
        for window in fault.WINDOWS:
            sample = sample_receipt(window)
            self.assertEqual(fault.check_mmap(sample, BOOT, 115, window), sample["samples"])
            with self.assertRaises(ValueError):
                fault.check_mmap(sample, BOOT, 116, window)
            wrong = copy.deepcopy(sample)
            wrong["samples"][0]["maps_line"] = wrong["samples"][0]["maps_line"].replace("00:43", "00:33")
            with self.assertRaises(ValueError):
                fault.check_mmap(wrong, BOOT, 115, window)
            wrong = copy.deepcopy(sample)
            wrong["samples"][1]["present_after_first_indices"].pop()
            with self.assertRaises(ValueError):
                fault.check_mmap(wrong, BOOT, 115, window)


if __name__ == "__main__":
    unittest.main()
