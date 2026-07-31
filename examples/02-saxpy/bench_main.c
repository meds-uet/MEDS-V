// Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
//
// Bare-metal benchmark harness. Built three ways so the harness cost can be
// subtracted from the kernel cost:
//   -DKERNEL=0  no kernel  (baseline: array init only)
//   -DKERNEL=1  scalar SAXPY
//   -DKERNEL=2  vector SAXPY
// Each variant must be built with the SAME -march, or the auto-vectorised
// init loop will differ and the subtraction will be wrong. (We learned this
// the hard way -- see Book Ch 15 section 15.3.)
#ifndef N
#define N 1024
#endif
#ifndef KERNEL
#define KERNEL 0
#endif

float x[N], y[N];

void saxpy_scalar(unsigned long n, float a, const float *x, float *y);
void saxpy_rvv   (unsigned long n, float a, const float *x, float *y);

int main(void) {
    for (int i = 0; i < N; i++) { x[i] = 1.0f; y[i] = 2.0f; }

#if   KERNEL == 1
    saxpy_scalar(N, 3.0f, x, y);
#define EXPECT 5.0f          // 3*1 + 2
#elif KERNEL == 2
    saxpy_rvv(N, 3.0f, x, y);
#define EXPECT 5.0f
#else
#define EXPECT 2.0f          // baseline: y untouched
#endif

    // The self-check runs in ALL THREE builds, including the baseline, so its
    // cost cancels in the subtraction. Leaving it out of the baseline only
    // would charge the check loop to the kernel and understate the speedup.
    for (int i = 0; i < N; i++)
        if (y[i] != EXPECT) return 1;

    return 0;
}
