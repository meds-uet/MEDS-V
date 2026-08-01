// Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
// Scalar reference implementations of the six MEDS-V benchmark kernels.
// These are the correctness oracle AND the speedup baseline (Book Ch 14).
#include <stdint.h>
#include <stddef.h>

void memcpy32_s(int32_t *d, const int32_t *s, size_t n) {
    for (size_t i = 0; i < n; i++) d[i] = s[i];
}

void saxpy_s(size_t n, int32_t a, const int32_t *x, int32_t *y) {
    for (size_t i = 0; i < n; i++) y[i] = a * x[i] + y[i];
}

int32_t dotprod_s(const int32_t *x, const int32_t *y, size_t n) {
    int32_t acc = 0;
    for (size_t i = 0; i < n; i++) acc += x[i] * y[i];
    return acc;
}

void relu_s(int32_t *y, const int32_t *x, size_t n) {
    for (size_t i = 0; i < n; i++) y[i] = x[i] > 0 ? x[i] : 0;
}

// FIR: y[i] = sum_k h[k] * x[i+k].  Output length n - taps + 1.
void fir_s(int32_t *y, const int32_t *x, const int32_t *h,
           size_t n, size_t taps) {
    for (size_t i = 0; i + taps <= n; i++) {
        int32_t acc = 0;
        for (size_t k = 0; k < taps; k++) acc += h[k] * x[i + k];
        y[i] = acc;
    }
}

// Row-major GEMM: C[MxN] = A[MxK] * B[KxN]
void gemm_s(int32_t *C, const int32_t *A, const int32_t *B,
            size_t M, size_t K, size_t N) {
    for (size_t i = 0; i < M; i++)
        for (size_t j = 0; j < N; j++) {
            int32_t acc = 0;
            for (size_t k = 0; k < K; k++) acc += A[i*K + k] * B[k*N + j];
            C[i*N + j] = acc;
        }
}
