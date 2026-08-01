# Chapter 15 — Benchmarking and Comparison

> **Purpose of this chapter.** Turn a working processor into a defensible result. What to
> measure, how to avoid the traps that produce wrong numbers, and how to build a comparison
> table that survives scrutiny.
>
> A reviewer's first question about any speedup number is *"compared to what, exactly?"*
> This chapter is about being able to answer it.

---

## 15.1 What to measure

Four categories, in descending order of how much they matter for this project.

| Category | Metric | Where it comes from |
|---|---|---|
| **Correctness** | Tests passed / total | Chapter 13 |
| **Performance** | Cycles per kernel; elements per cycle | RTL simulation |
| **Efficiency** | Lane utilisation; instructions per element | Trace analysis |
| **Cost** | LUTs/FFs or gate count; f_max | Synthesis (optional) |

Correctness comes first, and not as a formality: **a performance number from an unverified
design is worthless**, because the fastest way to compute the wrong answer is always
available.

### The primary metric

For a vector processor the most informative single number is **elements per cycle**:

```
                        elements processed
   elements/cycle  =  ──────────────────────
                        cycles taken
```

It is directly comparable across VLEN, lane count, and against other designs, and it has a
theoretical ceiling the team can state: `NR_LANES × ELEN / SEW`. Reporting *achieved* versus
*peak* elements per cycle is the single most useful efficiency figure the project can
produce.

```
                       achieved elements/cycle
   lane utilisation = ──────────────────────────
                       NR_LANES × (ELEN / SEW)
```

A design at 85% lane utilisation on memcpy and 30% on dot product has told its reader
exactly where its weaknesses are — and that is a *better* result than a vague "the team achieved
speedup", because it demonstrates understanding.

---

## 15.2 Instructions, cycles, and the difference

Chapter 1 measured instruction counts. Instruction counts are easy to obtain, useful for
sanity-checking, and **not a performance result**.

| | Instruction count | Cycle count |
|---|---|---|
| Source | Spike | RTL simulation |
| Available from | M0 | M4 |
| Measures | ISA efficiency | **The design** |
| Affected by microarchitecture | No | Yes |

A vector instruction that processes 32 elements takes many cycles. Reporting "11× fewer
instructions" as though it were "11× faster" is the most common way student vector-processor
projects overstate their results, and it is immediately obvious to anyone who reads
carefully.

**The honest formulation** separates the two:

> "The vector implementation executes 12.5× fewer instructions than the scalar baseline. On
> MEDS-V-S (VLEN=128, 1 lane) this translates to a 3.2× cycle-count speedup; the gap is
> accounted for by the single-lane datapath, which processes one element per cycle."

That sentence states the result, states the shortfall, and explains it. It is stronger than
the larger number would have been.

---

## 15.3 How to measure without lying to the implementerrself

Three traps, all of which produced wrong numbers while preparing this book.

### Trap 1 — Mismatched baselines

The scalar and vector builds must differ **only** in the kernel. They must use the same
harness, the same input data, and the same self-checks.

While building the SAXPY benchmark in Chapter 1, a single `rv64gc` baseline was used for
both variants. The `rv64gcv` build's array-initialisation loop had been auto-vectorised by
GCC, making the *whole program* cheaper than its supposed baseline — and the subtraction
produced **negative kernel instruction counts**.

The fix is a baseline per ISA. But the deeper lesson is that any measurement built on
subtracting two different builds is fragile.

### Trap 2 — Asymmetric harnesses

A subtler version of the same thing. If the self-check loop runs only in the kernel builds
and not in the baseline, its cost is charged to the kernel. In the SAXPY harness that
inflated the scalar figure from 7.0 to 12.0 instructions per element — a 70% error, in the
direction that flatters the vector result.

### Trap 3 — Dead-code elimination differences

The one that finally forced a change of method. The six-kernel benchmark originally
subtracted a `-DKERNEL=0` build with the kernel call removed. Removing the call changes what
the optimiser can eliminate, so the two builds differed by considerably more than the
kernel. The result: a vector memcpy apparently costing **4.3 instructions per element**,
roughly twenty times the true figure — and, crucially, a number that looked plausible enough
to publish.

### The method that works: differential measurement

Build the harness **twice, identically**, except that one runs the kernel once and the other
runs it twice. Subtract.

```c
    for (int rep = 0; rep < REPS; rep++) {
        BARRIER();                     // asm volatile("" ::: "memory")
        kernel(...);
        BARRIER();
    }
```

```
   cost of one kernel invocation  =  count(REPS=2) − count(REPS=1)
```

Startup, initialisation, the checksum loop, code layout, and whatever the auto-vectoriser
did to the harness are **identical by construction** and cancel exactly. The memory barriers
stop the compiler merging or eliminating the second call.

The corrected numbers were physically consistent for the first time:

```
  kernel      scalar  VLEN=128  VLEN=256  VLEN=512    x128    x256    x512
  --------- -------- --------- --------- --------- ------- ------- -------
  memcpy        5141       275       147        83  18.69x  34.97x  61.94x
  saxpy         8214       660       340       180  12.45x  24.16x  45.63x
  dotprod       7193      2331      1179       603   3.09x   6.10x  11.93x
  relu          7489       307       163        91  24.39x  45.94x  82.30x
  fir          66134      7580      3805      1917   8.72x  17.38x  34.50x
  gemm         30925      3620      1876      1876   8.54x  16.48x  16.48x
```

> **🎯 The check that catches all three traps: predict the number first.**
> memcpy at `m8`, VLEN=128 gives VLMAX=32, so 1024 elements need 32 passes at ~8
> instructions each ≈ 256. Measured: 275. The model and the measurement agree.
>
> Under the broken method the same cell read 4406 — which no model predicts. **Any
> measurement that a hand calculation cannot reproduce to within ~15% should be treated as
> a bug in the measurement, not a discovery about the hardware.** This one checks would have
> caught every trap in this section.

---

## 15.4 Measuring cycles on the RTL

From M4, the real numbers come from simulation. Instrument the testbench with a free-running
cycle counter and bracket the kernel:

```systemverilog
  // Count cycles between two magic markers the kernel writes to a
  // testbench-observable address, so setup and teardown are excluded.
  always_ff @(posedge clk_i)
    if (counting) cycle_count <= cycle_count + 1;
```

Report, per kernel per configuration:

| Column | Meaning |
|---|---|
| Cycles | Total for the kernel |
| Elements | Problem size |
| Elements/cycle | The primary metric |
| Peak elements/cycle | `NR_LANES × ELEN / SEW` |
| Lane utilisation | Achieved ÷ peak |
| Stall cycles | Broken down by cause |

**The stall breakdown is where the engineering insight lives.** Categorise every stalled
cycle:

- waiting for memory (VLSU)
- RAW hazard on a vector register
- RAW hazard on `v0` (the mask dependency)
- structural conflict on the VRF write port
- `vsetvli` synchronisation with the scalar core

A pie chart of stall causes tells the reader — and the team — exactly what to fix next. It
is far more valuable than another speedup digit, and it is the evidence that the M6
optimisation choices were made on data rather than intuition.

---

## 15.5 The configuration sweep

The headline result. Same RTL, same tests, same kernels, across the parameter space:

```
                    VLEN=128        VLEN=256        VLEN=512
                  1L   2L   4L    1L   2L   4L    1L   2L   4L
   memcpy         ..   ..   ..    ..   ..   ..    ..   ..   ..
   saxpy          ..   ..   ..    ..   ..   ..    ..   ..   ..
   dotprod        ..   ..   ..    ..   ..   ..    ..   ..   ..
   relu           ..   ..   ..    ..   ..   ..    ..   ..   ..
   fir            ..   ..   ..    ..   ..   ..    ..   ..   ..
   gemm           ..   ..   ..    ..   ..   ..    ..   ..   ..
```

Six kernels × nine configurations = 54 data points from one designs, produced by one script.
Nobody can generate that table without a genuinely parameterised, genuinely working
processor, which is exactly why it is the strongest thing the project can show.

**Two questions this table answers, and neither is obvious in advance:**

1. **VLEN or lanes — which is the better use of area?** Both increase throughput. VLEN adds
   register file; lanes add datapath. The kernels will not agree, and the disagreement is
   the finding.
2. **Where does each kernel saturate?** GEMM already stops scaling past VLEN=256 in the
   instruction-count data (Chapter 14 §14.9), because a 16×16 matrix runs out of elements.
   Expect more of this in the cycle data, and expect the saturation point to differ per
   kernel.

> **⚠️ Report saturation, do not hide it.** A table where everything scales linearly means
> either a very narrow benchmark set or a measurement error. Real designs saturate, and
> explaining *why* each kernel saturates where it does is the analysis a reviewer is looking
> for.

---

## 15.6 Comparing against other designs

This is where projects most often overreach. The rules:

### Rule 1 — Compare like with like, and say so

| Design | VLEN | Lanes | ELEN | FP? | Technology | Source |
|---|---|---|---|---|---|---|
| **MEDS-V-S** | 128 | 1 | 32 | No | FPGA / sim | This work |
| **MEDS-V-L** | 512 | 4 | 32 | No | FPGA / sim | This work |
| Vicuna | 128 | — | 32 | No | FPGA | TU Wien |
| Ara2 | varies | 2–16 | 64 | Yes | 22 nm ASIC | ETH Zürich |
| Saturn | varies | varies | 64 | Yes | ASIC | UC Berkeley |

The moment this table is drawn, the differences become visible: comparing a 32-bit
integer-only FPGA design against a 64-bit ASIC with a floating-point unit is not a like-for-
like comparison, and pretending otherwise is worse than not comparing at all.

### Rule 2 — Normalise, and state the normalisation

Raw cycle counts are not comparable across designs. Useful normalised metrics:

- **Elements per cycle per lane** — removes the lane-count difference
- **Elements per cycle per VLEN bit** — removes the width difference
- **Cycles per element at matched VLEN** — the closest to like-for-like

### Rule 3 — Distinguish measured from cited

Numbers measured on MEDS-V and numbers quoted from a paper are different kinds of evidence.
Mark them. If a published figure is quoted, cite it, and state the configuration it came
from.

### Rule 4 — The scalar baseline is the most honest comparison

The comparison the team fully controls, fully understands, and can defend in every detail:
**the same kernel, the same compiler, the same simulator, scalar versus vector**. It is not
glamorous, but it is unimpeachable, and it should be the primary result. Comparisons against
other projects are context.

### A defensible claim

> On the six-kernel suite, MEDS-V-L (VLEN=512, 4 lanes) achieves *X* elements per cycle on
> memcpy against a peak of 16, a lane utilisation of *Y*%. Against the scalar RV64GC
> baseline compiled at `-O2` and run on the same simulator, this is a *Z*× cycle-count
> speedup. Ara2 reports higher utilisation at comparable lane counts; its design includes
> chaining and a multi-banked VRF, neither of which MEDS-V v1 implements.

Specific, bounded, and it names the gap before a reviewer does.

---

## 15.7 Area and frequency

If the design is synthesised — for FPGA or with an open ASIC flow — report:

| Metric | Note |
|---|---|
| LUTs / FFs / BRAM (FPGA) | State the device and the tool version |
| Gate count (ASIC) | State the library and the target |
| f_max | State the constraint and whether timing closed |
| Critical path | **Name the path.** This is the useful part. |

The critical path is worth more than the frequency number. In a vector unit it is almost
always one of: the VRF read → ALU → VRF write loop, the mask-generation path into the write
enables, or the VLSU address generator. Knowing which one MEDS-V hits, and by how much, is a
genuine engineering result and directly informs what to pipeline next.

---

## 15.8 Reproducibility

Every number in the report should be regenerable by one command.

```bash
./scripts/run_all_benchmarks.sh        # → results/YYYY-MM-DD/*.csv
```

Record alongside the results: the git commit hash, the tool versions, and the
configuration parameters. Six months later, when someone asks why a number changed, this is
the only way to find out.

The book's own numbers follow this rule:

```bash
python3 scripts/param_sweep.py                      # RTL configuration sweep
make -C verif tb_vec_csr                            # unit tests
make -C examples/04-workloads check                 # kernel correctness
make -C examples/04-workloads bench                 # instruction counts
make -C examples/02-saxpy bench                     # the Chapter 1 measurement
```

---

## 15.9 The results chapter of the report

A suggested structure:

1. **Methodology** — how measured, what compared, what normalised. *First, not last.*
2. **Correctness** — tests passed, by layer. The precondition for everything else.
3. **Instruction counts** — scalar vs vector, the ISA-level result.
4. **Cycle counts** — the design-level result, with the instruction/cycle gap explained.
5. **The configuration sweep** — the headline table, with saturation analysis.
6. **Stall analysis** — where the cycles went.
7. **Comparison** — scalar baseline first, other designs second, with the caveat table.
8. **Area and frequency** — if synthesised, with the critical path named.
9. **Limitations** — the scope contract, restated as a list. *Before* the conclusion.

> **Section 9 is not an apology.** A report that says "indexed loads are not implemented;
> the VLSU requires natural alignment; there is no chaining; here is what each costs" reads
> as authoritative. One that omits them reads as incomplete the moment a reviewer notices —
> and a reviewer will notice.

---

## 🔧 Exercises

**15.1** Reproduce all five commands in §15.8. Confirm the outputs match the book.

**15.2** For each of the three traps in §15.3, construct the wrong measurement deliberately
and observe the error. Predicting each error's direction beforehand is the point.

**15.3** Compute peak elements per cycle for all nine configurations of §15.5, at SEW=32 and
at SEW=8.

**15.4** From Chapter 14 §14.9, GEMM shows 1876 instructions at both VLEN=256 and 512.
Calculate the matrix size at which VLEN=512 would help again, and verify.

**15.5** Write `scripts/run_all_benchmarks.sh` to regenerate every number in one command,
tagged with the git hash and tool versions.

**15.6 (mentors)** Draft the comparison table of §15.6 with real figures from the Ara2 and
Saturn papers. For each row, write the sentence explaining why the comparison is or is not
like-for-like.

---

## Key takeaways

- **Elements per cycle** is the primary metric; **lane utilisation** (achieved ÷ peak) is the
  most informative efficiency figure.
- **Instructions are not cycles.** State both, and explain the gap.
- Three measurement traps, all encountered while writing this book: mismatched baselines
  (negative counts), asymmetric harnesses (70% error), and dead-code-elimination differences
  (20× error).
- **Differential measurement — REPS=2 minus REPS=1 — is immune to all three**, because the
  two builds are identical by construction.
- **Predict every number before measuring it.** A measurement a hand model cannot reproduce
  is a measurement bug.
- The **configuration sweep** (6 kernels × 9 configurations) is the headline result. Report
  saturation rather than hiding it.
- Compare like with like; normalise and say how; distinguish measured from cited. **The
  scalar baseline is the most defensible comparison and should be primary.**
- Name the critical path — it is worth more than the frequency number.
- Every number regenerable by one command, tagged with commit and tool versions.
- Put limitations **before** the conclusion. They read as authority, not apology.

---

*Next: [Chapter 16 — Beyond v1](16-beyond-v1.md)*
