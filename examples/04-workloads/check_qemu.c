// Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
// Correctness oracle: every RVV kernel must match its scalar reference exactly.
// Runs under QEMU user mode at any VLEN.  Book Ch 14 section 14.8.
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>

#define N 257            // deliberately NOT a multiple of any VLMAX
#define TAPS 8
#define M_ 7
#define K_ 9
#define NC 11

void memcpy32_s(int32_t*,const int32_t*,size_t);
void memcpy32_v(int32_t*,const int32_t*,size_t);
void saxpy_s(size_t,int32_t,const int32_t*,int32_t*);
void saxpy_v(size_t,int32_t,const int32_t*,int32_t*);
int32_t dotprod_s(const int32_t*,const int32_t*,size_t);
int32_t dotprod_v(const int32_t*,const int32_t*,size_t);
void relu_s(int32_t*,const int32_t*,size_t);
void relu_v(int32_t*,const int32_t*,size_t);
void fir_s(int32_t*,const int32_t*,const int32_t*,size_t,size_t);
void fir_v(int32_t*,const int32_t*,const int32_t*,size_t,size_t);
void gemm_s(int32_t*,const int32_t*,const int32_t*,size_t,size_t,size_t);
void gemm_v(int32_t*,const int32_t*,const int32_t*,size_t,size_t,size_t);

static int32_t x[N+TAPS], y[N], ref[N], got[N], h[TAPS];
static int32_t A[M_*K_], B[K_*NC], Cs[M_*NC], Cv[M_*NC];
static int fails = 0;

static uint32_t rnd_state = 12345;
static int32_t rnd(void){ rnd_state = rnd_state*1103515245u + 12345u;
                          return (int32_t)(rnd_state >> 16) % 1000 - 500; }

static void cmp(const char *name, const int32_t *a, const int32_t *b, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (a[i] != b[i]) {
            printf("  FAIL  %-10s at [%zu]: scalar=%d vector=%d\n", name, i, a[i], b[i]);
            fails++; return;
        }
    printf("  pass  %-10s (%zu elements)\n", name, n);
}

int main(void) {
    unsigned long vlenb; asm volatile("csrr %0, vlenb":"=r"(vlenb));
    printf("\nVLEN = %lu bits, N = %d (not a multiple of VLMAX)\n\n", vlenb*8, N);

    for (int i = 0; i < N+TAPS; i++) x[i] = rnd();
    for (int i = 0; i < TAPS; i++)   h[i] = rnd() % 10;
    for (int i = 0; i < M_*K_; i++)  A[i] = rnd() % 20;
    for (int i = 0; i < K_*NC; i++)  B[i] = rnd() % 20;

    memcpy32_s(ref, x, N); memcpy32_v(got, x, N);  cmp("memcpy", ref, got, N);

    for (int i=0;i<N;i++){ref[i]=100;got[i]=100;}
    saxpy_s(N, 3, x, ref); saxpy_v(N, 3, x, got);  cmp("saxpy", ref, got, N);

    { int32_t a = dotprod_s(x, x+1, N), b = dotprod_v(x, x+1, N);
      if (a != b) { printf("  FAIL  dotprod: scalar=%d vector=%d\n", a, b); fails++; }
      else          printf("  pass  %-10s (result %d)\n", "dotprod", a); }

    relu_s(ref, x, N); relu_v(got, x, N);          cmp("relu", ref, got, N);

    fir_s(ref, x, h, N, TAPS); fir_v(got, x, h, N, TAPS);
    cmp("fir", ref, got, N - TAPS + 1);

    gemm_s(Cs, A, B, M_, K_, NC); gemm_v(Cv, A, B, M_, K_, NC);
    cmp("gemm", Cs, Cv, M_*NC);

    printf("\n%s\n\n", fails ? "SOME KERNELS FAILED" : "all 6 kernels match the scalar reference");
    return fails != 0;
}
