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
