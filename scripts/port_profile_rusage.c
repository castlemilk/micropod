// Sample one identified macOS process before and after a fixed amount of work.
#include <libproc.h>
#include <errno.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

int main(int argc, char **argv) {
    if (argc != 2 && argc != 3) return 2;
    char *end;
    long pid = strtol(argv[1], &end, 10);
    if (*end || pid <= 0 || pid > INT_MAX) return 2;
    unsigned long long expected_start = 0;
    if (argc == 3) {
        errno = 0;
        expected_start = strtoull(argv[2], &end, 10);
        if (errno || *end || *argv[2] < '0' || *argv[2] > '9' || !expected_start) return 2;
    }
    struct rusage_info_v4 r = {0};
    mach_timebase_info_data_t scale;
    if (mach_timebase_info(&scale) != KERN_SUCCESS ||
        proc_pid_rusage((int)pid, RUSAGE_INFO_V4, (rusage_info_t *)&r) != 0) {
        perror("read macOS process usage");
        return 1;
    }
    if (!r.ri_proc_start_abstime || (expected_start && r.ri_proc_start_abstime != expected_start)) {
        fprintf(stderr, "Cannot match process start for pid %ld\n", pid);
        return 1;
    }
    // Keep absolute ticks and the conversion factor together. CPU nanoseconds
    // are (after - before) * numer / denom, including on Apple Silicon.
    printf("{\"pid\":%ld,\"start_ticks\":%llu,\"sample_ticks\":%llu,"
           "\"user_ticks\":%llu,\"system_ticks\":%llu,\"numer\":%u,\"denom\":%u,"
           "\"interrupt_wakeups\":%llu,\"resident_bytes\":%llu,"
           "\"phys_footprint_bytes\":%llu,\"lifetime_max_phys_footprint_bytes\":%llu,"
           "\"instructions\":%llu,\"cycles\":%llu}\n",
           pid, r.ri_proc_start_abstime, mach_absolute_time(), r.ri_user_time, r.ri_system_time,
           scale.numer, scale.denom, r.ri_interrupt_wkups, r.ri_resident_size, r.ri_phys_footprint,
           r.ri_lifetime_max_phys_footprint, r.ri_instructions, r.ri_cycles);
    return 0;
}
