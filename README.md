# MEDS-V — Building a RISC-V Vector Processor

**A complete guide book, RTL skeleton, and benchmark suite for building a RISC-V Vector
(RVV 1.0) processor from first principles.**

Maktab-e-Digital Systems (MEDS), Lahore · Apache-2.0

---

## What this repository is

A sixteen-chapter book plus the working code to go with it, for a team that wants to design
a RISC-V vector processor and has never worked on one before.

It assumes familiarity with digital logic, SystemVerilog, and the scalar RV32I/RV64I ISA —
roughly the level of the MEDS *"Build your own RISC-V Processor in a Day"* workshop. It
assumes **no** prior knowledge of SIMD, vector architecture, or the V extension.

The target design, **MEDS-V**, is a parameterisable integer vector unit implementing a
documented subset of ratified RVV 1.0 (`Zve32x` + `Zvl128b`), attached to a scalar RV64 core
as a decoupled coprocessor.

Everything in the book that is presented as a fact has been checked against the ratified
specification or produced by running the tools. Instruction encodings were obtained by
assembling the instruction and reading back the machine word; performance figures are
captured simulator output, not illustrations.

---

## Repository layout

```
book/                 The guide book — 16 chapters + 5 appendices
├── 00-preface.md         How to use the book; chapter map
├── part1/                Foundations: what a vector processor is, and why
├── part2/                The RVV 1.0 ISA: the contract the hardware must honour
├── part3/                Microarchitecture: the block diagram, block by block
├── part4/                Building it: roadmap, RTL walkthrough, verification
├── part5/                Proving it: workloads, benchmarking, what comes next
└── appendix/             Quick reference, glossary, setup, reading list, scope contract

rtl/                  SystemVerilog skeleton — lints clean, elaborates at 16 configs
├── meds_v_pkg.sv         Parameters and types            [COMPLETE]
├── vec_csr.sv            CSR / vtype unit                [COMPLETE — worked reference]
├── vrf.sv                Vector register file            [COMPLETE]
├── vec_decoder.sv        Instruction decoder             [SKELETON — M1]
├── vec_lane.sv           Segmented ALU                   [SKELETON — M3]
├── vec_sequencer.sv      Sequencer + hazard unit         [SKELETON — M3]
├── vec_lsu.sv            Vector load/store unit          [SKELETON — M4]
└── meds_v_top.sv         Integration                     [SKELETON — M3]

verif/                Testbenches and lint targets
└── tb_vec_csr.sv         Reference unit testbench        [COMPLETE — 73 checks]

examples/             Runnable RVV programs, all verified
├── common/               Bare-metal startup and shared build rules
├── 01-hello-vector/      Smallest self-checking RVV program
├── 02-saxpy/             Scalar vs vector, measured
├── 03-stripmine/         Vector-length agnosticism, made visible
└── 04-workloads/         The six benchmark kernels

scripts/              Measurement and verification tooling
├── param_sweep.py        Elaborate across the VLEN × lane-count sweep
├── cosim_diff.py         Compare an RTL trace against Spike's golden trace
├── bench_kernels.py      Instruction-count benchmark for the six kernels
├── count_instr.py        SAXPY instruction counting
└── build_pdf.py          Render the whole book to a single PDF

docs/
└── MEDS-V-Building-a-RISC-V-Vector-Processor.pdf    174 pages, generated
```

### The book as a PDF

The whole book renders to a single typeset PDF — title page, contents, part dividers,
and all 22 chapters and appendices:

```bash
python3 scripts/build_pdf.py
```

It needs `pandoc` and `google-chrome`/`chromium`; there is no LaTeX dependency. Chrome's
print-to-PDF does the rendering, which suits this book better than LaTeX would, because the
ASCII block diagrams need a monospace font with full box-drawing coverage and no line
wrapping at all.

---

## Quick start

Requires a RISC-V toolchain with RVV 1.0 support, Spike, QEMU, and Verilator. Exact versions
and setup instructions are in [Appendix C](book/appendix/C-toolchain-setup.md).

```bash
# 1. Smallest RVV program, self-checking, on Spike at three vector lengths
make -C examples/01-hello-vector run-all

# 2. Vector-length agnosticism: ONE binary, three machines, different loop structure
make -C examples/03-stripmine run-all

# 3. The six benchmark kernels, checked against their scalar references
make -C examples/04-workloads check

# 4. RTL: lint, unit test, and the full parameter sweep
make -C verif lint
make -C verif tb_vec_csr
python3 scripts/param_sweep.py
```

If all four pass, the environment is complete. This is the milestone-M0 exit criterion for
every team member.

---

## What the code does today

**The examples all run.** Captured output, not illustration:

```
$ make -C examples/01-hello-vector run-all
  VLEN=128  PASS
  VLEN=256  PASS
  VLEN=512  PASS

$ make -C examples/04-workloads check
VLEN = 128 bits, N = 257 (not a multiple of VLMAX)
  pass  memcpy     (257 elements)
  pass  saxpy      (257 elements)
  pass  dotprod    (result -861571)
  pass  relu       (257 elements)
  pass  fir        (250 elements)
  pass  gemm       (77 elements)
all 6 kernels match the scalar reference
```

**The RTL lints clean and re-elaborates across the whole parameter space:**

```
$ python3 scripts/param_sweep.py
   VLEN  LANES       VRF  slice/lane   result
    128      1       4 Kib      128 b   PASS
    ...
   1024      8      32 Kib      128 b   PASS
  All configurations elaborate cleanly.
```

**The reference unit testbench passes, unmodified, at every vector length:**

```
  VLEN=128  === PASS : 73 checks ===
  VLEN=256  === PASS : 77 checks ===
  VLEN=512  === PASS : 85 checks ===
```

**Measured instruction counts for the six kernels** (Spike, N = 1024, one kernel invocation
isolated by differential measurement):

```
  kernel      scalar  VLEN=128  VLEN=256  VLEN=512    x128    x256    x512
  memcpy        5141       275       147        83  18.69x  34.97x  61.94x
  saxpy         8214       660       340       180  12.45x  24.16x  45.63x
  dotprod       7193      2331      1179       603   3.09x   6.10x  11.93x
  relu          7489       307       163        91  24.39x  45.94x  82.30x
  fir          66134      7580      3805      1917   8.72x  17.38x  34.50x
  gemm         30925      3620      1876      1876   8.54x  16.48x  16.48x
```

> These are **instruction counts, not cycle counts** — the distinction matters, and
> [Chapter 15](book/part5/15-benchmarking-and-comparison.md) is about not conflating them.
> Cycle counts come from the RTL, once the datapath and load/store unit are built.

**What is not built yet:** the decoder tables, the ALU beyond the segmented adder, the
sequencer FSM, the load/store unit, and the mask and reduction blocks. Those are the
project. The skeleton provides the module boundaries, the port lists, and the structurally
hard parts; the `TODO` markers are the work.

---

## Reading order

**Read Parts I and II before writing any RTL.** The most common way this project fails is a
team that starts on the datapath in week 1 and discovers in week 9 that it misunderstood
`vl`, `LMUL`, or the tail policy — and has to redo the register file.

| Part | Chapters | Content |
|---|---|---|
| [Preface](book/00-preface.md) | — | How to use the book |
| **I — Foundations** | [1](book/part1/01-why-vectors.md) · [2](book/part1/02-anatomy-of-a-vector-processor.md) · [3](book/part1/03-from-cray-to-riscv.md) | Why vectors; anatomy of a vector processor; Cray-1 to RISC-V |
| **II — The RVV 1.0 ISA** | [4](book/part2/04-rvv-programmers-model.md) · [5](book/part2/05-rvv-instruction-set-tour.md) · [6](book/part2/06-writing-and-running-rvv-code.md) · [7](book/part2/07-vector-length-agnostic-programming.md) | Programmer's model; instruction set; writing and running RVV code; VLA programming |
| **III — Microarchitecture** | [8](book/part3/08-big-picture-block-diagram.md) · [9](book/part3/09-building-blocks.md) · [10](book/part3/10-design-space.md) | The block diagram; every block in it; the design space |
| **IV — Building it** | [11](book/part4/11-project-roadmap.md) · [12](book/part4/12-rtl-skeleton-walkthrough.md) · [13](book/part4/13-verification-strategy.md) | Milestones M0–M7; RTL walkthrough; verification |
| **V — Proving it** | [14](book/part5/14-workloads.md) · [15](book/part5/15-benchmarking-and-comparison.md) · [16](book/part5/16-beyond-v1.md) | Workloads; benchmarking and comparison; beyond v1 |

**Appendices:**
[A — Instruction quick reference](book/appendix/A-instruction-quickref.md) ·
[B — Glossary](book/appendix/B-glossary.md) ·
[C — Toolchain setup](book/appendix/C-toolchain-setup.md) ·
[D — Reading list](book/appendix/D-reading-list.md) ·
[E — Scope contract](book/appendix/E-scope-contract.md)

[Chapter 4](book/part2/04-rvv-programmers-model.md) is the one to read twice. Everything the
hardware must do is defined there.

---

## The design

MEDS-V is a **decoupled coprocessor**: the scalar core recognises vector instructions and
hands them across a defined interface, and the vector unit executes them asynchronously.
That choice is made primarily so two teams can work in parallel behind a frozen interface.

```
   Scalar core ──► issue interface ──► ┌─────────────────────────────┐
                 ◄── scalar writeback  │  ① decoder   ② CSR/vtype    │
                                       │  ③ sequencer + hazards      │
                                       │  ④ vector register file     │
                                       │  ⑤ lane array (VALU/VMUL)   │
                                       │  ⑥ load/store unit  ◄───────┼──► memory
                                       │  ⑦ mask   ⑧ reduce/permute  │
                                       └─────────────────────────────┘
```

The full diagram, with every signal, is in
[Chapter 8](book/part3/08-big-picture-block-diagram.md).

### Reference configurations

| | VLEN | ELEN | Lanes | VRF |
|---|---|---|---|---|
| **MEDS-V-S** — development | 128 | 32 | 1 | 4 Kib |
| **MEDS-V-M** — demonstration | 256 | 32 | 2 | 8 Kib |
| **MEDS-V-L** — throughput | 512 | 32 | 4 | 16 Kib |

VLEN and lane count are parameters. Running the same tests and benchmarks across all nine
combinations, unmodified, is the project's headline result.

### Scope

MEDS-V v1 targets **~58 operations / ~120 encodings** — a genuine subset of `Zve32x`.
Floating point, indexed and segment addressing, `vrgather`, `vcompress`, and chaining are
deliberately deferred, each for a written reason.

[Appendix E](book/appendix/E-scope-contract.md) is a scope contract to be agreed in week 1
and reproduced in the final report. A verified 58-instruction vector processor that runs six
workloads and produces a defensible comparison table is a strong result; an unverified
300-instruction one that runs nothing is not.

---

## Project timeline

Eight milestones, roughly sixteen weeks. Full detail with exit criteria in
[Chapter 11](book/part4/11-project-roadmap.md).

| Milestone | Weeks | Deliverable |
|---|---|---|
| **M0** | 1–2 | Learn the ISA. No RTL. Toolchain working for everyone; scope contract signed |
| **M1** | 2–4 | Decoder and CSR/vtype unit |
| **M2** | 4–6 | Vector register file **and the co-simulation harness** |
| **M3** | 6–9 | Sequencer and lanes — first instruction executes |
| **M4** | 8–12 | Load/store unit — first real program runs |
| **M5** | 11–13 | Masks, reductions, slides — all six benchmarks run |
| **M6** | 13–15 | Optimise and scale across the parameter sweep |
| **M7** | 14–16 | Measure, compare, write up |

Two notes that matter more than the dates:

- **M2 builds the checker before there is anything to check.** This gate is hard: no M3 work
  starts until the trace comparator demonstrably catches an injected bug. Skipping it is the
  single biggest predictor of project failure.
- **M4 (the load/store unit) gets four weeks and the strongest engineer.** It is the hardest
  block by a wide margin, and it is where schedules slip.

---

## Verification

Four layers, described in [Chapter 13](book/part4/13-verification-strategy.md):

1. **Unit tests** — one testbench per block, expectations derived from parameters
2. **Co-simulation against Spike** — the backbone; instruction-by-instruction trace diff
3. **Architectural tests** — `riscv-arch-test`, for the implemented subset
4. **Random stress** — generated sequences, biased toward hazards

The co-simulation tool is ready to use:

```bash
spike --isa=rv64gcv_zvl128b -l --log-commits prog.elf > spike.log 2>&1
python3 scripts/cosim_diff.py spike.log rtl.log
python3 scripts/cosim_diff.py --emit-format     # the RTL trace format contract
```

Spike's commit log carries the SEW, LMUL, `vl`, the **full written vector register value**,
and every memory write — so the comparison can verify data, not just control flow.

---

## Contributing

This is teaching material as much as it is a design. Contributions that make it a better
guide are as welcome as contributions to the RTL.

- Corrections to the book — especially anything that contradicts the ratified spec
- Additional verified examples
- Completed RTL blocks, with their unit testbenches
- Benchmark kernels, with scalar references

Every claim in the book should be checkable. If something cannot be reproduced by running a
command in this repository, that is a bug in the book.

Before submitting RTL:

```bash
make -C verif lint              # must be clean at -Wall
make -C verif all               # all unit tests must pass
python3 scripts/param_sweep.py  # all configurations must elaborate
```

---

## Acknowledgements and further reading

The design draws on the published open-source RVV implementations, all of which are worth
reading: **Vicuna** (TU Wien) is the closest in scope and the most readable; **Ara/Ara2**
(ETH Zürich) is the reference multi-lane design; **Saturn** (UC Berkeley) has the best
written treatment of decoupled vector instruction scheduling. Full annotated list in
[Appendix D](book/appendix/D-reading-list.md).

Thanks to RISC-V International for the ratified specification, and to the Spike, QEMU, GCC,
and Verilator communities — without those tools none of the measurements in this book would
have been checkable.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Contact

**Maktab-e-Digital Systems (MEDS), Lahore**
Instructor: [Umer Shahid](mailto:umershahid@uet.edu.pk) ([@umershahidengr](https://github.com/umershahidengr))

Questions, corrections, and issues: please open a GitHub issue on this repository.
