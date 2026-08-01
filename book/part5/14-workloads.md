# Chapter 14 — Workloads

> **Purpose of this chapter.** Define the six benchmark kernels, explain what each one
> stresses in the hardware, and establish the correctness oracle. These kernels are the
> project's deliverable evidence: they are what "the processor works" means concretely.

All six kernels ship in [`examples/04-workloads/`](../../examples/04-workloads/), in scalar
and vector form, and every number in this chapter is captured output.

---

## 14.1 Choosing a benchmark suite

A good suite for this project satisfies five constraints:

1. **Each kernel stresses something different.** Six kernels that all measure unit-stride
   throughput teach nothing.
2. **A scalar reference exists** for every one, so correctness is checkable and speedup is
   measurable.
3. **They are small enough to simulate.** RTL simulation runs at roughly 10 kHz; a kernel
   that needs a hundred million cycles cannot be run on the design.
4. **They are recognisable.** Reviewers should be able to compare against published results.
5. **They fit the implemented subset.** No kernel should need a deferred instruction.

The six chosen:

| Kernel | Stresses | Vector features exercised |
|---|---|---|
| **memcpy** | Pure memory bandwidth | Unit-stride load/store only — no arithmetic |
| **SAXPY** | Balanced compute and memory | `vmacc.vx`, scalar operand broadcast |
| **dot product** | **Cross-lane reduction** | `vredsum`, `vmv.x.s`, cross-pass accumulation |
| **ReLU** | Data-dependent conditionals | `vmax.vx` (or mask + merge) |
| **FIR filter** | Multiply-accumulate depth, register reuse | `vmacc.vx` in a tap loop, data kept in the VRF |
| **GEMM** | Nested loops, 2-D blocking | `vmacc.vx`, row-major unit-stride |

Between them they cover every block in the Chapter 8 diagram. **memcpy** exercises the VLSU
and nothing else, which makes it the cleanest possible measurement of memory-path
efficiency. **dot product** is the only one that forces cross-lane traffic, which is why it
behaves so differently from the others (§14.9).

---

## 14.2 memcpy — the memory-path baseline

```c
void memcpy32_v(int32_t *d, const int32_t *s, size_t n) {
    for (size_t vl; n > 0; n -= vl, s += vl, d += vl) {
        vl = __riscv_vsetvl_e32m8(n);                 // m8: few live registers
        __riscv_vse32_v_i32m8(d, __riscv_vle32_v_i32m8(s, vl), vl);
    }
}
```

Four instructions in the loop body and no arithmetic at all. `m8` is the right choice here
because the kernel needs exactly one live vector register, so there is no register pressure
to trade against the reduced loop overhead (Chapter 7 §7.5).

**What it tells the implementer:** this kernel is a direct measurement of the VLSU. If
memcpy does not speed up, the load/store unit is the bottleneck and no amount of ALU work
will help.

---

## 14.3 SAXPY — the balanced case

```c
void saxpy_v(size_t n, int32_t a, const int32_t *x, int32_t *y) {
    for (size_t vl; n > 0; n -= vl, x += vl, y += vl) {
        vl = __riscv_vsetvl_e32m4(n);
        vint32m4_t vx = __riscv_vle32_v_i32m4(x, vl);
        vint32m4_t vy = __riscv_vle32_v_i32m4(y, vl);
        __riscv_vse32_v_i32m4(y, __riscv_vmacc_vx_i32m4(vy, a, vx, vl), vl);
    }
}
```

Two loads, one multiply-add, one store. `m4` rather than `m8` because two vectors are live
simultaneously; at `m8` that would consume 16 of the 32 registers and leave the compiler no
room.

Note `vmacc.vx` — the scalar `a` is broadcast to every element by the hardware, with no
separate splat instruction. That is the `.vx` operand form from Chapter 5 §5.1 earning its
place.

---

## 14.4 Dot product — the reduction case

This is the kernel that most repays careful reading, because it is where the tail policy
becomes load-bearing.

```c
int32_t dotprod_v(const int32_t *x, const int32_t *y, size_t n) {
    size_t vlmax = __riscv_vsetvlmax_e32m1();
    vint32m1_t acc = __riscv_vmv_v_x_i32m1(0, vlmax);

    for (size_t vl; n > 0; n -= vl, x += vl, y += vl) {
        vl = __riscv_vsetvl_e32m1(n);
        vint32m1_t vx = __riscv_vle32_v_i32m1(x, vl);
        vint32m1_t vy = __riscv_vle32_v_i32m1(y, vl);
        acc = __riscv_vmacc_vv_i32m1_tu(acc, vx, vy, vl);   // note _tu
    }
    __riscv_vsetvlmax_e32m1();
    vint32m1_t zero = __riscv_vmv_v_x_i32m1(0, vlmax);
    return __riscv_vmv_x_s_i32m1_i32(
               __riscv_vredsum_vs_i32m1_i32m1(acc, zero, vlmax));
}
```

Three things to notice:

**Element-wise accumulation, one reduction at the end.** The loop body is a `vmacc` — a
lane-local, full-throughput operation. The single cross-lane `vredsum` happens once, after
the loop. A version that reduced every pass would be far slower.

**The `_tu` suffix is mandatory.** On the final short pass `vl < vlmax`, so the upper
elements of `acc` are *tail*. Under the default agnostic policy the hardware is permitted
to overwrite them with all-1s — destroying the partial sums accumulated over every previous
pass. This is legal-but-wrong code that produces correct answers on some compliant machines
and wrong answers on others.

> **🎯 This kernel is the best single test of tail handling in the suite.** It is why
> Chapter 4 §4.8 recommends building the undisturbed write path: with element-granular write
> enables, this code is correct on MEDS-V by construction.

**`vmv.x.s` is on the critical path.** Extracting element 0 into a scalar register is the
last step of every reduction, and it synchronises the vector unit with the scalar core.

---

## 14.5 ReLU — the conditional case

```c
void relu_v(int32_t *y, const int32_t *x, size_t n) {
    for (size_t vl; n > 0; n -= vl, x += vl, y += vl) {
        vl = __riscv_vsetvl_e32m8(n);
        __riscv_vse32_v_i32m8(y,
            __riscv_vmax_vx_i32m8(__riscv_vle32_v_i32m8(x, vl), 0, vl), vl);
    }
}
```

`y[i] = max(0, x[i])` is a conditional, and there is no branch anywhere. Two ways to write
it (Chapter 5, Exercise 5.3):

| Form | Instructions | Notes |
|---|---|---|
| `vmax.vx` against zero | **1** | Ship this one |
| `vmslt` + `vmerge` | 3 | Instructive; demonstrates masking |

The suite ships the `vmax` form because it is what a real implementation would use, but
teams should implement both and measure the difference — it is a concrete demonstration
that choosing the right instruction matters more than microarchitectural cleverness.

---

## 14.6 FIR filter — the DSP case

```c
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
```

The important design decision is **which loop to vectorise**. The obvious choice — vectorise
over taps and reduce — needs a cross-lane reduction per output sample, which is slow. This
version vectorises over **output samples**: for each tap `k`, it accumulates
`h[k] * x[i+k]` across a whole vector of outputs at once.

The consequences are all good: the tap coefficient is a scalar, so the inner operation is
`vmacc.vx` with no cross-lane traffic; the accumulator stays in the VRF across all `taps`
iterations; and the loads are unit-stride.

This is the Cray lesson from Chapter 3 §3.1 in practice — **keep data in the register file
across multiple operations**. It is also why FIR shows the largest speedup in the suite.

> A production FIR would use `vslide1down` to shift the delay line rather than re-loading
> overlapping windows. That version is a good M5 exercise once slides work.

---

## 14.7 GEMM — the nested-loop case

```c
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
```

Again the choice is which dimension to vectorise. Vectorising over **N** (the column
dimension) means the `B` accesses are unit-stride, because `B` is row-major. Vectorising
over **K** would need either a reduction per output element or strided access down a
column of `B` — both much worse.

> **🔧 An instructive experiment.** Write the strided-`B` version, measure it, and compare.
> The difference between the two is a direct measurement of what unit-stride access is
> worth, and it makes the VLSU's importance concrete in a way no explanation does.

---

## 14.8 The correctness oracle

Every vector kernel is checked against its scalar reference before any performance number
is taken. The check runs under QEMU at three vector lengths, with **N = 257** — deliberately
prime, so it is not a multiple of any VLMAX and every kernel must handle a short final pass.

```
$ cd examples/04-workloads && make check
===== VLEN=128 =====

VLEN = 128 bits, N = 257 (not a multiple of VLMAX)

  pass  memcpy     (257 elements)
  pass  saxpy      (257 elements)
  pass  dotprod    (result -861571)
  pass  relu       (257 elements)
  pass  fir        (250 elements)
  pass  gemm       (77 elements)

all 6 kernels match the scalar reference
```

and identically at VLEN=256 and VLEN=512 — same binary, same results.

> **⚠️ Choose the test length deliberately.** With N = 256 at VLEN=128, `vl` is 4 or 32 on
> every pass and never short. Every tail bug passes. **N = 257 forces a short final pass in
> every kernel**, which is where tail-policy and write-enable bugs live. Using a round
> number here is one of the easiest ways to ship a broken tail path.

---

## 14.9 Measured results

Captured from `make bench`. The measurement method is explained in Chapter 15 §15.3 — each
kernel is built twice, once running the kernel once and once running it twice, and the
difference is one isolated invocation.

```
MEDS-V benchmark kernels -- committed instructions per invocation
(Spike; N = 1024; one kernel call isolated by the REPS=2 minus REPS=1 method)

  kernel      scalar  VLEN=128  VLEN=256  VLEN=512    x128    x256    x512
  --------- -------- --------- --------- --------- ------- ------- -------
  memcpy        5141       275       147        83  18.69x  34.97x  61.94x
  saxpy         8214       660       340       180  12.45x  24.16x  45.63x
  dotprod       7193      2331      1179       603   3.09x   6.10x  11.93x
  relu          7489       307       163        91  24.39x  45.94x  82.30x
  fir          66134      7580      3805      1917   8.72x  17.38x  34.50x
  gemm         30925      3620      1876      1876   8.54x  16.48x  16.48x
```

### Reading the table

These are **instruction counts, not cycles** — the caveat from Chapter 1 §1.2 still applies,
and Chapter 15 is about converting them into an honest performance claim. But the *shape* of
the table is already informative, and every feature of it has an explanation.

**Sanity-check the numbers against the model.** memcpy at `m8` and VLEN=128 gives
VLMAX = 8 × 128/32 = 32, so 1024 elements need 32 passes. At roughly 8 instructions per
pass that is ~256, and the measurement is 275. At VLEN=512, VLMAX = 128, so 8 passes ×
~10 instructions ≈ 80, measured 83. **The model predicts the measurement.** Any table where
it does not should be distrusted before it is published.

**memcpy and ReLU scale almost perfectly** — roughly 2× per doubling of VLEN. Both are `m8`
with a single live register and no cross-lane traffic. They are the ceiling.

**dot product scales, but from a much worse starting point** (3.09× at VLEN=128 versus
18.69× for memcpy). Two reasons, both structural: it uses `m1` rather than `m8`, so it does
8× more loop iterations; and it ends in a cross-lane reduction. This is the kernel that will
expose a slow reduction path in the RTL.

**GEMM stops improving between VLEN=256 and VLEN=512** — 1876 instructions at both. This is
not a measurement error. The matrix is 16×16, and at `m2` with VLEN=256 the vector already
holds 16 elements, so one pass covers an entire row. Doubling VLEN to 512 gives a machine
that can process 32 elements at once, and there are only 16 to process.

> **🎯 That GEMM row is the most instructive line in the table, and it belongs in the final
> presentation.** It is a concrete demonstration that **vector length is only useful up to
> the available data parallelism.** A wider machine does nothing for a problem that has run
> out of elements. Teams that report only memcpy and ReLU will show beautiful scaling and
> will have learned nothing; the GEMM row is where the engineering judgement is.
>
> It also implies a real design question: for a workload of small matrices, is a wide
> single-lane machine or a narrow multi-lane machine the better use of area? Chapter 15
> §15.5 turns that into a measurement.

---

## 14.10 Running the workloads on the RTL

Once M4 is complete, the same kernels run on the design itself:

1. Compile the kernel bare-metal for the target configuration.
2. Load the ELF into the testbench's memory model.
3. Run to completion, capturing the RTL trace.
4. Compare the trace against Spike (Chapter 13 §13.4).
5. Compare the final memory image against the scalar reference result.
6. Record the cycle count.

Steps 4 and 5 are both needed. The trace comparison finds *where* a divergence started; the
memory comparison confirms the program's actual output. A design can pass one and fail the
other — a VLSU that writes the right values to the wrong addresses produces a matching
instruction trace and a wrong answer.

---

## 🔧 Exercises

**14.1** Run `make check` and `make bench`. Confirm the outputs match §14.8 and §14.9.

**14.2** Explain the GEMM row in §14.9 in the own words. At what matrix size would
VLEN=512 start to help again? Verify by changing `NN` and re-measuring.

**14.3** Write the `vmslt` + `vmerge` version of ReLU. Measure it against the `vmax`
version. Explain the ratio.

**14.4** Remove the `_tu` from the dot-product accumulate. Does `make check` still pass?
Explain why the code is broken regardless of the answer. *(Chapter 7 §7.3.)*

**14.5** Change `N` in `check_qemu.c` from 257 to 256. Do all kernels still pass? What
class of bug would this test now miss?

**14.6** Write the strided-`B` GEMM from §14.7 and measure it. Express the difference as
the value of unit-stride access.

**14.7** Add a seventh kernel: 2-D convolution with a 3×3 kernel. Which existing kernel is
it most like? What new demand does it place on the VLSU?

**14.8 (mentors)** Predict, on paper, the instructions per element for each kernel at
VLEN=1024 before measuring. Check. Any kernel where the prediction is off by more than 15%
is one the team does not yet understand.

---

## Key takeaways

- Six kernels, each stressing something different: **memcpy** (pure VLSU), **SAXPY**
  (balanced), **dot product** (cross-lane reduction), **ReLU** (conditionals), **FIR**
  (MAC depth and register reuse), **GEMM** (nested loops).
- Vectorise the dimension that keeps memory access **unit-stride** and avoids reductions —
  FIR over output samples, GEMM over columns.
- The dot product's `_tu` accumulate is **required**, and makes it the suite's best test of
  tail handling.
- Test with a **prime N (257)**, never a round number, or every short-final-pass bug passes.
- Check correctness against the scalar reference **before** taking any performance number.
- Measured speedups span 3× to 82× — and the spread is the interesting part.
- **GEMM stops scaling past VLEN=256** because a 16×16 matrix runs out of elements. Vector
  length only helps up to the available data parallelism, and this row is the one worth
  presenting.
- Verify measurements against a hand model. If `10/vl` does not predict the result, the
  measurement is suspect.

---

*Next: [Chapter 15 — Benchmarking and Comparison](15-benchmarking-and-comparison.md)*
