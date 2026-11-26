// One EL1 producer. The host grants one private eight-frame slot to each live flow.
// Header: previous sequence, slot index, tenant cookie, grant count, published sequence.
.text
.p2align 2
.globl _mp_tx_guest_begin
_mp_tx_guest_begin:
    add x11, x0, #32
    mov x13, #0x0101010101010101
    cbz x3, Lgrant
    cmp x3, #2
    b.ne Ltable
    mrs x15, cpacr_el1
    orr x15, x15, #(3 << 20)
    msr cpacr_el1, x15
    isb
// Count and completion occupy the first 16 bytes. Each 40-byte descriptor
// carries slot, prior sequence, cookie, frame count, and the guest's last sequence.
Ltable:
    ldar x19, [x0]
    cbz x19, Ldone
    cmp x19, #32
    b.hi Lerror
    mov x21, x19
    add x20, x0, #16
Ldescriptor:
    ldp x7, x6, [x20]
    ldp x9, x10, [x20, #16]
    bl Lproduce
    str x6, [x20, #32]
    add x20, x20, #40
    subs x21, x21, #1
    b.ne Ldescriptor
    add x16, x0, #8
    stlr x19, [x16]
    hvc #0x41
    b Ltable
Lgrant:
    ldar x6, [x0]
    ldp x7, x9, [x0, #8]
    ldr x10, [x0, #24]
    cbz x10, Ldone
    bl Lproduce
    stlr x6, [x11]
    hvc #0x41
    b Lgrant
Lproduce:
    cmp x7, #32
    b.hs Lerror
    cbz x10, Lerror
    cmp x10, #8
    b.hi Lerror
    add x8, x0, #4, lsl #12
    add x8, x8, x7, lsl #19
Lframe:
    add x6, x6, #1
    add x15, x6, x9
    and x15, x15, #255
    mul x15, x15, x13
    mov x14, x8
    add x17, x8, #16, lsl #12
    cmp x3, #2
    b.eq Lneon
Lfill:
    stp x15, x15, [x14], #16
    stp x15, x15, [x14], #16
    stp x15, x15, [x14], #16
    stp x15, x15, [x14], #16
    cmp x14, x17
    b.lo Lfill
    b Lheader
Lneon:
    dup v0.16b, w15
Lwide:
    stp q0, q0, [x14], #32
    stp q0, q0, [x14], #32
    cmp x14, x17
    b.lo Lwide
Lheader:
    stp x6, x9, [x8]
    mov x8, x17
    subs x10, x10, #1
    b.ne Lframe
    ret
Ldone:
    hvc #0x42
Lerror:
    brk #0
.globl _mp_tx_guest_end
_mp_tx_guest_end:
