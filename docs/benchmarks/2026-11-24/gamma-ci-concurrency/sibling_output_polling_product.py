"""Freeze stock and optimized Linux log followers around one signed CI worker."""

import argparse
import difflib
from hashlib import sha256
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

from build_file_fault_around import BASE, HERE, ROOT, clone, digest, encode, read, require, verify_inputs


MANIFEST = "sibling-output-polling-product.json"
ARM = "output-polling-arm.json"
DELTA = "output-polling-delta.patch"
SCHEMA = "micropod-output-polling-product-v1"
TOOLS = "micropod-oci-tools"
RUNNER = Path("guest/runner")
JOB = Path(TOOLS) / "runner/bin/job"
ALLOWED = {str(RUNNER / name) for name in ("main_linux.go", "output_linux.go", "cri_output_linux_test.go", "go.mod", "go.sum")}
OCI_MODULES = {
    "github.com/opencontainers/go-digest": ("v1.0.0", "h1:apOUWs51W5PlhuyGyz9FCeeBIOUDA/6nW8Oi/yOhh5U=",
                                           "h1:0JzlMkj0TRzQZfJkVvzbP0HBR3IKzErnv2BNG4W4MAM="),
    "github.com/opencontainers/image-spec": ("v1.1.1", "h1:y0fUlFfIZhPF1W537XOLg0/fcx6zcHCJwooC2xJA040=",
                                             "h1:qpqAh3Dmcf36wStyyWU+kCeDgrGnAve2nCC8+7h8Q0M="),
}
MODES = ("stock", "optimized")
GO_VERSION = "go1.27.2"
PARENT_MANIFEST = HERE / "sibling-file-fault-around-product.json"
PARENT_SHA = "c6c36ce79c466b7e49a8b61ca4b2bed53252e706e77a4ec6fd443235f3870e9e"
STOCK_SHA = "5e6ef9b4a2c7092688c9ad5f426a3e6ca531756068392ec87fed6233f62fb895"
HOST_SHA = "fb9a3603625d41cadc9d41373b4c87f63797a07d17e5bbcf0a5a99c890ba65f5"
BOOT_SHA = "7bc36703e98c2e02026da6e5a58a87ea77caa6e040fa127ea10be43e761c2a9f"
ENV = {"GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0", "GOPROXY": "off"}


def hashed(data):
    return sha256(data).hexdigest()


def tree(root, exclude=()):
    rows = []
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root).as_posix()
        if name in exclude:
            continue
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            value = os.readlink(path)
        elif stat.S_ISREG(mode):
            value = digest(path)
        elif stat.S_ISDIR(mode):
            value = None
        else:
            raise ValueError(f"unexpected product tree entry {path}")
        rows.append([name, mode, value])
    return hashed(encode(rows))


def parent():
    require(digest(PARENT_MANIFEST) == PARENT_SHA, "unexpected signed fault-around parent manifest")
    manifest = read(PARENT_MANIFEST)
    product = Path(manifest["current_product"]).resolve()
    scope, record = product.parent, read(product)
    require(scope.parent == BASE and scope.name == "ci-published-link-cc0ed728a9291a8d"
            and record["guest_runner_sha256"] == manifest["new_guest_sha256"] == STOCK_SHA
            and record["worker_executable_sha256"] == manifest["host_sha256"] == HOST_SHA
            and record["guest_start_sha256"] == manifest["new_bootstrap_sha256"] == BOOT_SHA,
            "wrong sealed worker for output polling")
    verify_inputs(scope, record)
    return product, record, manifest


def toolchain(go):
    go = go.resolve()
    env = {**os.environ, **ENV}
    env.pop("GOROOT", None)
    version = subprocess.check_output([go, "version"], text=True, env=env).strip()
    require(version == f"go version {GO_VERSION} darwin/arm64", f"wrong Go toolchain {version}")
    directory = Path(subprocess.check_output([go, "env", "GOTOOLDIR"], text=True, env=env).strip())
    return env, {"path": str(go), "version": version, "sha256": digest(go),
                 "compiler_sha256": digest(directory / "compile"), "linker_sha256": digest(directory / "link"),
                 "go_flags": subprocess.check_output([go, "env", "GOFLAGS"], text=True, env=env).strip(),
                 "environment": ENV}


def binary_info(go, binary, env):
    first, *lines = subprocess.check_output([go, "version", "-m", binary], text=True, env=env).splitlines()
    require(first.endswith(": " + GO_VERSION) and any("GOARCH=arm64" in line for line in lines)
            and any("GOOS=linux" in line for line in lines), "wrong embedded runner build information")
    return [GO_VERSION, *(line.lstrip() for line in lines)]


def check_build_info(original, actual, mode):
    added = [f"dep\t{name}\t{version}\t{total}" for name, (version, total, _) in OCI_MODULES.items()] \
        if mode == "optimized" else []
    require(all(actual.count(line) == 1 for line in added)
            and [line for line in actual if line not in added] == original, "runner build settings differ from stock")


def check_modules(base, files):
    mod = {f"\t{name} {version} // indirect\n".encode() for name, (version, _, _) in OCI_MODULES.items()}
    sums = {line.encode() for name, (version, total, metadata) in OCI_MODULES.items()
            for line in (f"{name} {version} {total}\n", f"{name} {version}/go.mod {metadata}\n")}
    for name, expected in (("go.mod", mod), ("go.sum", sums)):
        path = str(RUNNER / name)
        rows = files[path].splitlines(keepends=True)
        require(all(rows.count(line) == 1 for line in expected)
                and b"".join(line for line in rows if line not in expected) == (base / path).read_bytes(),
                f"{path} changed more than the two pinned OCI dependencies")


def exact_diff(base, files):
    return "".join(line for name in sorted(files)
                   for line in difflib.unified_diff((base / name).read_text().splitlines(keepends=True),
                                                    files[name].decode().splitlines(keepends=True),
                                                    "a/" + name, "b/" + name)).encode()


def frozen_arm(previous, old, mode, files, tools, env, stable, expected_info):
    old_scope = previous.parent
    changed = {name: hashed(data) for name, data in files.items()}
    identity = {"parent": digest(previous), "mode": mode, "changed": changed,
                "toolchain": tools, "packager": digest(Path(__file__))}
    scope = BASE / ("ci-published-link-" + hashed(encode(identity))[:16])
    product = scope / "product.json"
    delta = exact_diff(old_scope / "src", files)
    if not scope.exists():
        with tempfile.TemporaryDirectory(prefix="output-polling-", dir=BASE) as temporary:
            stage = Path(temporary) / "product"
            stage.mkdir()
            for name in ("micropod", "micropod-oci", "build.log", "file-fault-around-bootstrap.sh", TOOLS, "src"):
                clone(old_scope / name, stage / name)
            for name, contents in files.items():
                (stage / "src" / name).write_bytes(contents)
            cwd = stage / "src" / RUNNER
            command = [tools["path"], "build", "-trimpath", "-o", str(stage / JOB), "."]
            compiled = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True,
                                      check=True, timeout=180)
            runner_sha = digest(stage / JOB)
            info = binary_info(tools["path"], stage / JOB, env)
            check_build_info(expected_info, info, mode)
            require((runner_sha == STOCK_SHA) == (mode == "stock"),
                    f"{mode} byte-for-byte guard failed, actual Linux runner SHA-256 {runner_sha}")
            patch = (old_scope / "worker.patch").read_bytes() + delta
            (stage / "worker.patch").write_bytes(patch)
            (stage / DELTA).write_bytes(delta)
            record = {**old, "arena": str(scope), "worker_executable": str(scope / "micropod"),
                      "compiled_sources": {**old["compiled_sources"], **changed},
                      "patch_sha256": hashed(patch), "guest_runner_sha256": runner_sha,
                      "output_polling_mode": mode, "output_polling_parent": str(previous)}
            (stage / "product.json").write_bytes(encode(record))
            receipt = {"schema": SCHEMA, "mode": mode, "identity": identity, "product": str(product),
                       "product_sha256": digest(stage / "product.json"), "runner_sha256": runner_sha,
                       "source_dir": str(scope / "src"), "runner_source_dir": str(scope / "src" / RUNNER),
                       "changed_sources": changed, "delta_sha256": hashed(delta), "tree_guards": stable,
                       "build": {"argv": command, "cwd": str(cwd), "toolchain": tools,
                                 "binary_build_info": info, "stdout": compiled.stdout, "stderr": compiled.stderr}}
            (stage / ARM).write_bytes(encode(receipt))
            stage.rename(scope)
    result = {"product": str(product), "product_sha256": digest(product),
              "runner_sha256": digest(scope / JOB), "build_manifest": str(scope / ARM),
              "build_manifest_sha256": digest(scope / ARM)}
    receipt = read(scope / ARM)
    require(receipt["identity"] == identity and (scope / DELTA).read_bytes() == delta,
            "existing output polling package uses different inputs")
    return result


def check_arm(manifest, mode):
    previous, stock, original = parent()
    require(manifest["schema"] == SCHEMA and manifest["previous_product"] == str(previous)
            and manifest["previous_product_sha256"] == digest(previous)
            and manifest["parent_manifest_sha256"] == PARENT_SHA and manifest["kernel"] == original["kernel"]
            and manifest["host_sha256"] == HOST_SHA and manifest["new_bootstrap_sha256"] == BOOT_SHA
            and set(manifest["arms"]) == set(MODES), "invalid output polling package manifest")
    arm = manifest["arms"][mode]
    path = Path(arm["product"])
    scope, product = path.parent, read(path)
    require(path.name == "product.json" and scope.parent == BASE and scope.name.startswith("ci-published-link-")
            and digest(path) == arm["product_sha256"]
            and Path(arm["build_manifest"]) == scope / ARM
            and digest(scope / ARM) == arm["build_manifest_sha256"]
            and product["output_polling_mode"] == mode and product["output_polling_parent"] == str(previous)
            and product["guest_runner_sha256"] == arm["runner_sha256"] == digest(scope / JOB)
            and ((arm["runner_sha256"] == STOCK_SHA) == (mode == "stock")),
            "wrong sealed Linux runner or product arm")
    receipt = read(scope / ARM)
    changed = {name: sha for name, sha in product["compiled_sources"].items()
               if stock["compiled_sources"].get(name) != sha}
    require((not changed if mode == "stock" else set(changed) == ALLOWED)
            and set(product["compiled_sources"]) == stock["compiled_sources"].keys()
            and receipt["changed_sources"] == changed and receipt["identity"]["changed"] == changed
            and receipt["build"]["toolchain"] == manifest["toolchain"]
            and receipt["runner_sha256"] == arm["runner_sha256"]
            and receipt["product_sha256"] == arm["product_sha256"], "output polling source or recipe differs")
    expected = {**stock, "arena": str(scope), "worker_executable": str(scope / "micropod"),
                "compiled_sources": {**stock["compiled_sources"], **changed},
                "patch_sha256": product["patch_sha256"], "guest_runner_sha256": arm["runner_sha256"],
                "output_polling_mode": mode, "output_polling_parent": str(previous)}
    require(product == expected, "output polling product changed another packaged input")
    sources = {name: (scope / "src" / name).read_bytes() for name in changed}
    if mode == "optimized":
        check_modules(previous.parent / "src", sources)
    delta = exact_diff(previous.parent / "src", sources)
    require((scope / DELTA).read_bytes() == delta and receipt["delta_sha256"] == hashed(delta)
            and (scope / "worker.patch").read_bytes() == (previous.parent / "worker.patch").read_bytes() + delta,
            "archived output polling patch differs from source")
    guards = {"tools_except_job": tree(scope / TOOLS, ("runner/bin/job",)),
              "source_except_follower": tree(scope / "src", ALLOWED)}
    require(guards == manifest["tree_guards"] == receipt["tree_guards"]
            and all(digest(scope / name) == digest(previous.parent / name)
                    for name in ("micropod-oci", "file-fault-around-bootstrap.sh")),
            "output polling altered an unrelated source or tool")
    verify_inputs(scope, product)
    return path, product, receipt


def freeze(candidate, go, output):
    previous, old, baseline = parent()
    require(ALLOWED <= old["compiled_sources"].keys(), "sealed product lacks one output follower input")
    files = {name: (candidate / Path(name).name).read_bytes() for name in ALLOWED}
    require(all(hashed(data) != old["compiled_sources"][name] for name, data in files.items()),
            "candidate must change exactly the sealed output follower sources")
    check_modules(previous.parent / "src", files)
    env, compiler = toolchain(go)
    info = binary_info(compiler["path"], previous.parent / JOB, env)
    require(f"build\tvcs.revision={old['base_revision']}" in info
            and "build\tvcs.modified=true" in info, "stock runner VCS recipe differs")
    guards = {"tools_except_job": tree(previous.parent / TOOLS, ("runner/bin/job",)),
              "source_except_follower": tree(previous.parent / "src", ALLOWED)}
    arms = {mode: frozen_arm(previous, old, mode, files if mode == "optimized" else {},
                             compiler, env, guards, info) for mode in MODES}
    manifest = {"schema": SCHEMA, "previous_product": str(previous), "previous_product_sha256": digest(previous),
                "parent_manifest_sha256": PARENT_SHA, "kernel": baseline["kernel"], "toolchain": compiler,
                "host_sha256": HOST_SHA, "new_bootstrap_sha256": BOOT_SHA, "tree_guards": guards, "arms": arms}
    for mode in MODES:
        check_arm(manifest, mode)
    data = encode(manifest)
    try:
        with output.open("xb") as stream:
            stream.write(data)
    except FileExistsError:
        require(output.read_bytes() == data, "different immutable output polling manifest already exists")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("freeze")
    build.add_argument("--go", type=Path, required=True)
    build.add_argument("--candidate-runner", type=Path, default=ROOT / RUNNER)
    build.add_argument("--manifest", type=Path, default=HERE / MANIFEST)
    verify = sub.add_parser("verify")
    verify.add_argument("--manifest", type=Path, default=HERE / MANIFEST)
    args = parser.parse_args()
    if args.command == "freeze":
        manifest = freeze(args.candidate_runner, args.go, args.manifest)
    else:
        manifest = read(args.manifest)
        for mode in MODES:
            check_arm(manifest, mode)
    print(encode(manifest).decode(), end="")


if __name__ == "__main__":
    main()
