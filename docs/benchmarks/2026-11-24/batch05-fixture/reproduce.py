"""Extract both actual DNS frame readers and run identical fixed-work streams."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
BASE = "7d9b565173a901cb18942e00384838da96e0ba98"
SOURCE = "guest/runner/docker_dns_linux.go"


def encoded_sha(value):
    return hashlib.sha256(value).hexdigest()


def changed_once(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


def extract(text, start):
    return text[text.index(start):text.index("func sendDNS(")]


control = subprocess.check_output(["git", "show", f"{BASE}:{SOURCE}"], cwd=HERE).decode()
candidate = changed_once(control, "defer stop()\n\t\t\t\tfor {",
                         "defer stop()\n\t\t\t\tvar scratch [512]byte\n\t\t\t\tfor {")
candidate = changed_once(candidate, "req, err := readDNS(c)", "req, err := readDNSWithBuffer(c, scratch[:])")
candidate = changed_once(candidate,
    "func readDNS(r io.Reader) ([]byte, error) {",
    "func readDNS(r io.Reader) ([]byte, error) {\n\treturn readDNSWithBuffer(r, nil)\n}\n\n"
    "func readDNSWithBuffer(r io.Reader, scratch []byte) ([]byte, error) {")
candidate = changed_once(candidate, "b := make([]byte, length)",
                         "var b []byte\n\tif int(length) <= len(scratch) {\n\t\tb = scratch[:length]\n"
                         "\t} else {\n\t\tb = make([]byte, length)\n\t}")
delta = "".join(difflib.unified_diff(control.splitlines(True), candidate.splitlines(True),
                                     fromfile=f"a/{SOURCE}", tofile=f"b/{SOURCE}")).encode()
assert (HERE / "bounded-reader.patch").read_bytes() == delta
preamble = 'package main\nimport ("encoding/binary";"errors";"io")\n'
readers = preamble + extract(control, "func readDNS(") + extract(candidate, "func readDNSWithBuffer(")
env = {**os.environ, "GOWORK": "off", "GOPROXY": "off", "GOMAXPROCS": "1", "GOTOOLCHAIN": "local"}
go = os.environ.get("GO", "go")
env.pop("GOROOT", None)
env.update(GOTELEMETRY="off", CGO_ENABLED="0", GOSUMDB="off", GOENV="off")
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    env["GOCACHE"] = str(work / "cache")
    (work / "readers.go").write_text(readers)
    (work / "driver.go").write_bytes((HERE / "driver.go").read_bytes())
    subprocess.run([go, "build", "-p", "1", "-o", "check", "driver.go", "readers.go"],
                   cwd=work, env=env, check=True)
    run = json.loads(subprocess.check_output([work / "check"], cwd=work, env=env))
result = dict(issue=231, direction="231.14", revision=BASE, tier="source/fixture",
              go=subprocess.check_output([go, "version"], env=env, text=True).strip(),
              control_sha256=encoded_sha(control.encode()), candidate_sha256=encoded_sha(candidate.encode()),
              patch_sha256=encoded_sha(delta), fixture_sha256=encoded_sha((HERE / "driver.go").read_bytes()),
              reproduce_sha256=encoded_sha(Path(__file__).read_bytes()), **run)
print(json.dumps(result, indent=2))
