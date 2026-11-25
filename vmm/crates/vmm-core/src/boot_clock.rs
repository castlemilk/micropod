use std::time::{SystemTime, UNIX_EPOCH};

const ARG: &str = "mp.boot_realtime_ns";
const MIN_UNIX_SECS: u64 = 1_577_836_800; // 2020-01-01 UTC, after unset/epoch clocks

pub(super) fn cmdline(args: &str, now: SystemTime) -> Result<String, String> {
    for arg in args.split_whitespace() {
        let key = arg.split_once('=').map_or(arg, |(key, _)| key);
        if key.trim_matches('"') == ARG {
            return Err(format!("kernel argument {ARG} is reserved by micropod-vmm"));
        }
    }

    let elapsed = now
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "host clock precedes the Unix epoch")?;
    let unix_ns = i64::try_from(elapsed.as_nanos()).map_err(|_| "host clock is out of range")?;
    if elapsed.as_secs() < MIN_UNIX_SECS {
        return Err("host clock is unset or earlier than 2020-01-01 UTC".into());
    }

    // Keep the host-generated field ahead of any user arguments the kernel truncates.
    let full = format!("{ARG}={unix_ns} {args}");
    // arm64 COMMAND_LINE_SIZE: the kernel silently drops the tail beyond it,
    // which would lose boot arguments such as the workspace path.
    if full.len() >= MAX_CMDLINE {
        return Err(format!(
            "kernel command line is {} bytes; Linux arm64 accepts at most {}",
            full.len(),
            MAX_CMDLINE - 1
        ));
    }
    Ok(full)
}

const MAX_CMDLINE: usize = 2048;

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn clock_prefix_preserves_caller_boot_arguments() {
        let args = r#"console=ttyAMA0  mp.workspace="/Users/me/test dir" panic=-1"#;
        let now = UNIX_EPOCH + Duration::new(1_770_000_000, 123_456_789);
        assert_eq!(
            cmdline(args, now).unwrap(),
            format!("{ARG}=1770000000123456789 {args}")
        );
        for field in [ARG.to_string(), format!("{ARG}=0"), format!("\"{ARG}=0\"")] {
            assert!(cmdline(&format!("{args} {field}"), now).is_err());
        }
        let long = "x".repeat(MAX_CMDLINE);
        assert!(cmdline(&long, now).unwrap_err().contains("at most 2047"));
    }

    #[test]
    fn invalid_host_clocks_fail_before_boot() {
        for now in [
            UNIX_EPOCH - Duration::from_secs(1),
            UNIX_EPOCH,
            UNIX_EPOCH + Duration::from_secs(MIN_UNIX_SECS - 1),
            UNIX_EPOCH + Duration::from_secs(i64::MAX as u64 / 1_000_000_000 + 1),
        ] {
            assert!(cmdline("console=ttyAMA0", now).is_err());
        }
    }
}
