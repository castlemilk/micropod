// Build with clang -O2 -Wall -Wextra on macOS. Outputs NDJSON to stdout.
#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <time.h>

// Some macOS SDKs only publish these proc_pidinfo flavors in XNU's
// bsd/sys/proc_info_private.h. Check the response layout on every call.
enum { coalition_info = 20, list_thread_ids = 28, thread_counts = 34 };
struct coalition_ids { uint64_t resource, jetsam, reserved[3]; };
struct level_counts {
    uint64_t instructions, cycles, user_ticks, system_ticks, energy;
};
struct thread_counts {
    uint16_t length, reserved;
    uint32_t padding;
    struct level_counts levels[];
};
_Static_assert(offsetof(struct thread_counts, levels) == 8, "unexpected XNU header");
_Static_assert(sizeof(struct level_counts) == 40, "unexpected XNU counters");

static int positive(const char *s) {
    char *end;
    errno = 0;
    long n = strtol(s, &end, 10);
    return !errno && *s && !*end && n > 0 && n <= INT_MAX ? (int)n : 0;
}

static const char *thread_group(const char *name) {
    if (strstr(name, ".thread.cpu-") || (!strncmp(name, "vcpu", 4) && name[4] >= '0' && name[4] <= '9'))
        return "vcpu";
    if (strcasestr(name, "virtio") || strcasestr(name, "iothread") || strcasestr(name, "vhost") ||
        strcasestr(name, "netdev") || strcasestr(name, "disk"))
        return "named_io";
    return "other";
}

// A saturated list may have raced with thread creation. Retry with more space.
static int read_ids(pid_t pid, uint64_t **ids, int *capacity) {
    for (;;) {
        int bytes = *capacity * (int)sizeof(**ids);
        int got = proc_pidinfo(pid, list_thread_ids, 0, *ids, bytes);
        if (got <= 0) return -1;
        if (got % (int)sizeof(**ids)) { errno = EPROTO; return -1; }
        if (got < bytes) return got / (int)sizeof(**ids);
        if (*capacity > INT_MAX / (int)sizeof(**ids) / 2) { errno = EOVERFLOW; return -1; }
        int bigger = *capacity * 2;
        uint64_t *p = realloc(*ids, (size_t)bigger * sizeof(*p));
        if (!p) return -1;
        *ids = p;
        *capacity = bigger;
    }
}

static int trace(pid_t pid, int samples, int interval_ms) {
    uint32_t levels = 0;
    size_t size = sizeof(levels);
    mach_timebase_info_data_t scale;
    if (sysctlbyname("hw.nperflevels", &levels, &size, NULL, 0) || !levels || levels > UINT16_MAX ||
        mach_timebase_info(&scale) != KERN_SUCCESS) {
        fprintf(stderr, "Cannot read this Mac's CPU performance levels or timebase\n");
        return 1;
    }
    int capacity = 64;
    int count_size = (int)(sizeof(struct thread_counts) + levels * sizeof(struct level_counts));
    uint64_t *ids = calloc((size_t)capacity, sizeof(*ids));
    struct thread_counts *counts = malloc((size_t)count_size);
    int status = 1;
    uint64_t birth = 0;
    if (!ids || !counts) goto done;
    printf("{\"pid\":%d,\"levels\":%u,\"tick_numer\":%u,\"tick_denom\":%u,\"level_names\":[",
           pid, levels, scale.numer, scale.denom);
    for (uint32_t i = 0; i < levels; i++) {
        char key[48], name[64] = {0};
        size_t n = sizeof(name);
        snprintf(key, sizeof(key), "hw.perflevel%u.name", i);
        if (sysctlbyname(key, name, &n, NULL, 0) || !n || n > sizeof(name)) name[0] = 0;
        name[sizeof(name) - 1] = 0;
        // Emit null when the OS supplies no printable JSON-safe label.
        if (i) putchar(',');
        if (!*name || strspn(name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_") != strlen(name))
            fputs("null", stdout);
        else printf("\"%s\"", name);
    }
    fputc(']', stdout);
    struct coalition_ids groups = {0};
    if (proc_pidinfo(pid, coalition_info, 0, &groups, sizeof(groups)) == sizeof(groups))
        printf(",\"resource_coalition\":%" PRIu64 ",\"jetsam_coalition\":%" PRIu64,
               groups.resource, groups.jetsam);
    fputs("}\n", stdout);
    for (int i = 0; i < samples; i++) {
        uint64_t at = clock_gettime_nsec_np(CLOCK_REALTIME), monotonic = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        struct rusage_info_v6 usage = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&usage)) {
            perror("read VM task counters");
            goto done;
        }
        if (i && birth != usage.ri_proc_start_abstime) {
            fprintf(stderr, "VM process changed during capture\n");
            goto done;
        }
        birth = usage.ri_proc_start_abstime;
        int n = read_ids(pid, &ids, &capacity);
        if (n < 0) {
            perror("read VM thread IDs");
            goto done;
        }
        int seen = 0;
        printf("{\"epoch_ns\":%" PRIu64 ",\"monotonic_ns\":%" PRIu64 ",\"birth_ticks\":%llu,"
               "\"cpu_ticks\":%llu,\"runnable_ticks\":%llu,\"legacy_ticks\":%llu,"
               "\"background_ticks\":%llu,\"default_ticks\":%llu,\"utility_ticks\":%llu,"
               "\"initiated_ticks\":%llu,\"interactive_ticks\":%llu,\"threads\":[",
               at, monotonic, usage.ri_proc_start_abstime, usage.ri_user_time + usage.ri_system_time,
               usage.ri_runnable_time, usage.ri_cpu_time_qos_legacy, usage.ri_cpu_time_qos_background,
               usage.ri_cpu_time_qos_default, usage.ri_cpu_time_qos_utility, usage.ri_cpu_time_qos_user_initiated,
               usage.ri_cpu_time_qos_user_interactive);
        for (int t = 0; t < n; t++) {
            struct proc_threadinfo info = {0};
            if (proc_pidinfo(pid, PROC_PIDTHREADID64INFO, ids[t], &info, sizeof(info)) != sizeof(info) ||
                proc_pidinfo(pid, thread_counts, ids[t], counts, count_size) != count_size ||
                counts->length != levels) continue;
            info.pth_name[sizeof(info.pth_name) - 1] = '\0';
            printf("%s{\"id\":%" PRIu64 ",\"group\":\"%s\",\"state\":%d,\"priority\":%d,"
                   "\"base_priority\":%d,\"policy\":%d,\"max_priority\":%d,\"cpu_usage\":%d,\"level_cpu_ticks\":[",
                   seen++ ? "," : "", ids[t], thread_group(info.pth_name), info.pth_run_state,
                   info.pth_curpri, info.pth_priority, info.pth_policy, info.pth_maxpriority, info.pth_cpu_usage);
            for (uint32_t level = 0; level < levels; level++) {
                const struct level_counts *c = &counts->levels[level];
                printf("%s%" PRIu64, level ? "," : "", c->user_ticks + c->system_ticks);
            }
            fputs("]}", stdout);
        }
        printf("],\"skipped_threads\":%d}\n", n - seen);
        if (!seen || fflush(stdout)) {
            fprintf(stderr, "No usable thread sample or output unavailable\n");
            goto done;
        }
        if (i + 1 < samples) {
            struct timespec delay = {.tv_sec = interval_ms / 1000, .tv_nsec = (interval_ms % 1000) * 1000000L};
            while (nanosleep(&delay, &delay) && errno == EINTR) {}
        }
    }
    status = 0;
done:
    free(counts);
    free(ids);
    return status;
}

int main(int argc, char **argv) {
    int pid = argc >= 2 ? positive(argv[1]) : 0;
    int samples = argc >= 3 ? positive(argv[2]) : 0;
    int interval = argc == 4 ? positive(argv[3]) : 10;
    if ((argc != 3 && argc != 4) || !pid || !samples || !interval) {
        fprintf(stderr, "usage: %s PID SAMPLES [INTERVAL_MS]\n", argv[0]);
        return 2;
    }
    return trace(pid, samples, interval);
}
