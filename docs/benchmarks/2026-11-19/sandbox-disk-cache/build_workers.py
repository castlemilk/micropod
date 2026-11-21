"""Use the existing SwiftPM release build to link just the two disk-stage workers."""

import json
from pathlib import Path
import subprocess


def git_source(repo, ref, path):
    return subprocess.check_output(["git", "-C", str(repo), "show", f"{ref}:{path}"], text=True)


def disk_functions(source):
    functions = []
    for name in ("resolveBase", "initfs", "pickVMInit", "normalize", "clone"):
        start = source.index(f"    static func {name}(")
        end = source.index("\n    }\n", start) + len("\n    }")
        functions.append(source[start:end])
    version = next(line for line in source.splitlines() if "static let linkedContainerizationVersion" in line)
    return "\n".join([version, *functions])


def build(repo, work, baseline, candidate):
    # Take both the compiler options and linked library objects from the same
    # release build, so the comparisons only differ in their runtime source.
    config = repo / ".build/release"
    swift = json.loads((config / "description.json").read_text())["swiftCommands"]
    compile_task = next(v for k, v in swift.items() if k.startswith("C.MicropodBench-"))
    args = compile_task["otherArguments"].copy()
    entry = args.index("-entry-point-function-name") - 1
    assert args[entry:entry + 4] == ["-Xfrontend", "-entry-point-function-name", "-Xfrontend", "MicropodBench_main"]
    del args[entry:entry + 4]
    args[args.index("-num-threads") + 1] = "1"
    args[args.index("-module-cache-path") + 1] = str(work / "modules")
    args.remove("-serialize-diagnostics")
    args.remove("-parseable-output")

    linked_objects = (config / "MicropodBench.product/Objects.LinkFileList").read_text().splitlines()
    objects_file = work / "objects"
    objects_file.write_text("\n".join(o for o in linked_objects if "/MicropodBench.build/" not in o) + "\n")
    link_spec = next(line for line in (repo / ".build/release.yaml").read_text().splitlines()
                     if "args: [" in line and "MicropodBench.product/Objects.LinkFileList" in line)
    link = json.loads(link_spec.split("args: ", 1)[1])
    alias = link.index("-alias") - 1
    assert link[alias:alias + 6] == ["-Xlinker", "-alias", "-Xlinker", "_MicropodBench_main", "-Xlinker", "_main"]
    del link[alias:alias + 6]
    file_index = next(i for i, a in enumerate(link) if a.startswith("@") and a.endswith("/Objects.LinkFileList"))
    link[file_index] = "@" + str(objects_file)

    runtime = "Sources/MicropodRuntime"
    template = Path(__file__).with_name("DiskWorker.swift").read_text()
    for label, ref in (("before", baseline), ("after", candidate)):
        sandbox = git_source(repo, ref, runtime + "/SandboxVM.swift")
        worker = template.replace("    // INSERT_DISK_FUNCTIONS", disk_functions(sandbox))
        if "SandboxDiskCache(" in sandbox:
            worker += "\n" + git_source(repo, ref, runtime + "/SandboxDiskCache.swift")
        source = work / (label + ".swift")
        obj = work / (label + ".o")
        source.write_text(worker)
        subprocess.run([compile_task["executable"], "-I", compile_task["importPath"], "-module-name",
                        "DiskProbe", "-c", *args, "-o", str(obj), str(source)], check=True)
        linker = link.copy()
        linker[linker.index("-o") + 1] = str(work / label)
        subprocess.run([*linker, str(obj)], check=True)
