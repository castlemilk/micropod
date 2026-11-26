"""Type-check optional performance APIs against the selected macOS SDK without starting a VM."""
import json
import platform
import subprocess


# Each row names the declaring framework, the symbol expected in diagnostics,
# and a small compile-only use. No snippet is linked or executed.
PROBES = [
    ("vmnet/vmnet.h", "vmnet_network_configuration_set_mtu", "(void)&vmnet_network_configuration_set_mtu"),
    ("vmnet/vmnet.h", "vmnet_network_configuration_add_port_forwarding_rule",
     "vmnet_network_configuration_add_port_forwarding_rule((vmnet_network_configuration_ref)p, 6, 2, 80, 8080, p)"),
    ("vmnet/vmnet.h", "vmnet_interface_remove_ip_port_forwarding_rule", "(void)&vmnet_interface_remove_ip_port_forwarding_rule"),
    ("Virtualization/Virtualization.h", "VZFileHandleNetworkDeviceAttachment",
     "((VZFileHandleNetworkDeviceAttachment *)p).maximumTransmissionUnit = 9000"),
    ("Virtualization/Virtualization.h", "VZLinuxRosettaDirectoryShare", "(void)VZLinuxRosettaDirectoryShare.availability"),
    ("Virtualization/Virtualization.h", "VZNVMExpressControllerDeviceConfiguration", "(void)[VZNVMExpressControllerDeviceConfiguration class]"),
    ("Virtualization/Virtualization.h", "VZVirtioTraditionalMemoryBalloonDevice",
     "(void)((VZVirtioTraditionalMemoryBalloonDevice *)p).targetVirtualMachineMemorySize"),
    ("Virtualization/Virtualization.h", "customVirtioDevices", "(void)((VZVirtualMachineConfiguration *)p).customVirtioDevices"),
    ("Virtualization/Virtualization.h", "VZGuestMemoryMapping", "(void)[VZGuestMemoryMapping class]"),
    ("Hypervisor/Hypervisor.h", "hv_vcpu_run", "(void)&hv_vcpu_run"),
    ("Hypervisor/Hypervisor.h", "hv_gic_create", "(void)&hv_gic_create"),
]


def inspect():
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    version = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
    compiler = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    command = [compiler, "-isysroot", sdk, "-target", f"arm64-apple-macos{version}",
               "-fsyntax-only", "-x", "objective-c", "-fblocks", "-Werror", "-"]
    results = []
    for header, symbol, expression in PROBES:
        sample = f"#import <{header}>\nvoid probe(void *p) {{ {expression}; }}\n"
        run = subprocess.run(command, input=sample, capture_output=True, text=True)
        errors = [s.split("error: ", 1)[1] for s in run.stderr.splitlines() if "error: " in s]
        if run.returncode and (not errors or not all(symbol in message for message in errors)):
            raise RuntimeError(f"unrelated SDK or compiler error for {symbol}: {run.stderr}")
        results.append({"symbol": symbol, "header": header, "type_checked": run.returncode == 0, "errors": errors})
    if not any(row["type_checked"] for row in results):
        raise RuntimeError("all controls failed to type-check")
    return {"scope": "compile only, without creating a network, device or VM",
            "host_macos": platform.mac_ver()[0], "sdk": version, "compiler": subprocess.check_output(
                [compiler, "--version"], text=True).splitlines()[0], "results": results}


if __name__ == "__main__":
    print(json.dumps(inspect(), indent=2))
