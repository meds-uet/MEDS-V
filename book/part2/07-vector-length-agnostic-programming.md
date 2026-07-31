# Chapter 7 — Vector-Length-Agnostic Programming

> **Goal of this chapter.** Master the stripmine idiom and the patterns built on it. This
> is a short chapter about one idea — but it is *the* idea, and your hardware exists to
> support it.

Why does a hardware team need a chapter on a software pattern? Because **the pattern
defines the hardware's contract.** Every requirement on your `vsetvli` implementation, your
`vl` handling, and your tail policy comes from making these loops work. If you understand
the loops, the hardware requirements are obvious. If you don't, they look arbitrary.

---

## 7.1 The stripmine loop

Here it is, the canonical form. Memorise it.

```c
for (size_t vl; n > 0; n -= vl, ptr += vl) {
    vl = __riscv_vsetvl_e32m1(n);      // ask: how many can you do?
    /* ... process vl elements ... */
}
```

Read it as a conversation between software and hardware:

```
   software:  "I have n elements left."                 ← AVL
   hardware:  "I'll take vl of them."                   ← returned in rd
   software:  ...processes exactly vl...
   software:  "Now I have n - vl left."
                          (repeat)
```

Three properties make this work, and each is a hardware requirement:

1. **`vsetvli` returns `vl`.** Software must be *told* how many elements it got. This is
   why `vsetvli` writes `rd` (Chapter 4 §4.4).
2. **`vl > 0` whenever `AVL > 0`.** Otherwise the loop never terminates. This is a
   spec guarantee your hardware must honour — `vl = 0` if and only if `AVL = 0`.
3. **Every operation in the body respects `vl`.** Loads load `vl` elements; stores store
   `vl`; arithmetic computes `vl`. The tail is untouched.

> **⚠️ If your hardware ever returns `vl = 0` for a non-zero AVL, every stripmine loop in
> existence hangs forever.** Put this in your directed tests at M2. It is a one-line bug
> with a catastrophic, hard-to-debug symptom.

### The general shape, in assembly

```asm
loop:
    vsetvli t0, a0, e32, m1, ta, ma   # t0 = vl, from AVL in a0
    vle32.v v1, (a1)                  # load vl elements
    # ... compute ...
    vse32.v v1, (a2)                  # store vl elements

    slli    t1, t0, 2                 # bytes = vl * sizeof(elem)
    add     a1, a1, t1                # advance source
    add     a2, a2, t1                # advance dest
    sub     a0, a0, t0                # n -= vl
    bnez    a0, loop
```

Nine instructions of scaffolding. Note `slli t1, t0, 2`: the pointer advance is
**computed from the returned `vl`**, never from a constant. That single dependency is what
makes the code VLEN-agnostic. Any time you see a hard-coded element count in supposedly-VLA
code, it's a bug.

---

## 7.2 Watching it adapt

From Chapter 6 §6.5, the same binary on three machines:

| | VLEN=128 (VLMAX=4) | VLEN=256 (VLMAX=8) | VLEN=512 (VLMAX=16) |
|---|---|---|---|
| pass 0 | AVL=20 → vl=4 | AVL=20 → vl=8 | AVL=20 → vl=16 |
| pass 1 | AVL=16 → vl=4 | AVL=12 → vl=8 | AVL=4 → vl=4 |
| pass 2 | AVL=12 → vl=4 | AVL=4 → vl=4 | — |
| pass 3 | AVL=8 → vl=4 | — | — |
| pass 4 | AVL=4 → vl=4 | — | — |
| **passes** | **5** | **3** | **2** |

The loop reorganised itself. No recompilation, no runtime dispatch, no CPU-feature
detection. Compare to the packed-SIMD world, where a numerical library ships six versions
of every kernel and picks one with `cpuid`.

---

## 7.3 Pattern: reductions across passes

Stripmining is easy when each element is independent. Reductions are the first case where
you must think.

**Wrong** — resets the accumulator every pass:
```c
for (size_t vl; n > 0; n -= vl, x += vl) {
    vl = __riscv_vsetvl_e32m1(n);
    vint32m1_t v = __riscv_vle32_v_i32m1(x, vl);
    vint32m1_t s = __riscv_vmv_v_x_i32m1(0, vl);        // BUG: zeroed each pass
    s = __riscv_vredsum_vs_i32m1_i32m1(v, s, vl);
}
```

**Right** — carry the accumulator across passes. Recall from Chapter 5 §5.7 that
`vredsum.vs` takes its initial value from element 0 of `vs1`, which is exactly the hook you
need:

```c
// Sum an int32 array, VLEN-agnostically.
int32_t sum_rvv(const int32_t *x, size_t n) {
    size_t vlmax = __riscv_vsetvlmax_e32m1();
    vint32m1_t acc = __riscv_vmv_v_x_i32m1(0, vlmax);   // acc[0] = running total

    for (size_t vl; n > 0; n -= vl, x += vl) {
        vl = __riscv_vsetvl_e32m1(n);
        vint32m1_t v = __riscv_vle32_v_i32m1(x, vl);
        acc = __riscv_vredsum_vs_i32m1_i32m1(v, acc, vl);   // acc[0] += sum(v)
    }
    return __riscv_vmv_x_s_i32m1_i32(acc);              // extract element 0
}
```

The accumulator lives in element 0 of a vector register for the whole loop. One
`vmv.x.s` at the very end moves it to a scalar register. **No scalar round-trip per
pass** — which matters, because a vector-to-scalar move is a synchronisation point that
drains your pipeline.

> **🎯 Hardware consequence.** This idiom means `vmv.x.s` and `vredsum.vs` sit on the
> critical path of every reduction kernel. Make sure your implementation of "read element 0
> of a vector register into a scalar register" is not accidentally expensive.

### The faster variant

A single `vredsum` per pass serialises the reduction. Better: accumulate element-wise
across passes with a plain `vadd`, and reduce **once** at the end.

```c
int32_t sum_rvv_fast(const int32_t *x, size_t n) {
    size_t vlmax = __riscv_vsetvlmax_e32m1();
    vint32m1_t acc = __riscv_vmv_v_x_i32m1(0, vlmax);   // a VECTOR of partial sums

    for (size_t vl; n > 0; n -= vl, x += vl) {
        vl = __riscv_vsetvl_e32m1(n);
        vint32m1_t v = __riscv_vle32_v_i32m1(x, vl);
        acc = __riscv_vadd_vv_i32m1_tu(acc, acc, v, vl);   // tail-undisturbed!
    }
    vint32m1_t zero = __riscv_vmv_v_x_i32m1(0, vlmax);
    return __riscv_vmv_x_s_i32m1_i32(
               __riscv_vredsum_vs_i32m1_i32m1(acc, zero, vlmax));
}
```

Now the loop body is one `vadd` — a full-throughput, lane-local operation — and there is
exactly one cross-lane reduction at the end.

> **⚠️ Note the `_tu` suffix.** That is **tail-undisturbed**, and it is *required* here.
> On the final short pass, `vl < vlmax`, so the upper elements of `acc` are in the tail.
> With the default agnostic policy the hardware is permitted to overwrite them with all-1s
> — destroying partial sums accumulated on earlier passes.
>
> **This is the clearest practical example of why the tail policy exists and why it is not
> a formality.** It is also a direct argument for Chapter 4 §4.8's recommendation: build
> element-granular write enables and implement tails as undisturbed, and this code is
> correct on your hardware. Build a machine that blasts 1s into agnostic tails, and this
> perfectly legal program silently produces wrong answers on your chip and right answers on
> Spike.
>
> **Put this kernel in your test suite.** It is the best single test of tail handling you
> can write.

---

## 7.4 Pattern: conditionals with masks

```c
// y[i] = (x[i] > threshold) ? x[i] * 2 : 0
void threshold_rvv(const int32_t *x, int32_t *y, size_t n, int32_t t) {
    for (size_t vl; n > 0; n -= vl, x += vl, y += vl) {
        vl = __riscv_vsetvl_e32m1(n);
        vint32m1_t v    = __riscv_vle32_v_i32m1(x, vl);
        vbool32_t  mask = __riscv_vmsgt_vx_i32m1_b32(v, t, vl);   // v > t
        vint32m1_t two  = __riscv_vsll_vx_i32m1(v, 1, vl);        // v * 2
        vint32m1_t out  = __riscv_vmerge_vvm_i32m1(
                              __riscv_vmv_v_x_i32m1(0, vl), two, mask, vl);
        __riscv_vse32_v_i32m1(y, out, vl);
    }
}
```

Two ways to use a mask, and the difference matters for your hardware:

**Merge (shown above)** — compute *both* results, select per element. Costs the work of
both branches, but the datapath is simple: a mux at the end.

**Predication** — `__riscv_vadd_vv_i32m1_m(mask, ...)` suppresses the *write* for inactive
elements. Costs only one computation, and the inactive elements keep their old value.

```c
        // predicated form: only active elements are written
        out = __riscv_vsll_vx_i32m1_m(mask, v, 1, vl);
```

> **🎯 Hardware consequence.** Predication is just the per-element write-enable you already
> built for tails (Chapter 4 §4.8). Merge needs `vmerge`, which is a per-element mux
> between two vector operands. **You need both**, and both are cheap. What you must *not*
> do is branch — there is no branch inside a vector body, ever. That is the point.

---

## 7.5 Pattern: LMUL as a tuning knob

Because LMUL multiplies VLMAX, raising it processes more elements per instruction and
amortises the loop scaffolding further:

| LMUL | VLMAX at VLEN=128, SEW=32 | Registers consumed | Scaffolding per element |
|---|---|---|---|
| 1 | 4 | 1 per operand | 9/4 = 2.25 |
| 2 | 8 | 2 per operand | 9/8 = 1.13 |
| 4 | 16 | 4 per operand | 9/16 = 0.56 |
| 8 | 32 | 8 per operand | 9/32 = 0.28 |

The change in source is one token — `m1` → `m8`:

```c
    vl = __riscv_vsetvl_e32m8(n);
    vfloat32m8_t vx = __riscv_vle32_v_f32m8(x, vl);
```

That is what the Preface's SAXPY used.

**But LMUL=8 leaves only 4 register groups.** A kernel needing five live vectors will spill
to memory and lose far more than it gained. The tuning rule:

| Kernel shape | Recommended LMUL |
|---|---|
| Few live vectors, memory-bound (SAXPY, memcpy, ReLU) | **m4 or m8** |
| Several live vectors (FIR with taps, small GEMM) | **m2** |
| Many live accumulators (GEMM microkernel, conv2d) | **m1** |
| Mixed-width, narrow source | **fractional** (`mf2`, `mf4`) |

> **🎯 Hardware consequence — this is a big one.** LMUL=8 means **one instruction occupies
> your functional unit for 8× as long**. That is excellent for throughput (the front end
> gets a long holiday) and terrible for latency and for hazard granularity. Your sequencer
> must handle a single instruction spanning many passes and many registers, and your hazard
> logic must track *register groups*, not individual registers.
>
> `vadd.vv v0, v8, v16` at LMUL=8 writes `v0`–`v7`. A later instruction reading `v3` must
> stall. If your scoreboard tracks single registers, you will miss this. **Design the
> scoreboard for groups from the start** — Chapter 9 §9.8.

---

## 7.6 Pattern: mixed-width with fractional LMUL

The real payoff of fractional LMUL. Sum 8-bit data into 32-bit accumulators:

```c
    // SEW=8, LMUL=1/4  ->  same element count as SEW=32, LMUL=1
    vl = __riscv_vsetvl_e8mf4(n);
    vint8mf4_t  v8  = __riscv_vle8_v_i8mf4(x, vl);
    vint32m1_t  v32 = __riscv_vsext_vf4_i32m1(v8, vl);   // widen 8 -> 32
    acc = __riscv_vadd_vv_i32m1_tu(acc, acc, v32, vl);
```

`e8, mf4` and `e32, m1` give the **same VLMAX** — which is precisely the point. The element
counts line up, so one `vl` governs the whole chain and no repacking is needed.

Work through the arithmetic once and it will stick:
```
   VLEN = 128
   e8,  mf4 :  VLMAX = (1/4 × 128) / 8  = 4
   e32, m1  :  VLMAX = (1   × 128) / 32 = 4     ✓ same
```

---

## 7.7 What VLA costs you

Be honest in your report — VLA is not free.

**1. `vl` is a runtime value.** The compiler cannot fully unroll, cannot compute loop trip
counts statically, and cannot software-pipeline as aggressively. Packed SIMD's fixed width
is a compile-time constant and enables optimisations RVV can't match.

**2. A `vsetvli` per pass.** At small `vl` this is real overhead. It is why `vsetivli`
exists, and why compilers work hard to hoist `vsetvli` out of loops when `vtype` doesn't
change.

**3. Awkward for very short, fixed-length vectors.** A 4-element dot product in a hot
inner loop is better served by fixed-width SIMD. RVV pays a setup cost to be general.

**4. Tail-policy subtleties.** §7.3's accumulator bug is legal-but-wrong code that works on
some machines and not others. This class of bug is *created* by the flexibility.

The trade is deliberate: RVV accepts per-loop overhead to gain binary portability across a
32× range of hardware widths. For the embedded and DSP markets it targets, that is clearly
the right call.

---

## 7.8 The hardware requirements, collected

Everything this chapter demands of your design, in one list. This is the "why" behind
Chapter 4's rules.

| Software pattern | Hardware requirement |
|---|---|
| Stripmine loop terminates | `vl > 0` whenever `AVL > 0`; `vl = 0` iff `AVL = 0` |
| Pointer advance | `vsetvli` **must** write the resulting `vl` to `rd` |
| Loop is VLEN-agnostic | `vlenb` readable; `vl` derived from AVL and VLMAX at runtime |
| Short final pass | Every operation honours `vl`; tail untouched |
| Cross-pass accumulation (§7.3) | **Tail-undisturbed must actually preserve the tail** |
| Reduction extraction | `vmv.x.s` and `vredsum.vs` must be correct and not slow |
| Conditionals (§7.4) | Per-element write enable (predication) **and** `vmerge` |
| LMUL tuning (§7.5) | Sequencer spans multi-register groups; **scoreboard tracks groups** |
| Mixed width (§7.6) | Fractional LMUL; EEW/EMUL derivation in the decoder |

Nine rows. Cross-check them against your M2 test plan.

---

## 🔧 Exercises

**7.1** Write a VLA `memcpy` for `int32` using only `vle32`/`vse32`. Verify on all three
VLENs. Then write it with `m8` and compare the instruction counts.

**7.2** Implement the `sum_rvv_fast` accumulator from §7.3. Now **remove the `_tu`
suffix**, rebuild, and run at VLEN=128 with N=10 on both Spike and QEMU. Do you get a wrong
answer? Explain why you might *not* — and why the code is still broken.

**7.3** Write a VLA function returning the **index** of the maximum element (not the value).
You will need `vid.v` and a mask. This is genuinely tricky; it is a good pair-programming
exercise.

**7.4** Take the SAXPY from example 02 and produce four variants: `m1`, `m2`, `m4`, `m8`.
Measure instructions/element for each at VLEN=128 and VLEN=512. Plot it. Explain the shape.

**7.5** Write a kernel that reads `int16` data and accumulates into `int32`, using
fractional LMUL. Confirm with `-S` that the compiler emits only one `vsetvli` per pass.

**7.6 (implementation)** For each of the nine rows in §7.8, write the directed test that
proves your hardware satisfies it. This is your M2 test plan — take it to Chapter 13.

**7.7 (mentors)** §7.3's `_tu` bug: construct a machine (on paper) on which the
non-`_tu` version gives the wrong answer, and one on which it gives the right answer. Both
must be spec-compliant. Use this to explain to your team why "it works on Spike" is not
verification.

---

## Key takeaways

- The **stripmine loop** is the one idiom: ask for `vl`, process `vl`, advance by `vl`,
  repeat. All the pointer arithmetic derives from the returned `vl`.
- The same binary reorganises itself across VLENs — 5 passes, 3 passes, 2 passes — with no
  recompilation.
- **Reductions** carry their accumulator in a vector register across passes. The fast form
  accumulates element-wise and reduces once — and **requires tail-undisturbed**, making it
  the single best test of your tail handling.
- **Conditionals** use masks two ways: predication (write-enable) and `vmerge` (mux). Never
  a branch.
- **LMUL is a tuning knob** trading register pressure for scaffolding overhead. It also
  forces your **scoreboard to track register groups**, not registers.
- **Fractional LMUL** makes mixed-width chains line up on a single `vl`.
- VLA costs you compile-time constants, a `vsetvli` per pass, and a class of tail-policy
  bugs. It buys binary portability across a 32× range of hardware.

---

*Part II complete. Next: [Chapter 8 — The Big Picture](../part3/08-big-picture-block-diagram.md)
— where all of this becomes a block diagram.*
