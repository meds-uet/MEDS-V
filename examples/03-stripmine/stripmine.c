// Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
//
// Example 03 -- Vector-length agnosticism, made visible.
//
// This program prints the vl chosen on every pass of a stripmine loop, plus the
// machine's VLEN read from the vlenb CSR. Run the SAME BINARY at several VLENs
// and watch the loop restructure itself. See Book Ch 7.
//
// Run:  make run        (QEMU user mode -- has printf)
//       make run-all    (the same ELF at VLEN = 128, 256, 512)
#include <stdio.h>
#include <riscv_vector.h>

#define N 20
static float x[N], y[N];

int main(void) {
    unsigned long vlenb;
    asm volatile ("csrr %0, vlenb" : "=r"(vlenb));
    printf("VLEN = %lu bits (vlenb = %lu bytes)\n", vlenb * 8, vlenb);
    printf("SEW = 32, LMUL = 1  =>  VLMAX = %lu elements\n\n", vlenb * 8 / 32);

    for (int i = 0; i < N; i++) { x[i] = (float)i; y[i] = 100.0f; }

    const float *px = x;
    float       *py = y;
    unsigned long n = N;
    int pass = 0;

    printf("  pass   AVL    vl   elements processed\n");
    printf("  ----  ----  ----   -------------------\n");

    for (unsigned long vl; n > 0; n -= vl, px += vl, py += vl) {
        vl = __riscv_vsetvl_e32m1(n);
        printf("  %4d  %4lu  %4lu   [%2d .. %2d]\n",
               pass++, n, vl, N - (int)n, N - (int)n + (int)vl - 1);

        vfloat32m1_t vx = __riscv_vle32_v_f32m1(px, vl);
        vfloat32m1_t vy = __riscv_vle32_v_f32m1(py, vl);
        __riscv_vse32_v_f32m1(py, __riscv_vfmacc_vf_f32m1(vy, 2.0f, vx, vl), vl);
    }

    printf("\n  %d passes for %d elements\n", pass, N);
    printf("  result: y[0] = %.1f  y[%d] = %.1f  (expect 100.0 and %.1f)\n",
           y[0], N - 1, y[N - 1], 100.0f + 2.0f * (N - 1));

    for (int i = 0; i < N; i++)
        if (y[i] != 100.0f + 2.0f * i) { printf("  MISMATCH at %d\n", i); return 1; }
    printf("  all %d elements correct\n", N);
    return 0;
}
