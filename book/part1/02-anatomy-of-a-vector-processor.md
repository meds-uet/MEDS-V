# Chapter 2 — Anatomy of a Vector Processor

> **Goal of this chapter.** Build a mental model of the machine, in the abstract, before
> any RISC-V specifics. By the end a reader should be able to draw a vector processor on a
> whiteboard from memory and explain what every box does.

Chapter 1 ended with a list of six things the machine needs. This chapter turns that list
into structure.

---

## 2.1 The one-slide picture

```
                    ╔═══════════════════════════════════════════════╗
   scalar core ────►║              VECTOR PROCESSOR                 ║
   (instructions,   ║                                               ║
    scalar operands)║   ┌─────────────┐      ┌──────────────────┐   ║
                    ║   │  Vector     │      │ Vector Length &  │   ║
                    ║   │  Control /  │◄────►│ Type State       │   ║
                    ║   │  Sequencer  │      │  (vl, vtype)     │   ║
                    ║   └──────┬──────┘      └──────────────────┘   ║
                    ║          │ per-element control                ║
                    ║   ┌──────▼──────────────────────────────┐     ║
                    ║   │      VECTOR REGISTER FILE            │    ║
                    ║   │      32 registers × VLEN bits        │    ║
                    ║   └──────┬────────────────────┬─────────┘     ║
                    ║          │                    │               ║
                    ║   ┌──────▼──────┐      ┌──────▼───────────┐   ║
                    ║   │  Vector     │      │  Vector Load/    │   ║
                    ║   │  Functional │      │  Store Unit      │◄──╬──► memory
                    ║   │  Units      │      │  (VLSU)          │   ║
                    ║   │  (lanes)    │      └──────────────────┘   ║
                    ║   └─────────────┘                             ║
                    ╚═══════════════════════════════════════════════╝
```

Five structures. That is the whole idea:

1. **Vector register file (VRF)** — where vectors live.
2. **Lanes / functional units** — where arithmetic happens, in parallel.
3. **Vector load/store unit (VLSU)** — moves vectors to and from memory.
4. **Vector length & type state** — how many elements, and how wide.
5. **Control / sequencer** — turns one instruction into many element operations.

Everything in Chapters 8 and 9 is a refinement of this picture. Learn these five.

---

## 2.2 The vector register file

A scalar register file holds 32 values of XLEN bits. A **vector** register file holds 32
*vectors*, each of **VLEN** bits.

```
              ◄─────────────── VLEN bits ───────────────►
            ┌────────┬────────┬────────┬────────┬─── ... ┐
     v0     │  elem  │  elem  │  elem  │  elem  │        │
            ├────────┼────────┼────────┼────────┼─── ... ┤
     v1     │        │        │        │        │        │
            ├────────┼────────┼────────┼────────┼─── ... ┤
      :     │                    :                       │
            ├────────┼────────┼────────┼────────┼─── ... ┤
     v31    │        │        │        │        │        │
            └────────┴────────┴────────┴────────┴─── ... ┘
              elem 0   elem 1   elem 2   elem 3
```

**VLEN is a parameter one chooses when one builds the hardware.** It is not in the ISA. A
tiny embedded implementation might use VLEN=128; a high-performance one 512, 1024, or more.

### How many elements fit?

That depends on how wide each element is. If VLEN = 128 bits:

| Element width | Elements per register |
|---|---|
| 8-bit  (byte)     | 16 |
| 16-bit (half)     | 8  |
| 32-bit (word)     | 4  |
| 64-bit (double)   | 2  |

The same physical bits, interpreted differently. **The register file does not know or care
what the element width is** — it stores VLEN bits. Element width is a property of the
*instruction* being executed, supplied by the control state (§2.5). This is a genuinely
important implementation insight: the VRF is just a wide, dumb SRAM. All the cleverness
about element widths lives in the lanes and the control path.

> **⚠️ Trap.** Newcomers try to build a register file that "knows" it holds 32-bit
> elements. Don't. Build it as `logic [VLEN-1:0] vrf [0:31]` and let the datapath slice it.
> The moment teams need to support two element widths, a width-aware VRF becomes a rewrite.

### Sizing it

The VRF is the largest single structure in the design. Its capacity is:

```
VRF bits = 32 × VLEN
```

| VLEN | Total VRF | Comparable to |
|---|---|---|
| 128  | 4 Kib  = 512 B  | a small scratchpad |
| 256  | 8 Kib  = 1 KiB  | |
| 512  | 16 Kib = 2 KiB  | |
| 1024 | 32 Kib = 4 KiB  | a small L1 cache |

Compare: an RV64 scalar register file is 32 × 64 = 2 Kib = 256 bytes. So even a modest
VLEN=256 vector unit has **4× more register storage than the entire scalar core**, and it
needs multiple read and write ports. This is why Chapter 9 §9.3 spends so long on banking:
one cannot build a 3-read/1-write flip-flop array of this size and still close timing.

---

## 2.3 Lanes — the key structural idea

Here is the question that defines the microarchitecture:

> A `vadd` on VLEN=512 with 32-bit elements must produce 16 sums. Do one builds 16 adders?

Three answers, all valid, at different points on the area/performance curve:

### Option A — one element per cycle (fully serial)
One adder. 16 cycles. Tiny area, low performance. This is a reasonable **milestone M3**
target: get it *correct* first.

### Option B — all elements at once (fully parallel)
16 adders, one cycle. Maximum performance, but the VRF must deliver 512 bits × 2 operands
per cycle and absorb 512 bits of result. Wiring and port pressure become brutal.

### Option C — lanes (what real designs do)
Pick a number of **lanes**, L. Each lane is a vertical slice containing:
- its own slice of every vector register (VLEN/L bits of each),
- its own ALU,
- its own connection to the memory pipeline.

A vector operation is processed in `VLEN/(SEW × L)` passes.

```
        LANE 0          LANE 1          LANE 2          LANE 3
     ┌───────────┐   ┌───────────┐   ┌───────────┐   ┌───────────┐
     │ VRF slice │   │ VRF slice │   │ VRF slice │   │ VRF slice │
     │ v0[ 0]    │   │ v0[ 1]    │   │ v0[ 2]    │   │ v0[ 3]    │
     │ v0[ 4]    │   │ v0[ 5]    │   │ v0[ 6]    │   │ v0[ 7]    │
     │ v0[ 8]    │   │ v0[ 9]    │   │ v0[10]    │   │ v0[11]    │
     │ v0[12]    │   │ v0[13]    │   │ v0[14]    │   │ v0[15]    │
     │    ...    │   │    ...    │   │    ...    │   │    ...    │
     ├───────────┤   ├───────────┤   ├───────────┤   ├───────────┤
     │    ALU    │   │    ALU    │   │    ALU    │   │    ALU    │
     └───────────┘   └───────────┘   └───────────┘   └───────────┘
           ▲               ▲               ▲               ▲
           └───────────────┴───────┬───────┴───────────────┘
                                   │
                        same control signals to all lanes
```

**Element *i* lives permanently in lane *i* mod L.** Element 0 → lane 0, element 1 → lane
1, … element 4 → lane 0 again. This is the standard interleaved mapping.

Why lanes are such a good deal:

- **Perfect scalability.** Want 2× throughput? Instantiate 2× lanes. Nothing else changes:
  same ISA, same control, same binaries.
- **No inter-lane wiring for element-wise ops.** `vadd` never needs lane 0 to talk to lane
  3. Each lane is an independent island. Physically, this means short wires and easy
  floorplanning — the reason multi-lane vector units scale to high frequency.
- **Local register ports.** Each lane's VRF slice is only VLEN/L bits wide, so it is a
  small, fast, cheap SRAM with its own ports.

And the price:

- **Some operations do need to cross lanes.** Reductions (sum all elements), slides
  (shift elements sideways), gathers (arbitrary permutation), and strided memory access.
  These need a crossbar or a ring, and they are the expensive, awkward parts of the design.
  Chapter 9 §9.7 is about exactly this.

> **🎯 Milestone hook.** MEDS-V starts at **L = 1** (milestone M3) and grows to L = 2 or 4
> (M6). If one writes the lane as a properly parameterised module from the start, that
> growth is a parameter change. Chapter 12's skeleton is built this way.

### The pipeline picture

With L lanes and `vl` elements, one vector instruction occupies the functional unit for
roughly `ceil(vl / L)` cycles. This is the **vector's other superpower**: a long-running
instruction. While `vadd` grinds through 16 elements over 4 cycles, the front end is idle
and free — it can be decoding the *next* instruction, and the VLSU can be prefetching. A
vector machine gets latency tolerance almost for free, without speculation.

---

## 2.4 Chaining — forwarding, for vectors

Consider two dependent vector instructions:

```asm
vmul.vv v3, v1, v2     # v3 = v1 * v2
vadd.vv v5, v3, v4     # v5 = v3 + v4     <-- needs v3
```

The naive approach: run `vmul` to completion over all 16 elements, write all of `v3`, then
start `vadd`. If each takes 16 cycles, total 32.

But look closer. `vadd` needs **element 0 of v3** to compute **element 0 of v5**. It does
not need element 15. The moment `vmul` produces element 0, `vadd` can start on element 0.

```
        cycle:  0    1    2    3    4    5    6    7    8   ...
  vmul  elem:  [0]  [1]  [2]  [3]  [4]  [5]  [6]  [7]  ...
                │    │    │    │    │    │    │    │
                ▼    ▼    ▼    ▼    ▼    ▼    ▼    ▼
  vadd  elem:       [0]  [1]  [2]  [3]  [4]  [5]  [6]  ...
                     ▲
                     └── starts 1 cycle later, runs concurrently
```

Total: ~17 cycles instead of 32. This is **chaining**, and it is the vector-machine
equivalent of operand forwarding in a scalar pipeline. It was Cray's signature trick and
it remains the single highest-leverage optimisation in a vector unit.

Chained together, a whole sequence — load → multiply → add → store — can run as one long
software pipeline, all four units busy simultaneously, sustaining one result per lane per
cycle.

> **⚠️ Trap.** Chaining is *hard* to get right and easy to get subtly wrong (element
> counters must stay in lockstep; a stall in one unit must back-pressure the whole chain).
> Do **not** attempt it in a first working design. Get a correct, non-chained machine
> first (M3), measure it, then add chaining (M6) and measure the improvement. That
> before/after number is one of the best results one can put in the report.

---

## 2.5 Vector length and the "how many elements?" problem

A vector register holds up to VLMAX elements. Real loops rarely have a multiple of VLMAX
iterations.

Suppose VLEN=128, 32-bit elements → 4 elements per register. The array has 10 elements.
Two full passes of 4 leaves 2 left over. What happens?

**Packed SIMD's answer:** the programmer writes a separate scalar loop for the remainder.
Every vectorised loop in SSE/AVX/NEON code has this tail. It is ugly, error-prone, and it
must be rewritten when the register width changes.

**The vector answer:** a **vector length register**, `vl`. The hardware operates on
elements `0 … vl-1` and leaves the rest alone. Before each pass, the program says "I have
`n` elements remaining", and the hardware replies with how many it will do this time:

```
   pass 1:  n = 10  →  vl = 4    (elements 0-3)
   pass 2:  n = 6   →  vl = 4    (elements 4-7)
   pass 3:  n = 2   →  vl = 2    (elements 8-9)  ← short pass, handled in hardware
   pass 4:  n = 0   →  loop exits
```

No cleanup code. This loop structure is called **stripmining**, and because the *hardware*
answers the "how many?" question, the same code works on any VLEN. This is the mechanism
behind vector-length agnosticism, and one saw its effect in Chapter 1 §1.2 — the identical
binary that ran 4, 8, and 16 elements per pass.

Chapter 4 §4.4 gives the exact RISC-V rules; Chapter 7 drills the programming idiom.

### The three regions of a vector register

Once `vl` can be less than VLMAX, every vector register splits into regions during an
operation. Teams must internalise this — it drives the write-enable logic in the VRF.

```
   ┌────────────┬─────────────────────────┬──────────────────────┐
   │  PRESTART  │          BODY           │         TAIL         │
   │            │                         │                      │
   │ idx <      │   vstart ≤ idx < vl     │      idx ≥ vl        │
   │  vstart    │                         │                      │
   ├────────────┼─────────────────────────┼──────────────────────┤
   │ never      │ operated on, subject    │ governed by the      │
   │ touched    │ to the mask             │ "tail policy"        │
   └────────────┴─────────────────────────┴──────────────────────┘
        0                                vl                   VLMAX
```

- **Body** — the elements one actually compute. Within the body, the mask decides which
  elements are *active*.
- **Tail** — elements past `vl`. They exist physically but are not part of this operation.
  What happens to them is a policy choice (Chapter 4 §4.8).
- **Prestart** — elements before `vstart`, used only when resuming an interrupted
  instruction. Almost always 0. (Chapter 4 §4.9.)

---

## 2.6 Masks — vectorising `if`

What about this?

```c
for (int i = 0; i < n; i++)
    if (x[i] > 0)
        y[i] = x[i] * 2;
```

Some elements should be updated, others not. A vector operation writes all of them.

The solution is a **mask**: a bit per element saying "this element is active".

```
   x        = [  5 , -3 ,  8 , -1 ,  2 ,  0 , -7 ,  4 ]
   x > 0    = [  1 ,  0 ,  1 ,  0 ,  1 ,  0 ,  0 ,  1 ]   ← the mask
                 ▲    ▲
                 │    └── inactive: y[1] untouched
                 └─────── active: y[0] = 10

   y before = [ 99 , 99 , 99 , 99 , 99 , 99 , 99 , 99 ]
   y after  = [ 10 , 99 , 16 , 99 ,  4 , 99 , 99 ,  8 ]
```

Two steps in hardware terms:
1. A **comparison instruction** produces a mask (one bit per element) instead of a vector
   of values.
2. Arithmetic instructions accept a mask operand and suppress the write-enable for
   inactive elements.

That second point is the whole implementation: **a mask is a per-element write enable.**
In the RTL it is one bit ANDed into the byte-enable of the VRF write port. Conceptually
profound; structurally trivial. That is a good sign the team has understood it.

Chapter 4 §4.7 covers how RVV encodes masks (spoiler: register `v0` is special).

---

## 2.7 The vector load/store unit

The VLSU is where the theory meets a hostile reality: memory.

Three access patterns matter, and they cost wildly different amounts:

### Unit-stride — consecutive elements
```
   memory:  [e0][e1][e2][e3][e4][e5][e6][e7]
             ▲───────────────────────────▲
             one contiguous burst
```
The good case. One wide burst; if VLEN matches the cache-line width, one cache access
serves the whole vector. **Optimise for this — it is 90% of real code.**

### Strided — every k-th element
```
   memory:  [e0][ x ][ x ][e1][ x ][ x ][e2][ x ][ x ][e3]
             ▲            ▲            ▲            ▲
             stride = 3 elements
```
Common in matrix code (walking a column of a row-major matrix). Each element may land in a
different cache line. Cost: potentially one memory access per element.

### Indexed (gather/scatter) — addresses from another vector
```
   index vector = [ 7 , 2 , 9 , 0 ]
   memory:  [e0][e1][e2][e3][e4][e5][e6][e7][e8][e9]
              ▲       ▲                   ▲       ▲
              4th     2nd                1st     3rd  element fetched
```
Fully general, fully unpredictable, and the most expensive. Needed for sparse data and
table lookups.

> **⚠️ Trap — this is where projects die.** Teams estimate the VLSU at 15% of the effort
> and it turns out to be 40%. Unaligned accesses, elements straddling cache lines, partial
> bursts, exceptions in the middle of a vector, ordering between vector and scalar
> accesses — it is all here. Chapter 11 allocates the VLSU its own milestone (M4) for this
> reason, and Appendix E's scope contract deliberately restricts v1 to unit-stride and
> strided, deferring indexed access.

---

## 2.8 Putting it together — a trace

Follow one instruction, `vadd.vv v3, v1, v2`, through a 4-lane machine with VLEN=256,
32-bit elements (so VLMAX = 8), and `vl = 6`.

| Step | What happens |
|---|---|
| 1. **Decode** | Scalar front end sees opcode `OP-V`, funct3 `OPIVV`, funct6 `vadd`. Sends it to the vector unit. |
| 2. **Read state** | Sequencer reads `vtype` (SEW=32, LMUL=1) and `vl` = 6. Computes: 6 elements, 4 lanes → **2 passes**. |
| 3. **Pass 0** | Lanes 0–3 read elements 0–3 of `v1` and `v2` from their local VRF slices. Four adders fire. Results written to elements 0–3 of `v3`. |
| 4. **Pass 1** | Lanes 0–3 read elements 4–7. But `vl` = 6, so elements 6 and 7 are **tail**. The sequencer asserts write-enable only for lanes 0 and 1. Lanes 2 and 3 compute garbage, which is discarded. |
| 5. **Tail** | Elements 6, 7 of `v3` are handled per the tail policy — either left alone or filled with 1s. |
| 6. **Retire** | Instruction complete; `vstart` reset to 0. |

Notice step 4. **The lanes still did the work; the sequencer just didn't keep it.** That is
almost always the cheapest way to handle a partial pass, and it is how real designs do it.
Do not build logic to *prevent* the computation — build logic to *discard* it.

---

## 🔧 Exercises

**2.1** For VLEN = 512 and SEW = 16, how many elements per vector register? With 4 lanes,
how many passes does one full-length operation take?

**2.2** Draw the lane assignment (which lane owns which element) for VLEN=256, SEW=32,
L=2. Now do it for SEW=8. What changed?

**2.3** A machine has 4 lanes and executes `vmul.vv` (4-cycle latency) followed by a
dependent `vadd.vv` (1-cycle) on `vl`=32. Draw the cycle-by-cycle timeline (a) without
chaining, (b) with chaining. What is the speedup? At what `vl` does chaining stop mattering?

**2.4** Explain in two sentences why a mask is "just a write enable", and why that means
masking costs almost no area.

**2.5 (mentors)** For VLEN=512, estimate the VRF area in bit-cells and compare it to the
32×64-bit scalar register file. If the VRF needs 3 read ports and 1 write port, and a
multi-ported bit-cell costs roughly (ports)² relative to a single-ported one, argue for or
against building it from flip-flops.

**2.6 (design decision)** The team must pick a starting VLEN and lane count for MEDS-V.
Write down the choice and three reasons. Revisit after Chapter 10 and see if one'd change
it.

---

## Key takeaways

- Five structures: **VRF, lanes, VLSU, length/type state, sequencer.** Everything else is
  detail.
- The VRF is 32 × VLEN bits of dumb wide storage. Element width lives in the *control
  path*, not the storage.
- **Lanes** are vertical slices (register slice + ALU). Element *i* lives in lane *i* mod
  L. Element-wise ops need no inter-lane communication; reductions and permutes do.
- **Chaining** is forwarding at element granularity — start the consumer as soon as the
  first element is ready. Huge win, but add it *after* correctness.
- **`vl`** lets hardware handle the loop remainder, eliminating cleanup code and enabling
  vector-length agnosticism. Registers divide into prestart / body / tail.
- **Masks** are per-element write enables. They vectorise `if`.
- The **VLSU** handles unit-stride, strided, and indexed access, in increasing order of
  pain. Budget far more time for it than feels reasonable.

---

*Next: [Chapter 3 — From Cray-1 to RISC-V](03-from-cray-to-riscv.md)*
