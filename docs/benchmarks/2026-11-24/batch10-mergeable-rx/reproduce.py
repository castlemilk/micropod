"""Compile the RX posting path of the pinned Linux 7.3.5 virtio-net driver."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

SOURCE_HASH = "d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace"
BASE = Path(__file__).resolve().parent


def original_functions(driver):
    signatures = [
        "static bool virtnet_check_guest_gso(",
        "static void virtnet_set_big_packets(",
        "static int virtnet_rq_submit(",
        "static int add_recvbuf_big(",
        "static unsigned int get_mergeable_buf_len(",
        "static int add_recvbuf_mergeable(",
        "static bool try_fill_recv(",
        "static unsigned int mergeable_min_buf_len(",
    ]
    functions = []
    for signature in signatures:
        start = driver.index(signature)
        end = driver.index("\n}", start) + 2
        functions.append(driver[start:end])
    return "\n\n".join(functions)


def posts_for_frame(post_bytes, header_bytes, frame_bytes, mergeable):
    # The device writes a single virtio header ahead of the first frame byte.
    needed = header_bytes + frame_bytes
    if not mergeable and needed > post_bytes:
        return None
    return (needed + post_bytes - 1) // post_bytes


def main():
    source = Path(sys.argv[1]).read_bytes()
    if hashlib.sha256(source).hexdigest() != SOURCE_HASH:
        raise ValueError("unexpected Linux virtio_net.c input")
    driver = source.decode()
    feature = "if (virtio_has_feature(vdev, VIRTIO_NET_F_MRG_RXBUF)) {"
    start = driver.index(feature)
    end = driver.index("\n\t}", start) + 3
    spec = (BASE / "fixture.c.in").read_text()
    src = spec.replace("@FUNCTIONS@", original_functions(driver))
    src = src.replace("@FEATURE@", driver[start:end])
    rows = []
    with tempfile.TemporaryDirectory() as temp:
        c = Path(temp) / "rx.c"
        exe = Path(temp) / "rx"
        c.write_text(src)
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-O1", "-Wall", "-Werror",
                        str(c), "-o", str(exe)], check=True)
        for feature_on in (0, 1):
            row = json.loads(subprocess.check_output([str(exe), str(feature_on)]))
            assert row["posted_chains"] == 32
            assert len(set(row["chain_lengths_bytes"])) == 1
            assert len(set(row["chain_sg_elements"])) == 1
            assert row["feature_on"] == feature_on
            row["modeled_posts_per_frame"] = {
                str(frame): posts_for_frame(row["chain_lengths_bytes"][0], 12, frame, feature_on)
                for frame in (1514, 63 * 1024)
            }
            rows.append(row)
    print(json.dumps({"linux_source_sha256": SOURCE_HASH, "arms": rows}, indent=2))


if __name__ == "__main__":
    main()
