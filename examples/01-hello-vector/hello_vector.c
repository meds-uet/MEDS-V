// Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
//
// Example 01 -- "Hello, vector": the smallest self-checking RVV program.
//
// Demonstrates, in inline assembly so nothing is hidden by the compiler:
//   * reading VLEN at runtime from the vlenb CSR
//   * vsetvli and the vl it returns
//   * a unit-stride load, an element-wise add, a unit-stride store
//   * that vl < VLMAX leaves tail elements alone
//
// Returns 0 on success, or the number of the first failing check.
// Run:  make run          (Spike, bare metal)

#define N 32

static int   src_a[N], src_b[N], dst[N];

static inline unsigned long read_vlenb(void) {
    unsigned long v;
    asm volatile ("csrr %0, vlenb" : "=r"(v));
    return v;
}

int main(void) {
    const unsigned long vlen_bits = read_vlenb() * 8;
    const unsigned long vlmax_e32 = vlen_bits / 32;   // SEW=32, LMUL=1

    for (int i = 0; i < N; i++) { src_a[i] = i; src_b[i] = 100 * i; dst[i] = -1; }

    // ---- Check 1: vsetvli with a large AVL must clamp vl to VLMAX ----------
    unsigned long vl;
    asm volatile ("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(vl) : "r"((unsigned long)N));
    if (vl != (vlmax_e32 < N ? vlmax_e32 : N)) return 1;

    // ---- Check 2: load, add, store one vector ------------------------------
    asm volatile (
        "vsetvli t0, %2, e32, m1, ta, ma \n"
        "vle32.v v1, (%0)                \n"
        "vle32.v v2, (%1)                \n"
        "vadd.vv v3, v1, v2              \n"   // note: vd, vs2, vs1
        "vse32.v v3, (%3)                \n"
        :: "r"(src_a), "r"(src_b), "r"(vl), "r"(dst)
        : "t0", "v1", "v2", "v3", "memory");

    for (unsigned long i = 0; i < vl; i++)
        if (dst[i] != src_a[i] + src_b[i]) return 2;

    // ---- Check 3: elements beyond vl must NOT have been written ------------
    for (unsigned long i = vl; i < N; i++)
        if (dst[i] != -1) return 3;

    // ---- Check 4: a short vl (vl = 2) touches exactly 2 elements -----------
    for (int i = 0; i < N; i++) dst[i] = -1;
    asm volatile (
        "vsetvli t0, %2, e32, m1, ta, ma \n"
        "vle32.v v1, (%0)                \n"
        "vle32.v v2, (%1)                \n"
        "vadd.vv v3, v1, v2              \n"
        "vse32.v v3, (%3)                \n"
        :: "r"(src_a), "r"(src_b), "r"(2UL), "r"(dst)
        : "t0", "v1", "v2", "v3", "memory");

    if (dst[0] != 0 || dst[1] != 101) return 4;
    if (dst[2] != -1)                 return 5;   // element 2 is tail: untouched

    // ---- Check 5: vsub.vv computes vs2 - vs1, not vs1 - vs2 ----------------
    // Book Ch 5 section 5.1: the FIRST source in assembly is vs2.
    asm volatile (
        "vsetvli t0, %2, e32, m1, ta, ma \n"
        "vle32.v v1, (%0)                \n"   // v1 = src_a  (0,1,2,...)
        "vle32.v v2, (%1)                \n"   // v2 = src_b  (0,100,200,...)
        "vsub.vv v3, v2, v1              \n"   // vs2=v2, vs1=v1  =>  v2 - v1
        "vse32.v v3, (%3)                \n"
        :: "r"(src_a), "r"(src_b), "r"(4UL), "r"(dst)
        : "t0", "v1", "v2", "v3", "memory");

    if (dst[1] != 100 - 1) return 6;           // 99, not -99

    return 0;
}
