#include <stdint.h>
#include <errno.h>
#include <libproc.h>
#include <sys/resource.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

/* Called by the parent process so access to its own child is sufficient. */
int process_totals(int pid, uint64_t out[5]) {
    struct rusage_info_v6 r = {0};
    mach_timebase_info_data_t t;
    if (mach_timebase_info(&t) != KERN_SUCCESS) return -1;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&r)) return errno ? errno : -2;
    out[0]=r.ri_proc_start_abstime; out[1]=r.ri_user_time+r.ri_system_time;
    out[2]=r.ri_runnable_time; out[3]=t.numer; out[4]=t.denom;
    return 0;
}

int host_cpu(uint32_t out[4]) {
    host_cpu_load_info_data_t val;
    mach_msg_type_number_t count=HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host=mach_host_self();
    kern_return_t status=host_statistics(host,HOST_CPU_LOAD_INFO,(host_info_t)&val,&count);
    mach_port_deallocate(mach_task_self(),host);
    if (status!=KERN_SUCCESS) return status;
    for (int i=0;i<4;i++) out[i]=val.cpu_ticks[i];
    return 0;
}
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <string.h>

int loopback_totals(uint32_t out[5]) {
    struct ifaddrs *all=NULL;
    if(getifaddrs(&all)!=0) return errno;
    int result=-1;
    for(struct ifaddrs *it=all; it; it=it->ifa_next) {
        if (!it->ifa_addr || !it->ifa_data || it->ifa_addr->sa_family!=AF_LINK || strcmp(it->ifa_name,"lo0")) continue;
        struct if_data *d=it->ifa_data;
        out[0]=d->ifi_ipackets;out[1]=d->ifi_opackets;out[2]=d->ifi_ierrors;
        out[3]=d->ifi_oerrors;out[4]=d->ifi_iqdrops;result=0;break;
    }
    freeifaddrs(all);return result;
}
