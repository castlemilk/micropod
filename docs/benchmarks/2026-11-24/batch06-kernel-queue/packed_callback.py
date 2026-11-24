"""Exercise both exact Linux packed-ring callback arms in a sequential completion fixture."""
import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MEMBERS = {
    "drivers/virtio/virtio_ring.c": ("59c42c2eeb83355a0f4f5d5160be659671149632818b2813d68fdbf8f9055e85",
        ["static inline u16 vring_read_packed_desc_flags(", "static bool packed_used_wrap_counter(",
         "static u16 packed_last_used(", "static inline bool is_used_desc_packed(", "static bool virtqueue_poll_packed(",
         "static unsigned int virtqueue_enable_cb_prepare_packed(", "static bool virtqueue_enable_cb_delayed_packed("]),
    "include/uapi/linux/virtio_ring.h": ("d5c9d2126e22415141e8d569fdb16584e920adfd4e30e38cd2031b6f741bb92f",
        ["static inline int vring_need_event("]),
}

def sha(data):
    return hashlib.sha256(data).hexdigest()

def run(root):
    chunks = []
    for path, (digest, signatures) in MEMBERS.items():
        data = (root / path).read_bytes()
        if sha(data) != digest:
            raise ValueError("kernel member hash mismatch: "+path)
        for sig in signatures:
            start=data.index(sig.encode())
            end=data.index(b"\n}\n",start)+3
            chunks.append(data[start:end])
    functions=b"\n".join(chunks)
    fixture=HERE/"packed_callback.c"
    with tempfile.TemporaryDirectory() as temp:
        d=Path(temp)
        (d/"linux_functions.inc").write_bytes(functions)
        subprocess.run(["cc","-Wall","-Wextra","-Werror","-std=c11","-I",str(d),str(fixture),"-o",str(d/"replay")],check=True)
        stdout=subprocess.check_output([d/"replay"],text=True)
    metrics=["reclaimed","notifications","first_notification_after","max_additional_completions_waited","sum_additional_completions_waited"]
    cases=[]
    for line in stdout.splitlines():
        start,count,mode,*values=map(int,line.split())
        cases.append(dict(start=start, descriptors=count,policy="immediate" if mode else "delayed",**dict(zip(metrics,values))))
    assert len(cases)==36 and all(row["reclaimed"]==row["descriptors"] for row in cases)
    assert len({(r["start"],r["descriptors"],r["policy"]) for r in cases})==36
    return dict(id="231.02",date="2026-11-24",tier="source/fixture",replay_base="17bcd4355234b11da3a7a1da2ded52f4dc20f5d1",
        linux="7.3.5",source_tar_sha256="8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990",
        source_members={k:v[0] for k,v in MEMBERS.items()},functions_sha256=sha(functions),fixture_sha256=sha(fixture.read_bytes()),
        replay_sha256=sha(Path(__file__).read_bytes()),cc=subprocess.check_output(["cc","--version"],text=True).splitlines()[0],
        conditions="256 slots, packed ring, EVENT_IDX set, one descriptor per buffer, ordered single completions, prompt service only following a notification, no parallel CPU or timing.",
        observations=cases)
if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("linux_tree",type=Path)
    print(json.dumps(run(p.parse_args().linux_tree),indent=2))
