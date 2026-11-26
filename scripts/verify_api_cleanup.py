"""Verify the two qualified endpoint inventories for this run's distinct labels."""
import argparse
import gzip
import http.client
import json
from pathlib import Path
import socket
import urllib.parse
p = argparse.ArgumentParser(description=__doc__)
for option in ("reference","candidate","audit","out"):
    p.add_argument("--"+option,type=Path,required=True)
args = p.parse_args()
with gzip.open(args.audit, "rt") as data:
    audit = json.load(data)
report = {}
class LocalHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        self.sock.settimeout(15)
        self.sock.connect(self.host)
for side, filename in (("reference",args.reference),("candidate",args.candidate)):
    labels=audit["scopes"][side]["labels"]
    query=urllib.parse.urlencode({"filters":json.dumps({"label":[k+"="+v for k,v in labels.items()]})})
    report[side]={}
    for kind,path in (("containers","/containers/json?all=1&"),("images","/images/json?all=1&"),("networks","/networks?"),("volumes","/volumes?")):
        conn=LocalHTTP(str(filename))
        try:
            conn.request("GET","/v1.47"+path+query,headers={"Host":"localhost"})
            resp=conn.getresponse()
            if resp.status != 200:
                raise RuntimeError((side,kind,resp.status,resp.read(180)))
            rows=json.load(resp)
            if kind=="volumes":
                rows=rows.get("Volumes") or []
            owned=[r for r in rows if all((r.get("Labels") or {}).get(k)==v for k,v in labels.items())]
            report[side][kind]=dict(status=resp.status, returned=len(rows), matching=len(owned))
            assert resp.status==200 and not rows, (side, kind, len(rows))
        finally:
            conn.close()
args.out.write_text(json.dumps(report,indent=2)+"\n")
