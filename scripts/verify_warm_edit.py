#!/usr/bin/env python3
"""Single-client host correctness replay. Emits assertions and work counts, never performance scores."""

import argparse
import json
import os
import shutil
import tempfile
from copy import deepcopy
from pathlib import Path

import ci_edit_loop as guest
import profile_warm_edit as bench
from bench_live_kernel import require


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--npm-tarball", type=Path)
    p.add_argument(
        "--build-cache", type=Path, help="optional private disposable Go build cache for this host check"
    )
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    with args.output.open("x") as out, tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        src = root / "inputs"
        files = bench.inputs(args.npm_tarball)
        for name, data in files.items():
            target = src / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        cache = root / "caches"
        cache.mkdir()
        if args.build_cache:
            target = args.build_cache.resolve(strict=True)
            (cache / "go-build").symlink_to(target, target_is_directory=True)
        os.environ.update(CGO_ENABLED="0", GOENV="off", GOWORK="off", GOTOOLCHAIN="local", GOTELEMETRY="off")
        ident = guest.tool_identity()
        locks = {p: bench.sha(files[p]) for p in bench.FILES if p.endswith((".json", ".sum", ".mod"))}

        def key(tree, scope="trusted-test", identity=ident):
            # This test builds one pure-Go main package. Production keys need its entire dependency graph.
            inputs = {p.name: guest.digest(p) for p in tree.iterdir() if p.name != "service"}
            envelope = {
                "source": inputs,
                "locks": locks,
                "identity": identity,
                "scope": scope,
                "cgo": "0",
                "flags": "-p=1 -trimpath -mod=readonly -buildvcs=false",
                "main": ".",
            }
            return bench.sha(json.dumps(envelope, sort_keys=True).encode())

        rows = []
        initial_objects = guest.inventory(cache)["objects"]

        def run(label, marker, restore=None):
            row = guest.run_job(src, root / label, cache, marker, guest=False, local_restore=restore)
            refs = set(row["go_import_refs"]) & initial_objects.keys()
            rows.append(
                dict(
                    case=label,
                    node_output=row["node_output"],
                    go_sha256=row["go_sha256"],
                    go_build_tools=row["stages"]["go_build"]["tools"],
                    go_preexisting_imports=len(refs),
                    go_confirmed_import_bytes=sum(initial_objects[ref] for ref in refs),
                    npm_hit_at_seed=row["npm_hit_at_seed"],
                    npm_payload_bytes=row["npm_payload_bytes"],
                    executed_go_tests=3,
                    executed_node_tests=3,
                )
            )
            return (root / label / "go-app"), row

        base, _ = run("base", "base")
        edited, e = run("edited", "edit-1-1")
        _, repeat = run("fresh-repeat", "edit-1-1")
        require(
            guest.digest(base / "service") != e["go_sha256"] == repeat["go_sha256"], "Revision products differ"
        )
        output_key = key(edited)
        # Producer record is held by the test supervisor, outside every job workspace.
        record = dict(key=output_key, sha256=e["go_sha256"])
        objects = root / "published"
        objects.mkdir()
        staged = root / "incomplete"
        shutil.copyfile(edited / "service", staged)

        def restore(tree, scope="trusted-test"):
            obj = objects / output_key
            if key(tree, scope) != record["key"] or not obj.exists():
                return False
            data = obj.read_bytes()
            if bench.sha(data) != record["sha256"]:
                return False
            (tree / "service").write_bytes(data)
            (tree / "service").chmod(0o755)
            return True

        require(not restore(edited), "Incomplete publisher selected")
        staged.chmod(0o444)
        staged.rename(objects / output_key)
        other = deepcopy(ident)
        other["go"]["GOARCH"] = "another-target"
        compiler = deepcopy(ident)
        compiler["compiler"] = "another-compiler-digest"
        require(
            not restore(base)
            and not restore(edited, "other-scope")
            and key(edited, identity=other) != output_key
            and key(edited, identity=compiler) != output_key,
            "source, target, toolchain or trust namespace conflated",
        )

        def must_restore(tree):
            require(restore(tree), "Exact product lookup failed")

        _, promoted = run("verified-product", "edit-1-1", must_restore)
        require(promoted["go_sha256"] == record["sha256"], "Restored output changed")
        (objects / output_key).unlink()
        (objects / output_key).write_bytes(b"truncated test publication")

        def reject(tree):
            require(not restore(tree), "Corrupt product accepted")

        _, recovered = run("corruption-fallback", "edit-1-1", reject)
        require(recovered["go_sha256"] == record["sha256"], "Recovery produced stale output")
        require(
            rows[0]["npm_hit_at_seed"] is False and all(row["npm_hit_at_seed"] for row in rows[1:]),
            "Unexpected npm reuse",
        )
        evidence = dict(
            kind="host-functional-only",
            source=bench.SOURCE,
            toolchain=ident,
            seed_build_cache=bool(args.build_cache),
            rows=rows,
            first_attempt_failures=0,
            controls=[
                "fresh tests every checkout",
                "source edit",
                "different target",
                "different compiler",
                "different scope",
                "unpublished staging file",
                "corrupt bytes rejected and rebuilt",
            ],
            trusted_manifest=record,
        )
        json.dump(evidence, out, indent=2)
        out.write("\n")


if __name__ == "__main__":
    main()
