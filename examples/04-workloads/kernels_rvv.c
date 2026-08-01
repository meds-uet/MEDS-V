// Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
// RVV implementations of the six MEDS-V benchmark kernels.
//
// All are vector-length agnostic: no kernel contains a hard-coded element
// count, and every one runs unmodified at any VLEN (Book Ch 7).
#include <stdint.h>
#include <stddef.h>
#include <riscv_vector.h>

// --- 1. memcpy -- pure memory bandwidth, no arithmetic at all ---------------
void memcpy32_v(int32_t *d, const int32_t *s, size_t n) {
    for (size_t vl; n > 0; n -= vl, s += vl, d += vl) {
        vl = __riscv_vsetvl_e32m8(n);                 // m8: few live registers
        __riscv_vse32_v_i32m8(d, __riscv_vle32_v_i32m8(s, vl), vl);
    }
}

// --- 2. SAXPY -- one multiply-add per element, 2 loads + 1 store ------------
void saxpy_v(size_t n, int32_t a, const int32_t *x, int32_t *y) {
    for (size_t vl; n > 0; n -= vl, x += vl, y += vl) {
        vl = __riscv_vsetvl_e32m4(n);
        vint32m4_t vx = __riscv_vle32_v_i32m4(x, vl);
        vint32m4_t vy = __riscv_vle32_v_i32m4(y, vl);
        __riscv_vse32_v_i32m4(y, __riscv_vmacc_vx_i32m4(vy, a, vx, vl), vl);
    }
}

// --- 3. dot product -- exercises the cross-lane reduction path --------------
// Accumulates ELEMENT-WISE across passes and reduces ONCE at the end, which is
// far cheaper than a vredsum per pass.  The _tu (tail-undisturbed) on the
// accumulate is REQUIRED: on the final short pass the upper elements of acc are
// tail, and an agnostic policy is permitted to overwrite them -- destroying the
// partial sums.  See Book Ch 7 section 7.3.
int32_t dotprod_v(const int32_t *x, const int32_t *y, size_t n) {
    size_t vlmax = __riscv_vsetvlmax_e32m1();
    vint32m1_t acc = __riscv_vmv_v_x_i32m1(0, vlmax);

    for (size_t vl; n > 0; n -= vl, x += vl, y += vl) {
        vl = __riscv_vsetvl_e32m1(n);
        vint32m1_t vx = __riscv_vle32_v_i32m1(x, vl);
        vint32m1_t vy = __riscv_vle32_v_i32m1(y, vl);
        acc = __riscv_vmacc_vv_i32m1_tu(acc, vx, vy, vl);
    }
    __riscv_vsetvlmax_e32m1();
    vint32m1_t zero = __riscv_vmv_v_x_i32m1(0, vlmax);
    return __riscv_vmv_x_s_i32m1_i32(
               __riscv_vredsum_vs_i32m1_i32m1(acc, zero, vlmax));
}

// --- 4. ReLU -- data-dependent conditional, vectorised with vmax ------------
// vmax.vx against zero is one instruction; the vmslt + vmerge form costs three.
// Both are in the book (Ch 5 exercise 5.3); this is the one to ship.
void relu_v(int32_t *y, const int32_t *x, size_t n) {
    for (size_t vl; n > 0; n -= vl, x += vl, y += vl) {
        vl = __riscv_vsetvl_e32m8(n);
        __riscv_vse32_v_i32m8(y,
            __riscv_vmax_vx_i32m8(__riscv_vle32_v_i32m8(x, vl), 0, vl), vl);
    }
}

// --- 5. FIR filter -- the classic DSP kernel --------------------------------
// Vectorised over OUTPUT samples, not taps: for each tap k, accumulate
// h[k] * x[i+k] across a whole vector of outputs i.  The tap coefficient is a
// scalar, so this is vmacc.vx -- no cross-lane traffic in the inner loop.
void fir_v(int32_t *y, const int32_t *x, const int32_t *h,
           size_t n, size_t taps) {
    size_t nout = (n >= taps) ? n - taps + 1 : 0;
    for (size_t i = 0, vl; i < nout; i += vl) {
        vl = __riscv_vsetvl_e32m2(nout - i);
        vint32m2_t acc = __riscv_vmv_v_x_i32m2(0, vl);
        for (size_t k = 0; k < taps; k++) {
            vint32m2_t vx = __riscv_vle32_v_i32m2(&x[i + k], vl);
            acc = __riscv_vmacc_vx_i32m2(acc, h[k], vx, vl);
        }
        __riscv_vse32_v_i32m2(&y[i], acc, vl);
    }
}

// --- 6. GEMM -- vectorised over the N (column) dimension --------------------
// B rows are contiguous in row-major layout, so the inner loop is unit-stride.
// Vectorising over N (rather than K) avoids needing a reduction per output.
void gemm_v(int32_t *C, const int32_t *A, const int32_t *B,
            size_t M, size_t K, size_t N) {
    for (size_t i = 0; i < M; i++) {
        for (size_t j = 0, vl; j < N; j += vl) {
            vl = __riscv_vsetvl_e32m2(N - j);
            vint32m2_t acc = __riscv_vmv_v_x_i32m2(0, vl);
            for (size_t k = 0; k < K; k++) {
                vint32m2_t vb = __riscv_vle32_v_i32m2(&B[k*N + j], vl);
                acc = __riscv_vmacc_vx_i32m2(acc, A[i*K + k], vb, vl);
            }
            __riscv_vse32_v_i32m2(&C[i*N + j], acc, vl);
        }
    }
}
