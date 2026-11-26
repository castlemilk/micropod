// Shared single-vCPU lifecycle and checked notification decoder for the two probes.
#pragma once
#include <Hypervisor/Hypervisor.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>

enum { MP_PAGE = 16384 };
struct probe_vm {
    hv_vcpu_t cpu;
    const hv_vcpu_exit_t *exit;
    void *data;
    uint64_t code_ipa, data_ipa, bell_ipa;
};

bool hv_checked(hv_return_t rc, const char *operation);
uint64_t probe_ns(uint64_t ticks);
int probe_notification(const struct probe_vm *vm, bool hypercall);
int probe_run(size_t bytes, bool (*window)(struct probe_vm *, unsigned, unsigned, unsigned));
hv_return_t mp_tx_boot(hv_vcpu_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
