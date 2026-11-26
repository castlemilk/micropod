#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint16_t u16;
typedef uint16_t __u16;
enum { RING = 256, VRING_PACKED_EVENT_F_WRAP_CTR = 15,
       VRING_PACKED_EVENT_FLAG_ENABLE = 0, VRING_PACKED_EVENT_FLAG_DISABLE = 1,
       VRING_PACKED_EVENT_FLAG_DESC = 2, VRING_PACKED_DESC_F_AVAIL = 7, VRING_PACKED_DESC_F_USED = 15 };
struct event { u16 off_wrap, flags; };
struct descriptor { u16 flags; };
struct vring_virtqueue {
    bool event, weak_barriers;
    u16 last_used_idx;
    struct { unsigned int num_free; } vq;
    struct {
        u16 event_flags_shadow;
        struct { u16 num; struct descriptor desc[RING]; struct event *driver; } vring;
    } packed;
};
#define cpu_to_le16(x) (x)
#define le16_to_cpu(x) (x)
#define READ_ONCE(x) (x)
#define START_USE(v) ((void)(v))
#define END_USE(v) ((void)(v))
#define virtio_wmb(x) ((void)(x))
#define virtio_mb(x) ((void)(x))

#include "linux_functions.inc"

static u16 offset(int absolute) {
    return (absolute % RING) | (((absolute / RING) % 2) << VRING_PACKED_EVENT_F_WRAP_CTR);
}

static void mark(struct vring_virtqueue *v, int absolute, bool completed) {
    unsigned int wrap = (absolute / RING) % 2;
    v->packed.vring.desc[absolute % RING].flags =
        (wrap << VRING_PACKED_DESC_F_AVAIL) | ((completed ? wrap : !wrap) << VRING_PACKED_DESC_F_USED);
}

static bool arm(struct vring_virtqueue *v, bool immediate) {
    if (!immediate) return virtqueue_enable_cb_delayed_packed(v);
    unsigned int opaque = virtqueue_enable_cb_prepare_packed(v);
    return !virtqueue_poll_packed(v, opaque);
}

/* Single-threaded device model. A requested descriptor event signals once
 * when that descriptor is used. The guest drains every available completion
 * immediately upon that signal. There is no timer or independent poller. */
static void run(int start, int offered, bool immediate) {
    struct event ev = {0};
    struct vring_virtqueue v = {.event=true};
    v.packed.vring.num = RING;
    v.packed.vring.driver = &ev;
    for (int i=0; i<offered; ++i) mark(&v, start+i, false);
    int done=0, notified=0, first=0, sum_wait=0, max_wait=0;
    while (done < offered) {
        v.vq.num_free = RING - (offered-done);
        v.last_used_idx = offset(start+done);
        v.packed.event_flags_shadow = VRING_PACKED_EVENT_FLAG_DISABLE;
        if (!arm(&v, immediate) || ev.flags != VRING_PACKED_EVENT_FLAG_DESC) abort();
        int target=start+done;
        while (target<start+offered && offset(target)!=ev.off_wrap) target++;
        if (target==start+offered) abort();
        int before=done;
        while (done<offered) {
            int old=start+done;
            mark(&v, old, true);
            done++;
            if (vring_need_event((u16)target, (u16)(old+1), (u16)old)) break;
        }
        notified++;
        if (notified==1) first=done;
        int burst=done-before;
        if (burst-1 > max_wait) max_wait=burst-1;
        sum_wait += burst*(burst-1)/2;
        for (int i=before; i<done; ++i)
            if (!virtqueue_poll_packed(&v, offset(start+i))) abort();
    }
    printf("%d %d %d %d %d %d %d %d\n", start, offered, immediate, done, notified, first, max_wait, sum_wait);
}

int main(void) {
    const int sizes[] = {1,4,16,32,128,256};
    const int starts[] = {0,248,504};
    for (unsigned i=0;i<sizeof(sizes)/sizeof(*sizes);i++)
        for (unsigned j=0;j<sizeof(starts)/sizeof(*starts);j++)
            for(int mode=0; mode<2; mode++) run(starts[j],sizes[i],mode);
    return 0;
}
