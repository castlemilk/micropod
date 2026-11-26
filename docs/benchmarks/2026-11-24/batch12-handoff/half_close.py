"""Unscored TCP delivery and FIN guard against the same compiled relay. Uses bounded buffers."""
import asyncio
import hashlib
import json
from pathlib import Path
import select
import subprocess
import sys
from study import POLICIES, WORK

async def verify(name, dst):
    content=bytes(range(251))*4096
    async def serve(r,w):
        data=await r.read();w.write(hashlib.sha256(data).digest()+data[::-1]);await w.drain();w.close();await w.wait_closed()
    server=await asyncio.start_server(serve,'127.0.0.1',0)
    async with server:
        with (dst/(name+'.stderr')).open('xb') as log:
            child=subprocess.Popen([WORK/('relay-'+name),str(server.sockets[0].getsockname()[1])],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True)
            try:
                if not select.select([child.stdout],[],[],8)[0]:raise TimeoutError('bind')
                config=json.loads(child.stdout.readline());port=config['port']
                async def flow(idx):
                    r,w=await asyncio.open_connection('127.0.0.1',port);payload=bytes([idx])+content
                    w.write(payload);await w.drain();w.write_eof()
                    h=hashlib.sha256();size=0
                    while data:=await r.read(8191):h.update(data);size+=len(data)
                    expected=hashlib.sha256(payload).digest()+payload[::-1];assert size==len(expected) and h.digest()==hashlib.sha256(expected).digest()
                    w.close();await w.wait_closed();return [idx,len(payload),size,h.hexdigest()]
                results=await asyncio.wait_for(asyncio.gather(*(flow(i) for i in range(4))),10)
                return {'config':config,'bytes_and_digests':results,'client_write_half_closed_before_read':True}
            finally:
                child.stdin.close()
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:child.kill();child.wait()
                child.stdout.close()

def main():
    root=Path(sys.argv[1]).resolve();root.mkdir(exist_ok=False);report={}
    for name in POLICIES:report[name]=asyncio.run(verify(name,root));(root/'receipt.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
