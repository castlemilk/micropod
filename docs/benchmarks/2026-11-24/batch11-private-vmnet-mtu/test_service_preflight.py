"""Exercise the strict service verifier without opening a socket or starting a worker."""
import copy
import unittest

import service_preflight as s
from test_mtu_path import DirectPathMTUTests as DF


def fixture(mtu):
    DF.setUpClass()
    case = DF()
    path = case.attach_reverse(case.fixture())
    if mtu == 1500:
        # Convert only the synthetic jumbo DF observation lengths.
        import json
        path = json.loads(json.dumps(path).replace("9000", "1500").replace("8972", "1472").replace("8980", "1480"))
    ident = dict(name="disposable-a", mtu=mtu, relay_pid=42, worker_ipv4=path["worker_ipv4"],
                 endpoint="127.0.0.1:32100", worker="worker", instance="instance", container="c"*64,
                 candidate_sha256="a"*64)
    path.update(identity_before=dict(ident),identity_after=dict(ident))
    service = path["service_route"][0]["prefsrc"]
    gateway = path["gateway_ipv4"]
    row = dict(guest_ss=(f"0 0 [::ffff:{service}]:8080 [::ffff:{gateway}]:44112\n"
                         f"  reno wscale:7,7 mss:{mtu-52} pmtu:{mtu} advmss:{mtu-52}"),
               darwin=dict(pid=42, local_address=gateway, local_port=44112,
                           peer_address=ident["worker_ipv4"],peer_port=40112,send_mss=mtu-52))
    return dict(path=path,identity=ident,identity_after=dict(ident),before=row,after=copy.deepcopy(row),
                service_marker="disposable-a",http_status=206,content_range=f"bytes 0-{s.SIZE-1}/{s.SIZE}",
                content_length=str(s.SIZE),bytes=s.SIZE,sha256=s.BODY_HASH)


class ServiceProof(unittest.TestCase):
    def test_receives_pinned_body_and_full_effective_mss_at_both_ends(self):
        for mtu in (1500,9000):
            with self.subTest(mtu=mtu):
                result=s.validate(fixture(mtu), mtu, "a"*64)
                self.assertEqual((result["guest_send_mss"],result["host_send_mss"]), (mtu-52,)*2)
                self.assertEqual(result["receiver_bytes"], 8 << 20)
                self.assertEqual(result["bridge_observed_worker_df_requests"],3)

    def test_rejects_unbound_incomplete_or_clamped(self):
        changes = [
            (("path","identity_before","container"),"other"),(("identity_after","instance"),"other"),
            (("before","darwin","local_port"),44111),(("before","darwin","pid"),43),
            (("before","darwin","peer_address"),"127.0.0.1"),(("before","darwin","send_mss"),1448),
            (("after","darwin","peer_port"),40113),(("bytes",),s.SIZE-1),(("sha256",),"wrong"),
            (("content_length",),"5"),(("http_status",),200),(("service_marker",),"stale"),
        ]
        for keys,value in changes:
            raw=fixture(9000)
            node=raw
            for key in keys[:-1]: node=node[key]
            node[keys[-1]]=value
            with self.subTest(keys=keys), self.assertRaises(ValueError):
                s.validate(raw,9000,"a"*64)
        for old,new in [("mss:8948","mss:1448"),("pmtu:9000","pmtu:1500"),
                        (":8080",":8079"),("reno","cubic"),("44112","44111")]:
            raw=fixture(9000)
            raw["before"]["guest_ss"]=raw["before"]["guest_ss"].replace(old,new,1)
            with self.subTest(substitution=old), self.assertRaises(ValueError):
                s.validate(raw,9000,"a"*64)
        raw=fixture(9000)
        del raw["path"]["worker_to_host"]
        with self.assertRaises(ValueError): s.validate(raw,9000,"a"*64)


if __name__=="__main__":
    unittest.main()
