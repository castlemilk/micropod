//! Direct Apple Silicon Hypervisor.framework bindings for macOS 15–26+.
//! Includes hardware-assisted ARM GICv3 (`hv_gic_create`), 16 KiB Stage-2
//! IPA granules (`HV_IPA_GRANULE_16KB`), and `hv_vm_allocate`.

#![allow(non_camel_case_types, dead_code)]

use std::ffi::c_void;
use std::fmt;

pub type hv_return_t = i32;
pub type hv_vcpu_t = u64;
pub type hv_ipa_t = u64;
pub type hv_memory_flags_t = u64;
pub type hv_allocate_flags_t = u64;
pub type hv_vm_config_t = *mut c_void;
pub type hv_vcpu_config_t = *mut c_void;
pub type hv_gic_config_t = *mut c_void;
pub type hv_gic_state_t = *mut c_void;

/// All ARM64 EL1/EL0 system register encodings saved/restored across HVF VM snapshots.
/// Read-only CPU ID registers and EL2/SME registers are excluded; any encoding that
/// returns HV_UNSUPPORTED on a given host is skipped during save.
pub const SNAPSHOT_SYS_REGS: &[u16] = &[
    // Debug breakpoints/watchpoints (0..15) + debug control
    0x8004, 0x8005, 0x8006, 0x8007, 0x800c, 0x800d, 0x800e, 0x800f, 0x8010, 0x8012, 0x8014, 0x8015,
    0x8016, 0x8017, 0x801c, 0x801d, 0x801e, 0x801f, 0x8024, 0x8025, 0x8026, 0x8027, 0x802c, 0x802d,
    0x802e, 0x802f, 0x8034, 0x8035, 0x8036, 0x8037, 0x803c, 0x803d, 0x803e, 0x803f, 0x8044, 0x8045,
    0x8046, 0x8047, 0x804c, 0x804d, 0x804e, 0x804f, 0x8054, 0x8055, 0x8056, 0x8057, 0x805c, 0x805d,
    0x805e, 0x805f, 0x8064, 0x8065, 0x8066, 0x8067, 0x806c, 0x806d, 0x806e, 0x806f, 0x8074, 0x8075,
    0x8076, 0x8077, 0x807c, 0x807d, 0x807e, 0x807f,
    // Core EL1 MMU, exception, PAC, thread-ID, and timer state
    0xc080, // SCTLR_EL1
    0xc081, // ACTLR_EL1
    0xc082, // CPACR_EL1
    0xc100, // TTBR0_EL1
    0xc101, // TTBR1_EL1
    0xc102, // TCR_EL1
    0xc108, // APIAKEYLO_EL1
    0xc109, // APIAKEYHI_EL1
    0xc10a, // APIBKEYLO_EL1
    0xc10b, // APIBKEYHI_EL1
    0xc110, // APDAKEYLO_EL1
    0xc111, // APDAKEYHI_EL1
    0xc112, // APDBKEYLO_EL1
    0xc113, // APDBKEYHI_EL1
    0xc118, // APGAKEYLO_EL1
    0xc119, // APGAKEYHI_EL1
    0xc200, // SPSR_EL1
    0xc201, // ELR_EL1
    0xc208, // SP_EL0
    0xc288, // AFSR0_EL1
    0xc289, // AFSR1_EL1
    0xc290, // ESR_EL1
    0xc300, // FAR_EL1
    0xc3a0, // PAR_EL1
    0xc510, // MAIR_EL1
    0xc518, // AMAIR_EL1
    0xc600, // VBAR_EL1
    0xc681, // CONTEXTIDR_EL1
    0xc684, // TPIDR_EL1
    0xc687, // SCXTNUM_EL1
    0xc708, // CNTKCTL_EL1
    0xd000, // CSSELR_EL1
    0xde82, // TPIDR_EL0
    0xde83, // TPIDRRO_EL0
    0xde87, // SCXTNUM_EL0
    0xdf19, // CNTV_CTL_EL0
    0xdf1a, // CNTV_CVAL_EL0
    0xe208, // SP_EL1
    0xdf11, // CNTP_CTL_EL0
    0xdf12, // CNTP_CVAL_EL0
];

/// Writable ARM GICv3 EL1 CPU interface (ICC) registers saved per vCPU alongside `hv_gic_state`.
/// (`ICC_RPR_EL1` / 0xc65b is architecturally read-only and derived from AP0R0/AP1R0.)
pub const SNAPSHOT_GIC_ICC_REGS: &[u16] = &[
    0xc230, // HV_GIC_ICC_REG_PMR_EL1
    0xc643, // HV_GIC_ICC_REG_BPR0_EL1
    0xc644, // HV_GIC_ICC_REG_AP0R0_EL1
    0xc648, // HV_GIC_ICC_REG_AP1R0_EL1
    0xc663, // HV_GIC_ICC_REG_BPR1_EL1
    0xc664, // HV_GIC_ICC_REG_CTLR_EL1
    0xc665, // HV_GIC_ICC_REG_SRE_EL1
    0xc666, // HV_GIC_ICC_REG_IGRPEN0_EL1
    0xc667, // HV_GIC_ICC_REG_IGRPEN1_EL1
];

pub const HV_SUCCESS: hv_return_t = 0;

pub const HV_MEMORY_READ: hv_memory_flags_t = 1 << 0;
pub const HV_MEMORY_WRITE: hv_memory_flags_t = 1 << 1;
pub const HV_MEMORY_EXEC: hv_memory_flags_t = 1 << 2;
pub const HV_MEMORY_RWX: hv_memory_flags_t = HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC;

pub const HV_ALLOCATE_DEFAULT: hv_allocate_flags_t = 0;

#[repr(u32)]
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub enum hv_ipa_granule_t {
    HV_IPA_GRANULE_4KB = 0,
    HV_IPA_GRANULE_16KB = 1,
}

#[repr(u32)]
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub enum hv_exit_reason_t {
    HV_EXIT_REASON_CANCELED = 0,
    HV_EXIT_REASON_EXCEPTION = 1,
    HV_EXIT_REASON_VTIMER_ACTIVATED = 2,
    HV_EXIT_REASON_UNKNOWN = 3,
}

#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct hv_vcpu_exit_exception_t {
    pub syndrome: u64,
    pub virtual_address: u64,
    pub physical_address: hv_ipa_t,
}

#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct hv_vcpu_exit_t {
    pub reason: hv_exit_reason_t,
    pub exception: hv_vcpu_exit_exception_t,
}

#[repr(u32)]
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub enum hv_reg_t {
    HV_REG_X0 = 0,
    HV_REG_X1 = 1,
    HV_REG_X2 = 2,
    HV_REG_X3 = 3,
    HV_REG_X4 = 4,
    HV_REG_X5 = 5,
    HV_REG_X6 = 6,
    HV_REG_X7 = 7,
    HV_REG_X8 = 8,
    HV_REG_X9 = 9,
    HV_REG_X10 = 10,
    HV_REG_X11 = 11,
    HV_REG_X12 = 12,
    HV_REG_X13 = 13,
    HV_REG_X14 = 14,
    HV_REG_X15 = 15,
    HV_REG_X16 = 16,
    HV_REG_X17 = 17,
    HV_REG_X18 = 18,
    HV_REG_X19 = 19,
    HV_REG_X20 = 20,
    HV_REG_X21 = 21,
    HV_REG_X22 = 22,
    HV_REG_X23 = 23,
    HV_REG_X24 = 24,
    HV_REG_X25 = 25,
    HV_REG_X26 = 26,
    HV_REG_X27 = 27,
    HV_REG_X28 = 28,
    HV_REG_X29 = 29,
    HV_REG_X30 = 30,
    HV_REG_PC = 31,
    HV_REG_FPCR = 32,
    HV_REG_FPSR = 33,
    HV_REG_CPSR = 34,
}

impl hv_reg_t {
    pub fn gpr(idx: u32) -> Option<Self> {
        match idx {
            0 => Some(Self::HV_REG_X0),
            1 => Some(Self::HV_REG_X1),
            2 => Some(Self::HV_REG_X2),
            3 => Some(Self::HV_REG_X3),
            4 => Some(Self::HV_REG_X4),
            5 => Some(Self::HV_REG_X5),
            6 => Some(Self::HV_REG_X6),
            7 => Some(Self::HV_REG_X7),
            8 => Some(Self::HV_REG_X8),
            9 => Some(Self::HV_REG_X9),
            10 => Some(Self::HV_REG_X10),
            11 => Some(Self::HV_REG_X11),
            12 => Some(Self::HV_REG_X12),
            13 => Some(Self::HV_REG_X13),
            14 => Some(Self::HV_REG_X14),
            15 => Some(Self::HV_REG_X15),
            16 => Some(Self::HV_REG_X16),
            17 => Some(Self::HV_REG_X17),
            18 => Some(Self::HV_REG_X18),
            19 => Some(Self::HV_REG_X19),
            20 => Some(Self::HV_REG_X20),
            21 => Some(Self::HV_REG_X21),
            22 => Some(Self::HV_REG_X22),
            23 => Some(Self::HV_REG_X23),
            24 => Some(Self::HV_REG_X24),
            25 => Some(Self::HV_REG_X25),
            26 => Some(Self::HV_REG_X26),
            27 => Some(Self::HV_REG_X27),
            28 => Some(Self::HV_REG_X28),
            29 => Some(Self::HV_REG_X29),
            30 => Some(Self::HV_REG_X30),
            _ => None,
        }
    }
}

#[repr(u16)]
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub enum hv_sys_reg_t {
    HV_SYS_REG_MIDR_EL1 = 0xc000,
    HV_SYS_REG_MPIDR_EL1 = 0xc005,
    HV_SYS_REG_ID_AA64PFR0_EL1 = 0xc020,
    HV_SYS_REG_ID_AA64PFR1_EL1 = 0xc021,
    HV_SYS_REG_ID_AA64DFR0_EL1 = 0xc028,
    HV_SYS_REG_ID_AA64DFR1_EL1 = 0xc029,
    HV_SYS_REG_ID_AA64ISAR0_EL1 = 0xc030,
    HV_SYS_REG_ID_AA64ISAR1_EL1 = 0xc031,
    HV_SYS_REG_ID_AA64MMFR0_EL1 = 0xc038,
    HV_SYS_REG_ID_AA64MMFR1_EL1 = 0xc039,
    HV_SYS_REG_ID_AA64MMFR2_EL1 = 0xc03a,
    HV_SYS_REG_SCTLR_EL1 = 0xc080,
    HV_SYS_REG_ACTLR_EL1 = 0xc081,
    HV_SYS_REG_CPACR_EL1 = 0xc082,
    HV_SYS_REG_CNTKCTL_EL1 = 0xc708,
    HV_SYS_REG_CNTV_CTL_EL0 = 0xdf19,
    HV_SYS_REG_CNTV_CVAL_EL0 = 0xdf1a,
    HV_SYS_REG_CNTP_CTL_EL0 = 0xdf11,
    HV_SYS_REG_CNTP_CVAL_EL0 = 0xdf12,
    HV_SYS_REG_SP_EL1 = 0xe208,
}

#[repr(u16)]
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub enum hv_gic_intid_t {
    HV_GIC_INT_PERFORMANCE_MONITOR = 23,
    HV_GIC_INT_MAINTENANCE = 25,
    HV_GIC_INT_EL2_PHYSICAL_TIMER = 26,
    HV_GIC_INT_EL1_VIRTUAL_TIMER = 27,
    HV_GIC_INT_EL1_PHYSICAL_TIMER = 30,
}

#[link(name = "Hypervisor", kind = "framework")]
unsafe extern "C" {
    pub fn os_release(object: *mut c_void);

    // VM configuration & lifecycle
    pub fn hv_vm_config_create() -> hv_vm_config_t;
    pub fn hv_vm_config_get_max_ipa_size(ipa_bit_length: *mut u32) -> hv_return_t;
    pub fn hv_vm_config_get_default_ipa_size(ipa_bit_length: *mut u32) -> hv_return_t;
    pub fn hv_vm_config_set_ipa_size(config: hv_vm_config_t, ipa_bit_length: u32) -> hv_return_t;
    pub fn hv_vm_config_get_default_ipa_granule(granule: *mut hv_ipa_granule_t) -> hv_return_t;
    pub fn hv_vm_config_set_ipa_granule(
        config: hv_vm_config_t,
        granule: hv_ipa_granule_t,
    ) -> hv_return_t;
    pub fn hv_vm_get_max_vcpu_count(max_vcpu_count: *mut u32) -> hv_return_t;
    pub fn hv_vm_create(config: hv_vm_config_t) -> hv_return_t;
    pub fn hv_vm_destroy() -> hv_return_t;
    pub fn hv_vm_map(
        addr: *mut c_void,
        ipa: hv_ipa_t,
        size: usize,
        flags: hv_memory_flags_t,
    ) -> hv_return_t;
    pub fn hv_vm_unmap(ipa: hv_ipa_t, size: usize) -> hv_return_t;
    pub fn hv_vm_protect(ipa: hv_ipa_t, size: usize, flags: hv_memory_flags_t) -> hv_return_t;
    pub fn hv_vm_allocate(
        uvap: *mut *mut c_void,
        size: usize,
        flags: hv_allocate_flags_t,
    ) -> hv_return_t;
    pub fn hv_vm_deallocate(uva: *mut c_void, size: usize) -> hv_return_t;

    // Hardware ARM GICv3
    pub fn hv_gic_config_create() -> hv_gic_config_t;
    pub fn hv_gic_config_set_distributor_base(
        config: hv_gic_config_t,
        addr: hv_ipa_t,
    ) -> hv_return_t;
    pub fn hv_gic_config_set_redistributor_base(
        config: hv_gic_config_t,
        addr: hv_ipa_t,
    ) -> hv_return_t;
    pub fn hv_gic_create(config: hv_gic_config_t) -> hv_return_t;
    pub fn hv_gic_set_spi(intid: u32, level: bool) -> hv_return_t;
    pub fn hv_gic_get_distributor_size(size: *mut usize) -> hv_return_t;
    pub fn hv_gic_get_distributor_base_alignment(align: *mut usize) -> hv_return_t;
    pub fn hv_gic_get_redistributor_region_size(size: *mut usize) -> hv_return_t;
    pub fn hv_gic_get_redistributor_size(size: *mut usize) -> hv_return_t;
    pub fn hv_gic_get_redistributor_base_alignment(align: *mut usize) -> hv_return_t;
    pub fn hv_gic_get_redistributor_base(vcpu: hv_vcpu_t, addr: *mut hv_ipa_t) -> hv_return_t;
    pub fn hv_gic_get_spi_interrupt_range(base: *mut u32, count: *mut u32) -> hv_return_t;
    pub fn hv_gic_get_intid(interrupt: hv_gic_intid_t, intid: *mut u32) -> hv_return_t;
    pub fn hv_gic_state_create() -> hv_gic_state_t;
    pub fn hv_gic_state_get_size(state: hv_gic_state_t, gic_state_size: *mut usize) -> hv_return_t;
    pub fn hv_gic_state_get_data(state: hv_gic_state_t, gic_state_data: *mut c_void)
    -> hv_return_t;
    pub fn hv_gic_set_state(gic_state_data: *const c_void, gic_state_size: usize) -> hv_return_t;
    pub fn hv_gic_get_icc_reg(vcpu: hv_vcpu_t, reg: u16, value: *mut u64) -> hv_return_t;
    pub fn hv_gic_set_icc_reg(vcpu: hv_vcpu_t, reg: u16, value: u64) -> hv_return_t;

    // vCPU
    pub fn hv_vcpu_config_create() -> hv_vcpu_config_t;
    pub fn hv_vcpu_create(
        vcpu: *mut hv_vcpu_t,
        exit: *mut *const hv_vcpu_exit_t,
        config: hv_vcpu_config_t,
    ) -> hv_return_t;
    pub fn hv_vcpu_destroy(vcpu: hv_vcpu_t) -> hv_return_t;
    pub fn hv_vcpu_run(vcpu: hv_vcpu_t) -> hv_return_t;
    pub fn hv_vcpus_exit(vcpus: *const hv_vcpu_t, count: u32) -> hv_return_t;
    pub fn hv_vcpu_get_reg(vcpu: hv_vcpu_t, reg: hv_reg_t, value: *mut u64) -> hv_return_t;
    pub fn hv_vcpu_set_reg(vcpu: hv_vcpu_t, reg: hv_reg_t, value: u64) -> hv_return_t;
    pub fn mp_hv_vcpu_get_reg_raw(vcpu: hv_vcpu_t, reg: u32, value: *mut u64) -> hv_return_t;
    pub fn mp_hv_vcpu_set_reg_raw(vcpu: hv_vcpu_t, reg: u32, value: u64) -> hv_return_t;
    pub fn mp_hv_vcpu_get_simd_fp_reg(vcpu: hv_vcpu_t, reg: u32, out_bytes: *mut u8)
    -> hv_return_t;
    pub fn mp_hv_vcpu_set_simd_fp_reg(
        vcpu: hv_vcpu_t,
        reg: u32,
        in_bytes: *const u8,
    ) -> hv_return_t;
    pub fn hv_vcpu_get_sys_reg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t, value: *mut u64) -> hv_return_t;
    pub fn hv_vcpu_set_sys_reg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t, value: u64) -> hv_return_t;
    pub fn mp_hv_vcpu_get_sys_reg_raw(vcpu: hv_vcpu_t, reg: u16, value: *mut u64) -> hv_return_t;
    pub fn mp_hv_vcpu_set_sys_reg_raw(vcpu: hv_vcpu_t, reg: u16, value: u64) -> hv_return_t;
    pub fn hv_vcpu_get_vtimer_mask(vcpu: hv_vcpu_t, masked: *mut bool) -> hv_return_t;
    pub fn hv_vcpu_set_vtimer_mask(vcpu: hv_vcpu_t, masked: bool) -> hv_return_t;
    pub fn hv_vcpu_get_vtimer_offset(vcpu: hv_vcpu_t, offset: *mut u64) -> hv_return_t;
    pub fn hv_vcpu_set_vtimer_offset(vcpu: hv_vcpu_t, offset: u64) -> hv_return_t;
    pub fn hv_vcpu_get_exec_time(vcpu: hv_vcpu_t, time: *mut u64) -> hv_return_t;
}

unsafe extern "C" {
    pub fn mach_absolute_time() -> u64;
    pub fn clonefile(src: *const std::ffi::c_char, dst: *const std::ffi::c_char, flags: u32)
    -> i32;
}

#[derive(Debug, Clone)]
pub struct HvError {
    pub op: &'static str,
    pub code: hv_return_t,
}

impl fmt::Display for HvError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "HVF {} failed: {:#010x}", self.op, self.code as u32)
    }
}

impl std::error::Error for HvError {}

impl From<HvError> for String {
    fn from(e: HvError) -> Self {
        e.to_string()
    }
}

pub fn check(rc: hv_return_t, op: &'static str) -> Result<(), HvError> {
    if rc == HV_SUCCESS {
        Ok(())
    } else {
        Err(HvError { op, code: rc })
    }
}
