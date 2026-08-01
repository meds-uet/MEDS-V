# Appendix B — Glossary

Terms are defined as they are used in this book. Chapter references point to where each is
introduced properly.

---

**AVL** — *Application Vector Length*. The number of elements the program still has to
process, handed to `vsetvli` as its input. The hardware replies with `vl`, which may be
smaller. Not to be confused with `vl` or VLMAX. → Ch 4 §4.4

**Agnostic** — A policy (`vta=1` or `vma=1`) declaring that the program does not care what
happens to tail or inactive elements. The hardware may preserve them or fill them with 1s.
Exists to let implementations avoid a read-modify-write. → Ch 4 §4.8

**Body** — The elements an instruction actually operates on: indices from `vstart` up to
`vl-1`. → Ch 2 §2.5

**Chaining** — Starting a dependent instruction as soon as the producer's first element is
available, rather than waiting for the whole vector. Operand forwarding at element
granularity; the Cray-1's signature optimisation. → Ch 2 §2.4

**Co-simulation** — Running the same program on the RTL and on a reference model (Spike) and
comparing the committed-instruction streams. The backbone of this project's verification.
→ Ch 13 §13.4

**Decoupled coprocessor** — A vector unit that receives instructions over a defined
interface and executes them asynchronously, rather than being a stage in the scalar
pipeline. MEDS-V's chosen structure, mainly so two teams can work in parallel. → Ch 8 §8.1

**EEW** — *Effective Element Width*. The element width an individual operand uses, which may
differ from SEW: `vle32.v` always loads 32-bit elements regardless of `vtype`. → Ch 4 §4.10

**ELEN** — The widest element width an implementation supports. A hardware parameter.
MEDS-V uses ELEN = 32. → Ch 4 §4.2

**EMUL** — *Effective LMUL*. The register grouping implied by an operand's EEW:
`EMUL = LMUL × EEW / SEW`. Outside 1/8…8 the encoding is reserved. → Ch 4 §4.10

**Fault-only-first** — A load (`vle32ff.v`) that truncates `vl` instead of trapping when an
element past the first faults. What makes a vectorised `strlen` safe. → Ch 5 §5.3

**Fractional LMUL** — LMUL values of 1/2, 1/4, 1/8, encoded as negative numbers in the
signed `vlmul` field. Exists so mixed-width chains have matching element counts.
→ Ch 3 §3.4, Ch 4 §4.3

**Gather / scatter** — Indexed memory access, where addresses come from a vector of indices
rather than a pattern. The most expensive addressing mode. Deferred in MEDS-V v1.
→ Ch 2 §2.7

**HTIF** — *Host-Target Interface*. Spike's mechanism for a bare-metal program to signal
exit, via the `tohost` symbol. → Ch 6 §6.2

**Lane** — A vertical slice of the vector unit: a portion of every vector register plus its
own ALU. Element *i* lives in lane *i* mod NR_LANES. Element-wise operations need no
inter-lane communication. → Ch 2 §2.3

**LMUL** — *Vector register group multiplier*. Glues 2, 4, or 8 registers into one longer
logical vector, or uses a fraction of one. A software setting in `vtype`. → Ch 4 §4.3

**Mask** — One bit per element controlling whether that element is active. Always supplied
by `v0`. Structurally, a per-element write enable. → Ch 4 §4.7

**mstatus.VS** — The two-bit field enabling the vector unit (Off / Initial / Clean / Dirty).
Starts **Off**; every vector instruction traps until it is set. The most common
"my vector code does nothing" bug. → Ch 4 §4.1

**Packed SIMD** — SIMD where the register width is fixed by the ISA (SSE, AVX, NEON).
Requires new opcodes to widen, and a hand-written remainder loop. Contrast *true vector*.
→ Ch 3 §3.2

**Prestart** — Elements below `vstart`, skipped when resuming an interrupted instruction.
→ Ch 2 §2.5

**Reduction** — An operation collapsing a vector to a single value (`vredsum`). Breaks the
lane model, because it needs data to cross lanes. → Ch 5 §5.7

**SEW** — *Selected Element Width*. The element width currently in force, from `vtype`.
Software-settable, unlike ELEN. → Ch 4 §4.2

**Segmented ALU** — An ALU whose carry chain is broken at element boundaries so one 32-bit
datapath acts as 1×32, 2×16, or 4×8 independent units. → Ch 9 §9.4

**Spike** — The official RISC-V ISA simulator, and this project's golden reference model.
→ Ch 6 §6.2

**Stripmining** — The loop idiom that asks `vsetvli` how many elements it can do, processes
that many, and repeats. The mechanism behind vector-length agnosticism. → Ch 7 §7.1

**Tail** — Elements at or beyond `vl`. Governed by the tail policy (`vta`). → Ch 2 §2.5

**True vector** — A vector ISA where register length is an implementation parameter, not
part of the ISA, so one binary exploits wider hardware. RVV and ARM SVE. → Ch 3 §3.2

**Undisturbed** — A policy (`vta=0` or `vma=0`) requiring tail or inactive elements to keep
their previous values. Implementable for free with element-granular write enables — and
because it is a legal implementation of *agnostic* too, building only this path gives full
compliance with both. → Ch 4 §4.8

**Unit-stride** — Consecutive elements in memory. The common and cheap access pattern; one
wide burst. → Ch 2 §2.7

**v0** — Vector register 0. An ordinary register, except that it is the *only* source of
masks. → Ch 4 §4.7

**VLA** — *Vector-Length Agnostic*. Code that runs correctly and efficiently at any VLEN
without recompilation. The central property of RVV. → Ch 7

**vl** — The number of elements the next vector instruction will process. Written only by
`vsetvl{i}`, which also returns it in `rd`. → Ch 4 §4.4

**vlenb** — A read-only CSR holding VLEN/8. How software discovers the machine's vector
length at runtime. → Ch 4 §4.1

**VLEN** — The width of one vector register in bits. A hardware parameter, deliberately not
part of the ISA. → Ch 4 §4.2

**VLMAX** — The most elements one instruction could process in the current configuration:
`LMUL × VLEN / SEW`. The ceiling that `vl` is clamped to. → Ch 4 §4.2

**VLSU** — *Vector Load/Store Unit*. Block ⑥; the hardest block in the design. → Ch 9 §9.6

**VRF** — *Vector Register File*. 32 × VLEN bits. The largest structure in the design.
→ Ch 9 §9.3

**vill** — The top bit of `vtype`, set when an unsupported configuration is requested.
Does **not** trap; the next vector instruction does. → Ch 4 §4.5

**vstart** — The element index at which the next instruction begins, used to resume an
interrupted vector instruction. Reset to 0 at retire. → Ch 4 §4.9

**vtype** — The CSR holding SEW, LMUL, the tail and mask policies, and `vill`. → Ch 4 §4.3

**Zve32x** — A standard RVV subset: 32-bit integer elements, no floating point, VLEN ≥ 32.
MEDS-V v1's target, paired with `Zvl128b` for VLEN ≥ 128. → Ch 3 §3.4

**Zvl<N>b** — A standard extension guaranteeing VLEN ≥ N bits. Also how Spike's ISA string
sets the vector length. → Ch 3 §3.4
