// Compare the real Darwin TCP notification after a full send buffer has drained.
#include <arpa/inet.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static void check(int ok,const char *op) { if(!ok) err(1,"%s",op); }
static void option(int fd,int level,int key,int value) {
    check(setsockopt(fd,level,key,&value,sizeof(value))==0,"socket option");
}
static int get_int(int fd,int key) {
    int v=0;socklen_t n=sizeof(v);
    check(getsockopt(fd,SOL_SOCKET,key,&v,&n)==0,"read option");
    return v;
}
static void bounded(int fd) {
    struct timeval t={.tv_sec=2};
    check(setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&t,sizeof(t))==0 &&
          setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&t,sizeof(t))==0,"setup watchdog");
    option(fd,IPPROTO_TCP,TCP_NODELAY,1);
}
static void send_bytes(int fd,const unsigned char *data,size_t n) {
    while(n) {ssize_t m=write(fd,data,n);check(m>0,"write");data+=m;n-=(size_t)m;}
}
static void read_byte(int fd,unsigned char expected,size_t n) {
    unsigned char buf[4096];
    while(n) {ssize_t m=read(fd,buf,n<sizeof(buf)?n:sizeof(buf));check(m>0,"read");for(ssize_t i=0;i<m;i++)check(buf[i]==expected,"payload");n-=(size_t)m;}
}
static void arm(int q,int fd,unsigned note,size_t low) {
    struct kevent e;EV_SET(&e,fd,EVFILT_WRITE,EV_ADD|EV_ENABLE,note,(intptr_t)low,NULL);
    check(kevent(q,&e,1,NULL,0,NULL)==0,"register kqueue");
}
static int snapshot(int q,long *space) {
    struct kevent e;struct timespec now={0};
    int n=kevent(q,NULL,0,&e,1,&now);check(n==0 || (n==1 && !(e.flags&(EV_ERROR|EV_EOF))),"snapshot");
    *space=n?(long)e.data:-1;return n;
}
static void attempt(int l,struct sockaddr_in address,int sendbuf,int suffix,int changed,int pair,int order) {
    int c=socket(AF_INET,SOCK_STREAM,0);check(c>=0,"client");
    check(connect(c,(struct sockaddr *)&address,sizeof(address))==0,"connect");
    int s=accept(l,NULL,NULL);check(s>=0,"accept"); bounded(s);bounded(c);
    option(s,SOL_SOCKET,SO_SNDBUF,sendbuf);int actual=get_int(s,SO_SNDBUF);
    int flags=fcntl(s,F_GETFL);check(flags>=0 && fcntl(s,F_SETFL,flags|O_NONBLOCK)==0,"nonblock");
    unsigned char block[4096];memset(block,173,sizeof(block));
    size_t filled=0;
    while(1) {
        ssize_t n=write(s,block,sizeof(block));
        if(n<0){check(errno==EAGAIN||errno==EWOULDBLOCK,"fill EAGAIN");break;}
        check(n>0 && filled<2*1024*1024,"bounded fill");
        filled+=(size_t)n;
    }
    int observed=kqueue(),shadow=kqueue();check(observed>=0&&shadow>=0,"kqueue");
    arm(observed,s,changed?NOTE_LOWAT:0,changed?(size_t)suffix:0);
    arm(shadow,s,0,0);
    long start,free_actual,free_reference;
    int registered_ready=snapshot(observed,&start);
    read_byte(c,173,filled);
    unsigned char ack=71;send_bytes(c,&ack,1);
    check(fcntl(s,F_SETFL,flags)==0,"blocking");read_byte(s,ack,1);
    int queued=get_int(s,SO_NWRITE);
    int shadow_ready=snapshot(shadow,&free_reference);
    int reported=snapshot(observed,&free_actual);
    // Complete the probe even if no event was returned. This checks actual capacity.
    memset(block,223,sizeof(block));
    for(int left=suffix;left>0;left-=(int)sizeof(block)) {
        size_t n=left<(int)sizeof(block)?(size_t)left:sizeof(block);
        send_bytes(s,block,n);read_byte(c,223,n);
    }
    check(shutdown(s,SHUT_WR)==0 && read(c,block,1)==0 && shutdown(c,SHUT_WR)==0 && read(s,block,1)==0,"both FIN");
    printf("{\"pair\":%d,\"order\":%d,\"arm\":\"%s\",\"requested_sendbuf\":%d,\"effective_sendbuf\":%d,"
           "\"pending_bytes\":%d,\"filler_bytes\":%zu,\"ready_at_registration\":%d,\"complete_drain_unsent_bytes\":%d,"
           "\"default_ready\":%d,\"default_available\":%ld,\"tested_ready\":%d,\"tested_available\":%ld,"
           "\"verified_suffix_bytes\":%d,\"dual_fin\":true}\n",
           pair,order,changed?"candidate":"control",sendbuf,actual,suffix,filled,registered_ready,queued,
           shadow_ready,free_reference,reported,free_actual,suffix);
    fflush(stdout);close(observed);close(shadow);close(s);close(c);
}
int main(void) {
    signal(SIGPIPE,SIG_IGN);int l=socket(AF_INET,SOCK_STREAM,0);check(l>=0,"listener");
    option(l,SOL_SOCKET,SO_RCVBUF,32768);
    struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_addr={htonl(INADDR_LOOPBACK)}};
    socklen_t size=sizeof(address);
    check(bind(l,(struct sockaddr*)&address,sizeof(address))==0&&listen(l,4)==0&&getsockname(l,(struct sockaddr*)&address,&size)==0,"private listen");
    const int buffers[]={8192,65536},suffixes[]={4096,32768};
    for(int i=0;i<2;i++)for(int j=0;j<2;j++)for(int pair=0;pair<4;pair++)for(int pos=0;pos<2;pos++)
        attempt(l,address,buffers[i],suffixes[j],(pair%2)^pos,pair,pos);
    close(l);return 0;
}
