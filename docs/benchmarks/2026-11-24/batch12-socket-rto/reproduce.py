"""Check the actual release route and kernel config, then compile the pinned Linux timer paths."""
import argparse, gzip, hashlib, json, os, subprocess, tempfile
from pathlib import Path

HERE=Path(__file__).resolve().parent
REV="2e9b37c1e68334c443d71b729f0bd6334d824ddd"
INC="48203cdb3f765ef4712939735249fb48005f1f4f8d39ab49611b2cc084962abd"
ARCHIVES={
    "gamma-vm-scheduling.json.gz":"29f33979ca570117e54addabfe07aecb452ab23af7f0b9e039c996dbb9611e51",
    "gamma-direct-macvlan.json.gz":"cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976",
}

def git_bytes(path):
    return subprocess.check_output(["git","show",f"{REV}:{path}"],cwd=HERE)


def run(out):
    assert hashlib.sha256((HERE/"timers.inc").read_bytes()).hexdigest()==INC
    source=git_bytes("guest/runner/docker_port_direct_linux.go").decode()
    assert 'Congctl: "reno", RtoMin: 20, RtoMinLock: true' in source
    evidence={}
    for name,pin in ARCHIVES.items():
        raw=git_bytes("docs/benchmarks/2026-11-21/"+name)
        assert hashlib.sha256(raw).hexdigest()==pin
        evidence[name]=json.loads(gzip.decompress(raw))
    route=evidence["gamma-vm-scheduling.json.gz"]["scopes"]["lab-0"]["controller_proofs"]["reno"]["route"]
    assert [route[k] for k in ("RtoMin","RtoMinLock","Congctl")]==[20,True,"reno"]
    krn=evidence["gamma-direct-macvlan.json.gz"]["kernels"]
    assert "CONFIG_HZ=250" in krn["full"]["config"].splitlines()
    with tempfile.TemporaryDirectory() as d:
        exe=Path(d)/"fixture"
        subprocess.run([os.environ.get("CC","cc"),"-std=c11","-O2","-Wall","-Wextra","-Werror","-Wno-sign-compare",
                        str(HERE/"socket_fixture.c"),"-o",str(exe)],check=True)
        lines=subprocess.check_output([str(exe)],text=True).splitlines()
    keys=("route_locked","packets_out","candidate","set_status","get_option_us",
          "effective_floor_us","scheduled_probe_us")
    rows=[dict(zip(keys,map(int,line.split()),strict=True)) for line in lines]
    expected={(0,1):(204000,12000),(0,2):(4000,4000),(1,1):(24000,24000),(1,2):(4000,4000)}
    assert len(rows)==8
    for r in rows:
        lock,n,arm=(r[k] for k in ("route_locked","packets_out","candidate"))
        local=8000 if arm else 200000
        assert r["set_status"]==0 and r["get_option_us"]==local
        assert r["effective_floor_us"]==(20000 if lock else local)
        assert r["scheduled_probe_us"]==expected[lock,n][arm]
    data={"direction":"231.08","micropod_revision":REV,"linux_release":"v7.3.5",
          "kernel_source_archive_sha256":krn["source_sha256"],"excerpt_sha256":INC,
          "archived_route":route,"historical_files_sha256":ARCHIVES,
          "release_image_sha256":krn["full"]["image_sha256"],"kernel_hz":250,"input_srtt_us":1000,
          "rto_remaining_us":400000,"tcp_early_retrans":3,"sack":True,
          "arms":"Control initialized from stock netns TCP_RTO_MIN default. Candidate then sets TCP_RTO_MIN_US=8000. No route changes within any pair.",
          "rows":rows}
    with out.open("x") as fp:
        json.dump(data,fp,indent=2);fp.write("\n")

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("output",type=Path)
    run(p.parse_args().output)
