// Fixed-work policy qualification on a disposable Darwin pthread.
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <pthread/qos.h>
#define main original_filter_fixture
#include "filter_work.c"
#undef main

struct sample { int shares, default_policy, basic_policy, qos, base, current; };

static struct sample read_owner_policy(void) {
    thread_t t = pthread_mach_thread_np(pthread_self());
    thread_extended_policy_data_t e = {0};
    thread_basic_info_data_t b = {0};
    thread_extended_info_data_t i = {0};
    mach_msg_type_number_t n = THREAD_EXTENDED_POLICY_COUNT;
    boolean_t defaults = FALSE;
    check(thread_policy_get(t, THREAD_EXTENDED_POLICY, (thread_policy_t)&e, &n, &defaults) == KERN_SUCCESS, "policy get");
    n = THREAD_BASIC_INFO_COUNT;
    check(thread_info(t, THREAD_BASIC_INFO, (thread_info_t)&b, &n) == KERN_SUCCESS, "basic info");
    n = THREAD_EXTENDED_INFO_COUNT;
    check(thread_info(t, THREAD_EXTENDED_INFO, (thread_info_t)&i, &n) == KERN_SUCCESS, "extended info");
    return (struct sample){e.timeshare, defaults, b.policy, qos_class_self(), i.pth_priority, i.pth_curpri};
}

static void emit(const char *name, struct sample s) {
    printf(",\"%s\":{\"timeshare\":%d,\"get_default\":%d,\"basic_policy\":%d,\"qos\":%d,\"base_pri\":%d,\"current_pri\":%d}",
           name,s.shares,s.default_policy,s.basic_policy,s.qos,s.base,s.current);
}
struct attempt { int block, pos, fixed; kern_return_t status; };

static void *run(void *context) {
    struct attempt *a = context;
    struct sample initial = read_owner_policy();
    if (a->fixed) {
        thread_extended_policy_data_t request = {.timeshare = FALSE};
        a->status = thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_EXTENDED_POLICY,
                                      (thread_policy_t)&request, THREAD_EXTENDED_POLICY_COUNT);
    }
    struct sample start = read_owner_policy();
    int bytes = 0, completed = 0;
    if (a->status == KERN_SUCCESS) {
        mp_tcp_relay *owner = mp_tcp_relay_create_data("127.0.0.1");
        check(owner != NULL, "private owner");
        mp_tcp_listener *lease = new_listener(owner, 8080, 0);
        check(lease != NULL, "staged lease");
        for (int stream = 0; stream < 8; stream++) {
            int c[2], g[2]; stage(lease,c,g); drain(owner);
            unsigned char buf[4096], response = (unsigned char)(stream+3), one;
            for (size_t j=0; j<sizeof(buf); j++) buf[j]=(unsigned char)(stream+j);
            check(write(g[0],buf,sizeof(buf))==sizeof(buf) && shutdown(g[0],SHUT_WR)==0, "guest payload and FIN");
            drain(owner); expect_bytes(c[0],buf,sizeof(buf)); check(read(c[0],&one,1)==0,"forward FIN");
            check(write(c[0],&response,1)==1 && shutdown(c[0],SHUT_WR)==0, "reverse marker and FIN");
            drain(owner); expect_bytes(g[0],&response,1); check(read(g[0],&one,1)==0 && lease->active==0,"reverse FIN and retire");
            close(c[0]); close(g[0]); bytes+=sizeof(buf)+1; completed++;
        }
        mp_tcp_release(lease,NULL); mp_tcp_relay_destroy(owner);
    }
    struct sample end = read_owner_policy();
    printf("{\"pair\":%d,\"position\":%d,\"fixed_requested\":%d,\"set_status\":%d,\"verified_bytes\":%d,\"retired_flows\":%d",a->block,a->pos,a->fixed,a->status,bytes,completed);
    emit("initial",initial); emit("start",start); emit("end",end); puts("}"); return NULL;
}
int main(void) {
    const char first[]="ABBABAAB"; // Four blocks in each order.
    for (int i=0;i<8;i++) for (int pos=0;pos<2;pos++) {
        struct attempt a={i+1,pos+1,(first[i]=='B')^pos,KERN_SUCCESS};
        pthread_attr_t attr; pthread_t thread;
        check(pthread_attr_init(&attr)==0 && pthread_attr_set_qos_class_np(&attr,QOS_CLASS_USER_INITIATED,0)==0,"new pthread at relay QoS");
        check(pthread_create(&thread,&attr,run,&a)==0 && pthread_attr_destroy(&attr)==0 && pthread_join(thread,NULL)==0,"run policy cell");
        if (a.status!=KERN_SUCCESS) return 0; // Retain the first unsupported request without retrying it.
    }
    return 0;
}
