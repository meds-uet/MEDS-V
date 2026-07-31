# Chapter 10 — The Design Space

> **Goal of this chapter.** Make the handful of decisions that shape everything else, with
> the reasoning written down. This chapter is a **decision record template** as much as a
> tutorial — work through it as a team in week 3 and commit the answers.

---

## 10.1 The decisions, and when they must be made

| # | Decision | Deadline | Cost of changing later |
|---|---|---|---|
| 1 | Coupled vs decoupled | Week 1 | **Catastrophic** — full rewrite |
| 2 | ELEN (32 or 64) | Week 2 | High — datapath width everywhere |
| 3 | Target extension (`Zve32x`?) | Week 2 | Medium — changes the instruction list |
| 4 | VLEN | Week 3 | **Low, if parameterised** ← the point of VLA |
| 5 | Number of lanes | Week 3 | **Low, if parameterised** |
| 6 | Tail/mask policy support | Week 3 | High — VRF write path |
| 7 | VRF organisation | Week 4 | Medium — module-internal |
| 8 | Memory port width | Week 4 | High — VLSU structure |
| 9 | Chaining | Week 10 (M6) | Low — additive |

Notice the pattern: **VLEN and lane count are cheap to change; almost everything else is
not.** That is not an accident — it is precisely what vector-length agnosticism buys the
*hardware* designer, not just the programmer. Exploit it: parameterise those two, fix the
others early.

---

## 10.2 Decision 1 — Coupled vs decoupled

Settled in Chapter 8 §8.1: **decoupled**, primarily so two teams can work in parallel
behind a frozen interface.

The one argument for coupled: if your team is three people and you already have a scalar
core you know intimately, integrating directly avoids designing a protocol. If that
describes you, it is a legitimate choice — but you lose the parallel work streams, and
almost every real design is decoupled.

---

## 10.3 Decision 2 — ELEN: 32 or 64?

ELEN is the widest element you support. It sets your lane datapath width.

| | **ELEN = 32** | ELEN = 64 |
|---|---|---|
| Lane datapath | 32 bits | 64 bits |
| Multiplier | 32×32 | 64×64 (≈4× the area) |
| Supports `e64` | No | Yes |
| Widening from `e32` | Not possible (would need 64-bit results) | Yes |
| Standard name | `Zve32x` | `Zve64x` |

> **🎯 Recommendation: ELEN = 32.**
>
> - A 64×64 multiplier is roughly four times the area of a 32×32, and none of the Chapter
>   14 benchmarks need 64-bit elements.
> - `Zve32x` is a real, citable extension name.
> - It halves your VRF read/write datapath width per lane.
>
> **The one real cost:** you cannot do `vwmacc` from `e32` to `e64`, so 32-bit
> accumulation must be handled in 32 bits with overflow risk. For your benchmarks
> (`int8`/`int16` data widening to `int32`) this is fine. Say so explicitly in your report.

---

## 10.4 Decision 4 — VLEN

The parameter everyone wants to argue about. It matters less than you'd think, because it
should be a parameter.

| VLEN | VRF size | Elements (SEW=32) | Simulation speed | Good for |
|---|---|---|---|---|
| **128** | 4 Kib | 4 | Fast | **Development and debug** |
| 256 | 8 Kib | 8 | OK | Middle ground |
| **512** | 16 Kib | 16 | Slow | **Showing off throughput** |
| 1024 | 32 Kib | 32 | Painful | Probably not on an FPGA |

> **🎯 Recommendation: develop at VLEN = 128, demonstrate at 128/256/512.**
>
> VLEN=128 keeps RTL simulation fast, which matters enormously when you are running
> thousands of co-simulation tests. Then, because everything is parameterised, re-elaborate
> at 256 and 512 for the final measurements — **and that VLEN sweep is one of the best
> results in your report.** It is a graph nobody can produce without a working
> parameterised design, and it directly demonstrates the vector-length-agnosticism claim
> from Chapter 1.

> **⚠️ Trap.** For this to work, `VLEN` must appear **nowhere** as a literal. No `128`, no
> `16` (bytes), no `4` (elements). Everything derives from the parameter package. Grep your
> RTL for bare numeric literals before M6 — you will find some.

---

## 10.5 Decision 5 — Number of lanes

```
   Throughput ∝ NR_LANES        (for element-wise ops)
   Area       ∝ NR_LANES        (roughly)
   VRF ports  — unchanged, but each lane's slice narrows
```

| Lanes | VRF slice at VLEN=128 | Elements/cycle (SEW=32) | Complexity |
|---|---|---|---|
| **1** | 128 bits | 1 | Simplest. **Start here.** |
| 2 | 64 bits | 2 | Easy step |
| **4** | 32 bits | 4 | Good demonstration point |
| 8 | 16 bits | 8 | Cross-lane ops start to hurt |

> **🎯 Recommendation: build for 1, demonstrate at 1, 2, 4.**
>
> Lane count is the *other* free scaling axis, and a lane-count sweep alongside the VLEN
> sweep gives you a 2-D result table. Two parameters, one design, a real scalability story.

**The catch:** cross-lane operations (reductions, slides) get harder as lanes multiply. At
one lane there is no "cross-lane" at all — reductions are just a loop. This is another
reason to start at one lane: **blocks ⑦ and ⑧ are nearly free in the L=1 configuration**,
so you can get the whole benchmark suite running before you take on inter-lane wiring.

### The relationship you must not confuse

```
   elements per pass = NR_LANES × (ELEN / SEW)

   NOT  NR_LANES.
```

At VLEN=128, ELEN=32, NR_LANES=2, SEW=8: each lane's 32-bit datapath handles 4 bytes, so
one pass covers **8 elements**, and VLMAX (LMUL=1) is 16 — two passes. Get this wrong in
your sequencer and every `e8` operation is wrong by a factor of four.

---

## 10.6 Decision 6 — Tail and mask policy support

Chapter 4 §4.8 gave the answer, but state it as a decision:

| Option | What you build | Compliance |
|---|---|---|
| **A. Undisturbed always** | Element-granular write enables; never write inactive/tail elements | ✅ Fully compliant with `ta`, `tu`, `ma`, `mu` |
| B. Agnostic-as-ones | Full-width writes; fill tails with 1s | ✅ For `ta`/`ma`, ❌ for `tu`/`mu` — you'd need option A as well |
| C. Both, with a policy mux | Extra mux and control | ✅ Compliant, more area, no benefit |

> **🎯 Recommendation: Option A.** Build only the undisturbed datapath. Because "retain
> previous values" is an explicitly permitted implementation of agnostic, you get full
> `vta`/`vma` compliance for free, with no policy mux.
>
> **What you give up:** on a machine where a full-width write is cheaper than a masked one
> (some SRAM macros), agnostic would let you skip the byte-enable logic. You aren't on such
> a machine.
>
> **Write this decision down**, because it is a good one and a reviewer will ask why you
> have no `vta` mux.

---

## 10.7 Decision 8 — Memory port width

The decision that determines whether your VLSU is hard or very hard.

| Port width | Unit-stride load of VLEN bits | VLSU complexity |
|---|---|---|
| 32 bits | VLEN/32 requests + reassembly | High |
| 64 bits | VLEN/64 requests | Medium |
| **VLEN bits** | **1 request** | **Low** |

> **🎯 Recommendation: memory port = VLEN bits, natural alignment required.**
>
> This makes the common case — a unit-stride access — a single transaction with a byte
> mask. Combined with requiring natural EEW alignment, blocks 2 and 3 of §9.6 nearly
> disappear, and you get a working VLSU in M4 rather than M7.
>
> It is not free: a VLEN-bit memory port is a wide, expensive interface, and on a real SoC
> you would be constrained by the bus. **Say this in your report.** "We used a VLEN-wide
> idealised memory port; a production design would need a coalescing unit and a narrower
> AXI interface" is an honest limitation that shows you understand the problem.

---

## 10.8 The reference configurations

Three named configurations. Build the first; report all three.

```systemverilog
// MEDS-V-S : small -- the development configuration
localparam VLEN = 128;  ELEN = 32;  NR_LANES = 1;
// VRF 4 Kib, 1 element/cycle at SEW=32, fast to simulate

// MEDS-V-M : medium -- the demonstration configuration
localparam VLEN = 256;  ELEN = 32;  NR_LANES = 2;
// VRF 8 Kib, 2 elements/cycle at SEW=32

// MEDS-V-L : large -- the throughput configuration
localparam VLEN = 512;  ELEN = 32;  NR_LANES = 4;
// VRF 16 Kib, 4 elements/cycle at SEW=32
```

Running the same test suite and the same benchmarks across all three, unmodified, **is your
headline result.** It proves parameterisation, it proves VLA, and it gives you a
scalability curve. Chapter 15 §15.5 shows how to present it.

---

## 10.9 Anti-patterns

Things teams do that reliably cost weeks:

**"We'll make VLEN configurable later."** You won't. Literals spread. Parameterise on day
one — it is nearly free then and expensive at week 10.

**"Let's implement all of RVV."** ~600 instructions once you count SEW/LMUL/mask
combinations. A verified subset beats an unverified superset every time. Appendix E exists
for this.

**"We'll add verification once it works."** By then you cannot tell *what* works. Chapter
13 puts co-simulation at M2 for exactly this reason.

**"The ALU is the interesting part."** The ALU is a week. The VLSU and the sequencer are
the project. Allocate people accordingly — put your strongest engineer on the VLSU, not the
adder.

**"We'll do chaining from the start."** Chaining requires everything else to be correct
first. It is an optimisation, and optimising an incorrect machine wastes the effort twice.

**"Let's start with 8 lanes to show off."** Cross-lane operations at 8 lanes are hard, and
you will be debugging reduction trees before you have a working `vadd`. Start at one.

---

## 10.10 Your decision record

Copy this into `docs/decisions.md`, fill it in as a team, and date it. Revisit at M4 and
M7; note anything you changed and why.

```markdown
# MEDS-V Design Decisions
Team: ____________________   Date: ____________   Revision: ____

| # | Decision            | Choice | Rationale | Revisit? |
|---|---------------------|--------|-----------|----------|
| 1 | Coupling            |        |           |          |
| 2 | ELEN                |        |           |          |
| 3 | Target extension    |        |           |          |
| 4 | VLEN (dev / demo)   |        |           |          |
| 5 | Lanes (dev / demo)  |        |           |          |
| 6 | Tail/mask policy    |        |           |          |
| 7 | VRF organisation    |        |           |          |
| 8 | Memory port width   |        |           |          |
| 9 | Chaining            |        |           |          |

## Deferred features (see Appendix E)
- ...

## Known limitations to state in the report
- ...
```

---

## 🔧 Exercises

**10.1** Compute the VRF flip-flop count for all three reference configurations. At roughly
6 gates per flop, estimate gate count. Compare with a 32×64 scalar register file.

**10.2** For MEDS-V-L (VLEN=512, 4 lanes, ELEN=32), how many elements are processed per
pass at SEW=8? At SEW=32? How many passes for `vl` = 100 at each?

**10.3** §10.7 recommends a VLEN-wide memory port. For VLEN=512 that is a 512-bit bus.
Estimate the cost in wires. What would you do differently for a real SoC?

**10.4** Argue the case *against* ELEN=32. Under what workload would 64-bit elements be
worth quadrupling the multiplier area?

**10.5 (whole team)** Complete the decision record in §10.10. Every row needs a rationale
sentence. Present it in a design review.

---

## Key takeaways

- **VLEN and lane count are cheap to change if parameterised; everything else is not.**
  Fix the others early, sweep those two at the end.
- **ELEN = 32** — a 64-bit multiplier costs 4× and buys nothing for your benchmarks.
- **Develop at VLEN=128, 1 lane. Demonstrate at 128/256/512 × 1/2/4 lanes.** That sweep is
  your headline result.
- **Elements per pass = NR_LANES × ELEN/SEW**, not NR_LANES.
- **Build only the undisturbed write path** — it is fully compliant with both policies and
  needs no mux.
- **VLEN-wide memory port + natural alignment** is the simplification that makes the VLSU
  tractable in one milestone. State the limitation honestly.
- Anti-patterns that cost weeks: deferred parameterisation, unbounded scope, deferred
  verification, over-investing in the ALU, early chaining, too many lanes too soon.

---

*Part III complete. Next: [Chapter 11 — The Project Roadmap](../part4/11-project-roadmap.md)*
