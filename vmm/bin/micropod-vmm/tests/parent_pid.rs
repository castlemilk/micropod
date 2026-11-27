use std::process::{Command, Output};

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_micropod-vmm"))
        .args(["--kernel", ""])
        .args(args)
        .output()
        .expect("launch micropod-vmm")
}

#[test]
fn mismatched_parent_is_rejected_before_reading_the_kernel() {
    let actual = std::process::id();
    let expected = if actual == 2 { 3 } else { 2 };
    let output = run(&["--parent-pid", &expected.to_string()]);
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains(&format!("expected parent PID {expected}, found {actual}")),
        "{stderr}"
    );
}

#[test]
fn matching_parent_and_standalone_launch_enter_normal_boot() {
    let parent = std::process::id().to_string();
    for args in [&[][..], &["--parent-pid", &parent][..]] {
        let output = run(args);
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("read kernel"), "{stderr}");
    }
}

#[test]
fn invalid_parent_arguments_are_rejected() {
    for value in [None, Some("1"), Some("-1"), Some("abc"), Some("2147483648")] {
        let mut args = vec!["--parent-pid"];
        args.extend(value);
        let output = run(&args);
        assert_eq!(output.status.code(), Some(2));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("Invalid --parent-pid"), "{stderr}");
    }
}

#[test]
fn malformed_flags_exit_2_instead_of_panicking() {
    let value_flags = [
        "--initrd",
        "--disk",
        "--cpus",
        "--memory-mib",
        "--cmdline",
        "--share",
        "--vsock-expose",
        "--published-mtu",
        "--timeout",
        "--snapshot-trigger",
        "--snapshot-out",
        "--restore-from",
        "--telemetry-socket",
        "--prometheus-listen",
        "--otlp-endpoint",
        "--otlp-interval-secs",
        "--service-name",
        "--worker-id",
        "--otlp-traces-endpoint",
        "--trace-slow-ms",
        "--shutdown-timeout",
        "--console-log",
        "--workspace",
        "--cmdline-append",
        "--disk-flush",
        "--disk-flush-os",
    ];
    let mut cases: Vec<Vec<&str>> = value_flags.iter().map(|f| vec![*f]).collect();
    for numeric in [
        "--cpus",
        "--memory-mib",
        "--published-mtu",
        "--timeout",
        "--otlp-interval-secs",
        "--trace-slow-ms",
        "--shutdown-timeout",
    ] {
        cases.push(vec![numeric, "four"]);
    }
    cases.push(vec!["--vsock-expose", "/tmp/x.sock:port"]);
    cases.push(vec!["--vsock-expose", "no-port"]);
    cases.push(vec!["--share", "tag-only"]);
    cases.push(vec!["--no-such-flag"]);
    cases.push(vec!["--workspace", "/opt"]);
    cases.push(vec!["--workspace", "/tmp/."]);
    cases.push(vec!["--disk-flush", "fullfsync"]);
    cases.push(vec!["--disk-flush", ""]);
    cases.push(vec!["--disk-flush-os", "fullfsync"]);
    cases.push(vec!["--disk-flush-os", ""]);
    for args in cases {
        let output = run(&args);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(2), "{args:?}: {stderr}");
        assert!(!stderr.contains("panicked"), "{args:?}: {stderr}");
    }
}

#[test]
fn every_disk_flush_mode_is_accepted() {
    for mode in ["barrier", "full", "fsync"] {
        for flag in ["--disk-flush", "--disk-flush-os"] {
            let output = run(&[flag, mode]);
            assert_eq!(output.status.code(), Some(1), "{flag} {mode}");
            let stderr = String::from_utf8_lossy(&output.stderr);
            assert!(stderr.contains("read kernel"), "{flag} {mode}: {stderr}");
        }
    }
    let output = run(&["--disk-flush", "barrier", "--disk-flush-os", "fsync"]);
    assert_eq!(output.status.code(), Some(1));
}

#[test]
fn usage_names_the_per_disk_flush() {
    let output = Command::new(env!("CARGO_BIN_EXE_micropod-vmm"))
        .arg("--help")
        .output()
        .expect("launch micropod-vmm");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("[--disk-flush-os barrier|full|fsync]"),
        "{stdout}"
    );
    assert!(stdout.contains("the cache disk keeps"), "{stdout}");
}
