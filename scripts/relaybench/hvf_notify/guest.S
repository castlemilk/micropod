// EL1 producer. Both arms publish the same bytes, wait for a host acknowledgement
// and use the same exit count. x4 selects MMIO (0) or an explicit hypercall (1).
// x0: shared page, x1: doorbell IPA, x2: descriptor count, x3: max batch.
.text
.p2align 2
.globl _mp_tx_guest_begin
_mp_tx_guest_begin:
    add x7, x0, #64
    add x11, x0, #8
    mov x6, #0
Lbatch:
    sub x8, x2, x6
    cmp x8, x3
    csel x8, x8, x3, lo
    mov x9, #0
Ldescriptor:
    add x6, x6, #1
    str x6, [x7, x9, lsl #3]
    add x9, x9, #1
    cmp x9, x8
    b.lo Ldescriptor
    stlr x6, [x0]
    cbnz x4, Lhvc
    str wzr, [x1]
    b Lacknowledged
Lhvc:
    hvc #0x41
Lacknowledged:
    ldar x10, [x11]
    cmp x10, x6
    b.ne Lerror
    cmp x6, x2
    b.lo Lbatch
    cbnz x4, Lhvc_complete
    str wzr, [x1, #4]
    b Lerror
Lhvc_complete:
    hvc #0x42
Lerror:
    brk #0
.globl _mp_tx_guest_end
_mp_tx_guest_end:
