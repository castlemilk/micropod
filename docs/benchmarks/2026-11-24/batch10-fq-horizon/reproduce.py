"""Replay Linux fq offload-horizon admission on the pinned direct publication path."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ARCHIVE_SHA = "8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990"
REV = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
DRIVER = "drivers/net/macvlan.c"
FQ = "net/sched/sch_fq.c"
FIELD = b"max_pacing_offload_horizon"
REPO = Path(__file__).resolve().parents[4]


def scan_archive(archive):
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != ARCHIVE_SHA:
            raise ValueError("Expected the pinned Linux 7.3.5 source archive")
    hits = {}
    sources = {}
    with tarfile.open(archive, "r|xz") as tree:
        for item in tree:
            if not item.isfile() or not item.name.endswith((".c", ".h", ".rs")):
                continue
            path = item.name.removeprefix("linux-7.3.5/")
            content = tree.extractfile(item).read()
            if FIELD in content:
                hits[path] = [line.strip().decode() for line in content.splitlines() if FIELD in line]
            if path in (DRIVER, "drivers/net/virtio_net.c", FQ, "net/core/dev.c"):
                sources[path] = content
    return hits, sources


def run_fixture(fq):
    start = fq.index(b"if (tb[TCA_FQ_OFFLOAD_HORIZON]) {")
    block = fq[start:fq.index(b"\n\tif (!err)", start)].decode()
    harness = r"""
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
typedef uint64_t u64;
#define NSEC_PER_USEC 1000
#define TCA_FQ_OFFLOAD_HORIZON 0
#define nla_get_u32(x) (*(x))
#define WRITE_ONCE(x,y) ((x)=(y))
#define NL_SET_ERR_MSG_MOD(context,msg) ((void)0)
#define qdisc_dev(sch) (sch)
struct device { u64 max_pacing_offload_horizon; };
struct fq { u64 offload_horizon; };
static void trial(unsigned cap_ns, unsigned requested_us) {
    struct device dev = {cap_ns}, *sch = &dev;
    struct fq state = {0}, *q = &state;
    unsigned *tb[] = {&requested_us};
    int err = 0;
    @BLOCK@
    printf("%u %u %d %llu\n", cap_ns, requested_us, err,
           (unsigned long long)q->offload_horizon);
}
int main(void) {
    trial(0, 0);
    trial(0, 20);
    trial(20000, 20);
    return 0;
}
""".replace("@BLOCK@", block)
    with tempfile.TemporaryDirectory() as tmp:
        src, exe = Path(tmp)/"horizon.c", Path(tmp)/"horizon"
        src.write_text(harness)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(src), "-o", str(exe)], check=True)
        output = subprocess.check_output([str(exe)], text=True)
    return [dict(zip(("device_cap_ns", "request_us", "return_code", "effective_ns"), map(int,line.split())))
            for line in output.splitlines()]


def main():
    sources_path = Path(sys.argv[1])
    hits, sources = scan_archive(sources_path)
    assert DRIVER not in hits and "drivers/net/virtio_net.c" not in hits and "net/core/dev.c" not in hits
    assert b"dev = kvzalloc_flex(*dev, priv, sizeof_priv," in sources["net/core/dev.c"]
    raw = subprocess.check_output(["git", "-C", str(REPO), "show", REV + ":guest/runner/docker_port_direct_linux.go"])
    assert b'Name: "mppub0"' in raw and b"netlink.MACVLAN_MODE_PRIVATE" in raw
    assert b'paceDefaultQueue(end.pod, end.link, "noqueue")' in raw
    rows = run_fixture(sources[FQ])
    assert [x["return_code"] for x in rows] == [0, -22, 0]
    assert [x["effective_ns"] for x in rows] == [0, 0, 20000]
    result = dict(kernel_version="7.3.5", kernel_archive_sha256=ARCHIVE_SHA,
                  micropod_revision=REV, micropod_direct_source_sha256=hashlib.sha256(raw).hexdigest(),
                  kernel_source_sha256={k:hashlib.sha256(v).hexdigest() for k,v in sorted(sources.items())},
                  source_field_references=hits, stock_control_and_candidate=rows[:2],
                  synthetic_capable_device_check=rows[2], network_samples=0)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
