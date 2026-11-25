use std::ptr;

use hvf_sys::{
    check, hv_vcpu_create, hv_vcpu_destroy, hv_vcpu_t, hv_vm_create, hv_vm_destroy,
    mp_hv_vcpu_get_simd_fp_reg, mp_hv_vcpu_set_simd_fp_reg,
};

const REGISTERS: [(u32, [u8; 16]); 2] = [
    (
        0,
        [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x10, 0x32, 0x54, 0x76, 0x98, 0xba,
            0xdc, 0xfe,
        ],
    ),
    (
        31,
        [
            0xff, 0x20, 0xdb, 0x04, 0x6a, 0x80, 0x19, 0xc3, 0x73, 0x0a, 0x46, 0xf2, 0x95, 0xb7,
            0xe1, 0x5d,
        ],
    ),
];

#[repr(align(16))]
struct GuardedBytes([u8; 18]);

fn check_registers(vcpu: hv_vcpu_t) -> Result<(), String> {
    // The Rust side passes ordinary byte storage. Offset it by one byte so
    // the test also catches an alignment requirement leaking through the shim.
    for (reg, expected) in REGISTERS {
        let mut input = GuardedBytes([0xa5; 18]);
        input.0[1..17].copy_from_slice(&expected);
        check(
            unsafe { mp_hv_vcpu_set_simd_fp_reg(vcpu, reg, input.0[1..17].as_ptr()) },
            "set Q register",
        )?;
    }
    for (reg, expected) in REGISTERS {
        let mut output = GuardedBytes([0xa5; 18]);
        check(
            unsafe { mp_hv_vcpu_get_simd_fp_reg(vcpu, reg, output.0[1..17].as_mut_ptr()) },
            "get Q register",
        )?;
        if output.0[1..17] != expected || output.0[0] != 0xa5 || output.0[17] != 0xa5 {
            return Err(format!("Q{reg} byte roundtrip failed: {:02x?}", output.0));
        }
    }
    Ok(())
}

fn roundtrip_on_owned_vcpu() -> Result<(), String> {
    let mut vcpu = 0;
    let mut exit = ptr::null();
    check(
        unsafe { hv_vcpu_create(&mut vcpu, &mut exit, ptr::null_mut()) },
        "create vCPU",
    )?;
    let roundtrip = check_registers(vcpu);
    let cleanup = check(unsafe { hv_vcpu_destroy(vcpu) }, "destroy vCPU").map_err(String::from);
    roundtrip.and(cleanup)
}

#[test]
#[ignore = "requires an Apple Silicon host and a signed hypervisor-entitled test binary"]
fn simd_q0_q31_roundtrip() {
    check(
        unsafe { hv_vm_create(ptr::null_mut()) },
        "create default VM",
    )
    .unwrap();
    let roundtrip = roundtrip_on_owned_vcpu();
    let cleanup = check(unsafe { hv_vm_destroy() }, "destroy VM");
    roundtrip.unwrap();
    cleanup.unwrap();
    println!("Q0 and Q31 matched all 16 bytes with unaligned Rust buffers");
}
