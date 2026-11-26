#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <libproc.h>
#include <sys/resource.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>

enum { SHORTS = 12, BLOCK = 32768, HISTORY = 262144 };
static bool adaptive;
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
struct endpoint;
static struct endpoint *marked[SHORTS], *bulk_endpoint;
static uint64_t raised_ns[SHORTS], demoted_ns[SHORTS];
static void record_timer(struct endpoint *e, bool raising) {
    if (e == bulk_endpoint) return;
    for (int i = 0; i < SHORTS; i++) if (marked[i] == e) {
        if (raising) raised_ns[i] = now_ns(); else demoted_ns[i] = now_ns();
        return;
    }
}
static int loopback_pair(int domain, int type, int proto, int out[2]);
#define socketpair loopback_pair
#define RELAY_SOURCE "adaptive-prototype.c"
#define main unused_filter_main
#include "filter_work.c"
#undef main
#undef socketpair

static int loopback_pair(int domain, int type, int proto, int out[2]) {
    (void)domain;
    int ls = socket(AF_INET,type,proto);
    struct sockaddr_in addr = {.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    socklen_t len = sizeof(addr);
    check(ls>=0 && !bind(ls,(void *)&addr,len) && !listen(ls,1) &&
          !getsockname(ls,(void *)&addr,&len),"loopback listen");
    out[0] = socket(AF_INET,type,proto);
    check(out[0]>=0 && !connect(out[0],(void *)&addr,len),"loopback connect");
    out[1] = accept(ls,NULL,NULL);
    close(ls);
    int yes = 1;
    for (int i=0;i<2;i++) check(out[i]>=0 &&
        !setsockopt(out[i],IPPROTO_TCP,TCP_NODELAY,&yes,sizeof(yes)),"TCP_NODELAY");
    return 0;
}

struct flow { int rx,tx; };
static struct flow bulk, shorts[SHORTS];
static const unsigned char tiny[] = "0123456789abcdef";
static unsigned char pattern[BLOCK];
static _Atomic bool stop_writer;
static uint64_t score_start, score_end, bulk_sent, bulk_received, bulk_scored;
static uint64_t short_sent[SHORTS], short_received[SHORTS], warm_bytes[SHORTS];
static _Atomic unsigned effective_qos, callbacks, qos_mismatch;

static void until(uint64_t deadline) {
    for (;;) {
        uint64_t n=now_ns(); if (n>=deadline) return;
        uint64_t left=deadline-n;
        struct timespec ts={.tv_sec=(time_t)(left/1000000000),.tv_nsec=(long)(left%1000000000)};
        nanosleep(&ts,NULL);
    }
}
static void send_all(int fd,const unsigned char *buf,size_t n) {
    size_t used=0;
    while(used<n) {
        ssize_t k=write(fd,buf+used,n-used);
        if (k<0 && errno==EINTR) continue;
        check(k>0,"write required bytes"); used+=(size_t)k;
    }
}
static void receive_pattern(int fd, uint64_t n) {
    unsigned char b[BLOCK]; uint64_t at=0;
    while(at<n) {
        ssize_t k=read(fd,b,n-at<sizeof(b)?(size_t)(n-at):sizeof(b));
        if(k<0 && errno==EINTR) continue;
        check(k>0,"seed delivery");
        for(ssize_t j=0;j<k;j++) check(b[j]==pattern[(at+j)%BLOCK],"seed byte mismatch");
        at+=k;
    }
}
static void *write_bulk(void *unused) {
    (void)unused;
    while(!atomic_load(&stop_writer)) {send_all(bulk.tx,pattern,sizeof(pattern)); bulk_sent+=sizeof(pattern);}
    check(!shutdown(bulk.tx,SHUT_WR),"bulk half-close"); return NULL;
}
static void *read_bulk(void *unused) {
    (void)unused;
    unsigned char b[BLOCK];
    for (;;) {
        ssize_t k=read(bulk.rx,b,sizeof(b));
        if(k<0 && errno==EINTR) continue;
        check(k>=0,"bulk read"); if(!k)break;
        uint64_t t=now_ns(); size_t off=bulk_received%BLOCK, first=(size_t)k;
        if(first>BLOCK-off)first=BLOCK-off;
        check(!memcmp(b,pattern+off,first) && !memcmp(b+first,pattern,(size_t)k-first),"bulk data mismatch");
        if(t>=score_start && t<score_end)bulk_scored+=k;
        bulk_received+=k;
    }
    return NULL;
}
static void *short_replies(void *unused) {
    (void)unused;
    for(int i=0;i<SHORTS;i++) {
        until(score_start+(uint64_t)(i+1)*30000000);
        for(int block=0;block<HISTORY/BLOCK;block++)send_all(shorts[i].tx,pattern,BLOCK);
        receive_pattern(shorts[i].rx,HISTORY); warm_bytes[i]=HISTORY;
        short_sent[i]=now_ns();
        send_all(shorts[i].tx,tiny,sizeof(tiny));
        unsigned char received[sizeof(tiny)]; size_t got=0;
        while(got<sizeof(tiny)) {
            ssize_t n=read(shorts[i].rx,received+got,sizeof(tiny)-got);
            if(n<0 && errno==EINTR)continue;
            check(n>0,"open tail delivery");got+=n;
        }
        short_received[i]=now_ns();
        check(!memcmp(received,tiny,sizeof(tiny)),"open tail marker");
    }
    return NULL;
}

static struct flow install(mp_tcp_listener *listener,int index) {
    int client[2],guest[2],size=512*1024;
    struct pair *pair=stage(listener,client,guest);
    if(index>=0)marked[index]=&pair->guest; else bulk_endpoint=&pair->guest;
    for(int i=0;i<2;i++) {
        int fds[]={guest[i],client[i]};
        for(int j=0;j<2;j++) check(!setsockopt(fds[j],SOL_SOCKET,SO_SNDBUF,&size,sizeof(size)) &&
                                 !setsockopt(fds[j],SOL_SOCKET,SO_RCVBUF,&size,sizeof(size)),"TCP buffers");
    }
    check(!fcntl(guest[0],F_SETFL,0) && !fcntl(client[0],F_SETFL,0),"external blocking sockets");
    return (struct flow){.rx=client[0],.tx=guest[0]};
}
static void wake(void *ctx) {
    unsigned q=qos_class_self();
    atomic_store(&effective_qos,q); atomic_fetch_add(&callbacks,1);
    if(q!=QOS_CLASS_USER_INITIATED)atomic_fetch_add(&qos_mismatch,1);
    mp_tcp_relay_drain(ctx,2);
}
static void barrier(void *unused){(void)unused;}

int main(int argc,char **argv) {
    bool preflight = argc == 3 && strcmp(argv[2], "--preflight") == 0;
    check(argc == 2 || preflight,"expected adaptive 1/0 [--preflight]"); adaptive=atoi(argv[1])==1;
    signal(SIGPIPE,SIG_IGN);alarm(8);
    for(int i=0;i<BLOCK;i++)pattern[i]=(unsigned char)(193*i+i/257);
    mp_tcp_relay *relay=mp_tcp_relay_create_data("127.0.0.1");
    check(relay!=NULL,"data owner");
    mp_tcp_listener *listener=new_listener(relay,8080,0);
    check(listener!=NULL,"listener record");
    bulk=install(listener,-1);
    for(int i=0;i<SHORTS;i++)shorts[i]=install(listener,i);
    drain(relay);
    dispatch_queue_attr_t attr=dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0);
    dispatch_queue_t queue=dispatch_queue_create("dev.micropod.published-tcp.diagnostic",attr);
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,relay->kq,0,queue);
    dispatch_set_context(source,relay);
    dispatch_source_set_event_handler_f(source,wake);
    dispatch_resume(source);
    if (preflight) {
        send_all(shorts[0].tx,pattern,17);
        receive_pattern(shorts[0].rx,17);
        dispatch_sync_f(queue,NULL,barrier);
        check(atomic_load(&callbacks) && atomic_load(&qos_mismatch)==0,"effective queue QoS");
        printf("{\"preflight\":true,\"sent\":17,\"received_verified\":17,\"qos\":%u}\n",atomic_load(&effective_qos));
        return 0;
    }
    score_start=now_ns()+40000000; score_end=score_start+900000000;
    pthread_t writer,reader,probe;
    check(!pthread_create(&reader,NULL,read_bulk,NULL),"start receiver");
    check(!pthread_create(&writer,NULL,write_bulk,NULL),"start producer");
    check(!pthread_create(&probe,NULL,short_replies,NULL),"start marker probe");
    struct rusage_info_v4 start={0},end={0};
    until(score_start);
    uint64_t counter_open=now_ns();
    check(!proc_pid_rusage(getpid(),RUSAGE_INFO_V4,(rusage_info_t *)&start),"opening CPU");
    until(score_end);
    check(!proc_pid_rusage(getpid(),RUSAGE_INFO_V4,(rusage_info_t *)&end),"closing CPU");
    uint64_t counter_close=now_ns();
    atomic_store(&stop_writer,true);
    pthread_join(writer,NULL); pthread_join(reader,NULL); pthread_join(probe,NULL);
    dispatch_source_cancel(source);dispatch_sync_f(queue,NULL,barrier);
    check(bulk_sent==bulk_received && bulk_scored && atomic_load(&callbacks),"bulk delivery or callbacks");
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    printf("{\"adaptive\":%d,\"score_start_ns\":%llu,\"score_end_ns\":%llu,\"counter_open_ns\":%llu,\"counter_close_ns\":%llu,\"bulk_sent\":%llu,\"bulk_received\":%llu,\"bulk_window_bytes\":%llu,\"effective_qos_class\":%u,\"required_qos_class\":%u,\"qos_mismatches\":%u,\"callbacks\":%u,\"cpu_ticks\":%llu,\"runnable_ticks\":%llu,\"timebase\":[%u,%u],\"tails\":[",
           adaptive,score_start,score_end,counter_open,counter_close,bulk_sent,bulk_received,bulk_scored,
           atomic_load(&effective_qos),QOS_CLASS_USER_INITIATED,atomic_load(&qos_mismatch),atomic_load(&callbacks),
           end.ri_user_time-start.ri_user_time+end.ri_system_time-start.ri_system_time,end.ri_runnable_time-start.ri_runnable_time,
           tb.numer,tb.denom);
    for(int i=0;i<SHORTS;i++)printf("%s{\"seed_bytes\":%llu,\"marked_bytes\":%zu,\"sent_ns\":%llu,\"received_ns\":%llu,\"timer_armed_ns\":%llu,\"timer_serviced_ns\":%llu}",i?",":"",warm_bytes[i],sizeof(tiny),short_sent[i],short_received[i],raised_ns[i],demoted_ns[i]);
    puts("]}");return 0;
}
