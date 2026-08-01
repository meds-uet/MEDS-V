// Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
// Bare-metal benchmark harness for the six kernels, for Spike instruction counts.
//   -DKERNEL=0 baseline (init + check only)   -DVEC=0 scalar / -DVEC=1 vector
// Both builds use the SAME -march so the auto-vectorised harness cancels in the
// subtraction (Book Ch 15 section 15.3).
#include <stdint.h>
#include <stddef.h>
#ifndef NELEM
#define NELEM 1024
#endif
#ifndef TAPS
#define TAPS 8
#endif
#ifndef KERNEL
#define KERNEL 1
#endif
// REPS is the measurement mechanism.  Rather than subtracting a separate
// "baseline" build -- which is fragile, because dead-code elimination and code
// layout differ between builds and the difference lands in the result -- the
// harness is built TWICE with REPS=1 and REPS=2 and the counts subtracted.
// The delta is exactly one kernel invocation, with initialisation, checksum,
// startup and layout identical by construction.  Book Ch 15 section 15.3.
#ifndef REPS
#define REPS 1
#endif
#define BARRIER() asm volatile("" ::: "memory")
#ifndef VEC
#define VEC 0
#endif
#define MM 16
#define KK 16
#define NN 16

static int32_t x[NELEM+TAPS], y[NELEM], h[TAPS];
static int32_t A[MM*KK], B[KK*NN], C[MM*NN];
volatile int32_t sink;

void memcpy32_s(int32_t*,const int32_t*,size_t); void memcpy32_v(int32_t*,const int32_t*,size_t);
void saxpy_s(size_t,int32_t,const int32_t*,int32_t*); void saxpy_v(size_t,int32_t,const int32_t*,int32_t*);
int32_t dotprod_s(const int32_t*,const int32_t*,size_t); int32_t dotprod_v(const int32_t*,const int32_t*,size_t);
void relu_s(int32_t*,const int32_t*,size_t); void relu_v(int32_t*,const int32_t*,size_t);
void fir_s(int32_t*,const int32_t*,const int32_t*,size_t,size_t);
void fir_v(int32_t*,const int32_t*,const int32_t*,size_t,size_t);
void gemm_s(int32_t*,const int32_t*,const int32_t*,size_t,size_t,size_t);
void gemm_v(int32_t*,const int32_t*,const int32_t*,size_t,size_t,size_t);

int main(void) {
    for (int i = 0; i < NELEM+TAPS; i++) x[i] = i - 300;
    for (int i = 0; i < NELEM; i++)      y[i] = 100;
    for (int i = 0; i < TAPS; i++)   h[i] = i + 1;
    for (int i = 0; i < MM*KK; i++)  A[i] = i & 7;
    for (int i = 0; i < KK*NN; i++)  B[i] = i & 5;

    for (int rep = 0; rep < REPS; rep++) {
        BARRIER();
#if   KERNEL == 1
#  if VEC
        memcpy32_v(y, x, NELEM);
#  else
        memcpy32_s(y, x, NELEM);
#  endif
#elif KERNEL == 2
#  if VEC
        saxpy_v(NELEM, 3, x, y);
#  else
        saxpy_s(NELEM, 3, x, y);
#  endif
#elif KERNEL == 3
#  if VEC
        sink = dotprod_v(x, x+1, NELEM);
#  else
        sink = dotprod_s(x, x+1, NELEM);
#  endif
#elif KERNEL == 4
#  if VEC
        relu_v(y, x, NELEM);
#  else
        relu_s(y, x, NELEM);
#  endif
#elif KERNEL == 5
#  if VEC
        fir_v(y, x, h, NELEM, TAPS);
#  else
        fir_s(y, x, h, NELEM, TAPS);
#  endif
#elif KERNEL == 6
#  if VEC
        gemm_v(C, A, B, MM, KK, NN);
#  else
        gemm_s(C, A, B, MM, KK, NN);
#  endif
#endif
        BARRIER();
    }

    // Identical in every build, so its cost cancels in the subtraction.
    int32_t acc = 0;
    for (int i = 0; i < NELEM; i++) acc += y[i];
    for (int i = 0; i < MM*NN; i++) acc += C[i];
    sink = acc;
    return 0;
}
