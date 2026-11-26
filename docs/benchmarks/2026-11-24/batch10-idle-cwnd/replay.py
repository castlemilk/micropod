"""Verify and compile congestion-window policies directly from the retained Linux 7.3.5 tarball."""
import csv
import hashlib
import io
import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ARCHIVE_SHA = "8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990"
paths = ("include/net/tcp.h", "net/ipv4/tcp_output.c", "net/ipv4/tcp_ipv4.c")

def digest(data):
    return hashlib.sha256(data).hexdigest()

def extract_function(data, start):
    pos = data.index(b"\n" + start.encode() + b"(") + 1
    return data[pos:data.index(b"\n}\n", pos) + 3]

def main():
    archive = pathlib.Path(sys.argv[1])
    with archive.open("rb") as inp:
        assert hashlib.file_digest(inp, "sha256").hexdigest() == ARCHIVE_SHA
    expected = {"linux-7.3.5/" + path: path for path in paths}
    sources = {}
    with tarfile.open(archive, "r|xz") as tar:
        for member in tar:
            if member.name in expected:
                sources[expected[member.name]] = tar.extractfile(member).read()
            if len(sources) == len(paths):
                break
    header, out, ipv4 = (sources[key] for key in paths)
    assert b"net->ipv4.sysctl_tcp_slow_start_after_idle = 1;" in ipv4
    functions = [(header, "static inline __u32 tcp_current_ssthresh"),
                 (header, "static inline bool tcp_is_cwnd_limited"),
                 (out, "void tcp_cwnd_restart"),
                 (header, "static inline void tcp_slow_start_after_idle_check"),
                 (out, "static void tcp_cwnd_application_limited"),
                 (out, "static void tcp_cwnd_validate")]
    policies = b"\n".join(extract_function(src, name) for src, name in functions)
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        (work / "policies.inc").write_bytes(policies)
        exe = work / "idle"
        subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", tmp, str(HERE / "fixture.c"), "-o", str(exe)], check=True)
        raw = subprocess.check_output([exe], text=True)
    columns = "case position slow_start_after_idle path elapsed_ticks outstanding_segments starting_cwnd_segments observed_cwnd_segments restart_events".split()
    rows = [{k:(v if k in ("case", "path") else int(v)) for k,v in record.items()}
            for record in csv.DictReader(io.StringIO(raw), fieldnames=columns)]
    assert len(rows)==24 and len({(r["case"],r["slow_start_after_idle"]) for r in rows})==24
    assert all(r["starting_cwnd_segments"]==r["observed_cwnd_segments"] for r in rows if r["slow_start_after_idle"]==0)
    print(json.dumps(dict(date="2026-11-24", direction="231.08", tier="source/fixture",
                          revision="2e9b37c1e68334c443d71b729f0bd6334d824ddd",
                          archive_sha256=ARCHIVE_SHA, sources_sha256={k:digest(v) for k,v in sources.items()},
                          functions_sha256=digest(policies), fixture_sha256=digest((HERE/"fixture.c").read_bytes()),
                          replay_sha256=digest(pathlib.Path(__file__).read_bytes()),
                          compiler=subprocess.check_output(["cc","--version"],text=True).splitlines()[0],
                          rto_ticks=100,initial_cwnd_segments=10,rows=rows),indent=2))
if __name__ == "__main__":
    main()
