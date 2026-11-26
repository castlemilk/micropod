"""Build a matched 1,000 Hz ARM64 CI kernel and verify the three tick-related config differences."""
import argparse
import difflib
import json
import shutil
import subprocess
import tempfile
from datetime import UTC, datetime
from pathlib import Path

from qualify import require, terminal
from build_pages import BASE_CONFIG, SOURCE_SHA
import kernel_candidate

DELTA = {"CONFIG_HZ_250": ["y", "n"], "CONFIG_HZ_1000": ["n", "y"], "CONFIG_HZ": ["250", "1000"]}


def compare(control, candidate):
    standard, old = kernel_candidate.inspect(control, 16)
    trial, new = kernel_candidate.inspect(candidate, 16)
    changes = {k: [old.get(k), new.get(k)] for k in old.keys() | new.keys() if old.get(k) != new.get(k)}
    require(changes == DELTA and standard["embedded_config_verified"] and trial["embedded_config_verified"]
            and (control / "release").read_bytes() == (candidate / "release").read_bytes(),
            f"unexpected tick config or release: {changes}")
    return {"control": standard, "candidate": trial, "config_changes": changes}


def build(control, seed):
    control, seed = control.resolve(), seed.resolve()
    inputs = json.loads((control / "build-inputs.json").read_bytes())
    original = json.loads((control / "build-container.json").read_bytes())
    archive = control / "linux-7.3.5.tar.xz"
    script = control / "build-worker-kernel.sh"
    require(terminal.digest(archive) == inputs["source_sha256"] == SOURCE_SHA and
            terminal.digest(seed) == inputs["config_sha256"] == BASE_CONFIG and
            terminal.digest(script) == inputs["builder_sha256"] and original["image"] == inputs["alpine_image"],
            "unexpected source, seed, compiler image or builder")
    out = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-hz1000-"), dir=control.parent))
    print(out, flush=True)
    old = seed.read_text()
    new = old
    for before, after in (("CONFIG_HZ_250=y", "# CONFIG_HZ_250 is not set"),
                          ("# CONFIG_HZ_1000 is not set", "CONFIG_HZ_1000=y"), ("CONFIG_HZ=250", "CONFIG_HZ=1000")):
        require(new.count("\n" + before + "\n") == 1, "unexpected Apple tick selection")
        new = new.replace("\n" + before + "\n", "\n" + after + "\n")
    (out / "apple-tick.config").write_text(new)
    (out / "tick-config.patch").write_text("".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                                                        "apple.config", "apple-tick.config")))
    shutil.copy2(script, out / script.name)
    label = "mp-tick-" + out.name.lower().replace("_", "-")
    docker = ["docker", "--context", "orbstack"]
    args = [*docker, "run", "--rm", "--pull=never", "--cpus", "4", "--pids-limit", "1024", "--name", label,
            "--label", "io.micropod.bench.kernel-build=" + label]
    for key, value in original["env"].items():
        args += ["-e", key + "=" + value]
    for path, target in ((archive, "/inputs/linux.tar.xz"), (out / script.name, "/inputs/build-worker-kernel.sh"),
                         (out / "apple-tick.config", "/inputs/apple.config"), (out, "/out")):
        args += ["--mount", f"type=bind,src={path},dst={target}" + (",readonly" if target != "/out" else "")]
    command = inputs["command"].replace("for mode in full full-16k;", "for mode in full-16k;")
    require(command != inputs["command"], "unexpected control build recipe")
    args.extend([original["image"], "/bin/sh", "-ec", command])
    evidence = {"source_sha256": SOURCE_SHA, "seed_sha256": BASE_CONFIG, "selected_seed_sha256": terminal.digest(out / "apple-tick.config"),
                "builder_sha256": inputs["builder_sha256"], "compiler_image": original["image"], "environment": original["env"],
                "command": args, "control_directory": str(control)}
    terminal.save(out / "build-inputs.json", evidence)
    with (out / "driver.log").open("xb") as log:
        subprocess.run(args, check=True, stdout=log, stderr=subprocess.STDOUT)
    pair = compare(control / "full-16k", out / "full-16k")
    def packages(folder):
        return sorted(s for s in (folder / "toolchain.txt").read_text().splitlines() if " - " in s)
    require(packages(out) == packages(control) and len(packages(out)) == 97, "ARM64 toolchain packages differ")
    require(not subprocess.check_output([*docker, "ps", "-aq", "--filter", "label=io.micropod.bench.kernel-build=" + label],
                                        text=True).strip(), "kernel builder remains")
    terminal.save(out / "tick-build.json", {**pair, **evidence, "package_count": 97, "builder_retired": True})
    print(pair, flush=True)


def select(directory, control, files, folder):
    directory = directory.resolve()
    proof = json.loads((directory / "tick-build.json").read_bytes())
    pair = compare(control.resolve() / "full-16k", directory / "full-16k")
    require(all(proof[k] == v for k, v in pair.items()) and proof["source_sha256"] == SOURCE_SHA
            and proof["seed_sha256"] == BASE_CONFIG and proof["package_count"] == 97 and proof["builder_retired"],
            "tick build receipt differs")
    for n in ("tick-build.json", "tick-config.patch", "toolchain.txt", "build-worker-kernel.sh"):
        shutil.copy2(directory / n, folder / ("tick-" + n if not n.startswith("tick-") else n))
    files.update(kernel=directory / "full-16k/Image", kernel_config=directory / "full-16k/config")
    desc = pair["candidate"]
    return {"kernel_page_kib": 16, "kernel_hz": 1000, "kernel_image_sha256": desc["image_sha256"],
            "kernel_config_sha256": desc["config_sha256"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("control", type=Path)
    parser.add_argument("seed", type=Path)
    args = parser.parse_args()
    build(args.control, args.seed)
