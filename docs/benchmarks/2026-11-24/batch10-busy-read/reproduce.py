"""Exercise Linux TCP read-side busy polling for the archived Go HTTP service."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
KERNEL = {
    "include/net/busy_poll.h": "f6b0ecee25b0081a4c62778021b2bb2424e048db522a79c68e4a631140ea067c",
    "include/net/sock.h": "3669c26dc04a88bc5171e1aee82e1c2007181a5c565d6ccfb547641e792d70b6",
    "net/core/dev.c": "8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274",
    "net/core/sock.c": "0b693d70e0d9752caaca9816fadc82802ff8c2c62612b7bd5fb2691045a2e4a0",
    "net/ipv4/tcp.c": "ddac70efc3730e0f6be6d63b8b08df3a028996403716d8298e097320ee9386df",
    "net/ipv4/tcp_minisocks.c": "f874f19978fa92c57a0eb90c7e3be44c6208010550d484bde3eecb099e6823dd",
    "net/ipv4/inet_connection_sock.c": "186a4d560ced1c58b52a0636b434315ce979f0864ea4b6629d45cfdb7d3fc6e7",
    "net/socket.c": "2a22530e9b5ee06c7023beac9e31c8a1bbadc75d3e42cd77c11198ae61fe8c20",
}
IMAGE_CONFIG = "80996a25c9c753fcaf3f421a3f61557497b8ab539bdd68076074d181cfa71889"
SERVICE = "11616563078329f6d13d5c3b50628c57b431537c2fbd05dda7d8136d5f4572ba"


def digest(b):
    return hashlib.sha256(b).hexdigest()


def function(text, start):
    begin = text.index(start)
    while ";" in text[begin:text.index("{", begin)]:
        begin = text.index(start, begin + len(start))
    return text[begin:text.index("\n}", begin) + 2]


def span(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin) + len(end)]


def main():
    linux, image, goroot, config = map(Path, sys.argv[1:])
    src = {}
    for name, checksum in KERNEL.items():
        b = (linux / name).read_bytes()
        if digest(b) != checksum:
            raise ValueError(name)
        src[name] = b.decode()
    cfg = config.read_bytes()
    assert b"\nCONFIG_NR_CPUS=255\n" in cfg and b"\nCONFIG_NET_RX_BUSY_POLL=y\n" in cfg
    with tarfile.open(image) as tar:
        manifest = json.load(tar.extractfile("manifest.json"))[0]
        cfg_bytes = tar.extractfile(manifest["Config"]).read()
        assert digest(cfg_bytes) == IMAGE_CONFIG and len(manifest["Layers"]) == 1
        assert json.loads(cfg_bytes)["config"]["Entrypoint"] == ["/netbench"]
        with tarfile.open(fileobj=tar.extractfile(manifest["Layers"][0]), mode="r:*") as layer:
            service = layer.extractfile("netbench").read()
    assert digest(service) == SERVICE
    for symbol in ["net/http.(*Server).Serve", "net/http.ServeContent", "internal/poll.(*FD).Read",
                   "internal/poll.accept", "net.Listen", "runtime.netpoll"]:
        assert symbol.encode() + b"\0" in service
    go_evidence = {}
    for path, contents in {
        "internal/poll/sock_cloexec.go": ["Accept4Func(s, syscall.SOCK_NONBLOCK|syscall.SOCK_CLOEXEC)"],
        "internal/poll/fd_unix.go": ["ignoringEINTRIO(syscall.Read, fd.Sysfd, p)", "fd.pd.waitRead(fd.isFile)"],
    }.items():
        data = (goroot / "src" / path).read_bytes()
        assert all(x.encode() in data for x in contents)
        go_evidence[path] = digest(data)
    tcp, sock, bp = [src[k] for k in ["net/ipv4/tcp.c", "net/core/sock.c", "include/net/busy_poll.h"]]
    assert "sock_copy(newsk, sk);" in sock and "unsafe_memcpy(&nsk->sk_dontcopy_end" in sock
    layout = function(src["include/net/sock.h"], "struct sock {")
    assert layout.index("struct sock_common") < layout.index("sk_ll_usec;")
    assert "#define sk_dontcopy_end\t\t__sk_common.skc_dontcopy_end" in layout
    assert "return sk_clone(sk, priority, true);" in src["include/net/sock.h"]
    assert "newsk = sk_clone_lock(sk, priority);" in src["net/ipv4/inet_connection_sock.c"]
    assert "newsk = inet_csk_clone_lock(sk," in src["net/ipv4/tcp_minisocks.c"]
    assert "sk_ll_usec" not in src["net/ipv4/inet_connection_sock.c"] + src["net/ipv4/tcp_minisocks.c"]
    dev = src["net/core/dev.c"]
    assert "if (!loop_end || loop_end(loop_end_arg, start_time))\n\t\t\tbreak;" in dev
    for signature in ["int tcp_sendmsg_locked(", "int tcp_sendmsg("]:
        assert "busy_loop" not in function(tcp, signature)
    read = function(src["net/socket.c"], "static ssize_t sock_read_iter(")
    recv = function(tcp, "int tcp_recvmsg(")
    template = (HERE / "fixture.c.in").read_text()
    for key, value in {
        "CAN": function(bp, "static inline bool sk_can_busy_loop("),
        "VALID": function(bp, "static inline bool napi_id_valid("),
        "LOOP": function(bp, "static inline void sk_busy_loop("),
        "DEFAULT": span(sock, "sk->sk_ll_usec\t\t=", "READ_ONCE(sysctl_net_busy_read);"),
        "READ_FLAGS": span(read, "if (file->f_flags & O_NONBLOCK", "msg.msg_flags = MSG_DONTWAIT;"),
        "RECV": span(recv, "if (sk_can_busy_loop(sk)", "sk_busy_loop(sk, flags & MSG_DONTWAIT);"),
    }.items():
        template = template.replace("@" + key + "@", value)
    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        binary = temp / "netbench"
        binary.write_bytes(service)
        build = subprocess.check_output([str(goroot / "bin/go"), "version", "-m", binary], text=True)
        assert build.splitlines()[0].endswith(" go1.27.2") and "GOOS=linux" in build and "GOARCH=arm64" in build
        c = temp / "fixture.c"
        c.write_text(template)
        exe = temp / "fixture"
        subprocess.run(["cc", "-std=c11", "-O1", "-Wall", "-Werror", str(c), "-o", str(exe)], check=True)
        rows = []
        for setting in [0, 50]:
            rows.extend(json.loads(line) for line in subprocess.check_output([exe, str(setting)], text=True).splitlines())
    assert all(r["napi_calls"] == int(r["busy_read_us"] == 50 and r["case"] in
                                      ("new-empty-valid", "blocking-positive")) for r in rows)
    print(json.dumps({"kernel_inputs": KERNEL, "config_sha256": digest(cfg), "image_config": IMAGE_CONFIG,
                      "service_sha256": SERVICE, "go": "go1.27.2 linux arm64", "go_inputs": go_evidence,
                      "busy_poll_us": 0, "cases": rows}, indent=2))


if __name__ == "__main__":
    main()
