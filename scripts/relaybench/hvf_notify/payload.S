// Same producer in both arms. Publish batches of eight 64 KiB buffers from a
// rotating 64-slot ring. Every frame has a unique sequence and a checked body.
.text
.p2align 2
.globl _mp_tx_guest_begin
_mp_tx_guest_begin:
    cmp x3, #8
    b.ne Lerror
    add x11, x0, #8
    add x12, x0, #4, lsl #12
    mov x13, #0x0101010101010101
    mov x6, #0
Lframe:
    and x10, x6, #63
    add x8, x12, x10, lsl #16
    add x6, x6, #1
    and x15, x6, #255
    mul x15, x15, x13
    mov x14, x8
    add x17, x8, #16, lsl #12
Lfill:
    stp x15, x15, [x14], #16
    stp x15, x15, [x14], #16
    stp x15, x15, [x14], #16
    stp x15, x15, [x14], #16
    cmp x14, x17
    b.lo Lfill
    str x6, [x8]
    cmp x6, x2
    b.eq Lnotify
    tst x6, #7
    b.ne Lframe
Lnotify:
    stlr x6, [x0]
    str wzr, [x1]
    ldar x10, [x11]
    cmp x10, x6
    b.ne Lerror
    cmp x6, x2
    b.lo Lframe
    str wzr, [x1, #4]
Lerror:
    brk #0
.globl _mp_tx_guest_end
_mp_tx_guest_end:
