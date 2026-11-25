//! micropod-vmm: Apple Silicon Rust Hypervisor.framework VMM.
//! Boots Micropod's 16 KiB ARM64 Linux kernel directly on hv_gic_create +
//! HV_IPA_GRANULE_16KB + Virtio-MMIO v2 (RNG, Blk, Balloon MADV_FREE,
//! Virtio-FS, Virtio-Vsock, and smoltcp zero-vmnet Virtio-Net port bridge).

use std::env;
use std::path::PathBuf;
use vmm_core::{ShareSpec, TelemetryConfig, VmConfig, run_vm_with_parent};
use vmm_virtio::vsock::VsockExposeSpec;

fn parse_share(spec: &str) -> ShareSpec {
    // Format: tag:host_path[:ro]
    let parts: Vec<&str> = spec.split(':').collect();
    if parts.len() < 2 {
        eprintln!("Invalid --share spec (want tag:host_path[:ro]): {spec}");
        std::process::exit(2);
    }
    let read_only = parts.len() >= 3 && parts[2] == "ro";
    ShareSpec {
        tag: parts[0].to_string(),
        host_path: PathBuf::from(parts[1]),
        read_only,
    }
}

fn parse_vsock_expose(spec: &str) -> VsockExposeSpec {
    // Format: host_unix_path:guest_port
    let Some((path, port_s)) = spec.rsplit_once(':') else {
        eprintln!("Invalid --vsock-expose spec (want host_unix_path:guest_port): {spec}");
        std::process::exit(2);
    };
    let guest_port: u32 = port_s.parse().expect("invalid guest vsock port");
    VsockExposeSpec {
        host_unix_path: PathBuf::from(path),
        guest_port,
    }
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let mut kernel_path: Option<PathBuf> = None;
    let mut initrd_path: Option<PathBuf> = None;
    let mut disk_path: Option<PathBuf> = None;
    let mut disk_read_only = false;
    let mut num_vcpus: u32 = 4;
    let mut memory_mib: usize = 512;
    let mut cmdline = String::from(
        "earlycon=pl011,mmio32,0x09000000 console=ttyAMA0 rcupdate.rcu_expedited=1 \
         cgroup.memory=nokmem,nosocket slab_min_order=2 swiotlb=noforce \
         workqueue.power_efficient=1 panic=-1",
    );
    let mut enable_balloon = true;
    let mut enable_net = true;
    let mut enable_published_net = false;
    let mut published_mtu: u16 = 9000;
    let mut enable_vsock = false;
    let mut vsock_exposes = Vec::new();
    let mut shares = Vec::new();
    let mut echo_console = true;
    let mut json_summary = false;
    let mut timeout_secs: u64 = 0;
    let mut expected_parent_pid: Option<i32> = None;
    let mut snapshot_trigger: Option<PathBuf> = None;
    let mut snapshot_out: Option<PathBuf> = None;
    let mut snapshot_and_exit = false;
    let mut restore_from: Option<PathBuf> = None;
    let mut telemetry = TelemetryConfig::default();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--kernel" => {
                i += 1;
                kernel_path = args.get(i).map(PathBuf::from);
            }
            "--initrd" => {
                i += 1;
                initrd_path = args.get(i).map(PathBuf::from);
            }
            "--disk" => {
                i += 1;
                disk_path = args.get(i).map(PathBuf::from);
            }
            "--disk-ro" => disk_read_only = true,
            "--cpus" => {
                i += 1;
                num_vcpus = args[i].parse().expect("invalid --cpus");
            }
            "--memory-mib" => {
                i += 1;
                memory_mib = args[i].parse().expect("invalid --memory-mib");
            }
            "--cmdline" => {
                i += 1;
                cmdline = args[i].clone();
            }
            "--share" => {
                i += 1;
                shares.push(parse_share(&args[i]));
            }
            "--vsock" => enable_vsock = true,
            "--vsock-expose" => {
                i += 1;
                enable_vsock = true;
                vsock_exposes.push(parse_vsock_expose(&args[i]));
            }
            "--published-net" => enable_published_net = true,
            "--published-mtu" => {
                i += 1;
                published_mtu = args[i].parse().expect("invalid --published-mtu");
            }
            "--no-balloon" => enable_balloon = false,
            "--no-net" => enable_net = false,
            "--quiet" => echo_console = false,
            "--json-summary" => json_summary = true,
            "--timeout" => {
                i += 1;
                timeout_secs = args[i].parse().expect("invalid --timeout");
            }
            "--parent-pid" => {
                i += 1;
                let Some(pid) = args
                    .get(i)
                    .and_then(|s| s.parse::<i32>().ok())
                    .filter(|&pid| pid > 1)
                else {
                    eprintln!("Invalid --parent-pid (expected a PID greater than 1)");
                    std::process::exit(2);
                };
                expected_parent_pid = Some(pid);
            }
            "--snapshot-trigger" => {
                i += 1;
                snapshot_trigger = args.get(i).map(PathBuf::from);
            }
            "--snapshot-out" => {
                i += 1;
                snapshot_out = args.get(i).map(PathBuf::from);
            }
            "--snapshot-and-exit" => snapshot_and_exit = true,
            "--restore-from" => {
                i += 1;
                restore_from = args.get(i).map(PathBuf::from);
            }
            "--telemetry-socket" => {
                i += 1;
                telemetry.socket_path = args.get(i).map(PathBuf::from);
            }
            "--prometheus-listen" => {
                i += 1;
                telemetry.prometheus_listen = args.get(i).cloned();
            }
            "--otlp-endpoint" => {
                i += 1;
                telemetry.otlp_endpoint = args.get(i).cloned();
            }
            "--otlp-interval-secs" => {
                i += 1;
                telemetry.otlp_interval_secs =
                    args[i].parse().expect("invalid --otlp-interval-secs");
            }
            "--service-name" => {
                i += 1;
                telemetry.service_name = args[i].clone();
            }
            "--worker-id" => {
                i += 1;
                telemetry.worker_id = args.get(i).cloned();
            }
            "--trace" => {
                telemetry.tracing_enabled = true;
            }
            "--otlp-traces-endpoint" => {
                i += 1;
                telemetry.traces_endpoint = args.get(i).cloned();
            }
            "--trace-slow-ms" => {
                i += 1;
                telemetry.slow_op_threshold_ms = args[i].parse().expect("invalid --trace-slow-ms");
            }
            other => {
                eprintln!("Unknown argument: {other}");
                std::process::exit(2);
            }
        }
        i += 1;
    }

    let kernel_path = match (kernel_path, &restore_from) {
        (Some(k), _) => k,
        (None, Some(_)) => PathBuf::new(),
        (None, None) => {
            eprintln!(
                "Usage: micropod-vmm (--kernel <Image> | --restore-from <dir>) [--initrd <cpio>] \
                 [--disk <raw>] [--share tag:path[:ro]] [--vsock-expose unix_sock:guest_port] \
                 [--published-net] [--published-mtu 9000] [--cpus N] [--memory-mib N] [--cmdline STR] \
                 [--snapshot-trigger <path> --snapshot-out <dir> [--snapshot-and-exit]] \
                 [--quiet] [--json-summary] [--timeout S] [--parent-pid PID]"
            );
            std::process::exit(2);
        }
    };

    let cfg = VmConfig {
        kernel_path,
        initrd_path,
        disk_path,
        disk_read_only,
        num_vcpus,
        memory_mib,
        cmdline,
        enable_balloon,
        enable_net,
        enable_published_net,
        published_mtu,
        enable_vsock,
        vsock_exposes,
        shares,
        echo_console,
        timeout_secs,
        snapshot_trigger,
        snapshot_out,
        snapshot_and_exit,
        restore_from,
        telemetry,
    };

    match run_vm_with_parent(cfg, expected_parent_pid) {
        Ok(rep) => {
            if json_summary {
                println!(
                    "{{\"exit_reason\":\"{}\",\"ipa_granule\":\"{}\",\"num_vcpus\":{},\"vcpus_started\":{},\
                     \"memory_mib\":{},\"boot_to_first_uart_ms\":{},\"boot_to_init_ms\":{},\"total_wall_ms\":{:.2},\
                     \"mmio_exits\":{},\"wfi_exits\":{},\"blk_read_ops\":{},\"blk_write_ops\":{},\
                     \"blk_read_bytes\":{},\"blk_write_bytes\":{},\"balloon_kicks\":{},\"balloon_ranges\":{},\
                     \"balloon_reclaimed_bytes\":{},\"net_tx_packets\":{},\"net_tx_bytes\":{},\
                     \"net_rx_packets\":{},\"net_rx_bytes\":{},\"published_binds\":{},\"published_conns\":{},\
                     \"fs_requests\":{},\"fs_bytes_read\":{},\"host_phys_footprint_mib\":{:.2},\
                     \"host_peak_footprint_mib\":{:.2}}}",
                    rep.exit_reason,
                    rep.ipa_granule,
                    rep.num_vcpus,
                    rep.vcpus_started,
                    rep.memory_mib,
                    rep.boot_to_first_uart_ms
                        .map_or("null".into(), |v| format!("{v:.2}")),
                    rep.boot_to_init_ms
                        .map_or("null".into(), |v| format!("{v:.2}")),
                    rep.total_wall_ms,
                    rep.mmio_exits,
                    rep.wfi_exits,
                    rep.blk_read_ops,
                    rep.blk_write_ops,
                    rep.blk_read_bytes,
                    rep.blk_write_bytes,
                    rep.balloon_kicks,
                    rep.balloon_ranges,
                    rep.balloon_reclaimed_bytes,
                    rep.net_tx_packets,
                    rep.net_tx_bytes,
                    rep.net_rx_packets,
                    rep.net_rx_bytes,
                    rep.published_binds,
                    rep.published_conns,
                    rep.fs_requests,
                    rep.fs_bytes_read,
                    rep.host_phys_footprint_mib,
                    rep.host_peak_footprint_mib,
                );
            } else {
                eprintln!(
                    "\n[micropod-vmm] exit={} granule={} vcpus={}/{} wall={:.1}ms init={:?}ms \
                     blk=R:{}/W:{} fs_reqs={} balloon={:.1}MiB net_tx={}/rx={} pub_binds={} conns={} \
                     host_phys={:.1}MiB (peak {:.1}MiB)",
                    rep.exit_reason,
                    rep.ipa_granule,
                    rep.vcpus_started,
                    rep.num_vcpus,
                    rep.total_wall_ms,
                    rep.boot_to_init_ms,
                    rep.blk_read_ops,
                    rep.blk_write_ops,
                    rep.fs_requests,
                    rep.balloon_reclaimed_bytes as f64 / (1024.0 * 1024.0),
                    rep.net_tx_packets,
                    rep.net_rx_packets,
                    rep.published_binds,
                    rep.published_conns,
                    rep.host_phys_footprint_mib,
                    rep.host_peak_footprint_mib,
                );
            }
        }
        Err(e) => {
            eprintln!("micropod-vmm error: {e}");
            std::process::exit(1);
        }
    }
}
