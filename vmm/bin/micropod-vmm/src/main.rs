//! micropod-vmm: Apple Silicon Rust Hypervisor.framework VMM.
//! Boots Micropod's 16 KiB ARM64 Linux kernel directly on hv_gic_create +
//! HV_IPA_GRANULE_16KB + Virtio-MMIO v2 (RNG, Blk, Balloon MADV_FREE,
//! Virtio-FS, Virtio-Vsock, and smoltcp zero-vmnet Virtio-Net port bridge).

use std::env;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use vmm_core::exit::{EXIT_USAGE, EXIT_VMM_ERROR};
use vmm_core::{
    DEFAULT_SHUTDOWN_TIMEOUT_SECS, DiskFlush, ShareSpec, TelemetryConfig, VmConfig,
    run_vm_with_parent,
};
use vmm_virtio::vsock::VsockExposeSpec;

const USAGE: &str = "\
Usage: micropod-vmm (--kernel <Image> | --restore-from <dir>) [--initrd <cpio>]
  [--disk <raw> [--disk-ro]] [--cache-disk <raw>] [--disk-flush barrier|full|fsync]
  [--disk-flush-os barrier|full|fsync]
  [--share tag:path[:ro]] [--workspace <dir>]
  [--vsock-expose unix_sock:guest_port] [--published-net] [--published-mtu 9000]
  [--allow-host-port PORT]
  [--cpus N] [--memory-mib N] [--cmdline STR] [--cmdline-append STR]
  [--snapshot-trigger <path> --snapshot-out <dir> [--snapshot-and-exit]]
  [--quiet] [--console-log <path>] [--json-summary] [--timeout S]
  [--shutdown-timeout S] [--parent-pid PID]

--disk-flush is the host sync both disks run when the guest flushes (its ext4
journal commits): barrier (default) F_BARRIERFSYNC, writes persist in order
across a host crash or power loss; full F_FULLFSYNC, ordered and durable at
each flush; fsync fsync(2), safe only against the VMM itself crashing. A
filesystem without the fcntl falls back to full, then fsync.
--disk-flush-os sets it for the OS disk (--disk) alone; the cache disk keeps
--disk-flush. With fsync there, a host power loss or kernel panic can leave
the OS disk's journal holding commits whose blocks never reached the drive.

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

/// The value after `flag` (at `args[i]`), or exit 2 when it is missing.
fn flag_value<'a>(args: &'a [String], i: usize, flag: &str) -> &'a str {
    args.get(i)
        .map(String::as_str)
        .unwrap_or_else(|| usage_error(&format!("{flag} needs a value")))
}

/// The value after `flag` parsed as `T`, or exit 2.
fn parse_flag<T: FromStr>(args: &[String], i: usize, flag: &str) -> T {
    let value = flag_value(args, i, flag);
    value
        .parse()
        .unwrap_or_else(|_| usage_error(&format!("invalid {flag} value {value:?}")))
}

/// Guest directories a workspace may neither cover nor sit inside: the
/// guest's system directories and the mounts its init and engine depend on.
/// Guest init (`workspace.go`) refuses the same paths.
const GUEST_RESERVED_TREES: &[&str] = &[
    "/bin",
    "/dev",
    "/etc",
    "/lib",
    "/opt/micropod-oci",
    "/proc",
    "/root",
    "/run",
    "/sbin",
    "/sys",
    "/usr",
    "/var/lib",
];

/// Guest mounts a workspace may sit inside but not cover (the guest's /tmp).
const GUEST_RESERVED_MOUNTS: &[&str] = &["/tmp"];

/// The guest directory `workspace` (a canonical absolute path) would hide.
fn guest_reserved_overlap(workspace: &str) -> Option<&'static str> {
    let within = |path: &str, dir: &str| {
        path == dir || (path.starts_with(dir) && path.as_bytes().get(dir.len()) == Some(&b'/'))
    };
    GUEST_RESERVED_TREES
        .iter()
        .chain(GUEST_RESERVED_MOUNTS)
        .find(|r| within(r, workspace))
        .or_else(|| GUEST_RESERVED_TREES.iter().find(|r| within(workspace, r)))
        .copied()
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
    // Lexical, as guest init checks it (`path.Clean(p) == p`): Path::components
    // would silently drop the `.` in `/a/./b` or `/a/b/.`.
    let canonical = s.len() > 1
        && s.starts_with('/')
        && s[1..]
            .split('/')
            .all(|c| !c.is_empty() && c != "." && c != "..");
    if !canonical || s.contains(['\0', ':']) {
        return Err(format!(
            "--workspace {s}: need a canonical absolute directory path other than / without ':'"
        ));
    }
    if let Some(reserved) = guest_reserved_overlap(s) {
        return Err(format!(
            "--workspace {s}: overlaps the guest's {reserved}; share a directory outside it"
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
        usage_error(&format!(
            "Invalid --share spec (want tag:host_path[:ro]): {spec}"
        ));
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
        usage_error(&format!(
            "Invalid --vsock-expose spec (want host_unix_path:guest_port): {spec}"
        ));
    };
    let guest_port: u32 = port_s.parse().unwrap_or_else(|_| {
        usage_error(&format!(
            "Invalid --vsock-expose guest port {port_s:?} in {spec}"
        ))
    });
    VsockExposeSpec {
        host_unix_path: PathBuf::from(path),
        guest_port,
    }
}

fn main() {
    // Before any share sizes its handle budget from it.
    let _ = vmm_core::raise_open_file_limit();
    let args: Vec<String> = env::args().skip(1).collect();
    let mut kernel_path: Option<PathBuf> = None;
    let mut initrd_path: Option<PathBuf> = None;
    let mut disk_path: Option<PathBuf> = None;
    let mut disk_read_only = false;
    let mut cache_disk_path: Option<PathBuf> = None;
    let mut disk_flush = DiskFlush::default();
    let mut os_disk_flush: Option<DiskFlush> = None;
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
    let mut allow_host_ports: Vec<u16> = Vec::new();
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
                kernel_path = Some(PathBuf::from(flag_value(&args, i, "--kernel")));
            }
            "--initrd" => {
                i += 1;
                initrd_path = Some(PathBuf::from(flag_value(&args, i, "--initrd")));
            }
            "--disk" => {
                i += 1;
                disk_path = Some(PathBuf::from(flag_value(&args, i, "--disk")));
            }
            "--disk-ro" => disk_read_only = true,
            "--cache-disk" => {
                i += 1;
                cache_disk_path = Some(PathBuf::from(flag_value(&args, i, "--cache-disk")));
            }
            "--disk-flush" => {
                i += 1;
                disk_flush = flag_value(&args, i, "--disk-flush")
                    .parse()
                    .unwrap_or_else(|e: String| usage_error(&format!("--disk-flush: {e}")));
            }
            "--disk-flush-os" => {
                i += 1;
                os_disk_flush = Some(
                    flag_value(&args, i, "--disk-flush-os")
                        .parse()
                        .unwrap_or_else(|e: String| usage_error(&format!("--disk-flush-os: {e}"))),
                );
            }
            "--cpus" => {
                i += 1;
                num_vcpus = parse_flag(&args, i, "--cpus");
            }
            "--memory-mib" => {
                i += 1;
                memory_mib = parse_flag(&args, i, "--memory-mib");
            }
            "--cmdline" => {
                i += 1;
                cmdline = flag_value(&args, i, "--cmdline").to_string();
            }
            "--share" => {
                i += 1;
                shares.push(parse_share(flag_value(&args, i, "--share")));
            }
            "--vsock" => enable_vsock = true,
            "--vsock-expose" => {
                i += 1;
                enable_vsock = true;
                vsock_exposes.push(parse_vsock_expose(flag_value(&args, i, "--vsock-expose")));
            }
            "--published-net" => enable_published_net = true,
            "--published-mtu" => {
                i += 1;
                published_mtu = parse_flag(&args, i, "--published-mtu");
            }
            "--allow-host-port" => {
                i += 1;
                let port: u16 = parse_flag(&args, i, "--allow-host-port");
                if port == 0 {
                    usage_error("Invalid --allow-host-port (expected 1-65535)");
                }
                if !allow_host_ports.contains(&port) {
                    allow_host_ports.push(port);
                }
            }
            "--no-balloon" => enable_balloon = false,
            "--no-net" => enable_net = false,
            "--quiet" => echo_console = false,
            "--json-summary" => json_summary = true,
            "--timeout" => {
                i += 1;
                timeout_secs = parse_flag(&args, i, "--timeout");
            }
            "--parent-pid" => {
                i += 1;
                let Some(pid) = args
                    .get(i)
                    .and_then(|s| s.parse::<i32>().ok())
                    .filter(|&pid| pid > 1)
                else {
                    usage_error("Invalid --parent-pid (expected a PID greater than 1)");
                };
                expected_parent_pid = Some(pid);
            }
            "--snapshot-trigger" => {
                i += 1;
                snapshot_trigger = Some(PathBuf::from(flag_value(&args, i, "--snapshot-trigger")));
            }
            "--snapshot-out" => {
                i += 1;
                snapshot_out = Some(PathBuf::from(flag_value(&args, i, "--snapshot-out")));
            }
            "--snapshot-and-exit" => snapshot_and_exit = true,
            "--restore-from" => {
                i += 1;
                restore_from = Some(PathBuf::from(flag_value(&args, i, "--restore-from")));
            }
            "--telemetry-socket" => {
                i += 1;
                telemetry.socket_path =
                    Some(PathBuf::from(flag_value(&args, i, "--telemetry-socket")));
            }
            "--prometheus-listen" => {
                i += 1;
                telemetry.prometheus_listen =
                    Some(flag_value(&args, i, "--prometheus-listen").to_string());
            }
            "--otlp-endpoint" => {
                i += 1;
                telemetry.otlp_endpoint = Some(flag_value(&args, i, "--otlp-endpoint").to_string());
            }
            "--otlp-interval-secs" => {
                i += 1;
                telemetry.otlp_interval_secs = parse_flag(&args, i, "--otlp-interval-secs");
            }
            "--service-name" => {
                i += 1;
                telemetry.service_name = flag_value(&args, i, "--service-name").to_string();
            }
            "--worker-id" => {
                i += 1;
                telemetry.worker_id = Some(flag_value(&args, i, "--worker-id").to_string());
            }
            "--trace" => {
                telemetry.tracing_enabled = true;
            }
            "--otlp-traces-endpoint" => {
                i += 1;
                telemetry.traces_endpoint =
                    Some(flag_value(&args, i, "--otlp-traces-endpoint").to_string());
            }
            "--trace-slow-ms" => {
                i += 1;
                telemetry.slow_op_threshold_ms = parse_flag(&args, i, "--trace-slow-ms");
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
            other => usage_error(&format!("Unknown argument: {other}")),
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
        cache_disk_path,
        disk_flush,
        os_disk_flush,
        num_vcpus,
        memory_mib,
        cmdline,
        enable_balloon,
        enable_net,
        enable_published_net,
        published_mtu,
        allow_host_ports,
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
                     \"fs_requests\":{},\"fs_bytes_read\":{},\"fs_nodes_peak\":{},\
                     \"workspace_kicks\":{},\"workspace_used_batches\":{},\"workspace_irq_requests\":{},\
                     \"host_phys_footprint_mib\":{:.2},\
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
                    rep.fs_nodes_peak,
                    rep.workspace_kicks,
                    rep.workspace_used_batches,
                    rep.workspace_irq_requests,
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
        // `dir` exists, so only the spelling can make these fail.
        for bad in [
            "relative/dir".to_string(),
            "/".to_string(),
            "".to_string(),
            "/tmp/../etc".to_string(),
            "/tmp/./x".to_string(),
            "/tmp//x".to_string(),
            "/tmp/".to_string(),
            "/tmp/a:b".to_string(),
            "/definitely/not/a/dir/here".to_string(),
            format!("{dir}/."),
            format!("{dir}/./"),
            format!("{dir}/.."),
            dir.replacen('/', "/./", 2),
            dir.replacen('/', "//", 1),
        ] {
            assert!(workspace_boot_arg(Path::new(&bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn workspaces_may_not_hide_guest_system_directories() {
        for bad in [
            "/opt",
            "/opt/micropod-oci",
            "/opt/micropod-oci/runner",
            "/var",
            "/var/lib",
            "/var/lib/micropod",
            "/var/lib/docker/volumes",
            "/tmp",
            "/usr",
            "/usr/local",
            "/etc",
            "/proc/1",
            "/run",
            "/root/src",
            "/bin",
            "/lib",
        ] {
            assert!(guest_reserved_overlap(bad).is_some(), "{bad}");
        }
        for good in [
            "/Users/me",
            "/Users/me/projects",
            "/tmp/build",
            "/private/tmp",
            "/private/var/folders/x",
            "/var/folders/x",
            "/Volumes/External/src",
            "/opt/homebrew/src",
            "/library",
            "/libraries",
            "/usrdata",
            "/home/me",
        ] {
            assert_eq!(guest_reserved_overlap(good), None, "{good}");
        }
    }

    #[test]
    fn json_strings_are_escaped() {
        assert_eq!(json_string("a\"b\\c\nd"), "\"a\\\"b\\\\c\\u000ad\"");
    }
}
