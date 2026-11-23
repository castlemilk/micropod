"""Compare TCP DNS frame boundaries against the preceding single-address encoder, fully offline."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

from dns_snapshot import ROOT, GUEST, compile_arm, sha

BASE = "62a3be76fdac738368dff3b0854cebe191332d1b"
TEST = ROOT / GUEST / "docker_dns_frame_linux_test.go"
SELECT = "^(TestServiceTCPFrameBudget|TestSendDNSFrameLimitBeforeWriting|TestServiceTCPUnrepresentableAnswerCount)$"


def observe(go, arm, work, env):
    # The existing helper compiles the complete dnsReply, directory and encoders
    # and verifies its 60-response control. Add the same frame tests to both builds.
    exe, source = compile_arm(go, arm, work, env, BASE)
    (exe.parent / "frame_test.go").write_bytes(TEST.read_bytes())
    test = subprocess.run([go, "test", "-mod=readonly", "-p=2", "-count=1", "-run", SELECT, "-v"],
                          cwd=exe.parent, env=env, capture_output=True, text=True)
    rows = [json.loads(line) for line in re.findall(r"frame_observation (\{[^\n]+\})", test.stdout)]
    failures = re.findall(r"--- FAIL: (\S+/\S+) \(", test.stdout)
    if len(rows) != 9 or test.returncode != (1 if arm == "base" else 0):
        raise RuntimeError(test.stdout + test.stderr)
    messages = [row for row in rows if "name" in row]
    expected_failures = sorted([f'TestServiceTCPFrameBudget/{r["name"]}/{r["answers_offered"]}'
                                for r in messages if r["answers_offered"] > r["max_fitting_answers"]]
                               + ["TestSendDNSFrameLimitBeforeWriting/65536"]) if arm == "base" else []
    if len(messages) != 6 or sorted(failures) != expected_failures:
        raise ValueError(f"unexpected frame cases or test failures: {rows} {failures}")
    return dict(source_sha256=source["files"], ordinary_replies_sha256=source["verified_response_sha256"],
                boundary_tests_exit_code=test.returncode, failing_boundary_subtests=sorted(failures), observations=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        env = dict(os.environ, GOENV="off", GOPROXY="off", GOSUMDB="off", GOTOOLCHAIN="local", GOWORK="off",
                   GOMAXPROCS="2", GOFLAGS="-trimpath", GOTELEMETRY="off", CGO_ENABLED="0",
                   GOCACHE=os.environ.get("GOCACHE", str(work / "cache")))
        env.pop("GOROOT", None)
        arms = {arm: observe(args.go, arm, work, env) for arm in ("base", "candidate")}
        if arms["base"]["ordinary_replies_sha256"] != arms["candidate"]["ordinary_replies_sha256"]:
            raise ValueError("ordinary DNS control replies changed")
        for base, candidate in zip(arms["base"]["observations"], arms["candidate"]["observations"]):
            if base.get("name") and base["answers_offered"] == base["max_fitting_answers"] and base != candidate:
                raise ValueError("maximum fitting reply changed")
        print(json.dumps(dict(
            control_commit=BASE, platform=platform.platform(),
            go=subprocess.check_output([args.go, "version"], text=True, env=env).strip(),
            method="In-memory directory and byte streams. Reference dnsmessage encodings determine each name's "
                   "record capacity. The production handler, framed writer and reader verify complete fitting "
                   "replies; the candidate verifies question-only TC replies when a whole RRset cannot fit.",
            driver_sha256=sha(Path(__file__).read_bytes()), fixture_sha256=sha(TEST.read_bytes()),
            **arms), indent=2))


if __name__ == "__main__":
    main()
