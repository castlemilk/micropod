//! `micropod-vmm` process exit codes. A supervisor can tell a requested
//! poweroff from a crash or a forced stop without parsing any output.
//!
//! | code | meaning |
//! |------|---------|
//! | 0 | the guest powered off in an orderly way (including after SIGTERM), or `--snapshot-and-exit` finished |
//! | 1 | VMM error: bad configuration, a startup resource (kernel, disk, socket path) unusable, or a hypervisor/vCPU failure |
//! | 2 | invalid command line |
//! | 3 | the guest crashed or reset itself: kernel panic (`panic=-1` resets), unhandled exception, CPU off |
//! | 4 | guest init or the container engine failed; the guest flushed its disk and reported the failure |
//! | 5 | `--timeout` elapsed |
//! | 6 | stopped by a host signal without an orderly guest poweroff (the guest did not stop within `--shutdown-timeout`, a second signal arrived, or the guest control channel was not up) |
//! | 7 | the `--parent-pid` supervisor exited |

pub const EXIT_POWEROFF: i32 = 0;
pub const EXIT_VMM_ERROR: i32 = 1;
pub const EXIT_USAGE: i32 = 2;
pub const EXIT_GUEST_CRASH: i32 = 3;
pub const EXIT_GUEST_FAILURE: i32 = 4;
pub const EXIT_TIMEOUT: i32 = 5;
pub const EXIT_FORCED_STOP: i32 = 6;
pub const EXIT_PARENT_EXITED: i32 = 7;

/// Console marker guest init prints (on its own line) before it stops because
/// something failed: `MICROPOD_VMM_GUEST_STATUS <kind> <detail>`.
pub const GUEST_STATUS_MARKER: &str = "MICROPOD_VMM_GUEST_STATUS ";

/// Exit code for a run that ended with `exit_reason`, given any failure the
/// guest reported before stopping.
pub fn exit_code(exit_reason: &str, guest_failure: Option<&str>) -> i32 {
    match exit_reason {
        "poweroff" | "reboot" if guest_failure.is_some() => EXIT_GUEST_FAILURE,
        "poweroff" | "snapshot_done" => EXIT_POWEROFF,
        "timeout" => EXIT_TIMEOUT,
        "signal" => EXIT_FORCED_STOP,
        "parent-exited" => EXIT_PARENT_EXITED,
        // "reboot" (PSCI SYSTEM_RESET), "cpu_off", "unhandled_ec_*", "unknown_exit"
        _ => EXIT_GUEST_CRASH,
    }
}

/// Extracts the failure text from one console line carrying the marker.
pub fn parse_guest_status(line: &[u8]) -> Option<String> {
    let line = String::from_utf8_lossy(line);
    let (_, rest) = line.split_once(GUEST_STATUS_MARKER)?;
    let rest = rest.trim();
    if rest.is_empty() {
        return None;
    }
    Some(rest.chars().take(200).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_codes_separate_clean_stops_from_failures() {
        assert_eq!(exit_code("poweroff", None), EXIT_POWEROFF);
        assert_eq!(exit_code("snapshot_done", None), EXIT_POWEROFF);
        assert_eq!(
            exit_code("poweroff", Some("engine-exited status=1")),
            EXIT_GUEST_FAILURE
        );
        assert_eq!(
            exit_code("reboot", Some("init-failed mount")),
            EXIT_GUEST_FAILURE
        );
        assert_eq!(exit_code("reboot", None), EXIT_GUEST_CRASH);
        assert_eq!(
            exit_code("unhandled_ec_0x0_esr_0x0_pc_0x0", None),
            EXIT_GUEST_CRASH
        );
        assert_eq!(exit_code("cpu_off", None), EXIT_GUEST_CRASH);
        assert_eq!(exit_code("timeout", None), EXIT_TIMEOUT);
        assert_eq!(exit_code("signal", None), EXIT_FORCED_STOP);
        assert_eq!(exit_code("parent-exited", None), EXIT_PARENT_EXITED);
    }

    #[test]
    fn guest_status_lines_are_recognised_even_after_interleaved_output() {
        assert_eq!(
            parse_guest_status(b"MICROPOD_VMM_GUEST_STATUS engine-exited status=1").as_deref(),
            Some("engine-exited status=1")
        );
        assert_eq!(
            parse_guest_status(b"[  3.1] eth0: up MICROPOD_VMM_GUEST_STATUS init-failed x\r")
                .as_deref(),
            Some("init-failed x")
        );
        assert_eq!(parse_guest_status(b"MICROPOD_VMM_GUEST_STATUS   "), None);
        assert_eq!(parse_guest_status(b"MICROPOD_VMM_INIT_READY"), None);
        let long = format!("MICROPOD_VMM_GUEST_STATUS {}", "y".repeat(500));
        assert_eq!(parse_guest_status(long.as_bytes()).unwrap().len(), 200);
    }
}
