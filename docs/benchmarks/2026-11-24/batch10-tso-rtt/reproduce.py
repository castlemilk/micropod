"""Compare two RTT scaling settings using the two unmodified Linux 7.3.5 sender functions."""
import argparse
import gzip
import hashlib
import json
import random
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ARCHIVE = HERE.parents[1] / "2026-11-21/gamma-direct-macvlan.json.gz"
ARCHIVE_HASH = "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976"
KERNEL_TAR = "8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990"
HASHES = {
    "net/ipv4/tcp_output.c": "b55846bf35be5799cc19318c9215aa1b8a9a4881f8e3794cf5dc08b8aa4ea5b7",
    "net/ipv4/tcp_ipv4.c": "bbe547fe1e0a079d42c3c05ccf9f94f70fa70ac33a37d950882bf36890adfdcc",
    "net/core/sock.c": "0b693d70e0d9752caaca9816fadc82802ff8c2c62612b7bd5fb2691045a2e4a0",
}
MIB = 1 << 20
MSS = 1448
SOCKET_GSO_LIMIT = 63 * 1024
SEGMENT_LIMIT = 64
PACING_SHIFT = 10
MIN_SEGMENTS = 2
BASE = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def linux_source(kernel):
    files = {name: (kernel / name).read_bytes() for name in HASHES}
    for name, data in files.items():
        assert digest(data) == HASHES[name], name
    output = files["net/ipv4/tcp_output.c"]
    assert b"max_segs = tcp_tso_segs(sk, mss_now);" in output
    assert b"sysctl_tcp_tso_rtt_log = 9;" in files["net/ipv4/tcp_ipv4.c"]
    assert b"sysctl_tcp_min_tso_segs = 2;" in files["net/ipv4/tcp_ipv4.c"]
    assert b"WRITE_ONCE(sk->sk_pacing_shift, 10);" in files["net/core/sock.c"]
    functions = []
    for name in ("tcp_tso_autosize", "tcp_tso_segs"):
        start = output.index(("static u32 " + name + "(").encode())
        functions.append(output[start:output.index(b"\n}\n", start) + 3])
    return b"\n".join(functions)


def fixture_cases():
    raw = ARCHIVE.read_bytes()
    assert digest(raw) == ARCHIVE_HASH
    study = json.loads(gzip.decompress(raw))
    assert study["baseline_commit"] == "816121afd30fba52bda7828418cd963d4216166b"
    assert study["records"]["workers"]["full-reno"]["controller"] == "reno"
    cases = []
    for i in range(1, 11):
        arm = study["records"]["tuning"][str(i)]["engines"]["full-reno"]
        client = arm["client"]
        counts = client["per_stream_bytes"]
        assert arm["valid"] and len(counts) == 32 and sum(counts) == client["bytes"]
        assert not client["errors"] and not client["reopened"]
        for n, count in enumerate(counts):
            cases.append(dict(group="archived-rate proxy", block=i, stream=n,
                              delivered_bytes=count, window_s=client["window_s"],
                              pacing_Bps=int(count / client["window_s"]), min_rtt_us=128))
    for rate_MiB_s in (8, 32, 64, 128):
        for min_rtt in (8, 128, 511, 512, 1024, 4096):
            cases.append(dict(group="sensitivity control", pacing_Bps=rate_MiB_s * MIB,
                              min_rtt_us=min_rtt))
    return cases


def expected(rate, rtt, setting):
    shift = rtt >> setting
    allowance = SOCKET_GSO_LIMIT >> shift if shift < 32 else 0
    target_bytes = min(SOCKET_GSO_LIMIT, (rate >> PACING_SHIFT) + allowance)
    return min(SEGMENT_LIMIT, max(MIN_SEGMENTS, target_bytes // MSS))


def replay(kernel):
    functions = linux_source(kernel)
    cases = fixture_cases()
    pairs = [[9, 0] if i % 2 == 0 else [0, 9] for i in range(len(cases))]
    random.Random(23101).shuffle(pairs)
    lines = []
    for case, order in zip(cases, pairs):
        for setting in order:
            lines.append(f"{case['pacing_Bps']} {case['min_rtt_us']} {setting} {MSS} "
                         f"{SOCKET_GSO_LIMIT} {SEGMENT_LIMIT} {PACING_SHIFT} {MIN_SEGMENTS}")
    with tempfile.TemporaryDirectory() as work:
        path = Path(work)
        (path / "kernel-functions.h").write_bytes(functions)
        exe = path / "tso"
        subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", work, str(HERE / "fixture.c"), "-o", str(exe)], check=True)
        values = subprocess.check_output([str(exe)], input="\n".join(lines) + "\n",
                                         text=True).splitlines()
    assert len(values) == len(lines)
    for i, (case, order) in enumerate(zip(cases, pairs)):
        case["order"] = order
        case["wanted_segments"] = dict(zip(map(str, order), map(int, values[2*i:2*i+2])))
        for setting in order:
            assert case["wanted_segments"][str(setting)] == expected(
                case["pacing_Bps"], case["min_rtt_us"], setting)
    return dict(date="2026-11-24", stable_id="231.01", tier="source/fixture", analysis_base=BASE,
                kernel="Linux 7.3.5", kernel_tar_sha256=KERNEL_TAR, kernel_sources=HASHES,
                compiled_functions_sha256=digest(functions),
                raw_archive_file=ARCHIVE.name, raw_archive_sha256=ARCHIVE_HASH,
                raw_archive_commit="7a4eb51a04b51f6332ed49561b3dd0bb42ffacd9",
                raw_archive_recording_base="816121afd30fba52bda7828418cd963d4216166b",
                fixture_sha256=digest((HERE / "fixture.c").read_bytes()),
                reproducer_sha256=digest(Path(__file__).read_bytes()),
                compiler=subprocess.check_output(["cc", "--version"], text=True).splitlines()[0],
                fixed=dict(mss_B=MSS, socket_gso_limit_B=SOCKET_GSO_LIMIT,
                           max_segs=SEGMENT_LIMIT, pacing_shift=PACING_SHIFT, min_segs=MIN_SEGMENTS),
                output_units="desired TCP segments per TSO packet before send path constraints",
                assumptions="Archived per-stream delivered B/s are substituted for socket pacing B/s. "
                    "The study did not measure matched pacing rate, minimum RTT or socket GSO limit. "
                    "Every RTT and socket limit is a fixture input.", rows=cases)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("linux_source", type=Path)
    parser.add_argument("new_output", type=Path)
    args = parser.parse_args()
    result = replay(args.linux_source)
    with args.new_output.open("x") as out:
        json.dump(result, out, indent=2)
        out.write("\n")
