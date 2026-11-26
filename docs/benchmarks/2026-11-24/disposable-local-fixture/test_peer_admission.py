import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import local_admission


class PeerAdmissionTests(unittest.TestCase):
    def test_only_owned_single_endpoint_client_is_admitted(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            scope = root / "orb"
            scope.mkdir()
            (scope / "addr").write_text("127.0.0.1:32780\n")
            (scope / "name").write_text("peer-A\n")
            check = local_admission.Admission(root)
            check.receiver_group = 123
            check.peer_scopes = (scope,)
            endpoint = "http://127.0.0.1:32780"
            for group, arguments, allowed in (
                (123, [endpoint, "peer-A"], True),
                (456, [endpoint, "peer-A"], False),
                (123, [endpoint, "other"], False),
                (123, ["http://127.0.0.1:32781", "peer-A"], False),
                (123, [endpoint, "peer-A", endpoint, "peer-A"], False),
            ):
                command = (321, Path("/tmp/fixed"), ["fixed", *arguments])
                with (
                    self.subTest(group=group, arguments=arguments),
                    patch.object(local_admission, "processes", return_value=[command]),
                    patch.object(local_admission.os, "getpgid", return_value=group),
                ):
                    if allowed:
                        check.check(force=True)
                    else:
                        with self.assertRaisesRegex(ValueError, "foreign timed client"):
                            check.check(force=True)
