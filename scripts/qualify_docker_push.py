#!/usr/bin/env python3
"""Exercise a stock Docker client's pushes against a private TLS Distribution registry."""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tarfile
import tempfile
import threading
import time
from urllib.parse import quote
import uuid

from qualify_docker_image_history import tar_bytes
from qualify_engine_api import UnixHTTP


RELEASE_SHA = "09d26f88d2c0f161bd1b8bfc6c123571cc3d291dcca8af5477b3cacc4ec95e73"
MANIFEST_TYPES = ", ".join((
    "application/vnd.oci.image.index.v1+json", "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json", "application/vnd.docker.distribution.manifest.v2+json",
))
LABEL = "io.micropod.registry-qualification"
SERVICE = "/tmp/mp-registry"
PORT = 5443
REGISTRY_CONFIG = f"""version: 0.1
log:
  level: warn
storage:
  filesystem:
    rootdirectory: {SERVICE}/storage
http:
  addr: :{PORT}
  tls:
    certificate: {SERVICE}/server.crt
    key: {SERVICE}/server.key
auth:
  htpasswd:
    realm: Micropod qualifier
    path: {SERVICE}/htpasswd
"""

# This client runs inside the registry container. It always checks the certificate
# and connects to its own loopback interface. It never follows redirects.
REGISTRY_PROBE = f"""
import base64, http.client, json, ssl, sys
req = json.load(sys.stdin)
alt = req.get("untrusted", False)
conn = http.client.HTTPSConnection("127.0.0.1", {PORT} + int(alt), timeout=5,
    context=ssl.create_default_context(cafile="{SERVICE}/" + ("untrusted.crt" if alt else "ca.crt")))
headers = {{"Accept": "{MANIFEST_TYPES}"}}
if req.get("auth"):
    headers["Authorization"] = "Basic " + req["auth"]
if req.get("type"):
    headers["Content-Type"] = req["type"]
conn.request(req["method"], req["path"], base64.b64decode(req["body"]) if "body" in req else None, headers)
res = conn.getresponse()
body = res.read(4 * 1024 * 1024 + 1)
if len(body) > 4 * 1024 * 1024:
    raise ValueError("registry response exceeds fixture size limit")
print(json.dumps([res.status, res.getheader("Content-Type"), res.getheader("Docker-Content-Digest"),
                  base64.b64encode(body).decode()]))
"""


def check(ok, message):
    if not ok:
        raise RuntimeError(message)


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def run(args, *, data=None, env=None, check_status=True, timeout=60):
    result = subprocess.run(args, input=data, capture_output=True, env=env, timeout=timeout)
    if check_status and result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace").strip()[-1400:] or f"{args[0]} exited {result.returncode}")
    return result


def image_archive(tags, run_id, size=160 * 1024):
    payload = secrets.token_bytes(size)
    layer = tar_bytes([("ci-output.bin", payload)])
    config = json.dumps({
        "architecture": "arm64", "os": "linux", "config": {"Labels": {LABEL: run_id}},
        "rootfs": {"type": "layers", "diff_ids": [digest(layer)]},
        "history": [{"created_by": "COPY ci-output.bin /ci-output.bin"}],
    }, sort_keys=True, separators=(",", ":")).encode()
    filename = digest(config).split(":")[1] + ".json"
    manifest = json.dumps([{"Config": filename, "RepoTags": tags, "Layers": ["layer.tar"]}]).encode()
    return tar_bytes([("manifest.json", manifest), (filename, config), ("layer.tar", layer)]), config, layer


def client_config(directory, host="micropod-qualifier.invalid", credential=""):
    directory.mkdir(mode=0o700)
    # A nonempty auth map keeps the client in this isolated config on macOS.
    (directory / "config.json").write_text(json.dumps({"auths": {host: {"auth": credential}}}))


def push_wave(socket, repository, auth, tags):
    ready = threading.Barrier(len(tags))

    def send(tag):
        conn = UnixHTTP(socket)
        try:
            ready.wait(timeout=10)
            start = time.monotonic_ns()
            route = "/v1.47/images/" + quote(repository, safe=":/") + "/push?tag=" + tag
            conn.request("POST", route, headers={"X-Registry-Auth": auth})
            res = conn.getresponse()
            check(res.status == 200, f"concurrent push {tag} returned {res.status}")
            first = None
            terminal_digest = None
            for line in res:
                row = json.loads(line)
                check(not row.get("errorDetail") and not row.get("error"), f"push stream failed for {tag}")
                if first is None:
                    first = time.monotonic_ns()
                aux = row.get("aux", {})
                if aux.get("Tag") == tag:
                    terminal_digest = aux.get("Digest")
                match = re.fullmatch(re.escape(tag) + r": digest: (sha256:[0-9a-f]{64}) size: [0-9]+", row.get("status", ""))
                if match:
                    terminal_digest = match.group(1)
            check(first and terminal_digest, f"push stream omitted its result for {tag}")
            return {"tag": tag, "start_ns": start, "first_response_ns": first, "end_ns": time.monotonic_ns(),
                    "manifest_digest": terminal_digest}
        finally:
            conn.close()

    with ThreadPoolExecutor(max_workers=len(tags)) as pool:
        samples = list(pool.map(send, tags))
    # This interval requires each independent Engine stream to have delivered a
    # progress record to its caller before any of the streams reached EOF.
    overlap = min(s["end_ns"] for s in samples) - max(s["first_response_ns"] for s in samples)
    return {"jobs": samples, "all_streams_overlap_ms": max(0, overlap) / 1e6,
            "first_request_to_last_eof_ms": (max(s["end_ns"] for s in samples) - min(s["start_ns"] for s in samples)) / 1e6}


# In the private registry container, accept the selected push's TCP connection
# before forwarding any TLS bytes. This makes the deletion attempt repeatable.
PRIVATE_PUSH_PROXY = f"""
from pathlib import Path
import select, socket, socketserver, sys, time
directory = Path("{SERVICE}")
class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        (directory / "push-entered").touch()
        deadline = time.monotonic() + 15
        while not (directory / "push-continue").exists():
            if time.monotonic() > deadline:
                return
            time.sleep(0.01)
        with socket.create_connection(("127.0.0.1", {PORT}), timeout=10) as backend:
            sockets = (self.request, backend)
            while True:
                readable, _, _ = select.select(sockets, [], [], 15)
                if not readable:
                    return
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    sockets[1 - sockets.index(source)].sendall(data)
with socketserver.ThreadingTCPServer((sys.argv[1], {PORT + 2}), Relay) as server:
    server.daemon_threads = True
    (directory / "push-listening").touch()
    server.serve_forever()
"""


def active_push_removal(socket, docker, container_id, ip, repo, rid, wire, directory, created_refs, private_ids,
                        manifest, image_status, registry):
    host = f"{ip}:{PORT + 2}"
    config = directory / "gated-client"
    client_config(config, host, wire)
    docker("exec", "-d", container_id, "python3", "-c", PRIVATE_PUSH_PROXY, str(ip))

    def wait_file(filename):
        script = 'for n in $(seq 1 120); do [ ! -f "$1" ] || exit 0; sleep .05; done; exit 1'
        docker("exec", container_id, "/bin/sh", "-ec", script, "wait", SERVICE + "/" + filename, timeout=9)

    def remove_id(ident):
        conn = UnixHTTP(socket)
        try:
            conn.request("DELETE", "/v1.47/images/" + ident + "?force=1")
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    wait_file("push-listening")
    ids = {}
    for tag in ("active", "unrelated"):
        ref = host + "/" + repo + ":" + tag
        created_refs.append(ref)
        data, cfg, layer = image_archive([ref], rid)
        ident = digest(cfg)
        private_ids.add(ident)
        docker("load", "--quiet", data=data)
        ids[tag] = (ref, ident)
        if tag == "active":
            original_config, original_layer = cfg, layer
    unrelated_ref, unrelated = ids["unrelated"]
    active_ref, active = ids["active"]
    docker("image", "rm", unrelated_ref)
    with ThreadPoolExecutor(max_workers=1) as pool:
        push = pool.submit(docker, "push", active_ref, cfg=config, timeout=25)
        try:
            wait_file("push-entered")
            docker("image", "rm", active_ref, timeout=4)
            active_status, active_rows = remove_id(active)
            other_status, other_rows = remove_id(unrelated)
            check(active_status == 200 and any(row.get("Deleted") == active for row in active_rows)
                  and other_status == 200 and any(row.get("Deleted") == unrelated for row in other_rows),
                  f"unexpected concurrent removal statuses {active_status}/{other_status}")
            check(image_status(active)[0] == image_status(unrelated)[0] == 404, "removed IDs remained visible during push")
            check(not push.done(), "push finished before the registry gate opened")
        finally:
            docker("exec", container_id, "touch", SERVICE + "/push-continue")
        finished = push.result()
    _, result = manifest("active")
    check(digest(result).encode() in finished.stdout + finished.stderr, "stock push omitted the verified manifest digest")
    published = json.loads(result)
    check(published["config"]["digest"] == active, "pushed manifest named an unexpected config")
    config_code, _, _, saved_config = registry("GET", f"/v2/{repo}/blobs/{active}")
    layer_desc, = published["layers"]
    layer_code, _, _, raw = registry("GET", f"/v2/{repo}/blobs/{layer_desc['digest']}")
    check(config_code == layer_code == 200 and saved_config == original_config and digest(raw) == layer_desc["digest"],
          "the registry stored different blobs after removal")
    stored_layer = gzip.decompress(raw) if raw.startswith(b"\x1f\x8b") else raw
    check(stored_layer == original_layer, "the uploaded layer differs from the removed local image")
    final_status = image_status(active)[0]
    check(final_status == 404, "completed transfer unexpectedly restored the removed ID")
    return {"active_removal": active_status, "unrelated_removal": other_status, "absent_during_push": True,
            "inspect_after_eof": final_status, "published_config": active, "verified_layer_diff_id": digest(original_layer)}


def server_files(options, directory, ip, username, password):
    key, csr, cert, ext = (directory / n for n in ("server.key", "server.csr", "server.crt", "server.ext"))
    ext.write_text(f"basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                   f"extendedKeyUsage=serverAuth\nsubjectAltName=IP:{ip},IP:127.0.0.1\n")
    run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj",
         "/CN=Micropod registry fixture", "-out", str(csr), "-keyout", str(key)])
    run(["openssl", "x509", "-req", "-in", str(csr), "-CA", str(options.ca_cert), "-CAkey", str(options.ca_key),
         "-set_serial", str(secrets.randbits(120) + 1), "-days", "1", "-sha256", "-extfile", str(ext), "-out", str(cert)])
    htpasswd = run(["htpasswd", "-niB", username], data=(password + "\n").encode()).stdout
    release = options.registry_archive.read_bytes()
    check(digest(release) == "sha256:" + RELEASE_SHA, "unexpected Distribution v3.1.2 ARM64 release archive")
    files = [("distribution.tar.gz", release), ("server.crt", cert.read_bytes()), ("server.key", key.read_bytes()),
             ("ca.crt", options.ca_cert.read_bytes()), ("htpasswd", htpasswd), ("config.yml", REGISTRY_CONFIG.encode())]
    if not options.publish_loopback:
        alt_key, alt_cert = directory / "untrusted.key", directory / "untrusted.crt"
        run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-sha256",
             "-subj", "/CN=Untrusted registry fixture", "-addext", f"subjectAltName=IP:{ip},IP:127.0.0.1",
             "-keyout", str(alt_key), "-out", str(alt_cert)])
        alt_config = REGISTRY_CONFIG.replace(f":{PORT}", f":{PORT + 1}").replace("/server.", "/untrusted.").replace("/storage", "/untrusted-storage")
        files.extend([("untrusted.key", alt_key.read_bytes()), ("untrusted.crt", alt_cert.read_bytes()), ("untrusted.yml", alt_config.encode())])
    return tar_bytes(files)


def exercise(options, directory, report):
    env = {key: value for key, value in os.environ.items() if not key.startswith("DOCKER_")}
    env.update(DOCKER_API_VERSION="1.47", DOCKER_CLI_HINTS="false")
    base, authorized, denied = (directory / n for n in ("client", "authorized", "denied"))
    client_config(base)

    def docker(*args, cfg=base, **kwargs):
        return run(["docker", "--config", str(cfg), "--host", "unix://" + str(options.socket), *args], env=env, **kwargs)

    rid = report["run"]
    network, name, label = "mp-reg-net-" + rid, "mp-reg-" + rid, f"{LABEL}={rid}"
    repo = "micropod-fixture/" + rid
    user, password, wrong = "ci-fixture", secrets.token_urlsafe(24), secrets.token_urlsafe(24)
    wire = base64.b64encode(f"{user}:{password}".encode()).decode()
    bad_wire = base64.b64encode(f"{user}:{wrong}".encode()).decode()
    container_id = network_id = ""
    created_refs = []
    private_ids = set()

    def registry(method, path, *, auth=wire, content_type=None, data=None, untrusted=False):
        request = {"method": method, "path": path, "auth": auth, "type": content_type, "untrusted": untrusted}
        if data is not None:
            request["body"] = base64.b64encode(data).decode()
        raw = docker("exec", "-i", container_id, "python3", "-c", REGISTRY_PROBE, data=json.dumps(request).encode()).stdout
        code, mime, header_digest, payload = json.loads(raw)
        return code, mime, header_digest, base64.b64decode(payload)

    def image_status(ref):
        conn = UnixHTTP(options.socket)
        try:
            conn.request("GET", "/v1.47/images/" + quote(ref, safe=":/") + "/json")
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def manifest(ref):
        status, mime, declared, body = registry("GET", f"/v2/{repo}/manifests/{ref}")
        check(status == 200 and declared == digest(body), f"registry manifest digest mismatch for {ref}")
        return mime, body

    try:
        network_id = docker("network", "create", "--driver", "bridge", "--label", label, network).stdout.decode().strip()
        command = (f"set -eu; mkdir -p {SERVICE}; while [ ! -f {SERVICE}/ready ]; do sleep 0.1; done; "
                   f"exec {SERVICE}/registry serve {SERVICE}/config.yml")
        publish = ["-p", f"127.0.0.1::{PORT}/tcp"] if options.publish_loopback else []
        container_id = docker("run", "--pull=never", "-d", "--name", name, "--network", network, "--label", label, *publish,
                              "--entrypoint", "/bin/sh", options.worker_image, "-c", command).stdout.decode().strip()
        info, = json.loads(docker("container", "inspect", container_id).stdout)
        attachment = info["NetworkSettings"]["Networks"][network]
        check(attachment["NetworkID"] == network_id, "registry is outside its private fixture network")
        ip = ipaddress.ip_address(attachment["IPAddress"])
        check(ip.version == 4 and any(ip in ipaddress.ip_network(cidr) for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")),
              "registry address must belong to the disposable guest bridge")
        host = f"{ip}:{PORT}"
        if options.publish_loopback:
            endpoint = docker("port", container_id, f"{PORT}/tcp").stdout.decode().strip()
            match = re.fullmatch(r"127\.0\.0\.1:([0-9]+)", endpoint)
            check(match and 0 < int(match.group(1)) < 65536, "unexpected address for the loopback registry")
            host = endpoint
        full = host + "/" + repo
        one, two, remote = (full + ":" + t for t in ("one", "two", "roundtrip"))
        report.update(registry=host, repository=repo, release="distribution/v3.1.2", worker_image_id=info["Image"],
                      daemon_route="published-loopback" if options.publish_loopback else "guest-bridge-with-fixture-ca")
        client_config(authorized)
        client_config(denied, host, bad_wire)
        assets = server_files(options, directory, ip, user, password)
        docker("exec", "-i", container_id, "/bin/sh", "-ec",
               f"cd {SERVICE}; tar xf -; tar xzf distribution.tar.gz registry; chmod 700 registry; touch ready", data=assets)
        deadline = time.monotonic() + 20
        while True:
            try:
                if registry("GET", "/v2/", auth="")[0] == 401:
                    break
            except RuntimeError:
                pass
            if time.monotonic() >= deadline:
                raise RuntimeError("private TLS registry did not present its authentication challenge")
            time.sleep(.15)
        check(registry("GET", "/v2/")[0] == 200 and registry("GET", "/v2/", auth=bad_wire)[0] == 401,
              "private registry did not distinguish correct and incorrect Basic credentials")
        report["tls_and_basic_auth"] = True
        bad_login = docker("login", "--username", user, "--password-stdin", host, cfg=denied,
                           data=(wrong + "\n").encode(), check_status=False)
        bad_login_output = (bad_login.stdout + bad_login.stderr).decode(errors="replace").lower()
        report["denied_login_exit"] = bad_login.returncode
        loopback_fallback = options.publish_loopback and (
            f"login attempt to http://{host}/v2/ failed with status: 400 bad request" in bad_login_output)
        report["denied_login_loopback_http_fallback"] = loopback_fallback
        check(bad_login.returncode != 0 and (loopback_fallback or any(s in bad_login_output for s in ("denied", "unauthorized", "401", "authentication required"))),
              "stock login did not return an authentication denial: " + bad_login_output[-850:])
        good_login = docker("login", "--username", user, "--password-stdin", host, cfg=authorized,
                            data=(password + "\n").encode())
        saved = json.loads((authorized / "config.json").read_bytes()).get("auths", {}).get(host, {})
        check(saved.get("auth") == wire and b"Login Succeeded" in good_login.stdout, "stock login did not save the correct fixture credential")
        report["stock_login_accepted_and_rejected_credentials"] = True
        archive, config, layer = image_archive([one], rid)
        private_ids.add(digest(config))
        check(all(image_status(ref)[0] == 404 for ref in (one, two, remote)), "fixture image tag already exists")
        created_refs.extend((one, two, remote))
        docker("load", "--quiet", data=archive)
        docker("tag", one, two)
        denied_push = docker("push", one, cfg=denied, check_status=False)
        denied_output = (denied_push.stdout + denied_push.stderr).decode(errors="replace")
        check(denied_push.returncode != 0 and any(s in denied_output.lower() for s in ("unauthorized", "401", "denied", "authentication required")),
              "invalid credentials failed to produce an authentication error: " + denied_output[-400:])
        check(registry("GET", f"/v2/{repo}/manifests/one")[0] == 404, "denied push published a manifest")
        report["denied_push"] = True
        pushed = docker("push", one, cfg=authorized)
        mime, root_manifest = manifest("one")
        root_digest = digest(root_manifest)
        obj = json.loads(root_manifest)
        if "manifests" in obj:
            matches = [ent["digest"] for ent in obj["manifests"] if ent.get("platform", {}).get("architecture") == "arm64"]
            check(len(matches) == 1, "unexpected platform set in fixture index")
            _, child = manifest(matches[0])
            obj = json.loads(child)
        expected_config, expected_layer = digest(config), digest(layer)
        check(obj["config"]["digest"] == expected_config and len(obj["layers"]) == 1, "wrong image config or layer count")
        for blob_digest, expected in [(expected_config, config), (obj["layers"][0]["digest"], layer)]:
            code, _, _, body = registry("GET", f"/v2/{repo}/blobs/{blob_digest}")
            check(code == 200 and digest(body) == blob_digest, "registry blob failed its descriptor digest")
            decoded = gzip.decompress(body) if body.startswith(b"\x1f\x8b") else body
            check(decoded == expected, "registry returned different image contents")
        check(root_digest.encode() in pushed.stdout + pushed.stderr, "stock client did not report the uploaded digest")
        report.update(config_id=expected_config, diff_id=expected_layer, manifest_digest=root_digest,
                      manifest_mime=mime, registry_verified_image_bytes=True)
        check(registry("GET", f"/v2/{repo}/manifests/two")[0] == 404, "single-tag push published a second tag")
        docker("push", "--all-tags", full, cfg=authorized)
        check(digest(manifest("two")[1]) == root_digest, "all-tags push produced a different image")
        report["all_tags"] = True
        status, _, _, _ = registry("PUT", f"/v2/{repo}/manifests/roundtrip", content_type=mime, data=root_manifest)
        check(status == 201 and image_status(remote)[0] == 404, "remote alias setup failed")
        docker("pull", remote, cfg=authorized)
        code, image = image_status(remote)
        report["pulled_image"] = {"status": code, "id": image.get("Id"), "rootfs": image.get("RootFS"),
                                  "repo_digests": image.get("RepoDigests")}
        check(code == 200 and image.get("RootFS", {}).get("Layers") == [expected_layer], "stock pull returned different layers")
        with tarfile.open(fileobj=io.BytesIO(docker("image", "save", remote).stdout)) as exported:
            entry, = json.load(exported.extractfile("manifest.json"))
            exported_config = exported.extractfile(entry["Config"]).read()
        check(exported_config == config, "stock pull exported a different image configuration")
        report["pulled_image"]["exported_config_digest"] = digest(exported_config)
        if not options.publish_loopback:
            check(image["Id"] == expected_config, "native inspect returned an unexpected config ID")
        report["remote_only_pull"] = True
        ci_tags = {}
        for i in range(8):
            tag = f"ci-{i}"
            ref = full + ":" + tag
            check(image_status(ref)[0] == 404, "concurrent job tag already exists")
            created_refs.append(ref)
            job_archive, job_config, _ = image_archive([ref], rid, size=1024 * 1024)
            ci_tags[tag] = digest(job_config)
            private_ids.add(ci_tags[tag])
            docker("load", "--quiet", data=job_archive)
        header = base64.urlsafe_b64encode(json.dumps({"username": user, "password": password, "serveraddress": host}).encode()).decode()
        wave = push_wave(options.socket, full, header, ci_tags)
        for sample in wave["jobs"]:
            _, body = manifest(sample["tag"])
            check(digest(body) == sample["manifest_digest"], "stream receipt and registry disagree")
            obj = json.loads(body)
            if "manifests" in obj:
                desc, = [m for m in obj["manifests"] if m.get("platform", {}).get("architecture") == "arm64"]
                _, child = manifest(desc["digest"])
                obj = json.loads(child)
            check(obj["config"]["digest"] == ci_tags[sample["tag"]], "independent job published the wrong image")
            sample["verified_config"] = ci_tags[sample["tag"]]
        report["eight_concurrent_publications"] = wave
        if options.active_removal:
            report["removal_during_push"] = active_push_removal(options.socket, docker, container_id, ip, repo, rid, wire,
                                                               directory, created_refs, private_ids, manifest, image_status, registry)
        if not options.publish_loopback:
            docker("exec", "-d", container_id, SERVICE + "/registry", "serve", SERVICE + "/untrusted.yml")
            deadline = time.monotonic() + 10
            while True:
                try:
                    if registry("GET", "/v2/", untrusted=True)[0] == 200:
                        break
                except RuntimeError:
                    pass
                check(time.monotonic() < deadline, "second TLS registry never accepted its private probe")
                time.sleep(.1)
            unknown_host = f"{ip}:{PORT + 1}"
            unknown_ref = unknown_host + "/" + repo + ":blocked"
            check(image_status(unknown_ref)[0] == 404, "untrusted-registry fixture tag already exists")
            created_refs.append(unknown_ref)
            docker("tag", one, unknown_ref)
            unknown_client = directory / "untrusted-client"
            client_config(unknown_client, unknown_host, wire)
            refused_login = docker("login", "--username", user, "--password-stdin", unknown_host, cfg=unknown_client,
                                   data=(password + "\n").encode(), check_status=False)
            refused_push = docker("push", unknown_ref, cfg=unknown_client, check_status=False)
            absent = registry("GET", f"/v2/{repo}/manifests/blocked", untrusted=True)[0] == 404
            check(refused_login.returncode != 0 and refused_push.returncode != 0 and absent, "engine accepted an untrusted TLS registry")
            report["second_registry_untrusted_certificate"] = {"independent_authenticated_probe": 200, "stock_login_exit": refused_login.returncode,
                                                               "stock_push_exit": refused_push.returncode, "manifest_absent": absent}
    except Exception as exc:
        message = str(exc)
        for secret in (password, wrong, wire, bad_wire):
            message = message.replace(secret, "<redacted>")
        raise RuntimeError(message) from None
    finally:
        for ref in reversed(created_refs):
            code, img = image_status(ref)
            if code == 200 and (img.get("Config", {}).get("Labels") or {}).get(LABEL) == rid:
                private_ids.add(img["Id"])
                docker("image", "rm", ref, check_status=False)
        leftover_ids = []
        removal_attempts = {}
        for image_id in sorted(private_ids):
            code, img = image_status(image_id)
            if code == 200 and (img["Config"].get("Labels") or {}).get(LABEL) == rid and not img.get("RepoTags"):
                plain = docker("image", "rm", image_id, check_status=False)
                removal_attempts[image_id] = {"plain_exit": plain.returncode}
                code, current = image_status(image_id)
                if plain.returncode and code == 200 and not current.get("RepoTags") and (current["Config"].get("Labels") or {}).get(LABEL) == rid:
                    forced = docker("image", "rm", "--force", image_id, check_status=False)
                    removal_attempts[image_id]["force_exit"] = forced.returncode
            if image_status(image_id)[0] != 404:
                leftover_ids.append(image_id)
        if container_id:
            docker("container", "rm", "-f", container_id, check_status=False)
        if network_id:
            docker("network", "rm", network_id, check_status=False)
        report["cleanup"] = {
            "containers_absent": not docker("ps", "-aq", "--filter", "label=" + label).stdout.strip(),
            "networks_absent": not docker("network", "ls", "-q", "--filter", "label=" + label).stdout.strip(),
            "named_tags_absent": all(image_status(ref)[0] == 404 for ref in created_refs),
        }
        report["private_image_ids_until_worker_disposal"] = leftover_ids
        report["private_image_id_removal"] = removal_attempts
        check(all(report["cleanup"].values()), "registry fixture cleanup incomplete")
        check(options.disposable_worker or not leftover_ids, "registry fixture retained private image IDs")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("socket", "ca-cert", "ca-key", "registry-archive", "output"):
        parser.add_argument("--" + arg, type=Path, required=True)
    parser.add_argument("--worker-image", required=True, help="Preloaded Linux image with Python 3, a shell and tar")
    parser.add_argument("--disposable-worker", action="store_true", help="Worker disk will be removed after verifying named-resource cleanup")
    parser.add_argument("--publish-loopback", action="store_true", help="Exercise an independent dockerd using its loopback registry policy")
    parser.add_argument("--active-removal", action="store_true", help="Verify push completion after its visible source ID is deleted")
    options = parser.parse_args()
    if options.publish_loopback and options.active_removal:
        parser.error("active removal requires the private native bridge")
    check(options.socket.is_socket() and not options.output.exists(), "select a live local socket and a new receipt path")
    report = {"run": uuid.uuid4().hex, "passed": False, "api": "1.47"}
    try:
        with tempfile.TemporaryDirectory(prefix="push-", dir=options.ca_key.parent) as temp:
            exercise(options, Path(temp), report)
        report["passed"] = True
    except Exception as exc:
        report["error"] = str(exc)
    options.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
