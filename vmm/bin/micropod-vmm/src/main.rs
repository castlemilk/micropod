//! micropod-vmm: Apple Silicon Rust Hypervisor.framework VMM.
//! Boots Micropod's 16 KiB ARM64 Linux kernel directly on hv_gic_create +
//! HV_IPA_GRANULE_16KB + Virtio-MMIO v2 (RNG, Blk, Balloon MADV_FREE,
//! Virtio-FS, Virtio-Vsock, and smoltcp zero-vmnet Virtio-Net port bridge).

use std::env;
use std::path::{Component, Path, PathBuf};
use vmm_core::exit::{EXIT_USAGE, EXIT_VMM_ERROR};
use vmm_core::{
    DEFAULT_SHUTDOWN_TIMEOUT_SECS, ShareSpec, TelemetryConfig, VmConfig, run_vm_with_parent,
};
use vmm_virtio::vsock::VsockExposeSpec;

const USAGE: &str = "\
Usage: micropod-vmm (--kernel <Image> | --restore-from <dir>) [--initrd <cpio>]
  [--disk <raw> [--disk-ro]] [--share tag:path[:ro]] [--workspace <dir>]
  [--vsock-expose unix_sock:guest_port] [--published-net] [--published-mtu 9000]
  [--cpus N] [--memory-mib N] [--cmdline STR] [--cmdline-append STR]
  [--snapshot-trigger <path> --snapshot-out <dir> [--snapshot-and-exit]]
  [--quiet] [--console-log <path>] [--json-summary] [--timeout S]
  [--shutdown-timeout S] [--parent-pid PID]

Exit codes:
  0  the guest powered off in an orderly way (also after SIGTERM/SIGINT)
  1  VMM error: configuration, startup resource (kernel, disk, socket path), hypervisor
  2  invalid command line
  3  the guest crashed or reset (kernel panic, unhandled exception)
  4  guest init or the container engine failed (see guest_failure in the summary)
  5  --timeout elapsed
  6  stopped by a signal without an orderly guest poweroff (--shutdown-timeout passed)
  7  the --parent-pid process exited";

/// virtio-fs tag guest init mounts at the path named by `mp.workspace[_b64]`.
const WORKSPACE_TAG: &str = "workspace";

fn usage_error(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(EXIT_USAGE);
}

/// Standard base64 with padding (guest init decodes `mp.workspace_b64` strictly).
fn base64_encode(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Validate `--workspace PATH` and return the boot argument that names it.
/// The guest mounts the share at the same absolute path, so `docker run -v
/// PATH/sub:/dst` resolves to the Mac directory; guest init accepts only a
/// canonical absolute path other than `/`, without `:`.
fn workspace_boot_arg(path: &Path) -> Result<String, String> {
    let s = path
        .to_str()
        .ok_or("--workspace path must be valid UTF-8")?;
    let canonical = path.is_absolute()
        && path
            .components()
            .all(|c| matches!(c, Component::RootDir | Component::Normal(_)))
        && !s.ends_with('/')
        && !s.contains("//");
    if !canonical || s == "/" || s.contains(['\0', ':']) {
        return Err(format!(
            "--workspace {s}: need a canonical absolute directory path other than / without ':'"
        ));
    }
    if !path.is_dir() {
        return Err(format!("--workspace {s}: not a directory"));
    }
    Ok(format!("mp.workspace_b64={}.", base64_encode(s.as_bytes())))
}

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

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
    let mut shutdown_timeout_secs = DEFAULT_SHUTDOWN_TIMEOUT_SECS;
    let mut console_log: Option<PathBuf> = None;
    let mut workspace: Option<PathBuf> = None;
    let mut cmdline_appends: Vec<String> = Vec::new();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => {
                println!("{USAGE}");
                return;
            }
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
            "--shutdown-timeout" => {
                i += 1;
                shutdown_timeout_secs = args
                    .get(i)
                    .and_then(|s| s.parse::<u64>().ok())
                    .filter(|&s| (1..=600).contains(&s))
                    .unwrap_or_else(|| {
                        usage_error("Invalid --shutdown-timeout (expected 1-600 seconds)")
                    });
            }
            "--console-log" => {
                i += 1;
                console_log = Some(
                    args.get(i)
                        .map(PathBuf::from)
                        .unwrap_or_else(|| usage_error("--console-log needs a path")),
                );
            }
            "--workspace" => {
                i += 1;
                if workspace.is_some() {
                    usage_error("--workspace may be given once");
                }
                workspace = Some(
                    args.get(i)
                        .map(PathBuf::from)
                        .unwrap_or_else(|| usage_error("--workspace needs a directory")),
                );
            }
            "--cmdline-append" => {
                i += 1;
                cmdline_appends.push(
                    args.get(i)
                        .cloned()
                        .unwrap_or_else(|| usage_error("--cmdline-append needs arguments")),
                );
            }
            other => {
                eprintln!("Unknown argument: {other}");
                std::process::exit(2);
            }
        }
        i += 1;
    }

    if let Some(path) = &workspace {
        if cmdline
            .split_whitespace()
            .chain(cmdline_appends.iter().flat_map(|a| a.split_whitespace()))
            .any(|arg| arg.trim_matches('"').starts_with("mp.workspace"))
        {
            usage_error("--workspace conflicts with an mp.workspace boot argument");
        }
        if shares.iter().any(|s| s.tag == WORKSPACE_TAG) {
            usage_error("--workspace conflicts with --share workspace:...");
        }
        let arg = workspace_boot_arg(path).unwrap_or_else(|e| usage_error(&e));
        shares.push(ShareSpec {
            tag: WORKSPACE_TAG.to_string(),
            host_path: path.clone(),
            read_only: false,
        });
        cmdline.push(' ');
        cmdline.push_str(&arg);
    }
    for extra in &cmdline_appends {
        cmdline.push(' ');
        cmdline.push_str(extra);
    }

    let kernel_path = match (kernel_path, &restore_from) {
        (Some(k), _) => k,
        (None, Some(_)) => PathBuf::new(),
        (None, None) => {
            eprintln!("{USAGE}");
            std::process::exit(EXIT_USAGE);
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
        shutdown_timeout_secs,
        console_log,
    };

    match run_vm_with_parent(cfg, expected_parent_pid) {
        Ok(rep) => {
            let code = rep.exit_code();
            if json_summary {
                println!(
                    "{{\"exit_reason\":\"{}\",\"exit_code\":{},\"guest_failure\":{},\
                     \"ipa_granule\":\"{}\",\"num_vcpus\":{},\"vcpus_started\":{},\
                     \"memory_mib\":{},\"boot_to_first_uart_ms\":{},\"boot_to_init_ms\":{},\"total_wall_ms\":{:.2},\
                     \"mmio_exits\":{},\"wfi_exits\":{},\"blk_read_ops\":{},\"blk_write_ops\":{},\
                     \"blk_read_bytes\":{},\"blk_write_bytes\":{},\"balloon_kicks\":{},\"balloon_ranges\":{},\
                     \"balloon_reclaimed_bytes\":{},\"net_tx_packets\":{},\"net_tx_bytes\":{},\
                     \"net_rx_packets\":{},\"net_rx_bytes\":{},\"published_binds\":{},\"published_conns\":{},\
                     \"published_refused\":{},\
                     \"fs_requests\":{},\"fs_bytes_read\":{},\"host_phys_footprint_mib\":{:.2},\
                     \"host_peak_footprint_mib\":{:.2}}}",
                    rep.exit_reason,
                    code,
                    rep.guest_failure
                        .as_deref()
                        .map_or("null".into(), json_string),
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
                    rep.published_refused,
                    rep.fs_requests,
                    rep.fs_bytes_read,
                    rep.host_phys_footprint_mib,
                    rep.host_peak_footprint_mib,
                );
            } else {
                eprintln!(
                    "\n[micropod-vmm] exit={} code={} guest_failure={} granule={} vcpus={}/{} wall={:.1}ms init={:?}ms \
                     blk=R:{}/W:{} fs_reqs={} balloon={:.1}MiB net_tx={}/rx={} pub_binds={} conns={} \
                     host_phys={:.1}MiB (peak {:.1}MiB)",
                    rep.exit_reason,
                    code,
                    rep.guest_failure.as_deref().unwrap_or("none"),
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
            std::process::exit(code);
        }
        Err(e) => {
            eprintln!("micropod-vmm error: {e}");
            std::process::exit(EXIT_VMM_ERROR);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_the_guest_decoder_alphabet_and_padding() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        // Same vector as guest-init's TestParseWorkspace.
        assert_eq!(
            base64_encode("/private/tmp/build \"two words\" µ".as_bytes()),
            "L3ByaXZhdGUvdG1wL2J1aWxkICJ0d28gd29yZHMiIMK1"
        );
    }

    #[test]
    fn workspace_paths_must_be_canonical_existing_directories() {
        let dir = std::env::temp_dir();
        let dir = dir.to_str().unwrap().trim_end_matches('/').to_string();
        let arg = workspace_boot_arg(Path::new(&dir)).unwrap();
        assert_eq!(
            arg,
            format!("mp.workspace_b64={}.", base64_encode(dir.as_bytes()))
        );
        for bad in [
            "relative/dir",
            "/",
            "/tmp/../etc",
            "/tmp/./x",
            "/tmp//x",
            "/tmp/",
            "/tmp/a:b",
            "/definitely/not/a/dir/here",
        ] {
            assert!(workspace_boot_arg(Path::new(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn json_strings_are_escaped() {
        assert_eq!(json_string("a\"b\\c\nd"), "\"a\\\"b\\\\c\\u000ad\"");
    }
}
