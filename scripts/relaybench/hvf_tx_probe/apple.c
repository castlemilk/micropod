// Translate Apple's SDK types and register selectors at the Rust FFI boundary.
#include <Hypervisor/Hypervisor.h>
#include <libkern/OSCacheControl.h>
#include <stdint.h>
#include <string.h>

extern const unsigned char mp_tx_guest_begin[], mp_tx_guest_end[];

int mp_tx_install(void *code, size_t size) {
    size_t length = (uintptr_t)mp_tx_guest_end - (uintptr_t)mp_tx_guest_begin;
    if (!length || length > size) return -1;
    memcpy(code, mp_tx_guest_begin, length);
    sys_icache_invalidate(code, length);
    return 0;
}

hv_return_t mp_tx_map(void *page, uint64_t ipa, size_t size, int code) {
    return hv_vm_map(page, ipa, size, HV_MEMORY_READ | (code ? HV_MEMORY_EXEC : HV_MEMORY_WRITE));
}

hv_return_t mp_tx_boot(hv_vcpu_t cpu, uint64_t pc, uint64_t data,
                       uint64_t doorbell, uint64_t total, uint64_t batch) {
    const hv_reg_t registers[] = {HV_REG_PC, HV_REG_CPSR, HV_REG_X0, HV_REG_X1, HV_REG_X2, HV_REG_X3};
    const uint64_t values[] = {pc, 0x3c5, data, doorbell, total, batch};
    for (size_t i = 0; i < sizeof(registers) / sizeof(*registers); i++) {
        hv_return_t rc = hv_vcpu_set_reg(cpu, registers[i], values[i]);
        if (rc != HV_SUCCESS) return rc;
    }
    return HV_SUCCESS;
}

// Only the two 32-bit MMIO stores in guest.S are device operations.
int mp_tx_exit(hv_vcpu_t cpu, const hv_vcpu_exit_t *exit, uint64_t doorbell,
               uint64_t *count) {
    if (!exit || exit->reason != HV_EXIT_REASON_EXCEPTION) return -1;
    uint64_t esr = exit->exception.syndrome;
    if (((esr >> 26) & 63) != 0x24 || !(esr & (1u << 24)) || !(esr & (1u << 6)) ||
        ((esr >> 22) & 3) != 2) return -1;
    uint64_t ipa = exit->exception.physical_address;
    unsigned reg = (esr >> 16) & 31;
    if (ipa == doorbell + 4 && reg == 31) return 1;
    if (ipa != doorbell || reg != 1) return -1;
    uint64_t pc = 0;
    if (hv_vcpu_get_reg(cpu, HV_REG_X1, count) != HV_SUCCESS ||
        hv_vcpu_get_reg(cpu, HV_REG_PC, &pc) != HV_SUCCESS ||
        hv_vcpu_set_reg(cpu, HV_REG_PC, pc + 4) != HV_SUCCESS) return -1;
    return 0;
}
