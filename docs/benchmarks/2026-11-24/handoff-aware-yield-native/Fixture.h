#include "PublishedTCP.h"

mp_tcp_listener *fixture_parent(mp_tcp_relay *owner, int profile);
unsigned fixture_pending(mp_tcp_relay *owner);
int fixture_stage_bulk(mp_tcp_listener *target);
unsigned fixture_productive_callbacks(mp_tcp_relay *owner);
unsigned fixture_largest_callback_bytes(mp_tcp_relay *owner);
void fixture_finish_bulk(mp_tcp_listener *target);
