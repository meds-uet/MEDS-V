// Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
//
// Vector SAXPY using RVV intrinsics. This is the canonical stripmine loop:
// no remainder handling, no hard-coded vector width, and the SAME BINARY runs
// at full efficiency on any VLEN. See Book Ch 7.
#include <riscv_vector.h>

void saxpy_rvv(unsigned long n, float a, const float *x, float *y) {
    for (unsigned long vl; n > 0; n -= vl, x += vl, y += vl) {
        vl = __riscv_vsetvl_e32m1(n);                       // how many this pass?
        vfloat32m1_t vx = __riscv_vle32_v_f32m1(x, vl);
        vfloat32m1_t vy = __riscv_vle32_v_f32m1(y, vl);
        vy = __riscv_vfmacc_vf_f32m1(vy, a, vx, vl);        // vy += a * vx
        __riscv_vse32_v_f32m1(y, vy, vl);
    }
}
