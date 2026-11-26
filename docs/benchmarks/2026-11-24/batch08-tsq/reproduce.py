"""Replay an original Linux TCP Small Queues decision using fixed socket readbacks."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
BASE = 'ad9d174eda5eb499e0e15675829e21a00d836f84'
TAR = '8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990'
TCP = 'b55846bf35be5799cc19318c9215aa1b8a9a4881f8e3794cf5dc08b8aa4ea5b7'
MIB = 1 << 20


def sha(data):
    return hashlib.sha256(data).hexdigest()


def replay(kernel, output):
    src = (kernel/'net/ipv4/tcp_output.c').read_bytes()
    assert sha(src) == TCP
    start = src.index(b'static bool tcp_small_queue_check(')
    function = src[start:src.index(b'\n}\n',start)+3]
    default = (kernel/'net/ipv4/tcp_ipv4.c').read_bytes()
    sock = (kernel/'net/core/sock.c').read_bytes()
    assert b'sysctl_tcp_limit_output_bytes = 4 << 20;' in default
    assert b'WRITE_ONCE(sk->sk_pacing_shift, 10);' in sock
    assert b'if (tcp_small_queue_check(sk, skb, 0))' in src
    rates = (128,1024,4096,6144,8192)
    charges = (128*1024,140*1024,4*MIB,4*MIB+1,6*MIB,6*MIB+1,8*MIB,8*MIB+1)
    scenarios = [(rate,size,c,c,3) for rate in rates for size in (2048,69632) for c in charges]
    scenarios += [(6144,69632,5*MIB,5*MIB,entries) for entries in (0,1,3)]
    scenarios += [(6144,69632,5*MIB,4*MIB,3)]
    rng=random.Random(2310848)
    orders=[[4,8]]*(len(scenarios)//2)+[[8,4]]*(len(scenarios)//2)
    rng.shuffle(orders)
    encoded=[]
    for scenario,order in zip(scenarios,orders,strict=True):
        rate,size,first,second,entries=scenario
        for cap in order:
            encoded.append(f"{cap*MIB} {rate*MIB} {size} {first} {second} {entries}")
    with tempfile.TemporaryDirectory() as temp:
        build=Path(temp)
        (build/'original.inc').write_bytes(function)
        binary=build/'test'
        subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-I',temp,
                        HERE/'tsq.c','-o',binary],check=True)
        lines=subprocess.check_output([binary],input='\n'.join(encoded)+'\n',text=True).splitlines()
    assert len(lines)==2*len(scenarios)
    rows=[]
    for i,(rate,size,before,after,entries) in enumerate(scenarios):
        arm={}
        for offset,cap in enumerate(orders[i]):
            throttle,reads,flag=map(int,lines[2*i+offset].split())
            limit=min(cap*MIB,max(2*size,rate*MIB>>10))
            over=before>limit and entries>1
            assert (throttle,reads,flag)==(int(over and after>limit),1+int(over),int(over))
            arm[str(cap)]=dict(stop=bool(throttle),reads=reads,throttled_bit=bool(flag))
        rows.append(dict(rate_MiB_per_s=rate,skb_truesize_B=size,wmem_first_B=before,
                         wmem_second_B=after,rtx_entries=entries,first_attempt_order_MiB=orders[i],arms=arm))
    meta=dict(date='2026-11-24',direction='231.08',tier='source/fixture',base=BASE,
              kernel='Linux 7.3.5',tar_sha256=TAR,source_sha256=TCP,function_sha256=sha(function),
              ipv4_sha256=sha(default),sock_sha256=sha(sock),fixture_sha256=sha((HERE/'tsq.c').read_bytes()),
              reproducer_sha256=sha(Path(__file__).read_bytes()),compiler=subprocess.check_output(
                  ['cc','--version'],text=True).splitlines()[0],
              normal_send_factor=0,pacing_shift=10,tcp_tx_delay=0,rows=rows)
    with output.open('x') as f:
        json.dump(meta,f,indent=2)
        f.write('\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('linux_src',type=Path)
    parser.add_argument('output',type=Path)
    args=parser.parse_args()
    replay(args.linux_src,args.output)
