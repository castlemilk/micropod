#include <libproc.h>
#include <stdint.h>
#include <sys/resource.h>

int relay_energy(int pid, uint64_t *energy, uint64_t *birth) {
    struct rusage_info_v6 usage = {0};
    int status = proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&usage);
    if (status == 0) {
        *energy = usage.ri_energy_nj;
        *birth = usage.ri_proc_start_abstime;
    }
    return status;
}
