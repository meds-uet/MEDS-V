# Preface — How to Use This Book

*Building a RISC-V Vector Processor: from first principles to a benchmarked design*
Maktab-e-Digital Systems (MEDS), Lahore

---

## Who this book is for

Readers are assumed to have built, or to be able to follow, a single-cycle RV32I processor in SystemVerilog — the kind
of thing covered in the MEDS *"Build the own RISC-V Processor in a Day"* workshop. One
know what a register file, an ALU, and a control unit are. Most readers will never have touched a vector
processor, and the phrase "LMUL=1/2 with tail-agnostic policy" means nothing to the implementer yet.

That is exactly the right starting point. This book assumes:

| Assumed | Not assumed |
|---|---|
| Digital logic, FSMs, timing | Anything about SIMD or vectors |
| SystemVerilog RTL basics | Anything about RVV |
| The RV32I/RV64I scalar ISA | Out-of-order execution, scoreboards |
| How to run a simulator | Computer-architecture research literature |

Every vector-specific concept is built from zero.

## What the team has at the end

A working, parameterisable RISC-V vector processor — the team call the reference design
**MEDS-V** — that:

- implements a defined, honest subset of the ratified **RVV 1.0** extension,
- attaches to a scalar RV64 core as a decoupled coprocessor,
- runs real workloads (SAXPY, GEMM, FIR, 2-D convolution, ReLU/softmax, memcpy),
- is verified against Spike, the golden RISC-V reference model,
- and produces cycle counts one can defend in a comparison table against Ara, Vicuna,
  Saturn and a scalar baseline.

## How the book is organised

The book is five parts. **Read Part I and Part II before writing a single line of RTL.**
The single most common way this project fails is a team that starts coding datapath in
week 1 and discovers in week 9 that they misunderstood `vl`, `LMUL`, or the tail policy —
and has to throw away the register file.

| Part | Chapters | What it gives the implementer | Who reads it |
|---|---|---|---|
| **I — Foundations** | 1–3 | What a vector processor *is* and why it wins | Everyone, first |
| **II — The RVV 1.0 ISA** | 4–7 | The contract the hardware must honour | Everyone, first |
| **III — Microarchitecture** | 8–10 | The block diagram and every block in it | Everyone |
| **IV — Building It** | 11–13 | Milestones, RTL skeleton, verification | Implementers |
| **V — Proving It** | 14–16 | Workloads, measurement, comparison | Everyone, at the end |
| Appendices | A–E | Quick reference, glossary, setup, reading | Lookup |

### Chapter map

**Part I — Foundations**
- [Ch 1 — Why Vectors?](part1/01-why-vectors.md) — the loop-overhead problem, Flynn's
  taxonomy, SIMD vs. vector, where the energy actually goes.
- [Ch 2 — Anatomy of a Vector Processor](part1/02-anatomy-of-a-vector-processor.md) —
  vector registers, lanes, chaining, the vector length register, masks.
- [Ch 3 — From Cray-1 to RISC-V](part1/03-from-cray-to-riscv.md) — what each generation
  got right and wrong, and why RVV looks the way it does.

**Part II — The RVV 1.0 ISA**
- [Ch 4 — The Programmer's Model](part2/04-rvv-programmers-model.md) — VLEN, ELEN, SEW,
  LMUL, `vtype`, `vl`, the CSRs, masking, tail policies. **The most important chapter.**
- [Ch 5 — Instruction Set Tour](part2/05-rvv-instruction-set-tour.md) — every instruction
  class, with verified encodings.
- [Ch 6 — Writing and Running RVV Code](part2/06-writing-and-running-rvv-code.md) —
  assembly, intrinsics, autovectorisation, Spike and QEMU. Hands-on.
- [Ch 7 — Vector-Length-Agnostic Programming](part2/07-vector-length-agnostic-programming.md)
  — the stripmine idiom that makes RVV different from AVX and NEON.

**Part III — Microarchitecture**
- [Ch 8 — The Big Picture](part3/08-big-picture-block-diagram.md) — the MEDS-V top-level
  block diagram, explained signal by signal.
- [Ch 9 — The Building Blocks](part3/09-building-blocks.md) — one section per block:
  what it does, its interface, its internal structure, its hazards.
- [Ch 10 — The Design Space](part3/10-design-space.md) — VLEN, lane count, chaining,
  in-order vs. decoupled. The decisions teams must make in week 3, and their consequences.

**Part IV — Building It**
- [Ch 11 — The Project Roadmap](part4/11-project-roadmap.md) — milestones M0–M7 with exit
  criteria, team structure, and a week-by-week schedule.
- [Ch 12 — RTL Skeleton Walkthrough](part4/12-rtl-skeleton-walkthrough.md) — the file
  tree, the parameter package, and the modules one fill in.
- [Ch 13 — Verification Strategy](part4/13-verification-strategy.md) — unit tests,
  Spike co-simulation, the RVV architectural test suite, random stress.

**Part V — Proving It**
- [Ch 14 — Workloads](part5/14-workloads.md) — the six benchmark kernels, scalar and
  vector, and what each one stresses.
- [Ch 15 — Benchmarking and Comparison](part5/15-benchmarking-and-comparison.md) — what
  to measure, how to normalise it, and how to build a defensible comparison table.
- [Ch 16 — Beyond v1](part5/16-beyond-v1.md) — FPGA bring-up, floating point, multi-core.

**Appendices**
- [A — Instruction Quick Reference](appendix/A-instruction-quickref.md)
- [B — Glossary](appendix/B-glossary.md)
- [C — Toolchain Setup](appendix/C-toolchain-setup.md)
- [D — Annotated Reading List](appendix/D-reading-list.md)
- [E — Scope Contract (what MEDS-V v1 does and does not implement)](appendix/E-scope-contract.md)

## Conventions used in this book

> **📐 Spec box** — a direct, verified statement of what RVV 1.0 requires. When the RTL
> and this box disagree, the box is right.

> **⚠️ Trap** — a mistake teams reliably make here.

> **🔧 Exercise** — do this before moving on. Mentees: these are the homework.

> **🎯 Milestone hook** — connects the concept to a specific milestone in Chapter 11.

Code that appears in a fenced block with a `# verified` comment has been compiled and run
on the toolchain described in Appendix C. The outputs shown are real captured outputs, not
illustrations.

## A note to mentors

The failure mode of a project like this is not technical difficulty. It is **scope**. RVV
1.0 in full is roughly 600 instructions once one counts every SEW/LMUL/masking
combination — more than a small team can implement, let alone verify, in a semester.

Appendix E is a **scope contract**. Read it in week 1, negotiate it with the team, sign
it, and then defend it. A verified 60-instruction vector processor that runs six workloads
and has a comparison table is an excellent result. An unverified 300-instruction one that
runs nothing is not a result at all.

The second failure mode is verification debt. Chapter 13 puts Spike co-simulation at
**milestone M2**, not M6, for this reason. Build the checker before one builds the thing
it checks.

---

*Next: [Chapter 1 — Why Vectors?](part1/01-why-vectors.md)*
