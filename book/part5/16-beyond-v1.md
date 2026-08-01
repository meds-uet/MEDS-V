# Chapter 16 — Beyond v1

> **Purpose of this chapter.** Where the project goes after M7. Each section is a candidate
> follow-on with an honest estimate of its cost and what it would demonstrate.

---

## 16.1 Choosing what comes next

The v1 scope contract (Appendix E) defers a substantial amount. Not all of it is worth
picking up, and the criteria differ from the criteria that governed v1:

| Ask | Why it matters |
|---|---|
| What does it *demonstrate*? | v2 should teach something v1 did not |
| What does it *cost*? | Measured in the same units as Chapter 11's milestones |
| Does it *unblock* other work? | Some items are prerequisites for many others |
| Is there a **measurable** result? | A change with no number attached is hard to defend |

The options below are ordered by return on effort for a team that has just finished v1.

---

## 16.2 FPGA bring-up — the highest-value next step

**Cost:** 3–4 weeks. **Difficulty:** ●●●○○. **Prerequisite for:** everything physical.

Simulation proves function; an FPGA proves the design is real. It also produces the first
numbers that are not simulator artefacts: actual LUT and flip-flop counts, actual f_max, an
actual critical path.

What the move surfaces, roughly in the order it will hurt:

1. **The VRF is too big for flip-flops.** At VLEN=512 that is 16 Kib of storage with three
   read ports. The flat array from Chapter 9 §9.3 Option 1 will either fail to fit or fail
   timing. This forces the move to lane-sliced or banked storage — which is the *real*
   lesson of FPGA bring-up.
2. **Timing on the VRF read → ALU → VRF write loop.** Almost certainly the critical path.
3. **The memory interface.** The VLEN-wide idealised port of Chapter 10 §10.7 does not exist
   on real hardware. A proper AXI interface with a coalescing unit is needed, and that is
   the point at which the deferred VLSU complexity arrives.

> **The honest framing for a report:** "The simulation model assumed a VLEN-wide
> single-cycle memory port. On the FPGA this became an AXI4 interface at 64 bits, requiring
> a coalescing unit; memcpy throughput fell from X to Y elements/cycle as a result." That
> is a genuine engineering finding, and it is the kind of thing that distinguishes a project
> that was built from one that was only simulated.

Suggested targets: any board with ≥ 50k LUTs. Start at MEDS-V-S (VLEN=128, 1 lane) and grow
only after timing closes.

---

## 16.3 Floating point — `Zve32f`

**Cost:** 6–10 weeks. **Difficulty:** ●●●●● **as a whole**; ●●●○○ for the vector part.

The vector plumbing for floating point is nearly identical to the integer path — same
sequencer, same VRF, same masks, same tails. **The cost is the FPU itself**, and it is
almost entirely verification:

- five rounding modes,
- subnormal handling,
- NaN propagation rules (quiet vs signalling, which operand wins),
- five exception flags with precise semantics,
- `vfredosum` vs `vfredusum` — ordered and unordered reductions, which give *different*
  results and both must be right.

That last point is a genuine trap. Floating-point addition is not associative, so a
reduction's answer depends on its order. RVV therefore provides both an ordered form (slow,
reproducible) and an unordered form (fast, implementation-defined order). A tree reduction
implements the unordered form; the ordered form must be strictly sequential.

> **🎯 The decisive question:** does anyone on the team already have a working, verified
> pipelined IEEE-754 FPU? If yes, `Zve32f` is a 3-week integration job and well worth doing.
> If no, this is an FPU project with a vector wrapper, and the vector part is not what will
> be learned. Consider integrating an existing open-source FPU (such as `fpnew` from ETH
> Zürich) rather than building one.

---

## 16.4 Chaining

**Cost:** 3–4 weeks. **Difficulty:** ●●●●○. **Measurable result:** yes, directly.

The Cray-1's signature optimisation (Chapter 2 §2.4): start a dependent instruction as soon
as the first element of its operand is available, rather than waiting for the whole vector.

This is attractive as a v2 project precisely because v1 provides the baseline. The result is
a clean before/after on the same design, same tests, same kernels — which is exactly the
shape of a good result.

What it requires:

- element-granular dependency tracking, not the instruction-granular scoreboard of v1,
- element counters kept in lockstep across chained units,
- back-pressure propagating through the whole chain when any unit stalls,
- careful handling of the case where the producer is slower than the consumer.

**Where it pays:** kernels with dependent chains, which in this suite means FIR and GEMM.
memcpy has nothing to chain. Expect a modest and workload-dependent improvement — and report
it as such.

---

## 16.5 The deferred instructions

Roughly in order of value per unit of effort:

| Feature | Cost | Unlocks |
|---|---|---|
| `vslideup`/`vslidedown` (arbitrary) | 1 week | Sliding-window kernels, better FIR |
| Fault-only-first (`vle32ff.v`) | 1–2 weeks | Vectorised `strlen`, data-dependent loops |
| Indexed load/store (gather/scatter) | 3 weeks | Sparse data, table lookup, histogram |
| Segment load/store | 2–3 weeks | RGB/complex de-interleaving in one instruction |
| `vrgather` | 3–4 weeks | Arbitrary permutation, transpose |
| `vcompress` + `viota` | 2–3 weeks | Stream filtering |
| `vdiv`/`vrem` | 1–2 weeks | Completeness; little benchmark impact |

**Best value:** arbitrary slides, then fault-only-first. Slides are cheap because the ring
network already exists for `vslide1up`/`vslide1down`, and fault-only-first is the one
instruction that makes data-dependent loop bounds vectorisable at all.

**Highest cost, most impressive:** `vrgather`. It requires a real crossbar and is a genuine
research-adjacent problem — there is published work on implementing RVV permutations
efficiently (Appendix D). A team that implements `vrgather` well has something publishable.

---

## 16.6 Microarchitectural optimisations

Beyond chaining, and all measurable against the v1 baseline:

**Multiple outstanding memory requests.** v1 issues one at a time and waits. A request queue
lets the VLSU keep several in flight, which matters most for strided access where each
element may be a separate transaction. Cheap relative to its benefit — probably the best
optimisation-to-effort ratio available.

**Reduction tree.** Replace the serial reduction (Chapter 9 §9.8) with a `log₂(NR_LANES)`
tree. Directly improves the dot-product kernel, which Chapter 14 §14.9 identified as the
suite's weakest scaler.

**Banked VRF.** Required if the design grows past what flip-flops can supply, and forced by
the FPGA move anyway. Brings bank-conflict detection with it.

**Decoupled access-execute.** Let the VLSU run far ahead of the arithmetic units, buffering
loaded data. This is the Hwacha idea (Chapter 3 §3.3) and is the structural route to hiding
memory latency without speculation.

---

## 16.7 Multi-core and coherence

**Cost:** 8+ weeks. **Difficulty:** ●●●●●

Several MEDS-V cores sharing memory. The vector-specific problems on top of ordinary
multi-core work:

- **Coherence with wide accesses.** A vector store can touch many cache lines; invalidation
  traffic multiplies.
- **Vector context switching.** The VRF is 2–16 KiB of state. This is where `mstatus.VS`'s
  Clean/Dirty tracking (Chapter 4 §4.1) stops being optional — an OS that saved the VRF on
  every switch would be crippled.
- **Memory ordering** between vector and scalar accesses across cores.

This is a project in its own right, and the natural home for a follow-on team rather than an
extension of v1.

---

## 16.8 Running an operating system

**Cost:** 4–6 weeks on top of a working core with an MMU. **Difficulty:** ●●●●○

Booting Linux on the design is a milestone with real communicative value — it is
immediately legible to people who do not read RTL. The vector-specific requirements:

1. **Full `mstatus.VS` state machine**, including Clean/Dirty, so the kernel saves the VRF
   only when it has been touched.
2. **Precise, restartable vector instructions** — `vstart` must genuinely work, which v1
   implements only at instruction granularity (Chapter 4 §4.9).
3. **Page faults mid-instruction.** A vector load spanning a page boundary can fault
   partway; the VLSU must report the failing element index into `vstart`.

Item 3 is the hard one and is the reason v1 defers it. It is also unavoidable for a real OS.

---

## 16.9 A suggested v2 scope

For a team that has completed v1 and has another semester, the recommendation:

| Priority | Item | Weeks | Rationale |
|---|---|---|---|
| 1 | **FPGA bring-up** | 4 | Real numbers; forces the VRF redesign; unblocks everything |
| 2 | **Multiple outstanding loads** | 2 | Best effort-to-benefit ratio |
| 3 | **Reduction tree** | 2 | Fixes the suite's weakest kernel |
| 4 | **Arbitrary slides + fault-only-first** | 3 | Widens the workload set cheaply |
| 5 | **Chaining** | 4 | Clean before/after result against the v1 baseline |
| | *Total* | *15* | |

Notably absent: floating point and `vrgather`. Both are excellent projects and both are
large enough to deserve their own team rather than a slot in a list.

---

## 16.10 Publishing the work

The project is worth writing up beyond the internal report.

**Open-source the RTL.** Apache-2.0, matching the rest of the MEDS material. A documented,
verified, parameterised `Zve32x` implementation with a benchmark suite is a genuinely useful
artefact — Vicuna and Ara are widely read precisely because they are readable.

**What makes it citable rather than merely available:**

- A clear statement of the implemented subset (Appendix E is already this)
- Reproducible benchmarks (Chapter 15 §15.8)
- The configuration sweep — few open designs publish one
- Honest limitations

**Venues worth considering:** the RISC-V Summit (industry-facing, welcomes student work),
FPGA and computer-architecture education workshops, and the RISC-V International technical
mailing lists, where implementation experience reports are read carefully.

**The most valuable thing to write up** is not the design — it is what was learned building
it. The measurement traps of Chapter 15 §15.3, the VLEN=1024 elaboration bug of Chapter 12
§12.4, the `v0` mask hazard, the tail-policy dependency in the dot product: these are the
things another team would benefit from and that no specification document contains.

---

## Key takeaways

- **FPGA bring-up is the highest-value next step.** It produces real area and timing
  numbers and forces the VRF redesign that simulation lets a team avoid.
- **Floating point is an FPU project with a vector wrapper.** Worth it only if the FPU
  already exists or can be integrated.
- **Chaining gives a clean before/after result** against the v1 baseline — a good shape for
  a follow-on.
- Best deferred instructions to add: **arbitrary slides**, then **fault-only-first**.
  `vrgather` is the impressive one and is nearly a research project.
- Best cheap optimisations: **multiple outstanding loads**, then a **reduction tree** for
  the dot product.
- Multi-core and OS support are separate projects, not extensions.
- **Open-source it**, and write up what was learned — the traps and the bugs — not just the
  design.

---

*End of Part V. See the [Appendices](../appendix/A-instruction-quickref.md) for reference
material, and [Appendix E](../appendix/E-scope-contract.md) for the scope contract to sign
in week 1.*
