#include <stdint.h>

struct scheduled_thread {
    uint64_t tid;
    unsigned qos;
    int base, current;
};
struct scheduled_thread observe_thread(void);
void run_on_pthread(unsigned qos, void (*body)(void *), void *context);
