"""Replay stock tcp_push policy and separately recover two archived namespace counter pairs."""
from hashlib import sha256
import gzip
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ARCHIVE = HERE.parent.parent / "2026-11-21/gamma-mixed-path.json.gz"
BASE = "ad9d174eda5eb499e0e15675829e21a00d836f84"

def digest(data):
    return sha256(data).hexdigest()

def read_context():
    data = ARCHIVE.read_bytes()
    assert digest(data) == "09ebe5510401244cd6d299c1d0cf6dd8f88b256bf14b8c2c14f6db3eff61b74a"
    study = json.loads(gzip.decompress(data))
    res = []
    for scope in ["control","trial"]:
        points = {}
        for phase in ["before","after"]:
            member = f"diagnostics/{scope}/namespace.{phase}"
            proc = study["records"][member]["/proc/net/netstat"]
            names, values = [line.split()[1:] for line in proc.splitlines() if line.startswith("TcpExt:")]
            assert len(names)==len(set(names))==len(values)
            value = dict(zip(names,map(int,values),strict=True))
            points[phase] = dict(member=member, proc_sha256=digest(proc.encode()),
                                 TCPAutoCorking=value["TCPAutoCorking"],TCPOrigDataSent=value["TCPOrigDataSent"])
        delta = {k:points["after"][k]-points["before"][k] for k in ["TCPAutoCorking","TCPOrigDataSent"]}
        assert min(delta.values())>=0 and delta["TCPOrigDataSent"]>0
        trace = study["records"][f"diagnostics/{scope}/trace.json"]
        res.append(dict(scope=scope, snapshots=points, delta=delta,
                        events_per_million_orig_data_segments=1e6*delta["TCPAutoCorking"]/delta["TCPOrigDataSent"],
                        trace_streams=trace["streams"],trace_fresh_iterations=trace["fresh"]["iterations"],
                        trace_fresh_incomplete_phase_samples=trace["fresh"]["incomplete_phase_samples"],
                        trace_reopens=trace["reopened_connections"]))
    return dict(archive=ARCHIVE.name, compressed_sha256=digest(data), study=study["run"],
                study_baseline=study["baseline_commit"], scopes=res)

def replay(root):
    tcp = (root/"net/ipv4/tcp.c").read_bytes()
    ipv4 = (root/"net/ipv4/tcp_ipv4.c").read_bytes()
    assert digest(tcp)=="ddac70efc3730e0f6be6d63b8b08df3a028996403716d8298e097320ee9386df"
    assert digest(ipv4)=="bbe547fe1e0a079d42c3c05ccf9f94f70fa70ac33a37d950882bf36890adfdcc"
    assert b"net->ipv4.sysctl_tcp_autocorking = 1;" in ipv4
    parts=[]
    for signature in [b"static bool tcp_should_autocork(",b"void tcp_push("]:
        start=tcp.index(b"\n"+signature)+1
        parts.append(tcp[start:tcp.index(b"\n}\n",start)+3])
    code=b'\n'.join(parts)
    with tempfile.TemporaryDirectory() as tmp:
        work=Path(tmp)
        (work/"tcp_functions.inc").write_bytes(code)
        exe=work/"push"
        subprocess.run(["cc","-std=c11","-O2","-Wall","-Wextra","-Werror","-I",tmp,
                        str(HERE/"push.c"),"-o",str(exe)],check=True)
        lines=subprocess.check_output([exe],text=True).splitlines()
    names="sysctl_autocorking skb_bytes size_goal_bytes retransmit_queue_populated skb_truesize_bytes outstanding_first_bytes outstanding_recheck_bytes throttled_before collapsible push_pending_calls autocork_events throttled_after refcount_reads".split()
    rows=[]
    for line in lines:
        state,*nums=line.split()
        rows.append(dict(state=state,**dict(zip(names,map(int,nums),strict=True))))
    assert len(rows)==20 and len({(r["state"],r["sysctl_autocorking"]) for r in rows})==20
    return dict(date="2026-11-24", stable_id="231.08", micropod_base=BASE, tier="source/fixture",
                linux="7.3.5", tar_sha256="8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990",
                tree_sha256={"net/ipv4/tcp.c":digest(tcp),"net/ipv4/tcp_ipv4.c":digest(ipv4)},
                compiled_fragment_sha256=digest(code), fixture_sha256=digest((HERE/"push.c").read_bytes()),
                reproducer_sha256=digest(Path(__file__).read_bytes()),
                compiler=subprocess.check_output(["cc","--version"],text=True).splitlines()[0],
                inputs="One nonempty tail, no MSG_MORE, NODELAY, fixed 1460 B MSS. Supplied state of external helpers. "
                       "Only actual calls of tcp_push and tcp_should_autocork compiled. The instrumented pending-frames "
                       "boundary records decisions without sending packets. A later refcount sample can represent a TX completion.",
                rows=rows, archived_context=read_context())

if __name__=="__main__":
    print(json.dumps(replay(Path(sys.argv[1])),indent=2))
