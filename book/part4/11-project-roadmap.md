# Chapter 11 — The Project Roadmap

> **Goal of this chapter.** Turn the block diagram into a schedule with owners, deliverables,
> and exit criteria. This is the chapter mentors run the project from.

---

## 11.1 The shape of the project

Eight milestones over roughly 16 weeks. The proportions matter more than the absolute
numbers — scale to the team's calendar, but **keep the ratios**.

```
 Week:  1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16
        │    │    │    │    │    │    │    │    │    │    │    │    │    │    │    │
  M0 ███████│    │    │    │    │    │    │    │    │    │    │    │    │    │    │
  M1      ████████│   │    │    │    │    │    │    │    │    │    │    │    │    │
  M2           ████████    │    │    │    │    │    │    │    │    │    │    │    │
  M3               ██████████████     │    │    │    │    │    │    │    │    │    │
  M4                        ████████████████████│    │    │    │    │    │    │    │
  M5                                       ██████████████    │    │    │    │    │
  M6                                                 ██████████████     │    │    │
  M7                                                           ████████████████████
        │    │    │    │    │    │    │    │    │    │    │    │    │    │    │    │
       learn  decode  VRF   datapath      VLSU        mask/    optimise    measure
                                                      reduce             & write up
```

Note **M4 (the VLSU) gets four weeks** — more than any other block. That is deliberate
(Chapter 9 §9.6). If anything must be compressed, it should not be that.

---

## 11.2 The milestones

### M0 — Learn the ISA (weeks 1–2)

**Everyone**, mentors and mentees. No RTL.

| Deliverable | Owner |
|---|---|
| Toolchain installed and working for every team member | Everyone |
| Chapters 1–7 read; exercises completed | Everyone |
| All three examples built and run at three VLENs | Everyone |
| Dot product written from scratch in intrinsics (Ex 6.3) | Everyone |
| **Decision record** started (Ch 10 §10.10) | Mentors |
| **Interface specification** written and frozen (Ch 8 §8.4) | Lead |
| **Scope contract** signed (Appendix E) | Mentors |

**Exit criterion:** every team member can explain, at a whiteboard, what `vsetvli t0, a0,
e32, m1, ta, ma` does and what `vl` will be for a given AVL and VLEN.

> **Do not skip M0.** Two weeks feels like a lot when everyone is impatient to write RTL.
> It is the cheapest two weeks in the project. Teams that skip it spend six weeks in M4
> debugging misunderstandings from week 1.

### M1 — Decoder and CSR unit (weeks 2–4)

Blocks ① and ②. Pure combinational and small sequential logic — a good first RTL task and
an ideal mentee assignment.

| Deliverable | Exit criterion |
|---|---|
| `vec_decoder.sv` | All ~120 encodings decode correctly |
| `vec_csr.sv` | All 2048 `vsetvli` immediates match Spike |
| `meds_v_pkg.sv` (parameters and types) | Elaborates at VLEN = 128/256/512 |
| Unit testbenches for both | 100% of the decode table covered |

**Exit criterion:** feed the decoder 10 000 random 32-bit words; its `illegal_o` agrees
with Spike's on every one.

### M2 — VRF and the co-simulation harness (weeks 4–6)

Block ④, plus — critically — the verification infrastructure.

| Deliverable | Exit criterion |
|---|---|
| `vrf.sv` | Write/read all registers, all byte-enable patterns |
| **Spike trace capture script** | Produces a normalised trace from any ELF |
| **Trace comparison script** | Detects an injected single-instruction mismatch |
| RTL trace emission (stub) | Emits the same format |

> **🎯 M2 is the milestone teams are most tempted to cut, and cutting it is the single
> biggest predictor of project failure.** This means building the checker before the thing it
> checks. Chapter 13 §13.4 gives the trace format. Prove the comparison script works by
> deliberately corrupting a trace and confirming it is caught.

### M3 — The datapath (weeks 6–9)

Blocks ③ and ⑤. **The first milestone where something executes.**

| Deliverable | Exit criterion |
|---|---|
| `vec_lane.sv` (ALU) | Every op, every SEW, vs. a reference model |
| `vec_sequencer.sv` | Correct pass count for all SEW/LMUL/`vl` |
| `meds_v_top.sv` integration | `vadd.vv` runs end to end |
| Testbench that preloads the VRF | 20 directed arithmetic tests pass |

**Exit criterion:** a testbench pushes `vadd.vv v3, v1, v2` into the issue interface with
`v1`/`v2` preloaded, and `v3` is correct for `vl` = 0, 1, VLMAX−1, VLMAX.

> **There is no memory yet.** This is the point (Chapter 9 §9.9). Verify the sequencer and
> lanes in isolation, before the VLSU can muddy the picture.

### M4 — The VLSU (weeks 8–12)

Block ⑥. **The hardest milestone. Four weeks. It should get the team's strongest engineer.**

| Deliverable | Exit criterion |
|---|---|
| `vec_lsu.sv` — unit-stride | `vle32.v`/`vse32.v` bit-exact vs Spike |
| Strided support | Positive, negative, zero stride |
| Masked accesses | **No memory request for inactive elements** (bus monitor) |
| Simple memory model + AXI wrapper | Backpressure test passes |
| **First real program runs** | The Chapter 1 SAXPY loop executes correctly |

**Exit criterion:** a compiled C program with a stripmine loop runs on the RTL and
produces the same memory image as Spike.

That moment — the first real compiled program running on hardware the team designed — is the
emotional high point of the project. Plan a demo.

### M5 — Masks, reductions, permutes (weeks 11–13)

Blocks ⑦ and ⑧.

| Deliverable | Exit criterion |
|---|---|
| `vec_mask.sv` | Masked arithmetic matches Spike, random masks |
| Serial reduction | `vredsum` correct across stripmine passes |
| `vslide1up`/`vslide1down` | FIR delay line works |
| `vmv.x.s`/`vmv.s.x` | Scalar writeback path verified |

**Exit criterion:** **all six Chapter 14 benchmarks run correctly** at MEDS-V-S.

### M6 — Optimise and scale (weeks 13–15)

No new features. Make it faster and prove it scales.

| Deliverable | Exit criterion |
|---|---|
| 2-lane and 4-lane configurations | All tests pass unmodified |
| VLEN = 256 and 512 configurations | All tests pass unmodified |
| Optional: chaining | Measurable speedup, tests still pass |
| Optional: reduction tree | Measurable speedup |
| Optional: multiple outstanding loads | Measurable speedup |

**Exit criterion:** the full test suite passes on all nine (VLEN × lanes) combinations.

> Pick **at most one** of the three optional items. A team that attempts all three usually
> lands none. Chaining has the largest payoff and the largest risk.

### M7 — Measure, compare, write up (weeks 14–16)

| Deliverable | Exit criterion |
|---|---|
| Cycle counts for all benchmarks × all configurations | Reproducible via one script |
| Scalar baseline comparison | Speedup table |
| Comparison against Ara / Vicuna / Saturn | Normalised, with methodology stated |
| Area/frequency numbers (if synthesising) | Post-synthesis, stated tool and target |
| **Final report and presentation** | — |

---

## 11.3 The critical path

```
   M0 ──► M1 ──► M2 ──► M3 ──────► M4 ──────► M5 ──► M6 ──► M7
                        (datapath) (VLSU)
                             └─── the two long poles ───┘
```

**M3 and M4 together are half the project.** Everything before them is preparation;
everything after is refinement. When the schedule slips — and it will — protect these two
by cutting from M6, never from M2.

### What to cut, in order, when time runs short

1. Chaining and other M6 optimisations → cut first, always
2. The 4-lane configuration → report 1 and 2 lanes
3. Strided loads → report unit-stride only, document it
4. Reductions → cut the benchmarks that need them (dot product, softmax)
5. **Never cut:** co-simulation (M2), the scope contract, the final measurements

---

## 11.4 Risk register

Keep this live. Review it at every milestone gate.

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **VLSU takes longer than planned** | **High** | **High** | Wide port + natural alignment (Ch 10 §10.7). Four-week budget. Descope to unit-stride only. |
| Scope creep into full RVV | High | High | Signed scope contract (Appendix E). Review at each gate. |
| Verification deferred | Medium | **Critical** | M2 gate is hard — no M3 work starts until the trace comparator works |
| Team member leaves | Medium | Medium | Two owners per block; no single points of knowledge |
| Sequencer bugs found late | Medium | High | M3's memory-free testbench isolates it |
| Integration surprises | Medium | High | Interface frozen in week 2; weekly integration builds from M3 |
| Toolchain problems | Low | Medium | M0 requires everyone's toolchain working |

---

## 11.5 Team structure

Assuming **2 mentors + 4–6 mentees**. Adjust proportionally.

| Role | Who | Owns |
|---|---|---|
| **Architect / lead** | Senior mentor | Interface spec, scope contract, integration, design reviews |
| **Verification lead** | Mentor | M2 infrastructure, co-simulation, test plan, CI |
| **Front-end team** | 1–2 mentees | ① decoder, ② CSR unit |
| **Datapath team** | 2 mentees | ④ VRF, ⑤ lanes, ③ sequencer |
| **Memory team** | 1–2 mentees + a mentor | ⑥ VLSU ← *strongest people here* |
| **Benchmark team** | 1 mentee | Chapter 14 kernels, Chapter 15 measurement |

**Two rules that matter more than the org chart:**

1. **Every block has two people who understand it.** Not two owners — one owner, one
   reviewer who has read the code and could fix a bug in it.
2. **The benchmark team starts at M0, not M5.** The kernels must be written and validated
   on Spike long before the RTL can run them. A benchmark team that starts late is a
   benchmark team that discovers at week 14 that the design can't run the workload.

### Weekly rhythm

| When | What | Duration |
|---|---|---|
| Monday | Standup at the block diagram. Each owner: status, blockers. | 20 min |
| Wednesday | Design review: one block, in depth, code on screen | 60 min |
| Friday | Integration build + full regression. **Must be green to go home.** | — |
| Milestone gate | Formal review against exit criteria. Go / no-go. | 90 min |

The Friday green build is the discipline that makes everything else work. A red build on
Friday means Monday starts with debugging instead of progress.

---

## 11.6 What "done" looks like

At M7 a reader should be able to hand someone:

- [ ] A parameterised SystemVerilog vector processor implementing a documented subset of
      RVV 1.0 (`Zve32x`-flavoured)
- [ ] Passing co-simulation against Spike on a suite of test programs
- [ ] Six benchmark kernels running correctly
- [ ] Cycle counts across 3 VLENs × 3 lane counts
- [ ] A comparison table against a scalar baseline and against published open-source
      vector units
- [ ] A written scope contract listing exactly what is *not* implemented, and why
- [ ] A report that states its limitations before a reviewer has to find them

That last point is worth dwelling on. **A project that clearly states "the team implemented
unit-stride and strided loads, required natural alignment, and deferred indexed access
because X" is far stronger than one that quietly omits it.** Examiners and reviewers reward
knowing the own boundaries.

---

## 🔧 Exercises

**11.1 (mentors, week 1)** Map the milestones onto the implementerr actual calendar. Where are the
exams, holidays, and other deadlines? Adjust — but preserve the M3/M4 proportion.

**11.2 (mentors, week 1)** Fill in §11.5 with real names. Identify, for each block, the
second person who will understand it.

**11.3 (whole team, week 3)** Run a pre-mortem: it is week 16 and the project failed.
Write down why. Compare with §11.4 and add anything one found.

**11.4 (mentors, at each gate)** Score the exit criteria honestly. A milestone is not
complete because the date passed.

---

## Key takeaways

- **Eight milestones, ~16 weeks.** M3 (datapath) and M4 (VLSU) are half the project.
- **M0 is two weeks of learning with no RTL.** It is the cheapest time the team will spend.
- **M2 builds the verification harness before there is anything to verify.** This gate is
  hard: no M3 work until the trace comparator catches an injected bug.
- **M3 gives the implementer a working datapath with no memory** — isolating the sequencer from the
  VLSU.
- **M4 gets four weeks and the strongest engineer.** The VLSU is the schedule risk.
- Cut from M6 (optimisations) when one slip. **Never cut verification or scope discipline.**
- Two people understand every block. The benchmark team starts at M0.
- Friday integration build must be green.
- **Stating the limitations clearly is a strength**, not an admission.

---

*Next: [Chapter 12 — RTL Skeleton Walkthrough](12-rtl-skeleton-walkthrough.md)*
