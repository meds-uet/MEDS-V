# Chapter 3 — From Cray-1 to RISC-V

> **Goal of this chapter.** Understand *why RVV looks the way it does*. Every odd corner of
> the specification — fractional LMUL, the tail policy, `v0` as the only mask register —
> is a scar from a lesson learned by an earlier machine. Knowing the history turns
> "arbitrary rule I must memorise" into "obvious consequence I can re-derive."

---

## 3.1 The Cray-1 (1976) — the original

Seymour Cray's Cray-1 is where all of this starts. Stripped of its famous C-shaped cabinet
and freon cooling, its architecture is startlingly close to the machine described in this book:

| Cray-1 feature | Detail |
|---|---|
| Vector registers | **8 registers × 64 elements × 64 bits** |
| Vector length register | `VL`, settable 1–64 |
| Functional units | Separate add, multiply, reciprocal, logical, shift units |
| Chaining | Yes — the Cray-1's signature feature |
| Memory | Direct to main memory, no cache; heavily banked |
| Peak | 160 MFLOPS at 80 MHz |

Look at that list against Chapter 2. Vector registers: ✓. A vector length register: ✓.
Chaining: ✓. **The fundamental design was right in 1976 and has not changed.** What has
changed is the constraint set — Cray had no caches and effectively unlimited power budget;
the team has caches and a tight power budget.

### What Cray got right

**1. A vector length register.** Cray put `VL` in the machine from day one, so a loop over
37 elements needed no special-casing. RVV's `vl` is a direct descendant.

**2. Chaining.** Results forwarded element-by-element between functional units. This is
what let the machine sustain multiple FLOPs per cycle from a single instruction stream.

**3. Vector registers, not memory-to-memory.** Earlier vector machines (CDC STAR-100, TI
ASC) read operands straight from memory and wrote results straight back. That sounds
elegant and is a disaster: every operation pays full memory latency, and short vectors are
catastrophically slow — the STAR-100 needed vectors of ~100 elements just to break even
against its own scalar unit. Cray's register file meant intermediate results stayed on
chip.

> **Design lesson for MEDS-V.** Keep data in the VRF across multiple operations. The
> benchmark kernels in Chapter 14 should be written to load once, compute several times,
> store once. A kernel that loads and stores for every operation is measuring the memory
> system, not the vector unit.

**4. Banked memory.** With no cache, the Cray-1 interleaved memory across many banks so a
unit-stride vector load could pull one element per cycle. The VLSU faces the same problem
in modern dress: how do one gets VLEN bits per cycle out of a memory system built for 64?

### What Cray got wrong (or rather, what didn't survive)

- **Fixed 64-element registers.** The vector length was architecturally fixed at 64. A
  Cray-2 could not simply have longer vectors without changing the ISA. RVV fixes this by
  making VLEN an *implementation* parameter, invisible to the binary.
- **8 registers.** Too few; compilers spilled constantly. RVV has 32.
- **No masking (initially).** Conditional execution inside a vector loop needed awkward
  compress/expand gymnastics. Later Cray machines added vector mask registers.

---

## 3.2 The packed-SIMD detour (1996–2015)

Vector processing then disappeared from mainstream computing for twenty years, and came
back wearing a disguise.

The microprocessor vendors of the 1990s wanted to accelerate multimedia — video decode,
audio, 3-D graphics — on desktop CPUs. They did not want to build a Cray. So they did the
cheap thing: **take an existing 64-bit register, declare it to be "eight bytes", and add
instructions that operate on all eight at once.**

- **Intel MMX (1997)** — reused the x87 floating-point registers as 8×8-bit or 4×16-bit
  integers. Reusing the FP registers was so awkward one couldn't mix MMX and FP code
  without an explicit mode switch.
- **Intel SSE (1999)** — proper 128-bit registers (`xmm0`–`xmm15`), single-precision FP.
- **PowerPC AltiVec / VMX (1998)**, **ARM NEON (2005)** — the same idea elsewhere.
- **Intel AVX (2011)** — 256-bit (`ymm`). **AVX-512 (2013→)** — 512-bit (`zmm`), and
  masking finally arrives on x86.

This is **packed SIMD**, and it is worth being precise about the difference from a true
vector ISA, because the difference *is* the reason RVV exists.

### The three diseases of packed SIMD

**Disease 1 — The ISA is versioned by register width.**
`paddd xmm0, xmm1` means "add exactly four 32-bit integers." The count is welded into the
opcode. So a wider machine needs *entirely new instructions*: `vpaddd ymm` for 256-bit,
`vpaddd zmm` for 512-bit. Every widening duplicates the whole instruction set.

The result: x86 SIMD has accumulated MMX, SSE, SSE2, SSE3, SSSE3, SSE4.1, SSE4.2, AVX,
AVX2, AVX-512 (in a dozen sub-flavours), and AVX10. Thousands of instructions, most of them
the same operation at different widths. Decoders, compilers, and verification suites all
pay for this forever.

**Disease 2 — The binary cannot exploit better hardware.**
Compile for SSE, run on an AVX-512 machine: one gets SSE performance. To benefit, someone
must recompile — and since software ships as binaries, that means either shipping many
builds, or runtime dispatch (detect the CPU, jump to one of several hand-written code
paths). Every serious numerical library does this, and it is a permanent tax on the
ecosystem.

**Disease 3 — The programmer writes the remainder loop.**
```c
// The eternal packed-SIMD idiom
int i;
for (i = 0; i + 4 <= n; i += 4)   // vector body: 4 at a time
    ...SIMD...
for (; i < n; i++)                // scalar cleanup — every single time
    ...scalar...
```
Two implementations of the same maths, twice the bugs, and the `4` changes with the ISA
version.

> **Try this.** Look back at the RVV SAXPY in Chapter 1 §1.2. There is no cleanup loop.
> There is no `4`. That absence is the whole point.

### What packed SIMD got right

Don't overcorrect — it won commercially for good reasons. It is **cheap to add** to an
existing core (no new register file if one reuse FP registers, no `vl` state to save on
context switch), it has **short, predictable latency** (one instruction, one pass, done),
and it **needs no sequencer** — every instruction is a single-pass operation. Some of those
virtues are worth borrowing: MEDS-V's simplest configuration (VLEN=128, 4 lanes, SEW=32)
behaves *exactly* like packed SIMD internally. That is a good first milestone precisely
because it is the easy case.

---

## 3.3 The return of true vectors (2015– )

Two things brought vector length back:

**ARM SVE (Scalable Vector Extension, announced 2016).** ARM faced a fork: extend NEON to
512 bits and inherit x86's versioning disease, or go scalable. They went scalable — SVE
implementations choose a vector length from 128 to 2048 bits in 128-bit steps, and binaries
are length-agnostic. SVE proved the concept was viable in a modern, commercially serious
ISA.

**Berkeley's Hwacha project.** A research vector architecture from UC Berkeley (the same
group that created RISC-V), exploring decoupled vector-fetch designs. Hwacha's designers
and lessons fed directly into the RVV working group. If one reads one research paper
alongside this book, make it a Hwacha paper — much of RVV's microarchitectural thinking is
visible there in earlier form.

### RVV's timeline

| When | What |
|---|---|
| ~2015 | Vector extension work begins in the RISC-V community, informed by Hwacha |
| 2019–2021 | Draft versions 0.7.1 → 0.9 → 1.0-rc. **0.7.1 shipped in real silicon** (Alibaba/T-Head C906, XuanTie) and is *not* compatible with 1.0 |
| **November 2021** | **RVV 1.0 ratified** by RISC-V International |
| October 21, 2024 | **RVA23 profile ratified**, making V **mandatory** for 64-bit application-class RISC-V |

> **⚠️ Trap — version 0.7.1 is a real hazard.** A great deal of code, and several shipping
> chips (notably the T-Head C906 in the Allwinner D1), implement RVV **0.7.1**, which
> differs from 1.0 in instruction encodings, `vsetvli` semantics, and the tail policy.
> Tutorials, StackOverflow answers, and GitHub repos from 2019–2021 are frequently 0.7.1.
> **Check the version of anything one copies.** If one sees `vsetvli` without `ta`/`ma`
> policy bits, or the mnemonics `vfredsum` (rather than `vfredusum`), the source is
> 0.7.x. This project targets **1.0 only.**

That RVA23 line is the commercial punchline, and it belongs in the project's motivation
slide: **as of October 2024, a 64-bit RISC-V application processor that wants to run
standard Linux distributions must implement the vector extension.** It is no longer
optional. Vector processors are now core RISC-V competence, which is precisely why MEDS is
right to invest a team in it.

---

## 3.4 The design decisions RVV made, and why

Now the payoff. Here is each major RVV design choice with the historical problem it solves.
The team will meet all of these again in Chapter 4; meeting them here first, as *answers*, makes
them stick.

### VLEN is not in the ISA
**Problem solved:** packed SIMD's disease 1 and 2.
Hardware picks VLEN; software discovers it at runtime via `vsetvli` and the `vlenb` CSR.
One binary, all implementations. One measured this in Chapter 1.

### 32 vector registers
**Problem solved:** Cray's 8 registers caused constant spilling.
32 is enough for a compiler to keep a software-pipelined loop entirely in registers.

### LMUL — grouping registers together
**Problem:** 32 registers is *too many* for some kernels and *too few* for others. A simple
SAXPY needs 3 registers and wastes 29. A big matrix microkernel wants a few very long
accumulators.

**Solution:** `LMUL` (vector register group multiplier) lets an implementation glue 2, 4, or 8
architectural registers into one longer logical vector. With LMUL=8, `v8` means "v8 through
v15, as a single vector of 8×VLEN bits". One now have 4 usable registers, each 8× longer —
so one instruction does 8× the work, amortising overhead further.

This is the single most distinctive feature of RVV and has no analogue in SSE, AVX, or
NEON. It is why the SAXPY in the Preface used `m8`.

### Fractional LMUL — the clever bit
**Problem:** mixed-width arithmetic. Consider widening 8-bit data to 32-bit:
```
   8-bit source:  32 elements fill ONE register at VLEN=256
  32-bit result:  32 elements need FOUR registers
```
The source and destination need *different* numbers of registers for the *same* number of
elements. Without a fix, one waste 3/4 of the source register, or need awkward
split-and-merge code.

**Solution:** LMUL can be **fractional** — 1/2, 1/4, 1/8. `LMUL=1/4` means "use a quarter
of a register." Now the 8-bit source uses LMUL=1/4 and the 32-bit destination uses LMUL=1,
both hold the same 32 elements, and the element counts line up perfectly.

This is why the `vlmul[2:0]` encoding is a *signed* field with values for 1/8, 1/4, 1/2 —
a table that looks bizarre until one knows it exists to make mixed-width code natural.
Chapter 4 §4.3 gives the encoding.

### `v0` is the only mask register
**Problem:** AVX-512 added eight dedicated mask registers (`k0`–`k7`) — extra architectural
state, extra context-switch cost, extra encoding bits in every instruction.

**Solution:** RVV spends exactly **one bit** (`vm`) per instruction, and the mask always
comes from `v0`. No new register file, minimal encoding cost.
**Cost:** register pressure on `v0`, and extra `vmv`/mask-move instructions when one juggle
several masks. A deliberate trade: simplicity of hardware over convenience of software.

**Implementation consequence for the implementer:** the mask read port is *hardwired to `v0`*. That is
a real simplification — no mask-operand decoding, no general mask register file.

### Tail and mask policies (`ta` / `ma`)
**Problem:** what happens to elements beyond `vl`, or to masked-off elements?
Cray-style machines left them undisturbed, which forces the hardware to do a read-modify-
write on the destination register — the hardware must preserve bits it is not writing. That costs a
read port and adds a dependency on the destination register even for instructions that
"only write."

**Solution:** RVV lets software declare it doesn't care. **Agnostic** means the hardware may
leave those elements alone *or* overwrite them with all-1s, whichever is cheaper. If oner
implementation would rather blast a full-width write and not read the old value, agnostic
lets an implementation.

**Implementation consequence — this is a big one.** If one support *only* agnostic
policies, the VRF write port never needs to merge with old data for tails, and vector
instructions have no false dependency on their destination register. If one support
*undisturbed*, teams need a read-modify-write path. Appendix E's scope contract discusses
whether MEDS-V v1 implements undisturbed at all.

### Instructions are `vl`-dependent, not fixed-trip
**Problem:** packed SIMD's remainder loop (disease 3).
**Solution:** `vl` is architectural state; `vsetvli` computes it from the remaining trip
count. Hardware handles the short final pass. No cleanup code.

### Standardised subsets (`Zve*`, `Zvl*`)
**Problem:** the full V extension is too big for a microcontroller, but "V-like but
different" fragmentation would destroy the software ecosystem.

**Solution:** a defined ladder of subsets, so a small implementation can claim a *standard*
name rather than inventing one:

| Extension | ELEN | Floating point | Minimum VLEN |
|---|---|---|---|
| `Zve32x` | 32 | none (integer only) | 32 |
| `Zve32f` | 32 | FP32 | 32 |
| `Zve64x` | 64 | none | 64 |
| `Zve64f` | 64 | FP32 | 64 |
| `Zve64d` | 64 | FP32 + FP64 | 64 |
| **`V`** | 64 | FP32 + FP64 | **128** (i.e. `Zve64d` + `Zvl128b`) |

Separately, `Zvl<N>b` guarantees VLEN ≥ N: `Zvl32b`, `Zvl64b`, `Zvl128b`, `Zvl256b`,
`Zvl512b`, `Zvl1024b`, … up to `Zvl65536b`.

> **🎯 Milestone hook — pick the target name now.** MEDS-V v1 should aim at
> **`Zve32x` + `Zvl128b`** — 32-bit integer elements, VLEN ≥ 128, no floating point. That
> is a *real, standard, citable* extension name, achievable in a semester, and it means one
> can say "MEDS-V implements Zve32x_Zvl128b" rather than "MEDS-V implements some vector
> instructions the team chose." The difference in how that reads in a report is enormous.
> Floating point (`Zve32f`) is a stretch goal — see Chapter 16.

---

## 3.5 The landscape today: who else has built one

The team will be compared against these, so know them. All are open source and all are worth
reading — see Appendix D for links.

| Design | Origin | Language | Style | Notes for the implementer |
|---|---|---|---|---|
| **Ara / Ara2** | ETH Zürich | SystemVerilog | Long-vector, multi-lane, coupled to the CVA6 scalar core | The reference open RVV 1.0 design. 2–16 lanes. Read its lane structure. **Closest to MEDS-V.** |
| **Vicuna** | TU Wien | SystemVerilog | 32-bit integer coprocessor for Ibex/CV32E40X | **Start here.** Integer-only and modest — very close to the MEDS-V v1 scope. Readable. |
| **Saturn** | UC Berkeley | Chisel | Short-vector, deeply parameterised, in-order decoupled | Excellent companion *technical report* on instruction scheduling. Read the document even if one doesn't read the Chisel. |
| **Spatz** | ETH Zürich | SystemVerilog | Very small vector unit for tightly-coupled clusters | Good if one care about area efficiency. |
| **AraXL** | ETH Zürich | SystemVerilog | Scaled-out Ara for very long vectors | Shows what happens when one push lane counts up. |
| **SiFive X280 / T-Head** | Commercial | — | Shipping silicon | Performance reference points only; no RTL. |

> **🔧 Exercise 3.1 (do this in week 1).** Clone Vicuna and Ara. Do not try to understand
> them yet. Just run `find . -name '*.sv' | wc -l` and `wc -l` on the RTL directory of
> each, and note the numbers in the project log. This calibrates the team's sense of the effort
> involved and is a sanity check on the teamr own scope. Revisit in week 12.

---

## 3.6 Where MEDS-V fits

Put the own project on the map honestly. This table is a draft of a slide in the final
presentation:

| Axis | MEDS-V v1 target | Why |
|---|---|---|
| Spec target | `Zve32x` + `Zvl128b` (RVV 1.0 subset) | Standard, citable, achievable |
| VLEN | 128 (parameterised to 512) | Small enough to simulate fast, big enough to show VLA |
| Lanes | 1 → 2 → 4 | Correctness first, throughput later |
| Element widths | 8 / 16 / 32 | ELEN=32 keeps the datapath narrow |
| Floating point | **No** (v1) | FP adds an FPU project on top of a vector project |
| Coupling | Decoupled coprocessor to an RV64 scalar core | Clean interface; lets both teams work in parallel |
| Memory | Unit-stride + strided; indexed deferred | The VLSU is the schedule risk |
| Verification | Spike co-simulation from M2 | Non-negotiable |

That is not a weak project. It is a *scoped* one — and a scoped project that finishes,
runs six benchmarks, and produces a comparison table is worth more than an ambitious one
that doesn't.

---

## 🔧 Exercises

**3.1** (see §3.5) Clone Vicuna and Ara; record RTL line counts.

**3.2** Explain, in the own words and without looking, why AVX-512 needed new instruction
encodings when it widened from 256 to 512 bits, and why RVV did not.

**3.3** Write the packed-SIMD version of SAXPY in pseudocode, *including* the scalar
cleanup loop. Now count how many places the constant "4" (elements per vector) appears.
That count is the maintenance cost RVV eliminates.

**3.4** Fractional LMUL: the team has 16-bit input data and want 64-bit accumulators, with the
same element count in both. What LMUL should the input use if the accumulator uses LMUL=2?
(Chapter 4 will give the implementer the rule; try to reason it out first.)

**3.5 (mentors, decision)** Read Appendix E. Decide, as a team, whether MEDS-V v1 supports
tail-undisturbed. Write down the area/complexity argument on both sides and commit to an
answer. This decision affects the VRF design in M3 and is expensive to change later.

---

## Key takeaways

- The Cray-1 got the architecture right in 1976: vector registers, a length register,
  chaining. The design is a descendant.
- Packed SIMD (MMX→AVX-512, NEON) traded long-term ISA health for short-term ease of
  implementation: width baked into opcodes, binaries frozen at their compile-time width,
  and a hand-written remainder loop every time.
- RVV is a return to true vectors, with modern additions: **VLEN out of the ISA**, **32
  registers**, **LMUL** (including fractional, for mixed-width code), **`v0`-only masks**,
  and **agnostic tail/mask policies** that exist specifically to make hardware cheaper.
- RVV 1.0 was ratified in **November 2021**; **RVA23 (October 2024) makes V mandatory** for
  64-bit application-class RISC-V. This is now baseline competence, not a niche.
- **Version 0.7.1 is incompatible with 1.0 and is all over the internet.** Check everything.
- Target **`Zve32x_Zvl128b`** for MEDS-V v1 — a real, standard, achievable subset.

---

*Next: [Chapter 4 — The RVV Programmer's Model](../part2/04-rvv-programmers-model.md) —
the most important chapter in the book.*

**Sources for this chapter:**
[RVV 1.0 specification](https://docs.riscv.org/reference/isa/extensions/vector/_attachments/riscv-v-spec.pdf) ·
[RVV 1.0 ratification](https://riscv.org/blog/risc-v-vector-processing-is-taking-off-sifive/) ·
[RVA23 profile ratification, Oct 2024](https://riscv.org/blog/risc-v-announces-ratification-of-the-rva23-profile-standard/) ·
[Ara2 paper](https://arxiv.org/pdf/2210.08882v1) ·
[Saturn technical report](https://arxiv.org/pdf/2412.00997)
