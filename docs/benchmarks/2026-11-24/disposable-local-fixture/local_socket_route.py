"""Bind the held service flow to its actual guest return route in diagnostic mode."""
import http.client
import ipaddress
import json
import time


def require(ok, message):
    if not ok:
        raise ValueError(message)


def ipv4(value):
    require(isinstance(value, str), "expected an IPv4 address string")
    address = ipaddress.ip_address(value)
    if address.version == 6:
        address = address.ipv4_mapped
    require(address is not None and not address.is_unspecified, "expected a concrete IPv4 endpoint")
    return str(address)


def match_route(flow, routes, state):
    local, peer = ipv4(flow["local_ip"]), ipv4(flow["remote_ip"])
    require(type(flow["local_port"]) is int and flow["local_port"] == 8080
            and type(flow["remote_port"]) is int and 0 < flow["remote_port"] < 65536,
            "unexpected accepted service port or peer port")
    matches = []
    require(isinstance(routes.get("mppub0"), list), "missing mppub0 route list")
    for route in routes["mppub0"]:
        dst = route.get("Dst")
        if dst and dst["Mask"] == "/////w==" and ipv4(dst["IP"]) == peer:
            matches.append(route)
    require(len(matches) == 1, "need exactly one mppub0 /32 route for the accepted peer")
    route = matches[0]
    expected = {"Family": 2, "Scope": 253, "Table": 254, "Type": 1, "Gw": "",
                "Congctl": "reno", "RtoMin": 20, "RtoMinLock": True, "QuickACK": 0, "MTU": 0}
    require(all(type(route.get(k)) is type(v) and route[k] == v for k, v in expected.items())
            and type(route.get("LinkIndex")) is int and route["LinkIndex"] > 0,
            "service return route differs from the direct Reno policy")
    require(ipv4(route["Src"]) == local, "route source differs from the accepted local endpoint")
    interfaces = state["interfaces"]
    require("mppub0" in interfaces, "missing service mppub0 interface")
    # mppub0 is normally unnumbered. The DNAT address belongs to the pod.
    for name, interface in interfaces.items():
        if name == "lo":
            continue
        addresses = interface["addr"]
        require(isinstance(addresses, str) and addresses.startswith("[") and addresses.endswith("]"),
                "invalid service interface address list")
        if any(str(ipaddress.ip_interface(cidr).ip) == local for cidr in addresses[1:-1].split()):
            return route
    raise ValueError("accepted local address is absent from the service interfaces")


def observe(p, docker, fixture, evidence_path):
    evidence = {"type": "held service connection and guest return route",
                "socket_congestion_controller": None, "observations": []}

    def capture(stage, *args):
        row = {"stage": stage}
        evidence["observations"].append(row)
        row["stdout"] = p.command(*docker, "exec", fixture["id"], *args)
        return json.loads(row["stdout"])

    def connections(stage):
        data = capture(stage, "/mpcheck/socket-inventory")
        require(data["source"] == "proc_net_tcp" and isinstance(data["connections"], list),
                "unknown accepted socket inventory")
        return data["connections"]

    def wait_empty(stage):
        deadline = time.monotonic() + 3
        while connections(stage):
            require(time.monotonic() < deadline, f"other established service sockets remain {stage}")
            time.sleep(.2)

    def marker(conn, stage):
        conn.request("GET", "/id")
        response = conn.getresponse()
        expected = fixture["name"].encode()
        body = response.read(len(expected) + 1)
        evidence["observations"].append({"stage": stage, "status": response.status,
                                         "body": body.decode(errors="replace")})
        require(response.status == 200 and body == expected and conn.sock is not None,
                "service marker or HTTP keepalive failed")
        return conn.sock

    try:
        wait_empty("before_open")
        conn = http.client.HTTPConnection(fixture["address"], timeout=3)
        try:
            held = marker(conn, "first_marker")
            candidates = connections("first_socket")
            require(len(candidates) == 1, "need exactly one established service socket while holding the marker")
            flow = candidates[0]
            routes = capture("routes", "/mpcheck/pathproof", "routes")
            state = capture("service_addresses", "/mpcheck/check", "state")
            evidence["route"] = match_route(flow, routes, state)
            require(marker(conn, "second_marker") is held, "HTTP marker moved to a different host connection")
            require(connections("second_socket") == [flow], "accepted service connection changed while checking route")
        finally:
            conn.close()
        wait_empty("after_close")
        evidence["flow"] = flow
        evidence["passed"] = True
    except Exception as error:
        evidence.update(passed=False, error=str(error))
        raise
    finally:
        evidence_path.write_text(json.dumps(evidence, indent=2, allow_nan=False) + "\n")
