import unittest

from elf_page_layout import HEADER, PROGRAM, elf_layout


def executable(vaddr, align=4096):
    ident = b"\x7fELF\x02\x01\x01".ljust(16, b"\x00")
    hdr = HEADER.pack(ident, 2, 183, 1, 0, HEADER.size, 0, 0, HEADER.size, PROGRAM.size, 1, 0, 0, 0)
    return hdr + PROGRAM.pack(1, 5, 0, vaddr, 0, HEADER.size, HEADER.size, align)


class PageLayoutTests(unittest.TestCase):
    def test_intra_page_offsets_determine_layout_even_with_4k_alignment(self):
        self.assertEqual(elf_layout(executable(0x4000))["offset_mismatches"], {"4096": [], "16384": []})
        self.assertEqual(elf_layout(executable(0x1000))["offset_mismatches"], {"4096": [], "16384": [0]})

    def test_truncated_program_header_is_rejected(self):
        with self.assertRaises(ValueError):
            elf_layout(executable(0x4000)[:-1])
