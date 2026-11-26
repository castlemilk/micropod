"""Read socket and delivery evidence from an already-serving private MTU fixture."""
import argparse
import hashlib
import http.client
import ipaddress
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[3] / "scripts/relaybench"))
import gamma_pilot as pilot
import mtu_path

SIZE = 8 << 20
BODY_HASH = hashlib.sha256(b"micropod" * (SIZE // 8)).hexdigest()
KEY = "MICROPOD_BENCH_PRIVATE_PUBLICATION_MTU"


def read(path):
    return json.loads(path.read_text())


def check(condition, error):
    if not condition:
        raise ValueError(error)


def established_service(raw, service, gateway):
    lines = [line.strip() for line in raw.splitlines() if line.strip()]
    check(len(lines) == 2 and lines[1].split()[0] == "reno", "need exactly one established Reno service socket")

    def endpoint(text):
        addr, port = text.rsplit(":", 1)
        ip = ipaddress.ip_address(addr.strip("[]"))
        return str(getattr(ip, "ipv4_mapped", None) or ip), int(port)

    local, peer = map(endpoint, lines[0].split()[-2:])
    check(local == (service, 8080) and peer[0] == gateway and 0 < peer[1] <= 65535,
          "accepted service socket does not match the DNAT service and gateway")
    fields = {}
    for k in ("mss", "pmtu", "advmss"):
        fields[k] = int(mtu_path.one(re.findall(rf"(?:^|\s){k}:(\d+)(?=\s|$)", lines[1]), k))
    return dict(**fields, peer_port=peer[1], timestamps="ts" in lines[1].split())


def validate(raw, mtu, expected_build_sha):
    path = raw["path"]
    mtuproof = mtu_path.qualify(path, mtu, require_bidirectional=True)
    ident = raw["identity"]
    check(re.fullmatch(r"[a-f0-9]{64}", expected_build_sha) is not None
          and ident["candidate_sha256"] == expected_build_sha and re.fullmatch(r"[a-f0-9]{64}", ident["container"])
          and bool(ident["worker"]) and bool(ident["instance"]) and type(ident["relay_pid"]) is int
          and ident["relay_pid"] > 0, "invalid scope or unexpected signed candidate identity")
    check(ident == raw["identity_after"] == path["identity_before"] == path["identity_after"],
          "worker, boot, owner, endpoint or container changed during capture")
    check(ident["mtu"] == mtu and ident["worker_ipv4"] == path["worker_ipv4"], "DF capture belongs to a different worker")
    check(raw["service_marker"] == ident["name"], "service marker mismatch")
    check(re.fullmatch(r"127\.0\.0\.1:[1-9][0-9]{0,4}", ident["endpoint"]) is not None,
          "expected a private loopback publication")
    check(raw["http_status"] == 206 and raw["content_range"] == f"bytes 0-{SIZE-1}/{SIZE}"
          and raw["content_length"] == str(SIZE) and raw["bytes"] == SIZE and raw["sha256"] == BODY_HASH,
          "server did not parse the exact requested range and deliver the full pinned content")
    gateway, worker = path["gateway_ipv4"], path["worker_ipv4"]
    service = path["service_route"][0]["prefsrc"]
    rows = []
    for stage in ("before", "after"):
        guest = established_service(raw[stage]["guest_ss"], service, gateway)
        host = raw[stage]["darwin"]
        check(host["pid"] == ident["relay_pid"] and host["local_address"] == gateway
              and host["local_port"] == guest["peer_port"] and host["peer_address"] == worker
              and type(host["peer_port"]) is int and 0 < host["peer_port"] <= 65535,
              "Darwin socket is not the gateway connection accepted by this service")
        check(guest["pmtu"] == mtu and guest["mss"] in (mtu - 52, mtu - 40)
              and (not guest["timestamps"] or guest["mss"] == mtu - 52),
              "service sender MSS or socket PMTU does not match the full IPv4 path")
        check(host["send_mss"] in (mtu - 40, mtu - 52), "Darwin relay sender MSS does not match the full IPv4 path")
        rows.append((guest, host))
    check(rows[0] == rows[1], "socket identity, effective MSS or route changed during delivery")
    return dict(**mtuproof, guest_send_mss=rows[0][0]["mss"], host_send_mss=rows[0][1]["send_mss"],
                guest_advmss=rows[0][0]["advmss"], receiver_bytes=SIZE, receiver_sha256=BODY_HASH)


def identity(scope, build, mtu):
    scope = scope.resolve()
    arm = pilot.value(scope, "base")
    check(arm in ("a","b") and scope.name == arm and scope.parent.name == "data", "unexpected private arm layout")
    home = scope.parent.parent / arm
    session, worker = read(home / "session.json"), read(home / "worker.json")
    job = plistlib.loads((scope / "job.plist").read_bytes())
    env = job["EnvironmentVariables"]
    owner = int(pilot.value(scope, "relay"))
    check(session["started"] and session["owner"]["pid"] == owner and worker["publishedPath"] == "macvlan"
          and Path(env["MICROPOD_CI_HOME"]).resolve() == home and job["Label"].startswith("dev.micropod.benchmark."),
          "unexpected worker owner, publication path or launch job")
    key = build.get("publication_key", KEY)
    check(key in (KEY, "MICROPOD_CI_PUBLISHED_MTU") and env.get(key) == str(mtu),
          "loaded worker MTU selector differs")
    recorded = worker.get("publishedMTU") if key == "MICROPOD_CI_PUBLISHED_MTU" else worker.get("benchmarkPublicationMTU")
    check(recorded == (mtu if key == "MICROPOD_CI_PUBLISHED_MTU" else str(mtu)), "persisted publication MTU differs")
    binary = Path(build["worker_executable"])
    check(Path(job["ProgramArguments"][0]).resolve() == binary.resolve()
          and pilot.mapped_digest(binary, owner) == build["worker_executable_sha256"], "wrong mapped private build")
    endpoint = pilot.value(scope, "addr")
    check(re.fullmatch(r"127\.0\.0\.1:[1-9][0-9]{0,4}", endpoint) is not None, "expected local endpoint")
    cid, name = pilot.value(scope, "id"), pilot.value(scope, "name")
    check(re.fullmatch(r"[a-f0-9]{64}", cid) and name, "invalid scope container")
    docker = ["docker","--host","unix://" + str(home / "docker.sock")]
    container = json.loads(pilot.command(*docker,"inspect","--type","container","--format","{{json .}}",cid))
    check(container["Id"] == cid and container["State"]["Running"] and container["Name"].lstrip("/") == name
          and container["Config"]["Cmd"] == ["-listen",":8080","-marker",name]
          and pilot.command(*docker, "port", cid, "8080/tcp") == endpoint, "container identity or publication changed")
    check(pilot.image_config(docker, container) == pilot.IMAGE, "service image configuration differs")
    sock = (home / "oci.sock").stat()
    ready = session["readySocket"]
    check(ready["worker"] == worker["worker"] and (ready["device"], ready["inode"]) == (sock.st_dev, sock.st_ino),
          "worker endpoint identity changed")
    routes = json.loads(pilot.command(*docker, "exec", cid, "/mpcheck/pathproof", "routes"))
    check("mppub0" in routes, "service return interface missing")
    return dict(relay_pid=owner, container=cid, name=name, endpoint=endpoint, worker=worker["worker"],
                instance=session["instance"], worker_ipv4=session["publishedAddress"], mtu=mtu,
                candidate_sha256=build["worker_executable_sha256"]), docker


def collect(args, write):
    build = read(args.build)
    ident, docker = identity(args.scope, build, args.mtu)
    path = read(args.df)
    mtu_path.qualify(path, args.mtu, require_bidirectional=True)
    check(path["identity_before"] == path["identity_after"] == ident and path["worker_ipv4"] == ident["worker_ipv4"],
          "need same-scope owner snapshots bracketing the DF capture")
    raw = {"path":path, "identity":ident}
    write(raw)
    with tempfile.TemporaryDirectory() as tmp:
        helper = Path(tmp) / "relay-mss"
        subprocess.run(["xcrun","clang","-std=c11","-Wall","-Werror",str(HERE/"relay_mss.c"),"-o",str(helper)],check=True)
        conn = http.client.HTTPConnection(ident["endpoint"], timeout=8)
        try:
            conn.connect()
            original = conn.sock
            conn.request("GET","/id")
            ans = conn.getresponse()
            check(ans.status == 200, "marker request failed")
            raw["service_marker"] = ans.read(512).decode()
            check(raw["service_marker"] == ident["name"] and conn.sock is original, "service marker or connection changed")
            for stage in ("before","after"):
                guest = pilot.command(*docker,"exec",ident["container"],"/mpcheck/ss","-Htin","state","established","( sport = :8080 )")
                raw[stage] = {"guest_ss": guest}
                write(raw)
                peer = established_service(guest, path["service_route"][0]["prefsrc"], path["gateway_ipv4"])
                host = json.loads(subprocess.check_output([helper,str(ident["relay_pid"]),path["gateway_ipv4"],
                                                         str(peer["peer_port"]),path["worker_ipv4"]], timeout=5))
                raw[stage]["darwin"] = host
                write(raw)
                if stage == "before":
                    conn.request("GET","/data",headers={"Range":f"bytes=0-{SIZE-1}"})
                    response = conn.getresponse()
                    body = response.read(SIZE + 1)
                    raw.update(http_status=response.status, content_range=response.getheader("Content-Range"),
                               content_length=response.getheader("Content-Length"), bytes=len(body),
                               sha256=hashlib.sha256(body).hexdigest())
                    check(conn.sock is original, "service closed the verified TCP connection")
        finally:
            conn.close()
    raw["identity_after"], _ = identity(args.scope, build, args.mtu)
    write(raw)
    return validate(raw, args.mtu, build["worker_executable_sha256"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("identity", "collect", "replay"))
    parser.add_argument("--mtu", required=True, type=int, choices=(1500,9000))
    parser.add_argument("--scope", type=Path)
    parser.add_argument("--build", type=Path, default=HERE/"private-build/build.json")
    parser.add_argument("--df", type=Path)
    parser.add_argument("--raw", type=Path)
    a = parser.parse_args()
    if a.action == "replay" and a.raw:
        result = validate(read(a.raw), a.mtu, read(a.build)["worker_executable_sha256"])
    elif a.action == "identity" and a.scope:
        result = identity(a.scope, read(a.build), a.mtu)[0]
    elif a.action == "collect" and a.scope and a.raw and a.df:
        with a.raw.open("x") as out:
            def write(data):
                out.seek(0)
                json.dump(data,out,indent=2)
                out.truncate()
                out.flush()
            result = collect(a,write)
    else:
        parser.error("identity needs --scope, collect needs --scope --df --raw, replay needs --raw")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, http.client.HTTPException) as error:
        sys.exit(f"MTU service preflight failed: {error}")
