// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// Minimal bare-metal startup for RVV examples running under Spike.
// =============================================================================
// The vector unit powers up DISABLED. mstatus.VS[10:9] = 00 (Off) means every
// vector instruction -- including vsetvli -- traps as an illegal instruction,
// and a bare-metal program with no trap handler will simply hang.
// Enabling it is the first thing this file does. See Book Ch 4 section 4.1.
//
// There is no console here on purpose: Spike bare-metal runs are used for
// instruction counting and trace capture, where I/O would pollute the count.
// A test reports pass/fail through main()'s return value, which becomes the
// Spike exit code. For printf-style examples, use QEMU user mode instead
// (see the Makefile's `run-qemu` target).
// =============================================================================

.section .text.init
.globl _start
_start:
    li      t0, (1 << 9) | (1 << 13)   // mstatus.VS = Initial, mstatus.FS = Initial
    csrs    mstatus, t0

    la      sp, _stack_top
    call    main

    // HTIF exit protocol: writing (code << 1) | 1 to tohost terminates Spike
    // with that exit code. main() returning 0 therefore exits cleanly.
    slli    a0, a0, 1
    ori     a0, a0, 1
    la      t0, tohost
    sd      a0, 0(t0)
1:  j       1b

.section .data
.align 6
.globl tohost
tohost:   .dword 0
.align 6
.globl fromhost
fromhost: .dword 0

.section .bss
.align 4
.space 8192
_stack_top:
