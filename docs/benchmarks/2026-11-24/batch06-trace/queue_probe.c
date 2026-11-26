#include "queue_probe.h"

#include <assert.h>
#include <mach/mach.h>
#include <pthread.h>
#include <pthread/qos.h>

struct scheduled_thread observe_thread(void) {
    thread_extended_info_data_t info = {0};
    mach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
    assert(thread_info(pthread_mach_thread_np(pthread_self()), THREAD_EXTENDED_INFO,
                       (thread_info_t)&info, &count) == KERN_SUCCESS);
    uint64_t tid;
    assert(pthread_threadid_np(NULL, &tid) == 0);
    return (struct scheduled_thread){tid, qos_class_self(), info.pth_priority, info.pth_curpri};
}

struct call { void (*body)(void *); void *context; };
static void *invoke(void *opaque) {
    struct call *call = opaque;
    call->body(call->context);
    return NULL;
}

void run_on_pthread(unsigned qos, void (*body)(void *), void *context) {
    struct call call = {body, context};
    pthread_attr_t attr;
    pthread_t thread;
    assert(pthread_attr_init(&attr) == 0);
    assert(pthread_attr_set_qos_class_np(&attr, (qos_class_t)qos, 0) == 0);
    assert(pthread_create(&thread, &attr, invoke, &call) == 0);
    assert(pthread_attr_destroy(&attr) == 0);
    assert(pthread_join(thread, NULL) == 0);
}
