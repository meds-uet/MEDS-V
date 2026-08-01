// Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
// Link-time stubs for the vector kernels, used ONLY by the scalar (rv64gc)
// benchmark build, which must not compile kernels_rvv.c.  They are never called:
// bench_main.c selects between scalar and vector at compile time via -DVEC.
#include <stdint.h>
#include <stddef.h>
void memcpy32_v(int32_t*d,const int32_t*s,size_t n){(void)d;(void)s;(void)n;}
void saxpy_v(size_t n,int32_t a,const int32_t*x,int32_t*y){(void)n;(void)a;(void)x;(void)y;}
int32_t dotprod_v(const int32_t*x,const int32_t*y,size_t n){(void)x;(void)y;(void)n;return 0;}
void relu_v(int32_t*y,const int32_t*x,size_t n){(void)y;(void)x;(void)n;}
void fir_v(int32_t*y,const int32_t*x,const int32_t*h,size_t n,size_t t){(void)y;(void)x;(void)h;(void)n;(void)t;}
void gemm_v(int32_t*C,const int32_t*A,const int32_t*B,size_t M,size_t K,size_t N){(void)C;(void)A;(void)B;(void)M;(void)K;(void)N;}
