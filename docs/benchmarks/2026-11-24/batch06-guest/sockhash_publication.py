"""Exercise every arrival boundary during registration of a published TCP socket pair."""
import ctypes
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ARCHIVE = HERE.parents[3] / "docs/benchmarks/2026-11-21/gamma-mixed-scheduler.json.gz"
ARCHIVE_SHA = "9e3b184de862aafacff47312878441e940d030e8cfc8342c0e479d064f4724c8"
HELPER_SHA = "3c489dd5864c8df12b06fbe81ca2dacd47d55c2b2d4f5c6f4e9a5eb691044c8a"
BASE = "17bcd4355234b11da3a7a1da2ded52f4dc20f5d1"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def function(text, sig):
    start=text.index(sig)
    return text[start:text.index("\n}",start)+2]


def registration(source, candidate):
    original=function(source, "func (h *sockEngine) register(")
    actions=re.findall(r"^\tcheck\(h\.(?:socks|peers)\.Update\(.*$",original,re.M)
    assert len(actions)==4 and [line.split('.')[1] for line in actions]==['peers','peers','socks','socks']
    if not candidate:
        return original
    # Publish both redirect destinations before exposing either routing entry.
    return original.replace("\n".join(actions),"\n".join(actions[2:]+actions[:2]))


def stages(operations, helper):
    socks, peers = {},{}
    rows=[]
    for step in range(len(operations)+1):
        if step:
            op=operations[step-1]
            (socks if op['Map']=='socks' else peers)[op['Key']]=op['Value']
        for src,dst in [(11,22),(22,11)]:
            if src not in socks:
                verdict='ordinary_socket'
            elif src not in peers:
                verdict='verdict_pass_to_socket'
            else:
                mask = int(11 in socks) + 2*int(22 in socks)
                r=helper(mask,peers[src])
                if r == -1:
                    verdict='verdict_drop'
                else:
                    assert r == dst
                    verdict='verdict_redirect'
            rows.append(dict(completed_updates=step,origin_cookie=src,destination_cookie=dst,frame_bytes=64,verdict=verdict))
    return rows


def run(kernel):
    raw=ARCHIVE.read_bytes()
    assert digest(raw)==ARCHIVE_SHA
    arc=json.loads(gzip.decompress(raw))
    go_source=arc['records']['fixtures/sockexp/maps.go']
    main_source=arc['records']['fixtures/sockexp/main.go']
    assert 'defer maps.register(a, d)()' in main_source
    assert 'go copyHalf(d, a)' in main_source and 'copyHalf(a, d)' in main_source
    # The archived program sends a missing peer directly to SK_PASS; forwards a
    # failed redirect helper's actual return to exit. Confirm these branch bytes.
    verdict=go_source[go_source.index('in := asm.Instructions{'):go_source.index('\n\tvar e error')]
    assert 'asm.FnMapLookupElem.Call(), asm.JEq.Imm(asm.R0, 0, "pass")' in verdict
    assert 'asm.FnSkRedirectHash.Call(), asm.JNE.Imm(asm.R0, 1, "exit")' in verdict
    assert 'asm.Mov.Imm(asm.R0, 1).WithSymbol("pass"), asm.Return().WithSymbol("exit")' in verdict
    assert 'asm.Mov.Imm(asm.R4, 0), asm.FnSkRedirectHash.Call()' in verdict
    kern=Path(kernel).read_bytes()
    assert digest(kern)==HELPER_SHA
    helper=function(kern.decode(),'BPF_CALL_4(bpf_sk_redirect_hash,')
    skeleton=(HERE/'sockhash_register.go.in').read_text()
    go=os.environ.get('GO','go')
    env={**os.environ,'GOWORK':'off','GOENV':'off','GO111MODULE':'off','GOTOOLCHAIN':'local','GOPROXY':'off','GOSUMDB':'off','GOTELEMETRY':'off','GOMAXPROCS':'1','CGO_ENABLED':'0'}
    env.pop('GOROOT',None)
    arms={}
    with tempfile.TemporaryDirectory() as directory:
        wd=Path(directory)
        (wd/'redirect_hash.inc').write_text(helper+'\n')
        subprocess.run(['cc','-Wall','-Werror','-std=c11','-shared','-fPIC','-I',str(wd),str(HERE/'sockhash_helper.c'),'-o',str(wd/'helper.so')],check=True)
        native=ctypes.CDLL(str(wd/'helper.so')).try_target
        native.argtypes=[ctypes.c_int,ctypes.c_int]
        for candidate in (False,True):
            arm='targets_first' if candidate else 'original'
            body=registration(go_source,candidate)
            (wd/'register.go').write_text(skeleton.replace('REGISTER_BODY',body))
            subprocess.run([go,'build','-p','1','-o',str(wd/'probe'),str(wd/'register.go')],cwd=wd,env=env,check=True)
            actions=json.loads(subprocess.check_output([wd/'probe']))
            rows=stages(actions,native)
            arms[arm]=dict(register_sha256=digest(body.encode()),operations=actions,arrivals=rows,
                counts={v:sum(r['verdict']==v for r in rows) for v in ['ordinary_socket','verdict_pass_to_socket','verdict_drop','verdict_redirect']})
    assert [x['counts']['verdict_drop'] for x in arms.values()]==[1,0]
    assert all(x['arrivals'][-1]['verdict']==x['arrivals'][-2]['verdict']=='verdict_redirect' for x in arms.values())
    return dict(id='234.03',tier='source/fixture',base=BASE,archive=ARCHIVE.name,archive_sha256=ARCHIVE_SHA,
        archived_micropod_revision='692ace081c989f80fb2bce27a5a13af13098b77c',archived_socket_program_binary=arc['sha256']['sockhash'],
        archived_maps_go_sha256=digest(go_source.encode()),input_verdict_block_sha256=digest(verdict.encode()),
        kernel_helper_file='linux-7.3.5/net/core/sock_map.c',kernel_helper_file_sha256=digest(kern),kernel_helper_sha256=digest(helper.encode()),
        go=subprocess.check_output([go,'version'],env=env,text=True).strip(),
        fixture_sha256={p:digest((HERE/p).read_bytes()) for p in ['sockhash_publication.py','sockhash_helper.c','sockhash_register.go.in']},
        workload='One independently assessed 64-byte arrival per direction at each of the five boundaries of four registration operations, ten arrival cases per arm.',
        limits='Source/fixture. Original Go registration function executes with instrumented map writes, verdict control flow is modeled from verified archived branch instructions, pinned C redirect helper executes with in-memory socket lookup. Frames were never put on a wire. No guaranteed userspace fallback ordering, FIN coverage or observed cause of the historical EOFs.',arms=arms)


if __name__=='__main__':
    print(json.dumps(run(sys.argv[1]),indent=2))
