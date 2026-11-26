"""Compile selected unmodified functions from the pinned Linux 7.3.5 source."""
from hashlib import sha256
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
BASE = "ad9d174eda5eb499e0e15675829e21a00d836f84"
TAR = "8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990"
FQ = "29b796533fff2d9b2a71b3e6f4150580ccf7b07d7d87bca3d768079958331038"
SCHED = ["void fq_flow_set_detached", "bool fq_flow_is_detached", "void fq_flow_add_tail",
         "struct fq_flow *fq_classify", "struct sk_buff *fq_peek", "void fq_erase_head",
         "void fq_dequeue_skb", "void flow_queue_add", "bool fq_packet_beyond_horizon",
         "int fq_enqueue", "struct fq_flow_head *fq_pband_head_select", "struct sk_buff *fq_dequeue"]

def digest(data):
    return sha256(data).hexdigest()

def extract(data, signatures, prefix):
    pieces = []
    for sig in signatures:
        start = data.index(b"\n" + prefix + sig.encode() + b"(") + 1
        end = data.index(b"\n}\n", start) + 3
        pieces.append(data[start:end])
    return b"\n".join(pieces)

def run(root, mode):
    src = (root / "net/sched/sch_fq.c").read_bytes()
    assert digest(src) == FQ
    fragment = extract(src, SCHED, b"static ")
    assert b"q->flow_refill_delay\t= msecs_to_jiffies(40)" in src
    fields = dict(date="2026-11-24", stable_id="231.08", tier="source/fixture", micropod_base=BASE,
                  linux="7.3.5", archive_sha256=TAR, sch_fq_sha256=FQ,
                  scheduler_functions=SCHED, extracted_scheduler_sha256=digest(fragment))
    harness = HERE / (mode + ".c")
    fields["local_sha256"] = {p.name:digest(p.read_bytes()) for p in (harness, HERE/"fq_shim.h", Path(__file__))}
    fields["compiler"] = subprocess.check_output(["cc", "--version"], text=True).splitlines()[0]
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        (work / "fq_functions.inc").write_bytes(fragment)
        if mode == "refill":
            (work / "mark_hook.inc").write_text("#define INET_ECN_set_ce(skb) abort()\n")
        elif mode == "mark":
            ecn = (root / "include/net/inet_ecn.h").read_bytes()
            checksum = (root / "include/net/checksum.h").read_bytes()
            assert digest(ecn) == "ecd0c958702ca4edc575f4c015c6ffb11b7c8829cc6fb83dc2df67236ad6d0a9"
            assert digest(checksum) == "4251ff74db367041713098ed0723713532bfe1436a380fd0a4ad05a8ed16a38a"
            assert b"q->ce_threshold\t\t= (u64)NSEC_PER_USEC * ~0U" in src
            marking = (extract(checksum, ["__sum16 csum16_add"], b"static __always_inline ") +
                       extract(ecn, ["int IP_ECN_set_ce", "int INET_ECN_set_ce"], b"static inline "))
            (work / "mark_hook.inc").write_bytes(b'#include "ecn_support.h"\n' + marking)
            fields["kernel_marking"] = dict(inet_ecn_sha256=digest(ecn), checksum_sha256=digest(checksum),
                                             extracted_marking_sha256=digest(marking))
            fields["local_sha256"]["ecn_support.h"] = digest((HERE/"ecn_support.h").read_bytes())
        else:
            raise ValueError(mode)
        exe = work / "run"
        subprocess.run(["cc","-std=c11","-O2","-Wall","-Wextra","-Werror","-I",tmp,"-I",str(HERE),
                        str(harness),"-o",str(exe)],check=True)
        lines = subprocess.check_output([exe],text=True).splitlines()
    rows = []
    if mode == "mark":
        names = ["threshold_enabled", "original_ecn", "dequeue_lateness_ns", "final_ecn", "qdisc_ce_counter",
                 "checksum_before", "checksum_after", "ipv4_checksum_folded", "drained_skb_bytes"]
        rows = [dict(zip(names,map(int,line.split()),strict=True)) for line in lines]
        assert len(rows)==len({(r["original_ecn"],r["dequeue_lateness_ns"],r["threshold_enabled"]) for r in rows})==32
        assert all(r["ipv4_checksum_folded"]==65535 and r["drained_skb_bytes"]==1514 for r in rows)
        return dict(**fields, control_ce_threshold_ns=1000*(2**32-1), candidate_ce_threshold_ns=2000000,
                    fixture="One single-band IPv4 SKB eligible at the supplied timestamp, a separate "
                    "on-time old-flow SKB keeps classification off the internal fast path. Counter delta "
                    "and L3 header observed after dequeue, before the old SKB. All 4 ECN codepoints.",
                    rows=rows)
    for line in lines:
        d, idle, size, before, after, consumed, order = line.split()
        d, idle, size, before, after, consumed = map(int, (d,idle,size,before,after,consumed))
        assert order.count('O')+consumed==64 and order.count('R')==6 and order.count('F')==1
        ahead = order[:order.index('F')]
        rows.append(dict(refill_delay_ms=4*d, idle_ms=4*idle, recurring_skb_bytes=size,
                         credit_before_bytes=before, credit_on_return_bytes=after,
                         warm_background_dequeues=consumed, subsequent_dequeue_order=order,
                         packets_ahead_of_short=len(ahead),
                         bytes_ahead_of_short=ahead.count('O')*1514 + ahead.count('R')*size))
    assert len(rows)==len({(r["refill_delay_ms"],r["idle_ms"],r["recurring_skb_bytes"]) for r in rows})==16
    return dict(**fields,fixture="250 Hz ticks, one eligible band, no pacing delay. One old bulk flow with 64 1514 B SKBs. A 15000 B transmission leaves the recurring flow with 140 B credit after real dequeue/detachment. Its six SKBs return before a separate new 256 B response.",rows=rows)

if __name__=="__main__":
    print(json.dumps(run(Path(sys.argv[1]),sys.argv[2]), indent=2))
