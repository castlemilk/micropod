#!/usr/bin/env python3
"""Qualify stock Docker ancestor filters against isolated, owned image graphs."""

import argparse
import copy
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import tarfile
from tempfile import TemporaryDirectory
import time
from urllib.parse import quote, urlencode
from uuid import uuid4

from qualify_engine_api import Engine
from qualify_docker_image_history import familiar, tar_bytes


OWNER = "io.micropod.qualification.ancestor"
ROLES = ("parent", "child", "grandchild", "sibling", "lookalike")
PARENTS = {"child": "parent", "grandchild": "child"}


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def image_fixture(base_archive, directory):
    run = uuid4().hex
    repo = "micropod-qa/ancestor-" + run
    with tarfile.open(base_archive) as archive:
        base, = (row for row in json.load(archive.extractfile("manifest.json"))
                 if "alpine:3.23" in {familiar(tag) for tag in row["RepoTags"] or []})
        original = json.load(archive.extractfile(base["Config"]))
        base_layers = [archive.extractfile(path).read() for path in base["Layers"]]
    if original["architecture"] != "arm64" or original["os"] != "linux":
        raise ValueError("The fixture needs the preloaded Linux ARM64 Alpine archive")
    base_diff_ids = [digest(gzip.decompress(data) if data.startswith(b"\x1f\x8b") else data) for data in base_layers]
    if original["rootfs"]["diff_ids"] != base_diff_ids:
        raise ValueError("Archived Alpine layers do not match the image configuration")

    layers = {role: tar_bytes([(f"micropod-ancestor-{role}", f"{run}\n".encode())]) for role in ROLES}
    base_names = [f"base-{i}.tar" for i in range(len(base_layers))]
    members = [*zip(base_names, base_layers), *((role + ".tar", data) for role, data in layers.items())]
    stacks = {"parent": ["parent"], "child": ["parent", "child"], "grandchild": ["parent", "child", "grandchild"],
              "sibling": ["sibling"], "lookalike": ["parent", "child", "lookalike"]}
    image_refs, archive_rows = {}, []
    for role, chain in stacks.items():
        config = copy.deepcopy(original)
        config["config"]["Labels"] = {**(config["config"].get("Labels") or {}), OWNER: run, OWNER + ".role": role}
        config["config"]["Cmd"] = ["/bin/sh", "-c", "sleep 120"]
        config["rootfs"]["diff_ids"].extend(digest(layers[item]) for item in chain)
        config.setdefault("history", []).extend({"created_by": "COPY micropod-ancestor-" + item} for item in chain)
        payload = encode(config)
        config_id = digest(payload)
        config_name = config_id.removeprefix("sha256:") + ".json"
        members.append((config_name, payload))
        ref = f"{repo}:{'latest' if role == 'parent' else role}"
        archive_row = {"Config": config_name, "RepoTags": [ref],
                       "Layers": base_names + [item + ".tar" for item in chain]}
        parent = PARENTS.get(role)
        if parent:
            archive_row["Parent"] = image_refs[parent]["config_id"]
        archive_rows.append(archive_row)
        image_refs[role] = {"ref": ref, "config_id": config_id, "diff_ids": config["rootfs"]["diff_ids"]}

    directory.mkdir(mode=0o700)
    tar_path = directory / "images.tar"
    tar_path.write_bytes(tar_bytes([("manifest.json", encode(archive_rows)), *members]))
    manifest = {"run": run, "repository": repo, "images": image_refs, "archive_digest": digest(tar_path.read_bytes())}
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


class AncestorProbe:
    def __init__(self, engine, fixture, output):
        self.engine = engine
        self.fixture = fixture
        self.output = output
        self.run = fixture["run"]
        self.repo = fixture["repository"]
        assert re.fullmatch(r"[0-9a-f]{32}", self.run) and self.repo == "micropod-qa/ancestor-" + self.run
        assert set(fixture["images"]) == set(ROLES)
        self.names = {role: f"mp-ancestor-{self.run}-{role}" for role in (*ROLES, "retained")}
        self.tags = {role: row["ref"] for role, row in fixture["images"].items()}
        assert self.tags == {role: f"{self.repo}:{'latest' if role == 'parent' else role}" for role in ROLES}
        self.replace = f"{self.repo}:replace"
        self.base = self.image("alpine:3.23")[1]["Id"]
        self.report = {"run": self.run, "repository": self.repo, "images": {}, "containers": {}, "cases": {}, "cleanup": {}}

    def save(self):
        scratch = self.output.with_suffix(self.output.suffix + ".tmp")
        scratch.write_text(json.dumps(self.report, indent=2, sort_keys=True) + "\n")
        os.replace(scratch, self.output)

    def get(self, path):
        status, _, data = self.engine.request("GET", path)
        return status, json.loads(data)

    def cli(self, *args, data=None):
        result = self.engine.cli(*args, data=data, timeout=40)
        if result.returncode != 0:
            raise RuntimeError(f"docker {args}: {result.stderr.decode(errors='replace')[-1700:]}")
        return result.stdout.decode()

    def image(self, ref):
        return self.get("/images/" + quote(ref, safe="/:@") + "/json")

    def container(self, name):
        return self.get("/containers/" + name + "/json")

    def owned(self, row):
        return (row.get("Config", {}).get("Labels") or {}).get(OWNER) == self.run

    def list(self, filters, all_containers):
        status, rows = self.get("/containers/json?" + urlencode({"all": int(all_containers), "filters": json.dumps(filters)}))
        if status == 200:
            names = {name: role for role, name in self.names.items()}
            return status, [names[row["Names"][0].removeprefix("/")] for row in rows]
        return status, []

    def case(self, name, values, expected, *, all_containers=True, extra=(), status=200, stock=True):
        label = f"{OWNER}={self.run}"
        filters = {"label": {label: True}, **dict(extra)}
        options = ["--filter", "label=" + label]
        if values is not None:
            filters["ancestor"] = {value: True for value in values}
            for value in values:
                options += ["--filter", "ancestor=" + value]
        if stock:
            for key, value in extra:
                for item in value:
                    options += ["--filter", key + "=" + item]
        actual_status, wire = self.list(filters, all_containers)
        result = {"filters": filters, "all": all_containers, "status": actual_status, "raw_roles": wire}
        self.report["cases"][name] = result
        if stock:
            rows = self.cli("ps", *(["-a"] if all_containers else []), *options, "--format", "{{.Names}}")
            names = {container: role for role, container in self.names.items()}
            result["cli_roles"] = [names[row] for row in rows.splitlines()]
            assert result["cli_roles"] == wire, f"{name}: CLI and API results differ"
        if expected is not None:
            assert (actual_status, wire) == (status, expected), f"{name}: got {actual_status} {wire}, expected {status} {expected}"
        self.save()

    def load(self, archive, seeded):
        if not seeded:
            assert all(self.image(ref)[0] == 404 for ref in (*self.tags.values(), self.replace))
            self.cli("image", "load", "-q", data=archive)
        for role in ROLES:
            code, image = self.image(self.tags[role])
            assert code == 200 and self.owned(image), f"{role}: failed to inspect the owned image ({code})"
            assert image["RootFS"]["Layers"] == self.fixture["images"][role]["diff_ids"], role
            label = image["Config"]["Labels"][OWNER + ".role"]
            assert label == role, f"{role}: got image for {label}"
            self.report["images"][role] = {"id": image["Id"], "digests": image.get("RepoDigests") or [], "parent": image.get("Parent"),
                                           "diff_ids": image["RootFS"]["Layers"]}
            self.save()

    def exercise(self, linked, native):
        assert self.image(self.replace)[0] == 404
        self.cli("image", "tag", self.tags["child"], self.replace)
        assert self.image(self.replace)[1]["Id"] == self.report["images"]["child"]["id"]
        label = f"{OWNER}={self.run}"
        for role, name in self.names.items():
            assert self.container(name)[0] == 404
            ref = self.replace if role == "retained" else self.tags[role]
            cid = self.cli("create", "--pull=never", "--name", name, "--label", label, "--network=none", ref).strip()
            assert self.container(name)[1]["Id"] == cid
            self.report["containers"][role] = cid
        for role in ("parent", "grandchild"):
            self.cli("start", self.names[role])
            assert self.container(self.names[role])[1]["State"]["Running"], role

        parent_rows = ["retained", "grandchild", "child", "parent"] if linked else ["parent"]
        child_rows = ["retained", "grandchild", "child"] if linked else ["retained", "child"]
        parent_image = self.report["images"]["parent"]
        iid = parent_image["id"]
        repo_digest = next((ref for ref in parent_image["digests"] if familiar(ref).split("@", 1)[0] == self.repo), None)
        if not repo_digest:
            # The importer can advertise only an immutable import alias.
            repo_digest = parent_image["digests"][0]
        digest_name, digest_value = repo_digest.split("@", 1)
        tag = self.tags["parent"]
        for name, ref in (("tag", tag), ("default-tag", self.repo), ("image-id", iid),
                          ("short-image-id", iid[7:19]), ("repository-digest", repo_digest)):
            self.case(name, [ref], parent_rows)
        if familiar(digest_name) == self.repo:
            self.case("tag-and-digest", [tag + "@" + digest_value], parent_rows)
        self.case("child", [self.tags["child"]], child_rows)
        self.case("grandchild", [self.tags["grandchild"]], ["grandchild"])
        self.case("unrelated-layer-sibling", [self.tags["sibling"]], ["sibling"])
        self.case("prefix-lookalike", [self.tags["lookalike"]], ["lookalike"])
        self.case("running", [tag], ["grandchild", "parent"] if linked else ["parent"], all_containers=False)
        self.case("unfiltered-running", None, ["grandchild", "parent"], all_containers=False)
        missing = self.repo + ":missing"
        self.case("union-of-roots", [tag, self.tags["sibling"], missing],
                  ["retained", "sibling", "grandchild", "child", "parent"] if linked else ["sibling", "parent"])
        self.case("and-name-id-label-status", [self.tags["child"]], ["child"], all_containers=False,
                  extra=(("name", {self.names["child"]: True}), ("id", {self.report["containers"]["child"][:12]: True}),
                         ("status", {"created": True})))
        self.case("unknown-image", [missing], [])
        self.case("invalid-image", ["not a valid reference"], [])
        self.case("raw-layer-diff-id", [parent_image["diff_ids"][-1]], [])
        self.case("backend-config-id", [self.fixture["images"]["parent"]["config_id"]], parent_rows if native else [])
        self.case("backend-manifest-id", [digest_value], parent_rows)
        self.case("wrong-repository-digest", [self.repo + "-unrelated@" + digest_value], [] if native else None)
        self.case("empty-set", [], [], stock=False)
        self.case("map-keeps-false-ancestor-key", None, parent_rows, extra=(("ancestor", {tag: False}),), stock=False)
        self.case("malformed-filter", None, [], extra=(("ancestor", 42),), status=400, stock=False)
        self.case("unknown-filter", None, [], extra=(("unknown-ancestor-option", {"value": True}),), status=400, stock=False)

        self.cli("image", "tag", self.tags["sibling"], self.replace)
        assert self.image(self.replace)[1]["Id"] == self.report["images"]["sibling"]["id"]
        assert self.container(self.names["retained"])[1]["Image"] == self.report["images"]["child"]["id"]
        self.cli("image", "rm", "--force", "--no-prune", self.tags["child"])
        assert self.image(self.tags["child"])[0] == 404
        self.case("retagged-reference-moved", [self.replace], ["sibling"])
        self.case("retained-old-image-id", [self.report["images"]["child"]["id"]], child_rows)
        self.case("deleted-old-tag", [self.tags["child"]], [])
        self.case("parent-after-retag", [tag], parent_rows)

    def cleanup(self, native):
        cleanup = self.report["cleanup"]
        for name in self.names.values():
            status, row = self.container(name)
            if status == 200:
                if not self.owned(row):
                    raise RuntimeError(f"refusing removal of unowned container {name}")
                self.cli("rm", "--force", name)
            cleanup[name] = self.container(name)[0]
        ids = {entry["id"] for entry in self.report["images"].values()}
        if native:
            ids.update(entry["config_id"] for entry in self.fixture["images"].values())
        for ref in (self.replace, *reversed(self.tags.values())):
            status, row = self.image(ref)
            if status == 200:
                if not self.owned(row):
                    raise RuntimeError(f"refusing unowned tag removal {ref}")
                ids.add(row["Id"])
                self.cli("image", "rm", "--force", "--no-prune", ref)
            cleanup[ref] = self.image(ref)[0]
        if not native:
            ids.update(self.cli("image", "ls", "--all", "--quiet", "--no-trunc", "--filter", "label=" + OWNER + "=" + self.run).splitlines())
        for iid in sorted(ids):
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", iid):
                raise RuntimeError(f"refusing unverified image ID {iid}")
            status, row = self.image(iid)
            if native and status == 200 and self.owned(row):
                check_until = time.monotonic() + 3
                while status == 200 and self.owned(row) and row.get("RepoTags") and time.monotonic() < check_until:
                    # CRI removes the cached tags after the image-store events drain.
                    time.sleep(0.03)
                    status, row = self.image(iid)
            if status == 200:
                if not self.owned(row) or row["Id"] != iid or row.get("RepoTags"):
                    raise RuntimeError(f"refusing unowned or still-tagged ID removal {iid}")
                self.cli("image", "rm", "--force", "--no-prune", iid)
            cleanup[iid] = self.image(iid)[0]
        self.report["base_preserved"] = self.image("alpine:3.23")[1]["Id"] == self.base
        assert all(status == 404 for status in cleanup.values()) and self.report["base_preserved"], cleanup


def replay(args):
    fixture = json.loads((args.directory / "manifest.json").read_bytes())
    archive = (args.directory / "images.tar").read_bytes()
    assert digest(archive) == fixture["archive_digest"] and args.socket.is_socket() and not args.output.exists()
    with TemporaryDirectory(prefix="ancestor-docker-config-", dir=args.output.parent) as config:
        (Path(config) / "config.json").write_text('{"auths":{"fixture.invalid":{}}}')
        engine = Engine(args.socket, "alpine:3.23", None, None, api_version="1.47")
        engine.env["DOCKER_CONFIG"] = config
        engine.env.pop("DOCKER_CUSTOM_HEADERS", None)
        probe = AncestorProbe(engine, fixture, args.output)
        probe.report["mode"] = {"native": args.native, "linked": getattr(args, "linked", False)}
        if args.command == "recover":
            previous = json.loads(args.previous.read_bytes())
            assert previous["run"] == probe.run and previous["repository"] == probe.repo
            probe.report["images"] = previous["images"]
        try:
            if args.command == "probe":
                probe.load(archive, args.linked)
                probe.exercise(args.linked, args.native)
            probe.report["passed"] = True
        except Exception as exc:
            probe.report.update(passed=False, error=str(exc))
        finally:
            try:
                probe.cleanup(args.native)
            except Exception as exc:
                probe.report.update(passed=False, cleanup_error=str(exc))
            probe.save()
    return int(not probe.report["passed"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare", help="build an offline owned image fixture")
    prepare.add_argument("--base-archive", type=Path, required=True)
    prepare.add_argument("--directory", type=Path, required=True)
    probe = commands.add_parser("probe", help="run stock CLI and wire cases on one engine")
    probe.add_argument("--linked", action="store_true", help="verify the prepared graph already loaded with authoritative parent labels")
    recover = commands.add_parser("recover", help="remove only the images and containers owned by the recorded run")
    recover.add_argument("--previous", type=Path, required=True)
    for command in (probe, recover):
        command.add_argument("--socket", type=Path, required=True)
        command.add_argument("--directory", type=Path, required=True)
        command.add_argument("--output", type=Path, required=True)
        command.add_argument("--native", action="store_true", help="use native config IDs and require repository-scoped digest matching")
    args = parser.parse_args()
    if args.command == "prepare":
        print(json.dumps(image_fixture(args.base_archive, args.directory)))
        return 0
    if args.command == "probe" and args.linked and not args.native:
        parser.error("the linked archive is provisioned by the native fixture hook")
    return replay(args)


if __name__ == "__main__":
    raise SystemExit(main())
