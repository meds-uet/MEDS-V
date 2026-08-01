# Appendix D — Annotated Reading List

Ordered by when it becomes useful, not by importance.

---

## D.1 Specifications — read first, return to constantly

**RISC-V "V" Vector Extension, Version 1.0** — the ratified specification.
<https://docs.riscv.org/reference/isa/extensions/vector/_attachments/riscv-v-spec.pdf>

The primary source. Dense, and not a tutorial, but every table in this book was checked
against it. Sections worth reading in full: §3 (configuration), §5 (masking), §7 (memory),
§16 (permutation).

An HTML rendering, easier to search:
<https://dzaima.github.io/intrinsics-viewer/data/v-spec.html>

> **Check the version on anything found online.** RVV **0.7.1** shipped in real silicon and
> is incompatible with 1.0. Tutorials and repositories from 2019–2021 are frequently 0.7.1.
> Tell-tale signs: `vsetvli` without `ta`/`ma` policy bits, or the mnemonic `vfredsum`
> instead of `vfredusum`.

**RISC-V Unprivileged ISA Specification** — the base ISA the vector extension sits in.
<https://riscv.org/technical/specifications/>

**RVA23 Profile** (ratified October 2024) — makes V mandatory for 64-bit application-class
RISC-V. Useful for the motivation section of a report.
<https://riscv.org/blog/risc-v-announces-ratification-of-the-rva23-profile-standard/>

**RISC-V Vector Intrinsics Specification** — the `__riscv_*` C function naming rules.
<https://github.com/riscv-non-isa/rvv-intrinsic-doc>

---

## D.2 Open-source implementations — read the RTL

**Vicuna** (TU Wien) — 32-bit integer vector coprocessor for Ibex/CV32E40X.
<https://github.com/vproc/vicuna>

**Start here.** Integer-only, modest scope, and very close to MEDS-V v1's target. The most
readable open RVV implementation, and the most realistic comparison point.

**Ara / Ara2** (ETH Zürich) — multi-lane RVV 1.0 unit coupled to the CVA6 scalar core.
<https://github.com/pulp-platform/ara> · paper: <https://arxiv.org/pdf/2210.08882v1>

The reference open design and closest to MEDS-V's architecture. Read the lane structure and
the VRF banking. Ara2 supports 2–16 lanes and is the natural performance comparison.

**Saturn** (UC Berkeley) — Chisel, deeply parameterised, in-order decoupled.
<https://arxiv.org/pdf/2412.00997>

**Read the technical report even without reading the Chisel.** Its treatment of instruction
scheduling in a decoupled vector unit is the best single explanation of the sequencer
problem from Chapter 9 §9.5.

**Spatz** (ETH Zürich) — a very small vector unit for tightly-coupled clusters. Relevant if
area efficiency is the goal.

**AraXL** — Ara scaled to very long vectors; shows what happens as lane counts rise.
<https://arxiv.org/pdf/2501.10301>

---

## D.3 Papers

**"Efficient Implementation of RISC-V Vector Permutation Instructions"**
<https://arxiv.org/html/2505.07112v2>

Directly relevant to the deferred `vrgather`/`vcompress` work of Chapter 16 §16.5. Read
before attempting either.

**"Test-driving RISC-V Vector hardware for HPC"** — <https://arxiv.org/pdf/2304.10319>
Real measurements on real RVV silicon; useful calibration for what to expect.

**"Backporting RISC-V Vector assembly"** — <https://arxiv.org/pdf/2304.10324>
Concrete detail on the 0.7.1 versus 1.0 differences.

**Hwacha** (UC Berkeley) — the research vector architecture that fed into RVV's design.
Reading it explains *why* RVV looks the way it does.

---

## D.4 Background

**Hennessy & Patterson, *Computer Architecture: A Quantitative Approach*** — Chapter 4 is
the standard treatment of vector architecture, including the Cray-1 lineage and chaining.
The single best background text for Part I of this book.

**Russell, "The CRAY-1 Computer System"**, *CACM* 21(1), 1978 — the original. Short, clear,
and startlingly modern; the machine described is recognisably the one in Chapter 2.

**Asanović, "Vector Microprocessors"** (PhD thesis, Berkeley, 1998) — the deepest treatment
of vector microarchitecture available, by someone later central to RISC-V.

---

## D.5 Tools

- **Spike** — <https://github.com/riscv-software-src/riscv-isa-sim>
- **QEMU RISC-V** — <https://www.qemu.org/docs/master/system/target-riscv.html>
- **Verilator** — <https://verilator.org/guide/latest/>
- **riscv-arch-test** — <https://github.com/riscv-non-isa/riscv-arch-test> (Chapter 13 §13.5)
- **RISC-V Vector intrinsics viewer** — <https://dzaima.github.io/intrinsics-viewer/>
  Searchable index of every intrinsic; the fastest way to find the right function name.

---

## D.6 A suggested reading order

| When | Read |
|---|---|
| Week 1 | H&P Chapter 4; this book Parts I–II |
| Week 2 | RVV spec §3, §5; browse Vicuna's RTL |
| Week 3 | Saturn technical report; Ara2 paper |
| Week 4+ | RVV spec §7 (memory) before starting the VLSU |
| M5 | The permutation paper, if attempting `vrgather` |
| M7 | Ara2 and Saturn results sections, for the comparison table |
