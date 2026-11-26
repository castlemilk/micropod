"""Unscored path proof. Release 32 same-turn marker requests; assert exact replies and drain."""
import asyncio
from contextlib import ExitStack
import json
from pathlib import Path
import sys
from study import mixed, owned_relay, POLICIES, WORK

async def markers(port, marker):
    async def request():
        reader,writer=await asyncio.open_connection('127.0.0.1',port)
        writer.write(b'GET /id HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n');await writer.drain()
        data=await reader.read();writer.close();await writer.wait_closed()
        header,body=data.split(b'\r\n\r\n',1)
        assert b'200 OK' in header.split(b'\r\n')[0] and body==marker.encode()
    await asyncio.wait_for(asyncio.gather(*(request() for _ in range(32))),10)

def main():
    base=mixed();output=Path(sys.argv[1]).resolve();output.mkdir(exist_ok=False)
    marker='admission-group-smoke';report={}
    with ExitStack() as owners:
        service,port=base.service(owners,marker,output)
        for policy in POLICIES:
            arm=output/policy;arm.mkdir();observation={};report[policy]=observation
            with owned_relay(base,policy,port,arm,marker,observation) as (_,address):
                asyncio.run(markers(int(address.split(':')[1]),marker))
            assert sum(row[0] for row in observation['owner_accounting'])==34
            observation['marker_replies']=32
    (output/'receipt.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
