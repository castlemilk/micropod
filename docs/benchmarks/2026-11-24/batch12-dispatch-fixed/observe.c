#include "PublishedTCP.h"
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct observed {
    int shares, policy, qos, base_priority, current_priority;
    uint64_t tid;
};
static atomic_bool unsupported;
static atomic_uint serial;

static struct observed state(void) {
    const thread_t t = pthread_mach_thread_np(pthread_self());
    thread_extended_policy_data_t e = {0};
    thread_basic_info_data_t b = {0};
    thread_extended_info_data_t detailed = {0};
    mach_msg_type_number_t n = THREAD_EXTENDED_POLICY_COUNT;
    boolean_t defaults = FALSE;
    uint64_t tid = 0;
    if (thread_policy_get(t, THREAD_EXTENDED_POLICY, (thread_policy_t)&e, &n, &defaults) != KERN_SUCCESS
        || pthread_threadid_np(NULL, &tid) != 0) _exit(80);
    n = THREAD_BASIC_INFO_COUNT;
    if (thread_info(t, THREAD_BASIC_INFO, (thread_info_t)&b, &n) != KERN_SUCCESS) _exit(81);
    n = THREAD_EXTENDED_INFO_COUNT;
    if (thread_info(t, THREAD_EXTENDED_INFO, (thread_info_t)&detailed, &n) != KERN_SUCCESS) _exit(82);
    return (struct observed){e.timeshare, b.policy, qos_class_self(), detailed.pth_priority,
                             detailed.pth_curpri, tid};
}

static int shares(int requested) {
    thread_extended_policy_data_t policy = {.timeshare = requested};
    return thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_EXTENDED_POLICY,
                             (thread_policy_t)&policy, THREAD_EXTENDED_POLICY_COUNT);
}

static void emit(const char *key, struct observed s) {
    fprintf(stderr, ",\"%s\":{\"timeshare\":%d,\"basic_policy\":%d,\"qos\":%d,\"base\":%d,\"current\":%d,\"tid\":%llu}",
            key, s.shares, s.policy, s.qos, s.base_priority, s.current_priority, s.tid);
}

void bench_drain(mp_tcp_relay *r, int workers, const char *name) {
    if (workers == 0) { mp_tcp_relay_drain(r, workers); return; }
    const unsigned inv = atomic_fetch_add(&serial, 1) + 1;
    const int requested = strcmp(getenv("BENCH_CALLBACK_FIXED"), "1") == 0;
    const struct observed before = state();
    const int tried = requested && !atomic_load(&unsupported);
    int set_status = -1, restore_status = -1;
    if (tried) {
        set_status = shares(0);
        if (set_status != KERN_SUCCESS) atomic_store(&unsupported, 1);
    }
    const struct observed entered = state();
    mp_tcp_relay_drain(r, workers);
    const struct observed leaving = state();
    if (tried && set_status == KERN_SUCCESS) restore_status = shares(before.shares);
    const struct observed restored = state();
    const int lifetime_ok = restored.tid == before.tid && before.tid == entered.tid && entered.tid == leaving.tid;
    const int restored_ok = before.shares == restored.shares && before.policy == restored.policy
                            && before.qos == restored.qos && before.base_priority == restored.base_priority;
    flockfile(stderr);
    fprintf(stderr, "{\"invocation\":%u,\"owner\":\"%s\",\"set_status\":%d,\"restore_status\":%d,\"stable_thread\":%d,\"restored\":%d",
            inv, name, set_status, restore_status, lifetime_ok, restored_ok);
    emit("before", before); emit("entered", entered); emit("leaving", leaving); emit("restored_state", restored);
    fputs("}\n", stderr); fflush(stderr); funlockfile(stderr);
    // Never return an altered test thread to the dispatch pool if restoration failed.
    if (!lifetime_ok || (tried && set_status == KERN_SUCCESS && (restore_status != 0 || !restored_ok))) _exit(78);
}
