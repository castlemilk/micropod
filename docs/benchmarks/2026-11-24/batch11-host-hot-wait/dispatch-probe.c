#include "PublishedTCP.h"
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <stdio.h>
int main(int argc,char **argv){
    if(argc!=3)return 2;
    mp_tcp_relay *r=mp_tcp_relay_create(argv[1]); if(!r){perror("create");return 1;}
    uint16_t port=0; if(!mp_tcp_listen(r,0,atoi(argv[2]),&port,0)){perror("listen");return 1;}
    dispatch_queue_t q=dispatch_queue_create("mp.profile",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    dispatch_source_t s=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,mp_tcp_relay_descriptor(r),0,q);
    dispatch_source_set_event_handler(s,^{mp_tcp_relay_drain(r);});dispatch_resume(s);
    printf("127.0.0.1:%d\n",port);fflush(stdout);dispatch_main();
}
