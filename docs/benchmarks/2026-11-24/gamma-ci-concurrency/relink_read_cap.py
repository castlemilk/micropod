"""Relink a signed production fixture with its existing 512 KiB relay-read experiment."""

import argparse
import json
import shutil
import subprocess
from pathlib import Path

from build_delivery import BASE, CPUB, digest


def argument_lists(manifest):
    name = None
    for line in manifest.read_text().splitlines():
        if line.startswith('  "') and line.endswith('":'):
            name = json.loads(line.strip()[:-1])
        elif line.startswith("    args: "):
            yield name, json.loads(line.removeprefix("    args: "))


def build(donor):
    record = json.loads(donor.read_bytes())
    base = donor.resolve().parent
    if base.parent != BASE or digest(base / "micropod") != record["worker_executable_sha256"]:
        raise ValueError("production donor differs from its signed build")
    arena = BASE / ("ci-published-link-read512-" + record["worker_executable_sha256"][:12])
    product = arena / "product.json"
    if product.exists():
        if digest(arena / "micropod") != json.loads(product.read_bytes())["worker_executable_sha256"]:
            raise ValueError("signed candidate changed")
        return product
    arena.mkdir(exist_ok=True)
    release = base / "build/arm64-apple-macosx/release"
    executable = arena / "micropod"
    old = release / "CPublishedTCP.build/PublishedTCP.c.o"
    obj = arena / old.name
    commands = dict(argument_lists(base / "build/release.yaml"))
    compile_cmd = commands[str(old)].copy()
    if Path(compile_cmd[compile_cmd.index("-c") + 1]) != base / "src" / CPUB:
        raise ValueError("unexpected C input")
    compile_cmd[compile_cmd.index("-o") + 1] = str(obj)
    compile_cmd[compile_cmd.index("-MF") + 1] = str(arena / "PublishedTCP.c.d")
    compile_cmd = [
        ("-fmodules-cache-path=" + str(arena / "modules")) if s.startswith("-fmodules-cache-path=") else s
        for s in compile_cmd
    ]
    compile_cmd.insert(1, "-DMICROPOD_BENCH_512K_READS=1")
    subprocess.run(compile_cmd, check=True)
    link = commands["C.micropod-arm64-apple-macosx-release.exe"].copy()
    (at,) = [i for i, s in enumerate(link) if s.startswith("@") and s.endswith("Objects.LinkFileList")]
    objects = Path(link[at][1:]).read_text().splitlines()
    if objects.count(str(old)) != 1:
        raise ValueError("the production linker did not select exactly one relay object")
    objects[objects.index(str(old))] = str(obj)
    objlist = arena / "Objects.LinkFileList"
    objlist.write_text("\n".join(objects) + "\n")
    link[at] = "@" + str(objlist)
    link[link.index("-o") + 1] = str(executable)
    subprocess.run(link, check=True)
    subprocess.run(
        [
            "codesign",
            "--force",
            "--sign",
            "-",
            "--entitlements",
            base / "src/signing/micropod-cli.entitlements",
            executable,
        ],
        check=True,
    )
    subprocess.run(["codesign", "--verify", "--strict", executable], check=True)
    (arena / "src").symlink_to(base / "src", target_is_directory=True)
    (arena / "micropod-oci-tools").symlink_to(
        (base / "micropod-oci-tools").resolve(), target_is_directory=True
    )
    for file in ("micropod-oci", "worker.patch"):
        shutil.copy2(base / file, arena / file)
    record.update(
        arena=str(arena),
        worker_executable=str(executable),
        worker_executable_sha256=digest(executable),
        experimental_read_bytes=512 * 1024,
        donor_sha256=digest(base / "micropod"),
        c_command=compile_cmd,
        link_command=link,
        relay_object_sha256=digest(obj),
    )
    product.write_text(json.dumps(record, indent=2) + "\n")
    return product


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("donor", type=Path)
    print(build(parser.parse_args().donor), flush=True)
