//! Zero-dependency ARM64 Flattened Device Tree (FDT v17) generator.
//! Emits exact Apple Silicon L1/L2 cache topology so Linux builds a proper
//! shared-LLC (`MC`) scheduling domain, plus GICv3, ARM arch timer, PSCI 1.0,
//! PL011 UART, and Virtio-MMIO v2 devices.

use std::collections::BTreeMap;

const FDT_MAGIC: u32 = 0xd00d_feed;
const FDT_VERSION: u32 = 17;
const FDT_LAST_COMP_VERSION: u32 = 16;
const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_END: u32 = 9;

pub struct FdtBuilder {
    structs: Vec<u8>,
    strings: Vec<u8>,
    str_offsets: BTreeMap<String, u32>,
}

impl Default for FdtBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl FdtBuilder {
    pub fn new() -> Self {
        Self {
            structs: Vec::with_capacity(8192),
            strings: Vec::with_capacity(1024),
            str_offsets: BTreeMap::new(),
        }
    }

    fn align4(buf: &mut Vec<u8>) {
        while !buf.len().is_multiple_of(4) {
            buf.push(0);
        }
    }

    fn intern(&mut self, name: &str) -> u32 {
        if let Some(&off) = self.str_offsets.get(name) {
            return off;
        }
        let off = self.strings.len() as u32;
        self.strings.extend_from_slice(name.as_bytes());
        self.strings.push(0);
        self.str_offsets.insert(name.to_string(), off);
        off
    }

    pub fn begin_node(&mut self, name: &str) {
        self.structs
            .extend_from_slice(&FDT_BEGIN_NODE.to_be_bytes());
        self.structs.extend_from_slice(name.as_bytes());
        self.structs.push(0);
        Self::align4(&mut self.structs);
    }

    pub fn end_node(&mut self) {
        self.structs.extend_from_slice(&FDT_END_NODE.to_be_bytes());
    }

    pub fn prop_raw(&mut self, name: &str, data: &[u8]) {
        let name_off = self.intern(name);
        self.structs.extend_from_slice(&FDT_PROP.to_be_bytes());
        self.structs
            .extend_from_slice(&(data.len() as u32).to_be_bytes());
        self.structs.extend_from_slice(&name_off.to_be_bytes());
        self.structs.extend_from_slice(data);
        Self::align4(&mut self.structs);
    }

    pub fn prop_empty(&mut self, name: &str) {
        self.prop_raw(name, &[]);
    }

    pub fn prop_u32(&mut self, name: &str, val: u32) {
        self.prop_raw(name, &val.to_be_bytes());
    }

    pub fn prop_u64(&mut self, name: &str, val: u64) {
        self.prop_raw(name, &val.to_be_bytes());
    }

    pub fn prop_u32_list(&mut self, name: &str, vals: &[u32]) {
        let mut buf = Vec::with_capacity(vals.len() * 4);
        for &v in vals {
            buf.extend_from_slice(&v.to_be_bytes());
        }
        self.prop_raw(name, &buf);
    }

    pub fn prop_u64_list(&mut self, name: &str, vals: &[u64]) {
        let mut buf = Vec::with_capacity(vals.len() * 8);
        for &v in vals {
            buf.extend_from_slice(&v.to_be_bytes());
        }
        self.prop_raw(name, &buf);
    }

    pub fn prop_str(&mut self, name: &str, s: &str) {
        let mut buf = Vec::with_capacity(s.len() + 1);
        buf.extend_from_slice(s.as_bytes());
        buf.push(0);
        self.prop_raw(name, &buf);
    }

    pub fn prop_str_list(&mut self, name: &str, strs: &[&str]) {
        let mut buf = Vec::new();
        for s in strs {
            buf.extend_from_slice(s.as_bytes());
            buf.push(0);
        }
        self.prop_raw(name, &buf);
    }

    pub fn finish(mut self) -> Vec<u8> {
        self.structs.extend_from_slice(&FDT_END.to_be_bytes());
        let header_size: u32 = 40;
        let mem_rsvmap_size: u32 = 16; // single zero terminator entry
        let off_mem_rsvmap = header_size;
        let off_dt_struct = off_mem_rsvmap + mem_rsvmap_size;
        let size_dt_struct = self.structs.len() as u32;
        let off_dt_strings = off_dt_struct + size_dt_struct;
        let size_dt_strings = self.strings.len() as u32;
        let totalsize = off_dt_strings + size_dt_strings;

        let mut out = Vec::with_capacity(totalsize as usize);
        for word in [
            FDT_MAGIC,
            totalsize,
            off_dt_struct,
            off_dt_strings,
            off_mem_rsvmap,
            FDT_VERSION,
            FDT_LAST_COMP_VERSION,
            0, // boot_cpuid_phys
            size_dt_strings,
            size_dt_struct,
        ] {
            out.extend_from_slice(&word.to_be_bytes());
        }
        out.extend_from_slice(&[0u8; 16]); // mem_rsvmap terminator
        out.extend_from_slice(&self.structs);
        out.extend_from_slice(&self.strings);
        out
    }
}

#[derive(Debug, Clone)]
pub struct CacheTopology {
    pub l1i_size: u32,
    pub l1d_size: u32,
    pub l2_size: u32,
    pub line_size: u32,
}

impl Default for CacheTopology {
    fn default() -> Self {
        Self {
            l1i_size: 192 * 1024,
            l1d_size: 128 * 1024,
            l2_size: 16 * 1024 * 1024,
            line_size: 128,
        }
    }
}

#[derive(Debug, Clone)]
pub struct VirtioMmioDesc {
    pub base: u64,
    pub size: u64,
    pub spi: u32, // GIC SPI number (0-based, i.e., intid - 32)
}

#[derive(Debug, Clone)]
pub struct VmFdtConfig {
    pub num_vcpus: u32,
    pub ram_base: u64,
    pub ram_size: u64,
    pub gicd_base: u64,
    pub gicd_size: u64,
    pub gicr_base: u64,
    pub gicr_size: u64,
    pub uart_base: u64,
    pub uart_size: u64,
    pub uart_spi: u32,   // 0-based SPI (intid - 32)
    pub vtimer_ppi: u32, // 0-based PPI (intid - 16), usually 11 (intid 27)
    pub ptimer_ppi: u32, // 0-based PPI (intid - 16), usually 14 (intid 30)
    pub timer_freq_hz: u32,
    pub cmdline: String,
    pub initrd: Option<(u64, u64)>, // (start, end)
    pub cache: CacheTopology,
    pub virtio_mmio: Vec<VirtioMmioDesc>,
}

const PHANDLE_GIC: u32 = 1;
const PHANDLE_CLK: u32 = 2;
const PHANDLE_L2: u32 = 3;
const PHANDLE_CPU_BASE: u32 = 100;

pub fn build_arm64_fdt(cfg: &VmFdtConfig) -> Vec<u8> {
    let mut b = FdtBuilder::new();
    b.begin_node("");
    b.prop_str("compatible", "linux,dummy-virt");
    b.prop_u32("#address-cells", 2);
    b.prop_u32("#size-cells", 2);
    b.prop_u32("interrupt-parent", PHANDLE_GIC);

    // /chosen
    b.begin_node("chosen");
    b.prop_str("bootargs", &cfg.cmdline);
    b.prop_str("stdout-path", &format!("/pl011@{:x}", cfg.uart_base));
    if let Some((start, end)) = cfg.initrd {
        b.prop_u64("linux,initrd-start", start);
        b.prop_u64("linux,initrd-end", end);
    }
    b.end_node();

    // /memory
    b.begin_node(&format!("memory@{:x}", cfg.ram_base));
    b.prop_str("device_type", "memory");
    b.prop_u64_list("reg", &[cfg.ram_base, cfg.ram_size]);
    b.end_node();

    // /cpus with real Apple Silicon L1/L2 cache topology + cpu-map (shared L2 cluster)
    b.begin_node("cpus");
    b.prop_u32("#address-cells", 1);
    b.prop_u32("#size-cells", 0);

    for i in 0..cfg.num_vcpus {
        b.begin_node(&format!("cpu@{i}"));
        b.prop_str("device_type", "cpu");
        b.prop_str("compatible", "arm,armv8");
        b.prop_u32("reg", i);
        b.prop_str("enable-method", "psci");
        b.prop_u32("phandle", PHANDLE_CPU_BASE + i);
        b.prop_u32("i-cache-size", cfg.cache.l1i_size);
        b.prop_u32("i-cache-line-size", cfg.cache.line_size);
        b.prop_u32(
            "i-cache-sets",
            cfg.cache.l1i_size / (cfg.cache.line_size * 6),
        );
        b.prop_u32("d-cache-size", cfg.cache.l1d_size);
        b.prop_u32("d-cache-line-size", cfg.cache.line_size);
        b.prop_u32(
            "d-cache-sets",
            cfg.cache.l1d_size / (cfg.cache.line_size * 8),
        );
        b.prop_u32("next-level-cache", PHANDLE_L2);
        b.end_node();
    }

    // Shared L2 cache node -> enables Linux MC (shared-LLC) scheduler domain across vCPUs
    b.begin_node("l2-cache0");
    b.prop_str("compatible", "cache");
    b.prop_u32("cache-level", 2);
    b.prop_empty("cache-unified");
    b.prop_u32("cache-size", cfg.cache.l2_size);
    b.prop_u32("cache-line-size", cfg.cache.line_size);
    b.prop_u32("cache-sets", cfg.cache.l2_size / (cfg.cache.line_size * 16));
    b.prop_u32("phandle", PHANDLE_L2);
    b.end_node();

    // Explicit cpu-map placing all vCPUs into cluster0 (shared LLC)
    b.begin_node("cpu-map");
    b.begin_node("cluster0");
    for i in 0..cfg.num_vcpus {
        b.begin_node(&format!("core{i}"));
        b.prop_u32("cpu", PHANDLE_CPU_BASE + i);
        b.end_node();
    }
    b.end_node();
    b.end_node();

    b.end_node(); // /cpus

    // /psci
    b.begin_node("psci");
    b.prop_str_list("compatible", &["arm,psci-1.0", "arm,psci-0.2"]);
    b.prop_str("method", "hvc");
    b.end_node();

    // /apb-pclk (24 MHz reference clock for PL011)
    b.begin_node("apb-pclk");
    b.prop_str("compatible", "fixed-clock");
    b.prop_u32("#clock-cells", 0);
    b.prop_u32("clock-frequency", cfg.timer_freq_hz);
    b.prop_str("clock-output-names", "clk24mhz");
    b.prop_u32("phandle", PHANDLE_CLK);
    b.end_node();

    // /intc (ARM GICv3 backed by Apple hv_gic_create)
    b.begin_node(&format!("intc@{:x}", cfg.gicd_base));
    b.prop_str("compatible", "arm,gic-v3");
    b.prop_u32("#interrupt-cells", 3);
    b.prop_u32("#address-cells", 2);
    b.prop_u32("#size-cells", 2);
    b.prop_empty("interrupt-controller");
    b.prop_u32("phandle", PHANDLE_GIC);
    b.prop_u32("#redistributor-regions", 1);
    b.prop_u64_list(
        "reg",
        &[cfg.gicd_base, cfg.gicd_size, cfg.gicr_base, cfg.gicr_size],
    );
    b.end_node();

    // /timer (ARMv8 arch timer: sec-phys, nonsec-phys, virt, hyp)
    // IRQ type 1 = PPI, flags 8 = active-low level (standard GICv3 PPI)
    b.begin_node("timer");
    b.prop_str("compatible", "arm,armv8-timer");
    b.prop_empty("always-on");
    b.prop_u32("clock-frequency", cfg.timer_freq_hz);
    b.prop_u32_list(
        "interrupts",
        &[
            1,
            13,
            8, // Secure EL1 physical timer (intid 29)
            1,
            cfg.ptimer_ppi,
            8, // Non-secure EL1 physical timer (intid 30)
            1,
            cfg.vtimer_ppi,
            8, // Virtual timer (intid 27)
            1,
            10,
            8, // Hypervisor timer (intid 26)
        ],
    );
    b.end_node();

    // /pl011 (ARM PrimeCell PL011 UART)
    b.begin_node(&format!("pl011@{:x}", cfg.uart_base));
    b.prop_str_list("compatible", &["arm,pl011", "arm,primecell"]);
    b.prop_u64_list("reg", &[cfg.uart_base, cfg.uart_size]);
    b.prop_u32_list("interrupts", &[0, cfg.uart_spi, 4]); // SPI, level-high
    b.prop_u32_list("clocks", &[PHANDLE_CLK, PHANDLE_CLK]);
    b.prop_str_list("clock-names", &["uartclk", "apb_pclk"]);
    b.end_node();

    // Virtio-MMIO v2 devices
    for dev in &cfg.virtio_mmio {
        b.begin_node(&format!("virtio_mmio@{:x}", dev.base));
        b.prop_str("compatible", "virtio,mmio");
        b.prop_empty("dma-coherent");
        b.prop_u64_list("reg", &[dev.base, dev.size]);
        b.prop_u32_list("interrupts", &[0, dev.spi, 4]); // SPI, level-high
        b.end_node();
    }

    b.end_node(); // root
    b.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fdt_header_and_magic_valid() {
        let dtb = build_arm64_fdt(&VmFdtConfig {
            num_vcpus: 4,
            ram_base: 0x4000_0000,
            ram_size: 512 << 20,
            gicd_base: 0x0800_0000,
            gicd_size: 0x0001_0000,
            gicr_base: 0x080a_0000,
            gicr_size: 0x00f6_0000,
            uart_base: 0x0900_0000,
            uart_size: 0x1000,
            uart_spi: 1,
            vtimer_ppi: 11,
            ptimer_ppi: 14,
            timer_freq_hz: 24_000_000,
            cmdline: "console=ttyAMA0".into(),
            initrd: Some((0x4400_0000, 0x4410_0000)),
            cache: CacheTopology::default(),
            virtio_mmio: vec![VirtioMmioDesc {
                base: 0x0a00_0000,
                size: 0x200,
                spi: 16,
            }],
        });
        assert_eq!(u32::from_be_bytes(dtb[0..4].try_into().unwrap()), FDT_MAGIC);
        assert_eq!(
            u32::from_be_bytes(dtb[4..8].try_into().unwrap()) as usize,
            dtb.len()
        );
        assert_eq!(
            u32::from_be_bytes(dtb[20..24].try_into().unwrap()),
            FDT_VERSION
        );
    }
}
