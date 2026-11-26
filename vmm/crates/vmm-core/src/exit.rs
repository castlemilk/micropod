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
//! | 7 | the `--parent-pid` supervisor exited; the guest was still asked to power off and given `--shutdown-timeout` (`exit_reason` says how it stopped) |

use std::time::Duration;

pub const EXIT_POWEROFF: i32 = 0;
pub const EXIT_VMM_ERROR: i32 = 1;
pub const EXIT_USAGE: i32 = 2;
pub const EXIT_GUEST_CRASH: i32 = 3;
pub const EXIT_GUEST_FAILURE: i32 = 4;
pub const EXIT_TIMEOUT: i32 = 5;
pub const EXIT_FORCED_STOP: i32 = 6;
pub const EXIT_PARENT_EXITED: i32 = 7;

/// Console marker guest init prints at the start of a line right before it
/// resets because something failed: `MICROPOD_VMM_GUEST_STATUS <kind> <detail>`.
pub const GUEST_STATUS_MARKER: &str = "MICROPOD_VMM_GUEST_STATUS ";

/// How long after printing the marker guest init may take to reset: its whole
/// shutdown budget (at most the host's `--shutdown-timeout`, or its own default
/// before the host announced one) plus a margin. A marker older than this did
/// not announce the stop that followed.
pub fn guest_status_window(shutdown_timeout: Duration) -> Duration {
    shutdown_timeout.max(Duration::from_secs(10)) + Duration::from_secs(5)
}

/// Exit code for a run that ended with `exit_reason`, given the failure the
/// guest announced for that stop. Guest init always ends a failure with a
/// reset (PSCI SYSTEM_RESET), so a marker never turns a poweroff into one.
pub fn exit_code(exit_reason: &str, guest_failure: Option<&str>) -> i32 {
    match exit_reason {
        "reboot" if guest_failure.is_some() => EXIT_GUEST_FAILURE,
        "poweroff" | "snapshot_done" => EXIT_POWEROFF,
        "timeout" => EXIT_TIMEOUT,
        "signal" => EXIT_FORCED_STOP,
        "parent-exited" => EXIT_PARENT_EXITED,
        // "reboot" (PSCI SYSTEM_RESET), "cpu_off", "unhandled_ec_*", "unknown_exit"
        _ => EXIT_GUEST_CRASH,
    }
}

/// Extracts the failure text from one console line that starts with the marker
/// (after the `\r` a tty adds). Output that merely contains it, such as a
/// daemon echoing user input or a `/dev/kmsg` line with its timestamp, is not
/// guest init's report.
pub fn parse_guest_status(line: &[u8]) -> Option<String> {
    let line = String::from_utf8_lossy(line);
    let rest = line
        .trim_start_matches('\r')
        .strip_prefix(GUEST_STATUS_MARKER)?;
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
        // An orderly poweroff is clean whatever the console said before it.
        assert_eq!(
            exit_code("poweroff", Some("engine-exited status=1")),
            EXIT_POWEROFF
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
    fn guest_status_lines_must_start_with_the_marker() {
        assert_eq!(
            parse_guest_status(b"MICROPOD_VMM_GUEST_STATUS engine-exited status=1").as_deref(),
            Some("engine-exited status=1")
        );
        assert_eq!(
            parse_guest_status(b"\rMICROPOD_VMM_GUEST_STATUS init-failed x\r").as_deref(),
            Some("init-failed x")
        );
        for spoof in [
            &b"[  3.1] eth0: up MICROPOD_VMM_GUEST_STATUS init-failed x\r"[..],
            b"Kernel command line: mp.x=MICROPOD_VMM_GUEST_STATUS engine-exited",
            b"[ 12.000000] app: MICROPOD_VMM_GUEST_STATUS engine-exited status=1",
            b" MICROPOD_VMM_GUEST_STATUS engine-exited status=1",
        ] {
            assert_eq!(parse_guest_status(spoof), None);
        }
        assert_eq!(parse_guest_status(b"MICROPOD_VMM_GUEST_STATUS   "), None);
        assert_eq!(parse_guest_status(b"MICROPOD_VMM_INIT_READY"), None);
        let long = format!("MICROPOD_VMM_GUEST_STATUS {}", "y".repeat(500));
        assert_eq!(parse_guest_status(long.as_bytes()).unwrap().len(), 200);
    }

    #[test]
    fn guest_status_window_covers_the_guest_budget() {
        assert_eq!(
            guest_status_window(Duration::from_secs(1)),
            Duration::from_secs(15)
        );
        assert_eq!(
            guest_status_window(Duration::from_secs(600)),
            Duration::from_secs(605)
        );
    }
}
