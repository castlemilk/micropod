#include "vm.h"
#include <stdio.h>
#include <unistd.h>

int mp_tx_install(void *, size_t);
hv_return_t mp_tx_map(void *, uint64_t, size_t, int);
static const uint64_t CODE = 0x40000000, DATA = 0x40004000;
static mach_timebase_info_data_t timebase;

bool hv_checked(hv_return_t rc, const char *operation) {
    if (rc == HV_SUCCESS)
        return true;
    fprintf(stderr, "%s: 0x%x\n", operation, rc);
    return false;
}

uint64_t probe_ns(uint64_t ticks) { return (uint64_t)((__uint128_t)ticks * timebase.numer / timebase.denom); }

// HVC resumes at the next guest instruction. A trapped store resumes at the faulting
// instruction. The control has a fixed queue per address and needs no payload register.
int probe_notification(const struct probe_vm *vm, bool hypercall) {
    hv_vcpu_t cpu = vm->cpu;
    const hv_vcpu_exit_t *exit = vm->exit;
    if (exit->reason != HV_EXIT_REASON_EXCEPTION)
        return -1;
    uint64_t syndrome = exit->exception.syndrome;
    unsigned kind = (unsigned)((syndrome >> 26) & 63);
    if (hypercall) {
        if (kind != 0x16)
            return -1;
        switch (syndrome & 0xffff) {
        case 0x41:
            return 0;
        case 0x42:
            return 1;
        default:
            return -1;
        }
    }
    if (kind != 0x24 || !(syndrome & (1u << 24)) || !(syndrome & (1u << 6)) || ((syndrome >> 22) & 3) != 2 ||
        ((syndrome >> 16) & 31) != 31)
        return -1;
    uint64_t ipa = exit->exception.physical_address;
    if (ipa == vm->bell_ipa + 4)
        return 1;
    if (ipa != vm->bell_ipa)
        return -1;
    uint64_t pc;
    if (!hv_checked(hv_vcpu_get_reg(cpu, HV_REG_PC, &pc), "get PC") ||
        !hv_checked(hv_vcpu_set_reg(cpu, HV_REG_PC, pc + 4), "advance MMIO PC"))
        return -1;
    return 0;
}

int probe_run(size_t bytes, bool (*window)(struct probe_vm *, unsigned, unsigned, unsigned)) {
    if (getpagesize() != MP_PAGE || mach_timebase_info(&timebase) != KERN_SUCCESS)
        return 2;
    void *code = NULL, *data = NULL;
    hv_vcpu_t cpu = 0;
    hv_vcpu_exit_t *exit = NULL;
    bool vm = false, vcpu = false, ok = false;
    if (!hv_checked(hv_vm_allocate(&code, MP_PAGE, HV_ALLOCATE_DEFAULT), "allocate code") ||
        !hv_checked(hv_vm_allocate(&data, bytes, HV_ALLOCATE_DEFAULT), "allocate data"))
        goto done;
    if (mp_tx_install(code, MP_PAGE) != 0 || !hv_checked(hv_vm_create(NULL), "create VM"))
        goto done;
    vm = true;
    if (!hv_checked(mp_tx_map(code, CODE, MP_PAGE, 1), "map code") ||
        !hv_checked(mp_tx_map(data, DATA, bytes, 0), "map ring") ||
        !hv_checked(hv_vcpu_create(&cpu, &exit, NULL), "create vCPU"))
        goto done;
    vcpu = true;
    struct probe_vm state = {cpu, exit, data, CODE, DATA, DATA + bytes};
    unsigned block, mode, batch;
    int parsed;
    while ((parsed = scanf("%u %u %u", &block, &mode, &batch)) == 3) {
        if (mode > 1 || (batch != 1 && batch != 8) || !window(&state, block, mode, batch))
            goto done;
    }
    ok = parsed == EOF && !ferror(stdin);
done:
    if (vcpu && !hv_checked(hv_vcpu_destroy(cpu), "destroy vCPU"))
        ok = false;
    if (vm && !hv_checked(hv_vm_destroy(), "destroy VM"))
        return 2;
    if (data && !hv_checked(hv_vm_deallocate(data, bytes), "free data"))
        ok = false;
    if (code && !hv_checked(hv_vm_deallocate(code, MP_PAGE), "free code"))
        ok = false;
    return ok ? 0 : 2;
}
