"""Read the Mac TCP and AC power settings named in the performance study."""
import ctypes
import errno
import json
import platform
import subprocess
import sys
from datetime import datetime, timezone


KEYS = (
    "kern.ipc.maxsockbuf", "net.inet.tcp.autorcvbufmax", "net.inet.tcp.autosndbufmax",
    "net.inet.tcp.sendspace", "net.inet.tcp.recvspace", "net.inet.tcp.delayed_ack",
    "net.inet.tcp.rfc1323", "net.inet.tcp.slowstart_flightsize", "net.inet.tcp.msl",
    "net.inet.ip.portrange.first", "net.inet.ip.portrange.last", "kern.ipc.somaxconn",
    "kern.maxfiles", "kern.maxfilesperproc", "kern.serverperfmode",
)


def read_controls():
    api = ctypes.CDLL(None, use_errno=True).sysctlbyname
    api.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    values = {}
    for name in KEYS:
        buf = ctypes.create_string_buffer(8)
        size = ctypes.c_size_t(len(buf))
        if api(name.encode(), buf, ctypes.byref(size), None, 0) != 0:
            values[name] = {"errno": errno.errorcode.get(ctypes.get_errno(), str(ctypes.get_errno()))}
        elif size.value in (1, 2, 4, 8):
            values[name] = {"value": int.from_bytes(buf.raw[:size.value], sys.byteorder)}
        else:
            raise ValueError(f"unexpected size for integer sysctl {name}")
    commands = {}
    for view in ("cap", "custom", "ps"):
        run = subprocess.run(["/usr/bin/pmset", "-g", view], capture_output=True, text=True, check=True)
        # The first line of ps identifies the active power source.
        commands[view] = run.stdout.splitlines()[:1] if view == "ps" else run.stdout.splitlines()
    return {"observed_at": datetime.now(timezone.utc).isoformat(), "host_macos": platform.mac_ver()[0],
            "scope": "read-only local host settings; no socket, workload or power-mode changes",
            "sysctls": values, "pmset": commands}


if __name__ == "__main__":
    print(json.dumps(read_controls(), indent=2))
