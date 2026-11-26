// SPDX-License-Identifier: GPL-2.0
// Replay only the global flow lookup and its hash-steering fallback.
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t u32;
struct rps_sock_flow_table { u32 ent; };
struct table_tag { struct rps_sock_flow_table *table; u32 mask; };
struct cpu_map { u32 len, cpus[4]; };
static const struct { u32 rps_cpu_mask; } net_hotdata = {3};

#define READ_ONCE(x) (x)
#define rps_tag_to_table(tag) ((tag)->table)
#define rps_tag_to_mask(tag) ((tag)->mask)
#define reciprocal_scale(hash, len) ((u32)(((uint64_t)(hash) * (len)) >> 32))
#define cpu_online(cpu_id) ((cpu_id) < 4)

struct lookup { u32 cpu; int matched; };

static struct lookup select_reader(struct table_tag *global_tag_ptr, u32 hash)
{
    struct rps_sock_flow_table *sock_flow_table;
    u32 flow_id, ident, next_cpu, tcpu;
    int cpu = -1;
    struct cpu_map cpus = {.len = 4, .cpus = {0, 1, 2, 3}};
    struct cpu_map *map = &cpus;

#include "global-lookup.inc"
    return (struct lookup){next_cpu, 1};
#include "fallback.inc"
}

int main(void)
{
    enum { bulk = 32, fresh = 240 };
    u32 hashes[bulk + fresh];
    while (scanf("%" SCNu32, &hashes[0]) == 1) {
        for (int i = 1; i < bulk + fresh; i++)
            if (scanf("%" SCNu32, &hashes[i]) != 1) return 2;
        for (u32 entries = 32768; entries <= 65536; entries *= 2) {
            struct table_tag tag = {.table = calloc(entries, sizeof(*tag.table)), .mask = entries - 1};
            if (!tag.table) return 3;
            for (int i = 0; i < bulk + fresh; i++) {
                // Give each socket a known last-reader CPU and overwrite previous slot owners.
                tag.table[hashes[i] & tag.mask].ent = (hashes[i] & ~3U) | ((u32)i % 4);
            }
            u32 missed = 0, other_cpu = 0;
            for (int i = 0; i < bulk; i++) {
                struct lookup result = select_reader(&tag, hashes[i]);
                if (!result.matched) missed |= UINT32_C(1) << i;
                if (result.cpu != (u32)i % 4) other_cpu |= UINT32_C(1) << i;
            }
            printf("%08" PRIx32 " %08" PRIx32 " ", missed, other_cpu);
            free(tag.table);
        }
        putchar('\n');
    }
    return ferror(stdin) ? 4 : 0;
}
