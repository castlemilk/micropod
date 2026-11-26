"""Compile Linux 7.3.5 fq's original priority mapper and admission guards."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE_DIGESTS = {
    "sch_fq.c": "29b796533fff2d9b2a71b3e6f4150580ccf7b07d7d87bca3d768079958331038",
    "sch_generic.c": "5396cd77c6e674722da773c652e0309e594c46df4afd467206a70d166c825160",
}
BASE = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"


def read_source(directory, name):
    data = (directory / name).read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_DIGESTS[name]:
        raise ValueError(f"Unexpected contents of {name}")
    return data.decode()


def block(text, prefix):
    start = text.index(prefix)
    depth = 1
    pos = text.index("{", start) + 1
    while depth:
        depth += (text[pos] == "{") - (text[pos] == "}")
        pos += 1
    return text[start:pos]


def generate(source_dir):
    fq = read_source(source_dir, "sch_fq.c")
    generic = read_source(source_dir, "sch_generic.c")
    band_cap = int(re.search(r"sch->limit\s*= (\d+);", fq)[1])
    flow_cap = int(re.search(r"q->flow_plimit\s*= (\d+);", fq)[1])
    mapper = block(fq, "static u8 fq_prio2band(")
    compressor = block(fq, "static void fq_prio2band_compress_crumb(")
    table = block(generic, "const u8 sch_default_prio2band") + ";"
    enqueue = fq[fq.index("static int fq_enqueue("):]
    band_guard = enqueue[enqueue.index("band = fq_prio2band"):enqueue.index("now = ktime_get_ns()")]
    flow_guard = block(enqueue, "if (unlikely(f->qlen >= q->flow_plimit))")
    # The caller supplies the already classified, non-internal socket flow.
    # Its fresh packet has no future timestamp and the bulk queue is busy.
    template = (HERE / "fixture.c.in").read_text()
    code = template.replace("/* @MAPPING */", "\n".join((table, mapper, compressor)))
    code = code.replace("/* @BAND */", band_guard).replace("/* @FLOW */", flow_guard)
    return code, band_cap, flow_cap


def run(source_dir):
    code, band_cap, flow_cap = generate(source_dir)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        source = root / "fixture.c"
        binary = root / "fixture"
        source.write_text(code)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        str(source), "-o", str(binary)], check=True)
        rows = []
        for bulk_flows, flow_depth in [(32, 0), (100, 0), (32, flow_cap)]:
            for priority in (0, 6):
                args = [str(x) for x in (band_cap, flow_cap, bulk_flows, flow_depth, priority)]
                out = subprocess.check_output([str(binary), *args], text=True)
                band, reason = out.strip().split()
                rows.append(dict(bulk_flows=bulk_flows, queued_bulk_skbs=bulk_flows * flow_cap,
                                 probe_flow_queued_skbs=flow_depth, priority=priority,
                                 selected_band=int(band), admission=reason))
    assert [r["admission"] for r in rows] == [
        "admit", "admit", "band_limit", "admit", "flow_limit", "flow_limit"]
    return dict(date="2026-11-24", stable_id="231.08", tier="source/fixture",
                micropod_revision=BASE, kernel="Linux 7.3.5", source_sha256=SOURCE_DIGESTS,
                generated_c_sha256=hashlib.sha256(code.encode()).hexdigest(),
                stock_band_limit_skbs=band_cap, stock_flow_limit_skbs=flow_cap, probes=rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source_dir", type=Path, nargs="?", default=HERE / "source")
    args = parser.parse_args()
    print(json.dumps(run(args.source_dir), indent=2))
