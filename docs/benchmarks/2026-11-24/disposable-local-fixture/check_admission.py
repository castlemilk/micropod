"""Reproduce local VM contention-classification cases without running any client."""
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

import local_admission as gate


def main():
    cases = []
    binary = Path("/test/micropod")
    def observe(label, procs, reason=None, persistent=None, own=None):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            admission = gate.Admission(folder)
            def snapshot(*_):
                if isinstance(persistent, Exception):
                    raise persistent
                if persistent is None:
                    raise AssertionError("unexpected persistent-worker check")
                return persistent
            with patch.object(gate, "processes", return_value=iter(procs)), patch.object(gate, "inventory", side_effect=snapshot), patch.object(admission,"own_supervisor",return_value=bool(own)):
                try:
                    admission.check(force=True)
                    error = None
                except ValueError as exc:
                    error = str(exc)
            rec = json.loads((folder / "admission.jsonl").read_text())
            assert (error is None and reason is None) or (error and reason and reason in error), (label,error)
            assert "confidential-marker" not in json.dumps(rec)
            cases.append((label, bool(rec["blockers"])))
    observe("shell text mentions a benchmark", [(70,Path("/bin/zsh"),["zsh","-c","/test/micropod ci serve /test/fixed http://127.0.0.1:8080 confidential-marker"])])
    observe("inactive GitHub runner listener",[(71,Path("/usr/local/bin/cuttle"),["cuttle","agent","github-runner","confidential-marker"])])
    observe("actual job executor",[(72,Path("/usr/local/bin/Runner.Worker"),["Runner.Worker","spawn","confidential-marker"])],"PID 72")
    observe("TCP client first attempt",[(73,Path("/tmp/x/fixed"),["fixed","http://127.0.0.1:4242","confidential-marker"])],"PID 73")
    observe("TCP server only",[(74,Path("/tmp/x/netbench"),["netbench","-listen",":8080","-marker","confidential-marker"])])
    observe("actual netbench client",[(75,Path("/tmp/x/netbench"),["netbench","-url=http://127.0.0.1:9100"])],"PID 75")
    supervisor = [(76,binary,["micropod","ci","serve"])]
    observe("separate named worker",supervisor,"unrecognized Micropod",ValueError("unrecognized Micropod CI supervisor or scope"))
    observe("idle attested persistent worker",supervisor,persistent=dict(key=(76,"instance"),opened=112,worker="worker",instance="instance"))
    observe("active native sessions",supervisor,"active OCI sessions",ValueError("persistent worker has 1 active OCI sessions"))
    observe("running named container",supervisor,"running containers",ValueError("persistent worker has 1 running containers (IDs 0123456789ab)"))
    observe("socket inspection denied",supervisor,"permission denied",PermissionError("permission denied"))
    observe("native job between two polls",supervisor,"opened",ValueError("a native job opened on the persistent worker during this run"))
    observe("owned disposable supervisor",supervisor,own=True)
    print(json.dumps(dict(passed=len(cases),cases=dict(cases),unit="blocked=true"),indent=2))


if __name__ == "__main__":
    main()
