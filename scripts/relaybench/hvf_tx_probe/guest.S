// Arm64 guest entry. x0 is the descriptor page, x1 the doorbell, x2 the
// total descriptor count and x3 the maximum descriptors per notification.
.text
.p2align 2
.globl _mp_tx_guest_begin
_mp_tx_guest_begin:
    // Use the top of the descriptor page for the bare-metal guest stack.
    add x5, x0, #4, lsl #12
    mov sp, x5
    adr x4, Lmmio
    bl Lproduce
    brk #0

// C ABI shared by the bare-metal guest and the native functional control.
// x4 selects a synchronous notification callback with (context, count, page).
.globl _mp_tx_produce
_mp_tx_produce:
Lproduce:
    stp x19, x20, [sp, #-64]!
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    str x30, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, #0
    mov x24, x4
Lnext_batch:
    sub x1, x21, x23
    cmp x1, x22
    csel x1, x1, x22, lo
    mov x4, #0
Lslot:
    add x23, x23, #1
    str x23, [x19, x4, lsl #3]
    add x4, x4, #1
    cmp x4, x1
    b.lo Lslot
    dmb ishst
    mov x0, x20
    mov x2, x19
    blr x24
    cbnz w0, Lreturn
    cmp x23, x21
    b.lo Lnext_batch
    mov x0, x20
    mov x1, #0
    mov x2, x19
    blr x24
Lreturn:
    ldr x30, [sp, #48]
    ldp x23, x24, [sp, #32]
    ldp x21, x22, [sp, #16]
    ldp x19, x20, [sp], #64
    ret
Lmmio:
    cbz x1, Lcomplete
    str w1, [x0]
    mov w0, #0
    ret
Lcomplete:
    str wzr, [x0, #4]
    mov w0, #0
    ret
.globl _mp_tx_guest_end
_mp_tx_guest_end:
