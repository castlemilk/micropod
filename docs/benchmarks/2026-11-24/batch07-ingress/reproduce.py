"""Build pinned Linux functions with private in-memory boundary fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
BASE = "a60d203b16b24abd857e1b5c9e817636b241f850"
FILES = {
    "zcrx": ("io_uring/zcrx.c", "81710ffc59b47cacbcabc7f673d298ab7eff6de7e962b9663c88b8dda4f789c2", [
        "struct io_copy_cache {", "static ssize_t io_copy_page(", "static ssize_t io_zcrx_copy_chunk(",
        "static int io_zcrx_copy_frag(", "static int io_zcrx_recv_frag(", "static int\nio_zcrx_recv_skb("]),
    "vsock": ("net/vmw_vsock/virtio_transport_common.c", "fc75cae32ca8ed49e55a59523601d2a8ddab1a52bc0aab8b99750a4ab3d77614", [
        "static u32 virtio_transport_tx_buf_size(", "static s64 virtio_transport_has_space(",
        "u32 virtio_transport_get_credit(", "static void virtio_transport_dec_rx_pkt(",
        "void virtio_transport_inc_tx_pkt(", "static ssize_t\nvirtio_transport_stream_do_dequeue("])
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def section(src, prefix):
    pos = src.rindex("\n"+prefix)+1  # select the definition after any forward declaration
    end = src.index("\n}",pos)+2
    if src[end:end+1] == ";":
        end += 1
    return src[pos:end]+"\n"


def run(kind, tree):
    name, expected, parts = FILES[kind]
    data = (tree/name).read_bytes()
    if sha(data) != expected:
        raise ValueError("wrong kernel version")
    original = "\n".join(section(data.decode(),p) for p in parts)
    source = HERE/(kind + "_fixture.c")
    result = {"stable_id": "232.04" if kind=="vsock" else "233.04", "date":"2026-11-24",
              "base":BASE, "tier":"source/fixture", "kernel":"Linux 7.3.5", "kernel_member":name,
              "kernel_sha256":expected,"original_functions_sha256":sha(original.encode()),
              "fixture_sha256":sha(source.read_bytes()),"reproducer_sha256":sha(Path(__file__).read_bytes()),
              "compiler":subprocess.check_output(["clang","--version"],text=True).splitlines()[0],"attempts":[]}
    with tempfile.TemporaryDirectory() as temp:
        t=Path(temp)
        for arm in ("control","candidate"):
            functions=original
            if kind=="vsock" and arm=="candidate":
                condition="if (fwd_cnt_delta &&\n\t    (free_space < VIRTIO_VSOCK_MAX_PKT_BUF_SIZE || low_rx_bytes))"
                assert functions.count(condition)==1
                functions=functions.replace(condition,"if (fwd_cnt_delta)")
            (t/"code.inc").write_text(functions)
            subprocess.run(["clang","-std=c11","-O1","-Wall","-Werror","-Wno-unused-but-set-variable",
                            "-I",str(t),str(source),"-o",str(t/"fixture")],check=True)
            raw=subprocess.check_output([t/"fixture",arm],text=True)
            result["attempts"].append({"arm":arm,"functions_sha256":sha(functions.encode()),"cases":[json.loads(l) for l in raw.splitlines()]})
    return result


if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("kind",choices=FILES)
    parser.add_argument("kernel_tree",type=Path)
    args=parser.parse_args()
    print(json.dumps(run(args.kind,args.kernel_tree),indent=2))
