# Appendix E — The Scope Contract

> **This is a document to be signed in week 1, defended for sixteen weeks, and reproduced
> verbatim in the final report.**
>
> The most common way a project like this fails is not technical difficulty. It is scope.
> RVV 1.0 comprises roughly 600 instructions once every SEW, LMUL, and masking combination
> is counted — more than a small team can implement, let alone verify, in a semester.

---

## E.1 Why a contract

A written, agreed scope does three things:

1. **It makes "no" cheap.** When someone proposes adding indexed loads in week 9, the answer
   is not a negotiation — it is a reference to a document the team already agreed.
2. **It converts omissions into decisions.** An unimplemented feature that appears in this
   list is a *choice*. The same feature missing without explanation is a *gap*. Reviewers
   read the two very differently.
3. **It defines "done".** Without it there is no point at which the project is complete,
   only a point at which time runs out.

---

## E.2 What MEDS-V v1 implements

### Target extension

**`Zve32x` + `Zvl128b`** — a standard, citable RVV 1.0 subset: 32-bit integer elements, no
floating point, VLEN ≥ 128.

This matters. "MEDS-V implements `Zve32x_Zvl128b`" is a precise claim against a ratified
standard. "MEDS-V implements some vector instructions the team chose" is not.

### Parameters

| Parameter | Value | Swept for results |
|---|---|---|
| VLEN | 128 (development) | 128 / 256 / 512 |
| ELEN | 32 | fixed |
| NR_LANES | 1 (development) | 1 / 2 / 4 |
| SEW supported | 8, 16, 32 | |
| LMUL supported | 1/8 … 8 | |

### Instructions — ~58 operations, ~120 encodings

**Configuration (3)** — `vsetvli`, `vsetivli`, `vsetvl`

**Loads and stores (10)** — `vle8/16/32.v`, `vse8/16/32.v`, `vlse32.v`, `vsse32.v`,
`vl1re32.v`, `vs1r.v`

**Integer arithmetic (18)** — `vadd`, `vsub`, `vrsub`, `vand`, `vor`, `vxor`, `vsll`,
`vsrl`, `vsra`, `vmin`, `vminu`, `vmax`, `vmaxu`, `vmerge`, `vmv.v.*`, `vzext.vf2`,
`vsext.vf2`, `vid.v` — in `.vv`/`.vx`/`.vi` forms as applicable

**Comparisons (6)** — `vmseq`, `vmsne`, `vmslt`, `vmsltu`, `vmsle`, `vmsleu`

**Multiply (5)** — `vmul`, `vmulh`, `vmulhu`, `vmacc`, `vwmacc`

**Widening (3)** — `vwadd`, `vwaddu`, `vwmul`

**Reduction (3)** — `vredsum`, `vredmax`, `vredmin`

**Mask (6)** — `vmand`, `vmor`, `vmxor`, `vmnot`, `vcpop`, `vfirst`

**Permute (4)** — `vmv.x.s`, `vmv.s.x`, `vslide1up`, `vslide1down`

### Architectural behaviour

- All seven vector CSRs, including `vlenb` reporting the build-time VLEN
- `mstatus.VS` enable, with trap-on-disabled
- `vill` semantics: set the bit, zero the other fields, `vl = 0`, do not trap
- All four `vsetvli` AVL cases, including both `rs1 == x0` meanings
- `vl = min(AVL, VLMAX)`
- Tail and mask policies via element-granular write enables (see §E.4)
- `vstart` gating of element writes, cleared at retire
- Register-group alignment and EMUL-range legality checks

---

## E.3 What MEDS-V v1 does **not** implement

Each row states the reason. A deferral without a reason is a gap.

| Deferred | Reason | Chapter |
|---|---|---|
| **All floating point** (`OPFVV`, `OPFVF`) | Requires a pipelined IEEE-754 FPU — a separate project with its own verification burden | 5 §5.11, 16 §16.3 |
| `e64` elements | ELEN = 32 by design; a 64×64 multiplier costs ~4× a 32×32 and no benchmark needs it | 10 §10.3 |
| `vdiv`, `vrem` | Iterative, non-pipelined, negligible benchmark impact | 5 §5.5 |
| **Indexed load/store** (gather/scatter) | Requires reading an index vector before address generation; large VLSU complication | 9 §9.6 |
| **Segment load/store** | Significant VLSU complication; strided loads cover the same use cases more slowly | 5 §5.3 |
| **Fault-only-first** | Requires the VLSU to report a fault index back into `vl` | 5 §5.3 |
| `vrgather`, `vcompress` | Require a full crossbar; a project in themselves | 5 §5.9 |
| `viota`, `vmsbf/if/of` | Only useful alongside `vcompress` | 5 §5.8 |
| Arbitrary `vslideup`/`vslidedown` | Need a full shift network; the ±1 slides use a cheap ring | 9 §9.8 |
| Fixed-point saturating ops | Cheap to add later; not needed by the benchmark suite | 5 §5.6 |
| **Chaining** | An optimisation. Correctness first; a v1 baseline makes it a measurable v2 result | 2 §2.4, 16 §16.4 |
| Reduction tree | Serial reduction is correct and adequate; the tree is a measurable optimisation | 9 §9.8 |
| Multiple outstanding memory requests | One at a time in v1; a queue is a v2 optimisation | 9 §9.6 |
| Precise mid-instruction traps | Faults are precise at instruction granularity only | 4 §4.9 |
| `mstatus.VS` Clean/Dirty tracking | Only needed under an OS; bare metal hardwires Dirty | 4 §4.1 |
| Unaligned memory access | Natural EEW alignment required; violations trap | 9 §9.6, 10 §10.7 |
| Multi-core, coherence, MMU | Out of scope entirely | 16 §16.7 |

---

## E.4 Documented implementation choices

Not omissions — deliberate decisions that a reviewer should be told about.

**Tail and mask policies are implemented as undisturbed only.** Because "retain previous
values" is an explicitly permitted implementation of the *agnostic* policies, building only
the undisturbed write path yields full compliance with `vta` = 0 or 1 and `vma` = 0 or 1,
with no policy mux. The cost is foregoing the full-width-write optimisation that agnostic
would allow on some memory technologies. → Ch 4 §4.8

**`vl = min(AVL, VLMAX)`.** The specification permits an implementation to balance the final
two passes (returning, say, 5 and 4 rather than 8 and 1). MEDS-V takes the simple legal
option: one comparator, one mux. → Ch 4 §4.4

**The memory port is VLEN bits wide and requires natural alignment.** This makes a
unit-stride access a single transaction and is what makes the VLSU tractable in one
milestone. A production design would need a coalescing unit behind a narrower bus. → Ch 10
§10.7

**The scalar core stalls on scalar memory access while vector memory operations are
outstanding.** Full scalar/vector memory disambiguation is deferred; the conservative
interlock is one comparator and is obviously correct. Its cost is measured in Chapter 15.
→ Ch 8 §8.4

**One vector instruction in flight at a time** (extended in M6 to allow a load to overlap
arithmetic). → Ch 9 §9.5

---

## E.5 Acceptance criteria

The project is complete when all of the following hold.

**Functional**
- [ ] All ~120 encodings of §E.2 decode correctly
- [ ] All six Chapter 14 kernels produce results identical to their scalar references
- [ ] Kernels verified at N = 257 (a prime, forcing a short final pass)

**Verification**
- [ ] Unit testbenches pass for all seven blocks
- [ ] Spike co-simulation passes on the full test-program suite
- [ ] Architectural tests pass for the implemented subset, with exclusions listed
- [ ] Random instruction sequences pass
- [ ] CI green: lint, unit tests, parameter sweep, co-simulation

**Parameterisation**
- [ ] Elaborates and passes at VLEN ∈ {128, 256, 512} × NR_LANES ∈ {1, 2, 4}
- [ ] No bare VLEN-derived numeric literals anywhere in the RTL

**Results**
- [ ] Cycle counts for 6 kernels × 9 configurations
- [ ] Scalar baseline comparison, with the instruction-versus-cycle gap explained
- [ ] Stall-cause breakdown
- [ ] Comparison table against published designs, with a like-for-like caveat per row
- [ ] Every number regenerable by one command

**Documentation**
- [ ] This contract, reproduced in the report
- [ ] The decision record of Chapter 10 §10.10
- [ ] Limitations stated before the conclusion

---

## E.6 Change control

Changing this contract requires: a written proposal naming the item, its milestone cost, and
what is being **removed** to pay for it; agreement from both mentors; and a dated revision
below.

Adding scope without removing scope is not a change to the contract. It is how the project
fails.

---

## E.7 Signature block

```
MEDS-V v1 Scope Contract
Revision: 1.0          Date: ____________

Agreed:

  Architect / lead        ______________________   ____________

  Verification lead       ______________________   ____________

  Team members            ______________________   ____________
                          ______________________   ____________
                          ______________________   ____________
                          ______________________   ____________

Revision history
  1.0  ____________  Initial scope agreed
```

---

## E.8 A closing note on scope

It is worth stating plainly, because the instinct runs the other way:

> **A verified 58-instruction vector processor that runs six workloads and produces a
> defensible comparison table is an excellent result. An unverified 300-instruction one that
> runs nothing is not a result at all.**

The temptation in week 9 will be to add features. The right response is almost always to
improve verification, widen the configuration sweep, or sharpen the measurements — because
those are what turn a working design into evidence that it works.
