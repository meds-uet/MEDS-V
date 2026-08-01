# Chapter 1 — Why Vectors?

> **Goal of this chapter.** Establish, with measured numbers, that a vector processor
> solves a real problem — and make it possible to say precisely *which* problem, because that
> determines what the hardware must be good at.

---

## 1.1 The problem: most instructions do no useful work

Here is SAXPY — "single-precision A times X plus Y" — the *hello world* of numerical
computing. It is the inner loop of essentially every dense linear-algebra routine.

```c
void saxpy(int n, float a, const float *x, float *y) {
    for (int i = 0; i < n; i++)
        y[i] = a * x[i] + y[i];
}
```

Compiled for a plain scalar RV64GC core (`-O2`, vectorisation disabled), the inner loop is
exactly seven instructions:

```asm
# verified: riscv64-unknown-elf-gcc -march=rv64gc -mabi=lp64d -O2 -fno-tree-vectorize
.L3:
    flw     fa5, 0(a1)          # load x[i]
    flw     fa4, 0(a2)          # load y[i]
    addi    a2, a2, 4           # bump y pointer
    addi    a1, a1, 4           # bump x pointer
    fmadd.s fa5, fa5, fa0, fa4  # a*x[i] + y[i]        <-- the ONLY useful work
    fsw     fa5, -4(a2)         # store y[i]
    bne     a2, a0, .L3         # loop back
```

Count what the processor actually accomplishes. Of those seven instructions, **one** —
`fmadd.s` — performs the arithmetic the programmer asked for. Two more move data that
genuinely must move (`flw`, `flw`, `fsw` — call it three). The remaining three (`addi`,
`addi`, `bne`) are pure **loop overhead**: bookkeeping the machine performs to keep track
of *where it is*, which contributes nothing to the answer.

That is 3/7 ≈ 43% of the instruction stream spent on administration.

And the cost is worse than the count suggests, because every one of those seven
instructions must be individually:

1. **fetched** from instruction memory (I-cache energy, fetch bandwidth),
2. **decoded** (control logic switching),
3. **register-renamed / hazard-checked** (on any core more sophisticated than single-cycle),
4. **issued**, and
5. **committed**.

For a 32-bit `fmadd.s` doing one multiply-add, the *overhead of instruction delivery*
typically costs several times more energy than the arithmetic itself. This is the central
economic fact of modern processor design: **fetching and decoding instructions is
expensive; doing arithmetic is cheap.**

### The loop-carried branch is worse than it looks

`bne` is not just one instruction. On a pipelined core it is a control hazard. Predict it
right and one pays ~nothing; predict it wrong — which happens at least once per loop, on
the final iteration — and one flush the pipeline. On a deeply pipelined machine that is
10–20 cycles. A short loop that runs 8 times can spend more cycles recovering from its
exit misprediction than doing its work.

---

## 1.2 The idea: say it once, mean it many times

The insight is almost embarrassingly simple.

> The loop above tells the machine *"do this one thing"* 1024 times.
> Why not tell it once: *"do this thing to 1024 elements"*?

That is a **vector instruction**. One instruction, one fetch, one decode, one hazard
check — and *N* elements of work.

Here is the same SAXPY written with the RISC-V Vector extension:

```asm
# verified: riscv64-unknown-elf-gcc -march=rv64gcv -mabi=lp64d -O2
.L3:
    vsetvli   a5, a0, e32, m1, ta, ma   # how many elements can I do this pass?
    vle32.v   v2, 0(a1)                 # load a whole vector of x
    vle32.v   v1, 0(a2)                 # load a whole vector of y
    slli      a4, a5, 2                 # bytes consumed = vl * 4
    sub       a0, a0, a5                # n -= vl
    add       a1, a1, a4                # x += vl
    vfmacc.vf v1, fa0, v2               # v1 += a * v2   (whole vector!)
    vse32.v   v1, 0(a2)                 # store the vector back
    add       a2, a2, a4                # y += vl
    bne       a0, zero, .L3
```

Ten instructions — three *more* than the scalar loop. But the scalar loop's seven
instructions process **one** element. These ten process **`vl`** elements, where `vl` is
whatever the hardware can handle in one go.

The instructions-per-element figure is therefore `10 / vl`, and *`vl` grows with the
hardware*.

### The measurement

Both versions were run on Spike (the official RISC-V reference simulator), counting every
committed instruction, for N = 1024 elements, with the array-initialisation harness
subtracted out:

```
# verified: spike --isa=rv64gcv_zvl<VLEN>b -l, committed-instruction count
SAXPY kernel only, N = 1024 elements

  scalar rv64gc      7188 instr    7.020 instr/element    1.00x
  RVV VLEN=128       2578 instr    2.518 instr/element    2.79x
  RVV VLEN=256       1298 instr    1.268 instr/element    5.54x
  RVV VLEN=512        658 instr    0.643 instr/element   10.92x
```

Check the arithmetic against the model. A 128-bit vector register holds 4 × `float32`, so
`vl = 4`, and 10/4 = 2.50 instructions per element — measured 2.52. At VLEN=512, `vl = 16`,
so 10/16 = 0.625 — measured 0.643. The tiny excess is the loop prologue.

**The model predicts the measurement to within 3%.** That is the kind of understanding one
want before writing RTL: a reader should be able to predict a processor of one's own's instruction
count on paper.

> **⚠️ Trap — instructions are not cycles.**
> An 11× reduction in *instructions* is not an 11× reduction in *time*. A `vle32.v` that
> loads 16 floats takes longer than an `flw` that loads one. What the team has genuinely
> eliminated is the **overhead**: fetch, decode, hazard check, loop bookkeeping, branch
> mispredicts. Whether that becomes 11× or 3× of real speedup depends on the
> microarchitecture *one* are about to design. Chapter 15 is entirely about measuring this
> honestly.

---

## 1.3 The three things vectors actually buy one

Be precise about the wins, because each one maps to a design decision later.

### Win 1 — Amortised instruction delivery
One fetch/decode/issue serves `vl` elements. **Design consequence:** the front end can be
narrow and simple. One does *not* need superscalar issue to get high throughput; MEDS-V
issues one vector instruction at a time and still keeps many lanes busy. This is why
vector machines are attractive for a student project — the hard part of a fast scalar core
(wide issue, renaming, speculation) is simply not needed.

### Win 2 — Guaranteed independence
When a program says `vadd.vv v1, v2, v3`, it is *promising* the hardware that element 0 and
element 7 are independent. No dependency check is needed *between elements*. **Design
consequence:** one can build N parallel **lanes** and just let them run. Deriving that same
guarantee from a scalar loop requires a dependence analyser and speculative
memory-disambiguation hardware. The ISA hands it to the implementer for free.

### Win 3 — Known memory access patterns
`vle32.v` says "give me 16 consecutive 32-bit words starting here". That is a description
of a *pattern*, not 16 independent addresses. **Design consequence:** the load/store unit
can generate one wide, aligned burst instead of 16 lookups, and the request can be issued
long before the data is needed. Latency hiding becomes structural rather than speculative.

### And the thing they don't buy one
Vectors do **not** help code that is:
- **control-heavy** — `if`-dense logic with unpredictable branches (masking helps some;
  Chapter 4 §4.7),
- **serially dependent** — `x[i] = x[i-1] * k` cannot be vectorised without restructuring,
- **pointer-chasing** — linked lists, trees; the addresses aren't known in advance,
- **short** — if N is 3, the `vsetvli` overhead dominates.

Knowing what the machine is *not* for is part of the design. Say it out loud in the
project report.

---

## 1.4 Where vectors sit: Flynn's taxonomy

Michael Flynn's 1966 classification sorts machines by how many instruction streams and
data streams they manage:

| | Single data stream | Multiple data streams |
|---|---|---|
| **Single instruction stream** | **SISD** — a classic scalar core. The RV32I workshop processor. | **SIMD** — one instruction, many data elements. **Vector processors live here.** |
| **Multiple instruction streams** | MISD — rare; systolic/pipelined fault-tolerant designs. | **MIMD** — multicore, multiprocessor. Each core runs its own program. |

Vector processors are SIMD. So are GPUs (loosely — they are more precisely SIMT), and so
are the SIMD extensions bolted onto scalar ISAs (SSE, AVX, NEON).

The distinction that matters for *the* project is not SISD vs. SIMD. It is:

### Packed SIMD vs. true vector

These are the two ways to build a SIMD machine, and RVV deliberately chose the second.

| | **Packed SIMD** (SSE, AVX, NEON) | **True vector** (Cray, RVV) |
|---|---|---|
| Register width | **Fixed by the ISA.** `xmm0` is 128 bits, forever. | **An implementation choice.** VLEN is whatever one builds. |
| How many elements? | Baked into the opcode. `paddd` = exactly 4 int32. | Read from the `vl` register at runtime. |
| Widening VLEN | Requires a **new ISA**: SSE→AVX→AVX-512, new opcodes each time | Same binary, wider hardware, more speed. Nothing recompiles. |
| Loop remainder (N not a multiple of width) | Programmer writes a scalar cleanup loop | Hardware shortens the last `vl` automatically |
| Instruction count | 4000+ in AVX-512 | ~600 in RVV 1.0, and *far* fewer if one counts opcodes |

That third row is the killer argument, and one already have the evidence. Look again at
the measurement in §1.2:

> The **same, unmodified binary** produced 2.51, 1.26, and 0.64 instructions per element on
> VLEN=128, 256 and 512 machines.

Nothing was recompiled between those rows; only a simulator flag changed. A packed-SIMD binary
compiled for 128-bit SSE runs at exactly SSE speed on an AVX-512 machine forever, unless
someone rebuilds it.

This property is called **vector-length agnosticism (VLA)**, it is the single most
important idea in RVV, and Chapter 7 is devoted to it.

> **🎯 Milestone hook.** VLA is also why the project can be *incremental*. Build MEDS-V
> with VLEN=128 in milestone M3; re-parameterise to VLEN=512 in M6; every test and
> benchmark the team has written still runs, unmodified. Design for this from day one and the
> parameter is free. Hard-code `128` anywhere and the team will pay for it in week 10.

---

## 1.5 Vector vs. GPU — a question the team will be asked

Someone will ask "why not just use a GPU?" Have an answer.

| | **Vector unit (MEDS-V)** | **GPU** |
|---|---|---|
| Programming model | Instructions in *one* thread's stream | Thousands of independent threads (SIMT) |
| Divergent control flow | Masks — cheap, explicit, programmer-visible | Warp divergence — hardware serialises paths |
| Latency hiding | Long vectors + chaining + decoupling | Massive multithreading (swap warps on stall) |
| Coupling to scalar code | Tight — shares registers, cache, address space | Loose — separate memory, kernel launch cost |
| Good for | Kernels *embedded in* scalar programs; DSP; low latency; embedded/edge | Huge, uniform, throughput-bound batch work |
| Startup cost | One `vsetvli` (~1 cycle) | Kernel launch (~microseconds) |

The vector unit's advantage is **granularity**. It profits on a 200-element loop in the
middle of ordinary C code — far too small to be worth a GPU launch. That is precisely the
regime of embedded DSP, signal processing, and edge ML inference, which is where RVV is
being deployed commercially.

---

## 1.6 The energy argument (the real reason industry cares)

Rough, order-of-magnitude figures for a mature process node — the exact numbers vary, the
*ratios* are stable and are what matter:

| Operation | Relative energy |
|---|---|
| 32-bit integer add | 1× |
| 32-bit floating-point multiply-add | ~10× |
| Read a 32-bit value from the register file | ~2–5× |
| **Fetch + decode + issue one instruction** | **~20–50×** |
| Read 32 bits from L1 cache | ~50× |
| Read 32 bits from DRAM | ~5000× |

Read the fourth row again. **Delivering an instruction can cost more energy than the
floating-point operation it commands.**

A vector instruction amortises that ~20–50× cost over `vl` elements. At `vl = 16` the team has
divided the dominant energy term by 16 while the arithmetic energy stayed the same. That is
why every serious embedded AI/DSP chip has a vector unit, and it is the argument to put in
the project's motivation slide.

It also indicates where *not* to spend design effort: making the arithmetic units
marginally more efficient is second-order. Keeping the lanes *fed* is first-order.

---

## 1.7 What this means for the machine to be built

Everything above translates into concrete requirements. This list is the seed of the block
diagram in Chapter 8:

1. **A place to hold vectors.** Not 32 × 64-bit scalars, but 32 × VLEN-bit *vector
   registers*. This is the biggest structure by area — Chapter 9 §9.3.
2. **A way to say "how many elements".** A `vl` register, and an instruction to set it.
   This is the machinery of vector-length agnosticism — Chapter 4 §4.4.
3. **Parallel arithmetic.** Multiple **lanes**, each a slice of the register file plus its
   own ALU, all doing the same operation on different elements — Chapter 2 §2.3.
4. **A memory unit that speaks in patterns.** Unit-stride, strided, and indexed accesses,
   generating wide bursts — Chapter 9 §9.5. *This will be the hardest block. Budget for it.*
5. **A way to turn elements off.** Masks, so `if` inside a loop can be vectorised —
   Chapter 4 §4.7.
6. **A connection to the scalar core.** Vector code is embedded in scalar code; they share
   an instruction stream, and scalars flow in (`vfmacc.vf` took `fa0`) and out (reductions)
   — Chapter 9 §9.2.

---

## 🔧 Exercises

**1.1 (everyone)** Reproduce the measurement in §1.2. The harness is in
[`examples/02-saxpy/`](../../examples/02-saxpy/); run `make bench`. Confirm one gets ~7.0
instructions/element scalar and ~2.5 at VLEN=128.

**1.2 (everyone)** Change SAXPY to use `float64` instead of `float32`. Predict the
instructions/element at VLEN=128 *before* one measures. Then measure. Explain any gap.

**1.3** Take the scalar loop in §1.1 and hand-count instruction fetches for N=1000. Now do
the same for the vector loop at VLEN=256. Express the saving as a percentage of total
front-end energy, using the table in §1.6.

**1.4 (discussion)** Name three kernels from the own coursework that would vectorise well,
and two that would not. For the two, say *why* — dependence, control flow, or access
pattern? Keep this list; §14 turns the good ones into the benchmark suite.

**1.5 (mentors)** The vector loop in §1.2 has 10 instructions, of which 4 are scalar
bookkeeping (`slli`, `sub`, `add`, `add`) and 1 is a branch. At what value of `vl` does
scalar bookkeeping become the bottleneck again? What does that indicate about the minimum
useful VLEN for MEDS-V?

---

## Key takeaways

- Scalar loops spend a large fraction of their instructions — 43% in SAXPY — on overhead
  that computes nothing.
- A vector instruction amortises fetch, decode, and hazard-checking across many elements.
  Measured: 7.0 → 0.64 instructions/element from scalar to VLEN=512.
- Vectors buy one (1) amortised instruction delivery, (2) a free guarantee of element
  independence, (3) declared memory access patterns.
- RVV is a **true vector** ISA, not packed SIMD: the same binary gets faster on wider
  hardware. This is *vector-length agnosticism* and it shapes every design choice ahead.
- The dominant cost in modern chips is moving instructions and data, not arithmetic.
  The design goal is **keeping the lanes fed**, not building clever ALUs.

---

*Next: [Chapter 2 — Anatomy of a Vector Processor](02-anatomy-of-a-vector-processor.md)*
