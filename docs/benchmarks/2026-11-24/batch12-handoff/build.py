"""Build isolated throughput fixture from sealed production Swift and C sources."""
import hashlib, json, os, shutil, subprocess
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REV = '2e9b37c1e68334c443d71b729f0bd6334d824ddd'
WORK = ROOT/'.build/local-published-tcp/20261124-after-restart/handoff-bounded'
PREVIOUS = HERE.parent/'batch11-host-hot-wait'
REUSE = WORK.parent/'mixed'
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
run = subprocess.run

def build():
    WORK.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(WORK/'clang-cache'))
    def checkout(path):return subprocess.check_output(['git','show',REV+':'+path],cwd=ROOT)
    files = {'PublishedTCP.h':'Sources/CPublishedTCP/include/PublishedTCP.h','PublishedTCP.c':'Sources/CPublishedTCP/PublishedTCP.c','NativeLoopbackRelay.original.swift':'Sources/MicropodRuntime/NativeLoopbackRelay.swift'}
    for dest,source in files.items(): (WORK/dest).write_bytes(checkout(source))
    old=(WORK/'NativeLoopbackRelay.original.swift').read_text()
    adoption='''        func adopt(_ fd: Int32, accepted: UInt64) {
            owner.queue.async { mp_tcp_adopt(self.handle, fd, accepted) }
        }
'''
    release='''        func release(profile: Bool) -> mp_tcp_handoff_stats? {
            owner.queue.sync {
'''
    log='''                SecretSource.stderrLog("handoff " + String(admissions) + " " + String(submissions) + " " + String(completedAdmissions) + " " + String(completedBlocks) + " " + String(postWarmSubmissions))
'''
    assert old.count(adoption)==1 and old.count(release)==1
    (WORK/'NativeLoopbackRelay.swift').write_text(old.replace(adoption,(HERE/'handoff.swiftfrag').read_text()).replace(release,release+log))
    (WORK/'module.modulemap').write_text('module CPublishedTCP { header "PublishedTCP.h" export * }\n')
    run(['xcrun','clang','-std=gnu11','-O2','-Wall','-Werror','-c','PublishedTCP.c','-o','PublishedTCP.o'],cwd=WORK,env=env,check=True)
    for name, options in [('stock',[]),('batch2',['-D','BATCH_TWO'])]:
        run(['xcrun','swiftc','-O','-num-threads','1','-swift-version','6','-module-name','HandoffRelay','-module-cache-path',str(WORK/'swift-cache'),'-I',str(WORK),*options,'NativeLoopbackRelay.swift',str(HERE/'relay-main.swift'),'PublishedTCP.o','-o','relay-'+name],cwd=WORK,env=env,check=True)
    original=json.loads((PREVIOUS/'diagnostic-first/receipt.json').read_text())['file_sha256']
    for name in ('fixed','server','meter.dylib','suite.py'):
        src=REUSE/name if name!='suite.py' else PREVIOUS/name
        if src.is_file():
            assert sha(src)==original[name],(name,sha(src),original[name]);shutil.copy2(src,WORK/name)
        elif name in ('server','fixed'):
            source=name+'.go';assert sha(PREVIOUS/source)==original[source]
            shutil.copy2(PREVIOUS/source,WORK/source)
            go=os.environ.get('GO_BIN',str(Path.home()/'.local/share/mise/installs/go/1.27.2/bin/go'))
            goenv=dict(env,GOROOT=str(Path(go).resolve().parents[1]),GOTOOLCHAIN='local',GOMAXPROCS='2',GOPROXY='off',GOCACHE=str(WORK/'go-cache'))
            run([go,'build','-p=2','-trimpath','-o',name,source],cwd=WORK,env=goenv,check=True)
        else:
            assert name=='meter.dylib' and sha(PREVIOUS/'meter.c')==original['meter.c']
            shutil.copy2(PREVIOUS/'meter.c',WORK/'meter.c')
            run(['cc','-O2','-Wall','-Wextra','-Werror','-dynamiclib','meter.c','-o',name],cwd=WORK,env=env,check=True)
        assert sha(WORK/name)==original[name],name
    result={'revision':REV,'original_source':{p:sha(WORK/f) for f,p in files.items()},'fixture_sha256':{p:sha(HERE/p) for p in ('build.py','handoff.swiftfrag','relay-main.swift','study.py')},'binaries':{p:sha(WORK/p) for p in ('relay-stock','relay-batch2','fixed','server','meter.dylib','suite.py')},'clang':subprocess.check_output(['xcrun','clang','--version'],text=True),'swift':subprocess.check_output(['xcrun','swiftc','-version'],text=True)}
    (WORK/'build.json').write_text(json.dumps(result,indent=2)+'\n')

if __name__=='__main__':build()
