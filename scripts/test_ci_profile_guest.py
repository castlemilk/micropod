import unittest

from ci_profile_guest import go_tools


class GoToolTraceTests(unittest.TestCase):
    def test_go_linker_environment_and_version_queries(self):
        trace = """WORK=/tmp/go-build123
GOROOT='' /usr/local/go/pkg/tool/linux_arm64/link -o /tmp/app
GOOS=linux TMPDIR='/tmp/a b' "/some tools/compile" -o main.a
/usr/lib/go/asm -V=full
/usr/lib/go/asm -o asm.o
# copied /usr/lib/go/link command
an unrelated diagnostic about /a/link with 'unmatched quotes
"""
        self.assertEqual(go_tools(trace), {"compile": 1, "asm": 1, "link": 1})


if __name__ == "__main__":
    unittest.main()
