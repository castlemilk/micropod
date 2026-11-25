use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=src/simd_shim.c");
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let obj = out_dir.join("simd_shim.o");
    let lib = out_dir.join("libhvf_simd_shim.a");

    let status = Command::new("xcrun")
        .args(["clang", "-O2", "-c", "src/simd_shim.c", "-o"])
        .arg(&obj)
        .status()
        .expect("invoke xcrun clang");
    assert!(status.success(), "clang failed to compile src/simd_shim.c");

    let status = Command::new("ar")
        .args(["rcs"])
        .arg(&lib)
        .arg(&obj)
        .status()
        .expect("invoke ar");
    assert!(status.success(), "ar failed to archive libhvf_simd_shim.a");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=hvf_simd_shim");
}
