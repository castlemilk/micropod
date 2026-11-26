"""Seal and verify the private MTU candidate. This script never starts a VM."""
import argparse
import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
TREE = HERE.parents[3]
BASE = TREE / ".build/local-published-tcp"
ORIGINAL = BASE / "fixed-workers-5b8ea1a6/build"
ARENA = BASE / "private-pub-mtu-86ca2713"
SRC, BUILD = ARENA / "src", ARENA / "build"
REV = "86ca2713a0791d26c137e9a8c6385e1b6bd04ebb"
KEY = "MICROPOD_BENCH_PRIVATE_PUBLICATION_MTU"
OUT = HERE / "private-build"
RECORD = OUT / "build.json"


def run(args, **kw):
    return subprocess.run(list(map(str,args)),check=True,**kw)


def read(args):
    return subprocess.check_output(list(map(str,args)),text=True).strip()


def sha(p):
    with Path(p).open("rb") as f:
        return hashlib.file_digest(f,"sha256").hexdigest()


def save(p, v):
    tmp=p.with_suffix(".tmp")
    tmp.write_text(json.dumps(v,indent=2)+"\n")
    tmp.replace(p)


def paths(*names):
    return [SRC/"Sources/MicropodRuntime"/name for name in names]


def once(source, old, new):
    if source.count(old) != 1:
        raise ValueError("pinned source anchor differs: " + old[:100])
    return source.replace(old,new)


def prepare():
    if (ARENA/"prepared.json").is_file():
        return
    if SRC.exists():
        raise ValueError("source extraction is incomplete; preserve existing arena and supply a fresh build arena")
    OUT.mkdir(exist_ok=True)
    SRC.mkdir(parents=True)
    with subprocess.Popen(["git","-C",TREE,"archive",REV,"Package.swift","Package.resolved","Sources","Tests","sdk/swift","signing"],stdout=subprocess.PIPE) as git:
        run(["tar","-x","-C",SRC],stdin=git.stdout)
        if git.wait():
            raise ValueError("git archive failed")
    run(["git","apply","--directory=.",HERE/"published-mtu.patch"],cwd=SRC)
    helper,worker,service,vm,network=paths("PublishedMTUBenchmark.swift","CIWorker.swift","CIWorkerService.swift","SandboxVM.swift","SandboxNetwork.swift")
    shutil.copy2(HERE/"PublishedMTUBenchmark.swift",helper)
    before={p:p.read_text() for p in (worker,service,vm)}
    text=worker.read_text()
    text=once(text,'            "MICROPOD_CI_PORT_RELAY_WORKERS",','            "MICROPOD_CI_PORT_RELAY_WORKERS", "'+KEY+'",')
    text=once(text,"        var publishedPath: String? = nil","        var publishedPath: String? = nil\n        var benchmarkPublicationMTU: String? = nil")
    text=once(text,"    struct Configuration: Codable, Equatable {",'''    // Benchmark-only resource for one disposable worker. Existing manifests
    // have no selector. The first explicit value is immutable for that scope.
    func benchmarkPublicationMTU(existing: String?, publishedPath: String?) throws -> String? {
        guard let value = resourceEnvironment["MICROPOD_BENCH_PRIVATE_PUBLICATION_MTU"] ?? existing else { return nil }
        guard isNativeRunner, publishedPath == "macvlan", ["1500", "9000"].contains(value) else {
            throw MicropodError.message("Benchmark publication MTU requires a native macvlan worker and 1500 or 9000")
        }
        return value
    }

    struct Configuration: Codable, Equatable {''')
    text=once(text,'kernel: kernel, publishedPath: publishedPath == "bridge" ? nil : publishedPath)',
              'kernel: kernel, publishedPath: publishedPath == "bridge" ? nil : publishedPath,\n            benchmarkPublicationMTU: benchmarkPublicationMTU(existing: existing?.benchmarkPublicationMTU, publishedPath: publishedPath))')
    text=once(text,"        options.ciWorkspace = config.workspace","        options.benchmarkPublicationMTU = config.benchmarkPublicationMTU\n        options.ciWorkspace = config.workspace")
    worker.write_text(text)
    service.write_text(once(service.read_text(),"        var environment = resourceEnvironment","        _ = try benchmarkPublicationMTU(existing: nil, publishedPath: resourceEnvironment[\"MICROPOD_CI_PUBLISHED_PATH\"])\n        var environment = resourceEnvironment"))
    vm.write_text(once(once(vm.read_text(), "        var ciWorkspace: String?", "        var ciWorkspace: String?\n        var benchmarkPublicationMTU: String?"),
                       'benchmarkPublicationMTU: ProcessInfo.processInfo.environment["'+KEY+'"]','benchmarkPublicationMTU: options.benchmarkPublicationMTU'))
    chunks=[]
    for p,original in before.items():
        rel=p.relative_to(SRC)
        chunks.extend(difflib.unified_diff(original.splitlines(True),p.read_text().splitlines(True),fromfile="a/"+str(rel),tofile="b/"+str(rel)))
    (OUT/"worker-config-forwarding.patch").write_text(''.join(chunks))
    BUILD.mkdir()
    for name in ("checkouts","artifacts","repositories","workspace-state.json"):
        run(["/bin/cp","-cR",ORIGINAL/name,BUILD/name])
    for name in ("cache","config","security","modules","clang-modules"):
        (ARENA/name).mkdir(exist_ok=True)
    deps={}
    for p in json.loads((SRC/"Package.resolved").read_text())["pins"]:
        repo=BUILD/"checkouts"/p["identity"]
        expected=p["state"]["revision"]
        if read(["git","-C",repo,"rev-parse","HEAD"])!=expected or read(["git","-C",repo,"status","--porcelain","--untracked-files=no"]):
            raise ValueError("dependency checkout mismatch: " + p["identity"])
        deps[p["identity"]]=expected
    touched=[p.relative_to(SRC) for p in (helper,worker,service,vm,network)]
    sealed=[*touched,"Package.swift","Package.resolved","Sources/CPublishedTCP/PublishedTCP.c","signing/micropod-cli.entitlements"]
    save(ARENA/"prepared.json",dict(base_revision=REV,base_tree=read(["git","-C",TREE,"rev-parse",REV+"^{tree}"]),
         compiled_sources={str(p):sha(SRC/p) for p in sealed},patches={p.name:sha(p) for p in (HERE/"published-mtu.patch",HERE/"PublishedMTUBenchmark.swift",OUT/"worker-config-forwarding.patch")},
         dependency_revisions=deps,dependency_cache="read-only source, APFS private CoW copies",arena=str(ARENA)))


def render(binary):
    cases={}
    with tempfile.TemporaryDirectory(prefix="mp-mtu-render-",dir="/private/tmp") as d:
        home=Path(d)/"worker";home.mkdir(mode=0o700)
        for name,val,engine,path,ok in (("unset",None,"containerd","macvlan",True),("control","1500","containerd","macvlan",True),
                                      ("jumbo","9000","containerd","macvlan",True),("invalid","9001","containerd","macvlan",False),
                                      ("bridge","9000","containerd","bridge",False),("docker","9000","docker","macvlan",False)):
            env={k:v for k,v in os.environ.items() if not k.startswith("MICROPOD_")}
            env.update(MICROPOD_CI_HOME=str(home),MICROPOD_CI_ENGINE=engine,MICROPOD_CI_PUBLISHED_PATH=path,
                       MICROPOD_CI_PORT_RELAY="kqueue-interactive",MICROPOD_CI_PORT_RELAY_WORKERS="2",MICROPOD_CI_CPUS="4")
            if val is not None:env[KEY]=val
            p=subprocess.run([binary,"ci","launch-agent"],env=env,capture_output=True)
            if ok:
                assert p.returncode==0,p.stderr
                plist=plistlib.loads(p.stdout)
                assert plist["ProgramArguments"][1:]==["ci","serve"] and Path(plist["ProgramArguments"][0]).resolve()==binary and plist["EnvironmentVariables"].get(KEY)==val
            else:
                assert p.returncode and b"Benchmark publication MTU requires" in p.stderr,p.stderr
            cases[name]={"value":val,"engine":engine,"path":path,"render_exit":p.returncode,"forwarded":val if ok else None}
    return cases


def manifest_cases(binary):
    """Exercise the real configuration reader via cpu-plan, which never boots."""
    with tempfile.TemporaryDirectory(prefix="mp-mtu-manifest-",dir="/private/tmp") as home:
        common = {"schema":1,"worker":"00000000-0000-4000-8000-000000000001","cpus":4,
                  "diskGiB":6,"memoryMiB":4096,"publishedPath":"macvlan",
                  "image":"docker.io/library/alpine:3.23@sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2"}
        results=[]
        for existing,override,expect in ((None,None,"ok"),("1500","1500","ok"),("9000","9000","ok"),
                                         ("9000",None,"ok"),("1500","9000","mismatch"),("9000","1500","mismatch"),
                                         (None,"9000","mismatch"),("9000","9001","invalid")):
            doc=dict(common)
            if existing is not None:
                doc["benchmarkPublicationMTU"]=existing
            path=Path(home)/"worker.json"
            raw=json.dumps(doc).encode()
            path.write_bytes(raw)
            env={k:v for k,v in os.environ.items() if not k.startswith("MICROPOD_")}
            env.update(MICROPOD_CI_HOME=home,MICROPOD_CI_CPUS="4",MICROPOD_CI_ENGINE="containerd",
                       MICROPOD_CI_MEMORY_MIB="4096",MICROPOD_CI_DISK_GIB="6",MICROPOD_CI_PUBLISHED_PATH="macvlan")
            if override is not None:
                env[KEY]=override
            result=subprocess.run([binary,"ci","cpu-plan"],env=env,capture_output=True,text=True)
            if expect=="ok":
                if result.returncode or json.loads(result.stdout)!={"count":4,"source":"fixed"}:
                    raise ValueError("valid pinned manifest rejected: "+result.stderr)
            elif (result.returncode==0 or (expect=="mismatch" and "CI resources differ" not in result.stderr)
                  or (expect=="invalid" and "Benchmark publication MTU requires" not in result.stderr)):
                raise ValueError("unexpected response to mismatched private manifest: "+result.stderr)
            assert path.read_bytes()==raw and set(Path(home).iterdir())=={path}
            results.append(dict(existing=existing,override=override,expected=expect,exit=result.returncode,
                                stdout=result.stdout.strip(),stderr=result.stderr.strip()))
        return results


def verify():
    r=json.loads(RECORD.read_text())
    p=Path(r["worker_executable"])
    assert sha(p)==r["worker_executable_sha256"]
    run(["codesign","--verify","--strict",p])
    assert render(p)==r["launch_plist_cases"]
    cases=manifest_cases(p)
    save(OUT/"config-parser.json",dict(binary_sha256=sha(p),revision=REV,command="ci cpu-plan",cases=cases,
         fresh_private_manifest_per_case=True,host_networks_created=0,vm_boots=0,timed_attempts=0))
    print(f"{RECORD}  {sha(p)}; {len(cases)} checked worker-manifest cases")


def build(jobs):
    if RECORD.exists():
        return verify()
    prepare()
    prep=json.loads((ARENA/"prepared.json").read_text())
    for k,v in prep["compiled_sources"].items():
        assert sha(SRC/k)==v,k
    flags=["xcrun","swift","build","--disable-sandbox","--skip-update","--only-use-versions-from-resolved-file",
           "--cache-path",str(ARENA/"cache"),"--config-path",str(ARENA/"config"),"--security-path",str(ARENA/"security"),
           "--scratch-path",str(BUILD),"-c","release","--jobs",str(jobs),"--product","micropod","-Xswiftc","-num-threads","-Xswiftc","1","-Xswiftc","-j1"]
    env=dict(os.environ,GIT_ALLOW_PROTOCOL="file",CLANG_MODULE_CACHE_PATH=str(ARENA/"clang-modules"),SWIFTPM_MODULECACHE_OVERRIDE=str(ARENA/"modules"))
    log=ARENA/"build.log"
    with log.open("ab") as f:
        run(flags,cwd=SRC,env=env,stdout=f,stderr=subprocess.STDOUT)
    p=ARENA/"micropod"
    run(["/bin/cp","-c",BUILD/"arm64-apple-macosx/release/micropod",p])
    original=sha(p); ent=SRC/"signing/micropod-cli.entitlements"
    run(["codesign","--force","--sign","-","--entitlements",ent,p])
    run(["codesign","--verify","--strict",p])
    ents=plistlib.loads(subprocess.check_output(["codesign","-d","--entitlements","-","--xml",p],stderr=subprocess.DEVNULL))
    assert ents==plistlib.loads(ent.read_bytes())=={"com.apple.security.virtualization":True}
    sym=read(["nm","-u",p])
    assert "_vmnet_network_configuration_set_mtu" in sym,sym[-500:]
    qualified=Path.home()/".micropod/qualified/interactive-a41976076b67-2293dd639a7a"
    run(["/bin/cp","-c",qualified/"micropod-oci",ARENA/"micropod-oci"])
    if not (ARENA/"micropod-oci-tools").exists():
        (ARENA/"micropod-oci-tools").symlink_to(qualified/"micropod-oci-tools",target_is_directory=True)
    save(RECORD,dict(**prep,worker_executable=str(p),worker_executable_sha256=sha(p),pre_sign_sha256=original,
        recorded_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),command=flags,compile_log=str(log),
        compile_log_sha256=sha(log),swift=read(["xcrun","swift","--version"]),sdk=read(["xcrun","--show-sdk-version"]),
        entitlements=ents,launch_plist_cases=render(p),vmnet_setter_import=True,vm_boots=0,timed_attempts=0))
    verify()


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action",choices=["prepare","build","verify"])
    parser.add_argument("--jobs",type=int,choices=(1,2),default=2)
    args=parser.parse_args()
    if args.action=="prepare":prepare()
    elif args.action=="build":build(args.jobs)
    else:verify()
