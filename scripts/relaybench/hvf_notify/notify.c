// Compare two public HVF guest-exit paths at fixed notification count.
#include "vm.h"
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

enum { TOTAL = 65537, SLOTS = 8 };
struct queue {
    _Atomic uint64_t head, ack;
    uint64_t reserved[6], slots[SLOTS];
};
_Static_assert(offsetof(struct queue, ack) == 8 && offsetof(struct queue, slots) == 64, "guest ABI");

static bool window(struct probe_vm *vm, unsigned block, unsigned hypercall, unsigned batch) {
    hv_vcpu_t cpu = vm->cpu;
    const hv_vcpu_exit_t *exit = vm->exit;
    struct queue *q = vm->data;
    memset(q, 0, sizeof(*q));
    if (!hv_checked(mp_tx_boot(cpu, vm->code_ipa, vm->data_ipa, vm->bell_ipa, TOTAL, batch), "EL1 setup") ||
        !hv_checked(hv_vcpu_set_reg(cpu, HV_REG_X4, hypercall), "set transport"))
        return false;
    uint64_t guest_start, guest_end;
    if (!hv_checked(hv_vcpu_get_exec_time(cpu, &guest_start), "guest start time"))
        return false;
    uint64_t consumed = 0;
    unsigned exits = 0, expected = (TOTAL + batch - 1) / batch;
    uint64_t thread_start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    uint64_t start = mach_absolute_time();
    for (;;) {
        if (!hv_checked(hv_vcpu_run(cpu), "guest entry"))
            return false;
        int event = probe_notification(vm, hypercall);
        if (event < 0) {
            fprintf(stderr, "unexpected exit reason=%u, syndrome=0x%llx\n", (unsigned)exit->reason,
                    (unsigned long long)exit->exception.syndrome);
            return false;
        }
        if (event == 1)
            break;
        if (++exits > expected)
            return false;
        uint64_t head = atomic_load_explicit(&q->head, memory_order_acquire);
        uint64_t count = TOTAL - consumed < batch ? TOTAL - consumed : batch;
        if (!count || head != consumed + count)
            return false;
        for (uint64_t slot = 0; slot < count; ++slot) {
            if (q->slots[slot] != consumed + slot + 1)
                return false;
        }
        consumed = head;
        atomic_store_explicit(&q->ack, consumed, memory_order_release);
    }
    uint64_t elapsed = probe_ns(mach_absolute_time() - start);
    uint64_t thread_ns = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - thread_start;
    if (!hv_checked(hv_vcpu_get_exec_time(cpu, &guest_end), "guest end time") || guest_end < guest_start ||
        consumed != TOTAL || exits != expected || !elapsed)
        return false;
    printf("{\"block\":%u,\"transport\":\"%s\",\"batch\":%u,\"descriptors\":%u,"
           "\"data_exits\":%u,\"completion_exits\":1,\"wall_ns\":%llu,\"vcpu_ns\":%llu,"
           "\"thread_cpu_ns\":%llu}\n",
           block, hypercall ? "hvc" : "mmio", batch, TOTAL, exits, (unsigned long long)elapsed,
           (unsigned long long)probe_ns(guest_end - guest_start), (unsigned long long)thread_ns);
    fflush(stdout);
    return true;
}

int main(void) { return probe_run(MP_PAGE, window); }
