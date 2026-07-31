# Chapter 5 — The Instruction Set Tour

> **Goal of this chapter.** Give you a map of the whole RVV instruction set, organised the
> way your *decoder* will see it, with encodings you can trust. This chapter doubles as the
> reference you will keep open while writing `vec_decoder.sv`.

Every encoding here was produced by assembling the instruction with
`riscv64-unknown-elf-as` and reading back the machine word. Nothing is from memory.

---

## 5.1 The encoding space

RVV uses **three** major opcodes. That is a remarkably small footprint for ~600
instructions, and it is achieved by heavy use of `funct6` and the `funct3` sub-format field.

> **📐 Spec box — major opcodes.**
>
> | Opcode | Value | Used for |
> |---|---|---|
> | `LOAD-FP`  | `0000111` = `0x07` | **All** vector loads |
> | `STORE-FP` | `0100111` = `0x27` | **All** vector stores |
> | `OP-V`     | `1010111` = `0x57` | Everything else: config + all arithmetic |

Yes — vector loads and stores share opcodes with scalar floating-point loads and stores.
They are distinguished by the `width` field: scalar FP uses `width` = 010 (`flw`) and 011
(`fld`), while vector loads use 000, 101, 110, 111. Your decoder must check this.

### The `OP-V` instruction format

```
   31        26  25   24    20 19    15 14  12 11    7 6           0
  ┌────────────┬────┬─────────┬────────┬──────┬───────┬─────────────┐
  │   funct6   │ vm │   vs2   │  vs1/  │funct3│  vd/  │   1010111   │
  │            │    │         │ rs1/imm│      │  rd   │    OP-V     │
  └────────────┴────┴─────────┴────────┴──────┴───────┴─────────────┘
```

> **⚠️ Trap — operand order.** In assembly, `vadd.vv vd, vs2, vs1`. The **first** source
> operand written in assembly is **`vs2`** (bits 24:20), and the second is **`vs1`** (bits
> 19:15). This is reversed from what most people assume.
>
> It matters for non-commutative operations. `vsub.vv v1, v2, v3` computes
> **`v2 - v3`**, i.e. `vs2 - vs1`. Get this backwards in your ALU and every commutative
> test will pass while every subtract and shift silently fails. Write a directed test.

### `funct3` — the operand-source selector

`funct3` does not select the *operation*; it selects **where the second operand comes
from** and which functional-unit family handles it.

> **📐 Spec box — `funct3` encoding.** Verified.
>
> | `funct3` | Name | Second operand (`vs1` field) | Meaning |
> |---|---|---|---|
> | `000` | **OPIVV** | vector `vs1` | Integer, vector-vector |
> | `001` | OPFVV | vector `vs1` | Float, vector-vector |
> | `010` | **OPMVV** | vector `vs1` | Mask/multiply/reduction, vector-vector |
> | `011` | **OPIVI** | 5-bit signed immediate | Integer, vector-immediate |
> | `100` | **OPIVX** | scalar register `rs1` | Integer, vector-scalar |
> | `101` | OPFVF | scalar FP register `rs1` | Float, vector-scalar |
> | `110` | **OPMVX** | scalar register `rs1` | Mask/multiply, vector-scalar |
> | `111` | — | — | **Configuration** (`vsetvl{i}`) |

Bolded rows are the ones MEDS-V v1 needs (no floating point).

> **⚠️ Trap — `funct6` alone does not identify an instruction.** Verified example:
> ```
> 0x962180d7  vsll.vv v1,v2,v3    funct6 = 100101, funct3 = OPIVV
> 0x9621a0d7  vmul.vv v1,v2,v3    funct6 = 100101, funct3 = OPMVV
> ```
> Same `funct6`. Completely different operations. **Your decoder must key on
> `{funct6, funct3}` together** — a 9-bit lookup. Teams that build a `funct6`-only case
> statement discover this in the worst possible way.

The split is roughly: **OPI** = simple integer ALU work, **OPM** = multiplier, mask, and
reduction work, **OPF** = floating point. That maps neatly onto three functional units, and
is a hint about how to organise your datapath.

---

## 5.2 Configuration instructions

Covered in detail in Chapter 4 §4.4. Summary:

| Instruction | AVL source | `vtype` source |
|---|---|---|
| `vsetvli rd, rs1, vtypei` | register `rs1` | 11-bit immediate |
| `vsetivli rd, uimm, vtypei` | 5-bit immediate | 10-bit immediate |
| `vsetvl rd, rs1, rs2` | register `rs1` | register `rs2` |

```
# verified
0d0572d7   vsetvli  t0, a0, e32, m1, ta, ma
cd1672d7   vsetivli t0, 12,  e32, m2, ta, ma
80b572d7   vsetvl   t0, a0, a1
```

`vsetivli` exists for loops with a compile-time-known short trip count — no register needed
to hold the AVL. `vsetvl` (register form) exists mainly for **context restore**: an OS
saves `vtype` to memory and restores it with `vsetvl`.

---

## 5.3 Loads and stores

The VLSU is your hardest block, so understand its instruction space properly.

### Encoding

```
   31  29 28  27  26  25 24     20 19    15 14  12 11    7 6         0
  ┌──────┬───┬───────┬──┬─────────┬────────┬──────┬───────┬───────────┐
  │  nf  │mew│  mop  │vm│lumop/rs2│   rs1   │width │ vd/vs3│ 0000111  │  LOAD-FP
  │      │   │       │  │ /vs2    │ (base)  │      │       │ 0100111  │  STORE-FP
  └──────┴───┴───────┴──┴─────────┴────────┴──────┴───────┴───────────┘
```

> **📐 Spec box — `mop[1:0]`, the addressing mode.**
>
> | `mop` | Load | Store | Mode |
> |---|---|---|---|
> | `00` | `vle<EEW>.v`   | `vse<EEW>.v`   | **Unit-stride** |
> | `01` | `vluxei<EEW>.v`| `vsuxei<EEW>.v`| Indexed-**unordered** |
> | `10` | `vlse<EEW>.v`  | `vsse<EEW>.v`  | **Strided** |
> | `11` | `vloxei<EEW>.v`| `vsoxei<EEW>.v`| Indexed-**ordered** |

Verified:
```
# verified
02056087   vle32.v     v1, (a0)          mop=00  unit-stride
0ab56087   vlse32.v    v1, (a0), a1      mop=10  strided, stride in a1
06256087   vluxei32.v  v1, (a0), v2      mop=01  indexed-unordered, indices in v2
0e256087   vloxei32.v  v1, (a0), v2      mop=11  indexed-ordered
020560a7   vse32.v     v1, (a0)          opcode 0x27 (STORE-FP)
```

**Ordered vs unordered indexed** is about *memory ordering between the elements of one
instruction*. Ordered guarantees element 0's access is visible before element 1's — which
matters when indices collide (two elements writing the same address) or for
memory-mapped I/O. Unordered lets the hardware issue them in any order, which is much
faster. **Implement unordered first**; ordered can be implemented as "unordered, but issue
one at a time."

### The `width` field and EEW

> **📐 Spec box.** For vector loads/stores, `{mew, width[2:0]}` gives the **effective
> element width**, independent of `vtype.vsew`:
>
> | `mew` | `width` | EEW |
> |---|---|---|
> | 0 | `000` | 8 |
> | 0 | `101` | 16 |
> | 0 | `110` | 32 |
> | 0 | `111` | 64 |
>
> (`width` = 001/010/011/100 with `mew`=0 are the scalar FP loads `flh`/`flw`/`flq`/`fld`.)
>
> EMUL is then derived: `EMUL = LMUL × EEW / SEW`, and out-of-range EMUL (>8 or <1/8) is a
> **reserved encoding**.

This is why `vle32.v` loads 32-bit elements even if SEW is 8: the load's width comes from
the *opcode*, not from `vtype`. It lets you load narrow data and compute on it wide, or
vice versa, without a `vsetvli` in between.

### Unit-stride sub-modes (`lumop`/`sumop`)

The 5-bit `lumop`/`sumop` field distinguishes several unit-stride variants:

> **📐 Spec box.**
>
> | Value | Load | Store |
> |---|---|---|
> | `00000` | `vle<EEW>.v` — plain unit-stride | `vse<EEW>.v` |
> | `01000` | `vl<NF>re<EEW>.v` — **whole register** load | `vs<NF>r.v` |
> | `01011` | `vlm.v` — **mask** load (EEW=8, `ceil(vl/8)` bytes) | `vsm.v` |
> | `10000` | `vle<EEW>ff.v` — **fault-only-first** | — |

Verified:
```
# verified
02056087   vle32.v    v1, (a0)     lumop = 00000
02856087   vl1re32.v  v1, (a0)     lumop = 01000  whole-register
02b50087   vlm.v      v1, (a0)     lumop = 01011  mask load, width=000 (EEW=8)
03056087   vle32ff.v  v1, (a0)     lumop = 10000  fault-only-first
```

Three of these deserve explanation:

**Whole-register load/store (`vl1re32.v`, `vs1r.v`).** Moves an entire vector register
regardless of `vl` and `vtype`. This is the **context-switch and spill instruction** —
an OS or a compiler spilling a vector to the stack must move all VLEN bits, not just `vl`
elements. Cheap to implement (it ignores all the interesting state) and genuinely
necessary. Put it in v1.

**Mask load/store (`vlm.v`).** Loads `ceil(vl/8)` bytes as a packed bit-mask. Needed to get
a mask from memory into `v0`.

**Fault-only-first (`vle32ff.v`).** The clever one. It loads as many elements as it can; if
element *k* > 0 faults, instead of trapping it **truncates `vl` to *k*** and completes
successfully. This is what makes vectorised `strlen` safe:

```
    you want to load 16 bytes to search for a NUL
    but the string might end 3 bytes before an unmapped page
    → a plain vle8.v would segfault
    → vle8ff.v loads what it can, sets vl to what it got, no fault
```

Without it, you cannot safely vectorise any loop whose trip count depends on the data. It
is the one "exotic" load worth considering even in a small implementation — but it does
require your VLSU to report a fault index back to the `vl` CSR, which is real complexity.
**MEDS-V v1: defer it.** Note it in the scope contract.

### Segment loads (`nf`)

`nf[2:0]` encodes NFIELDS = `nf + 1`. A segment load with NFIELDS=3 loads *structs*:

```
   memory (array of struct {r,g,b}):  R0 G0 B0 R1 G1 B1 R2 G2 B2 ...

   vlseg3e8.v v1, (a0)   →   v1 = R0 R1 R2 ...
                             v2 = G0 G1 G2 ...
                             v3 = B0 B1 B2 ...
```

It is a de-interleave in hardware — exactly what you want for RGB pixel data or complex
numbers. Constraint: `EMUL × NFIELDS ≤ 8`.

**MEDS-V v1: defer.** It is very useful for the RGB→grayscale benchmark, but it is a
significant VLSU complication. Chapter 14 shows how to write that benchmark with strided
loads instead.

---

## 5.4 Integer arithmetic (OPIVV / OPIVX / OPIVI)

The bread and butter. Each of these exists in `.vv`, `.vx`, and often `.vi` forms — the
operation is the same, only `funct3` changes.

> **📐 Spec box — verified `funct6` values, `funct3` = OPIVV/OPIVX/OPIVI.**
>
> | `funct6` | Mnemonic | Operation |
> |---|---|---|
> | `000000` | `vadd`   | `vs2 + vs1` |
> | `000010` | `vsub`   | `vs2 - vs1` |
> | `000011` | `vrsub`  | `vs1 - vs2` (reverse subtract; `.vx`/`.vi` only) |
> | `000100` | `vminu`  | unsigned min |
> | `000101` | `vmin`   | signed min |
> | `000110` | `vmaxu`  | unsigned max |
> | `000111` | `vmax`   | signed max |
> | `001001` | `vand`   | bitwise AND |
> | `001010` | `vor`    | bitwise OR |
> | `001011` | `vxor`   | bitwise XOR |
> | `001100` | `vrgather` | register gather (see §5.9) |
> | `001110` | `vslideup` / `vrgatherei16` | slide / gather with 16-bit indices |
> | `001111` | `vslidedown` | slide down |
> | `010111` | `vmerge` / `vmv.v.*` | merge under mask / move |
> | `011000` | `vmseq`  | set-if-equal → mask |
> | `011001` | `vmsne`  | set-if-not-equal |
> | `011010` | `vmsltu` | set-if-less-than, unsigned |
> | `011011` | `vmslt`  | set-if-less-than, signed |
> | `011100` | `vmsleu` | set-if-less-or-equal, unsigned |
> | `011101` | `vmsle`  | set-if-less-or-equal, signed |
> | `100101` | `vsll`   | shift left logical |
> | `101000` | `vsrl`   | shift right logical |
> | `101001` | `vsra`   | shift right arithmetic |
> | `101100` | `vnsrl`  | narrowing shift right logical |
> | `101101` | `vnsra`  | narrowing shift right arithmetic |

Notes that matter:

- **Comparisons write masks, not vectors.** `vmseq.vv v1, v2, v3` writes a *bit* per
  element into `v1`. The destination is a mask register (usually `v0`, so the next
  instruction can use it). Verified: `0x622180d7 vmseq.vv v1,v2,v3`.
- **There is no `vmsgt.vv`.** Greater-than with two vectors is just `vmslt` with the
  operands swapped, so the spec omits it. `vmsgt.vx`/`.vi` *do* exist, because you cannot
  swap a scalar into the vector slot. A nice example of encoding-space economy — and a
  gap that will confuse your team if nobody explains it.
- **Shift amounts are taken modulo SEW.** `vsll.vv` with SEW=32 uses only the low 5 bits of
  each element of `vs1`.
- **`vrsub`** exists because OPIVI immediates can't be the second operand of a subtract;
  `vrsub.vi v1, v2, 0` is the idiomatic vector negate.

### Widening and narrowing

```
# verified
c221a257  vwaddu.vv v4,v2,v3   funct6=110000  OPMVV   2×SEW unsigned add
c621a257  vwadd.vv  v4,v2,v3   funct6=110001  OPMVV   2×SEW signed add
ee21a257  vwmul.vv  v4,v2,v3   funct6=111011  OPMVV
f6312257  vwmacc.vv v4,v2,v3   funct6=111101  OPMVV
b221b0d7  vnsrl.wi  v1,v2,3    funct6=101100  OPIVI
```

Naming convention, worth memorising:

| Prefix/suffix | Meaning |
|---|---|
| `vw…`  | **Widening**: destination is 2×SEW |
| `vn…`  | **Narrowing**: source `vs2` is 2×SEW, destination is SEW |
| `.wv`, `.wx`, `.wi` | The `vs2` operand is the **wide** (2×SEW) one |
| `.vv`, `.vx`, `.vi` | All vector operands are SEW |

So `vwadd.wv v4, v2, v3` adds a *wide* `v2` to a *narrow* `v3`, producing wide — different
from `vwadd.vv`, which widens both sources. Note that widening integer ops live in
**OPMVV**, not OPIVV.

Widening is essential for real DSP: accumulate 16-bit products into 32-bit sums without
overflow. Your FIR benchmark in Chapter 14 needs `vwmacc`.

### Extension instructions

```
# verified
4a232257  vzext.vf2 v4,v2      funct6=010010, OPMVV, distinguished by the vs1 field
4a23a257  vsext.vf2 v4,v2      funct6=010010, OPMVV
```

`vzext.vf2/vf4/vf8` and `vsext.*` zero- or sign-extend elements by 2×, 4×, or 8×. Note both
share `funct6 = 010010` and are distinguished by the **`vs1` field used as an opcode
extension**. This "unary op in the `vs1` slot" pattern recurs throughout OPMVV — your
decoder needs a second-level decode on `vs1` for `funct6 ∈ {010000, 010010, 010100}`.

---

## 5.5 Multiply, divide, and multiply-accumulate (OPMVV / OPMVX)

> **📐 Spec box — verified.**
>
> | `funct6` | Mnemonic | Operation |
> |---|---|---|
> | `100000` | `vdivu` | unsigned divide |
> | `100001` | `vdiv`  | signed divide |
> | `100010` | `vremu` | unsigned remainder |
> | `100011` | `vrem`  | signed remainder |
> | `100100` | `vmulhu`| high half of unsigned product |
> | `100101` | `vmul`  | low half of product |
> | `100111` | `vmulh` | high half of signed product |
> | `101001` | `vmadd` | `vd = (vd × vs1) + vs2` |
> | `101101` | `vmacc` | `vd = (vs1 × vs2) + vd` |
> | `101111` | `vnmsac`| `vd = -(vs1 × vs2) + vd` |

> **⚠️ Trap — `vmacc` vs `vmadd`.** Both are multiply-accumulate; they differ in **which
> operand is overwritten**:
> - `vmacc`: `vd += vs1 × vs2` — the *accumulator* is `vd`. This is what you want 95% of
>   the time.
> - `vmadd`: `vd = vd × vs1 + vs2` — the *multiplicand* is `vd`.
>
> Choosing wrong gives numerically plausible garbage. Test both explicitly.

**Division is genuinely expensive** — an iterative unit, tens of cycles, and it does not
pipeline well. Real vector units often implement it at reduced throughput or not at all.
`Zve32x` requires it, but **MEDS-V v1 should implement divide last**, or implement it as a
multi-cycle non-pipelined unit that stalls the lane. Document the choice.

---

## 5.6 Fixed-point and saturating arithmetic

```
# verified
822180d7  vsaddu.vv  funct6=100000 OPIVV   saturating unsigned add
862180d7  vsadd.vv   funct6=100001 OPIVV   saturating signed add
aa2180d7  vssrl.vv   funct6=101010 OPIVV   scaling (rounding) shift right
9e2180d7  vsmul.vv   funct6=100111 OPIVV   fractional multiply with rounding
ba2180d7  vnclipu.wv funct6=101110 OPIVV   narrowing clip, unsigned
be2180d7  vnclip.wv  funct6=101111 OPIVV   narrowing clip, signed
2621a0d7  vaadd.vv   funct6=001001 OPMVV   averaging add
```

These implement **fixed-point DSP semantics**: saturate instead of wrapping, round instead
of truncating. `vxsat` records whether any saturation occurred; `vxrm` selects one of four
rounding modes.

They are cheap to add (a comparator and a mux on top of the adder) and they make the
difference between "we can run a DSP kernel" and "we can run a DSP kernel *correctly*".
**Recommended for MEDS-V v1: `vsadd`, `vsaddu`, `vssub`, `vssubu`, `vnclip`, `vnclipu`.**
Skip `vsmul` and the averaging ops.

---

## 5.7 Reductions

A reduction collapses a whole vector into one value.

```
# verified
0221a0d7  vredsum.vs  v1,v2,v3   funct6=000000 OPMVV
0621a0d7  vredand.vs  v1,v2,v3   funct6=000001 OPMVV
1e21a0d7  vredmax.vs  v1,v2,v3   funct6=000111 OPMVV
c62180d7  vwredsum.vs v1,v2,v3   funct6=110001 OPIVV  (widening reduction)
```

The `.vs` suffix means "vector-scalar": the accumulator comes in as **element 0 of `vs1`**,
and the result is written to **element 0 of `vd`**.

```
   vredsum.vs v1, v2, v3

     v3[0]  ─────┐
     v2[0] ──┐   │
     v2[1] ──┼───┴──►  sum  ──► v1[0]     (v1[1..] are tail)
     v2[2] ──┤
       :   ──┘
```

Passing the initial value in via `vs1[0]` lets you accumulate across stripmine iterations
without a scalar round-trip.

> **⚠️ Implementation warning — reductions break the lane model.** Every other
> element-wise instruction keeps lane *l* talking only to itself. A reduction must combine
> results **across all lanes**. That means either:
> - a **reduction tree** across lanes (log₂(L) levels of adders — fast, more area), or
> - a **serial accumulate** in one lane, with other lanes feeding it over several cycles
>   (slow, tiny).
>
> **MEDS-V v1: build the serial version.** It is `vl` cycles, it is obviously correct, and
> reductions are a small fraction of the dynamic instruction count in your benchmarks. Log
> the cycle cost and propose the tree as future work — that's a clean, honest result.

Ordering note: `vredsum` for integers is exact and order-independent, so you may reduce in
any order. Floating-point reductions are *not* — hence RVV has both `vfredusum`
(**u**nordered, fast) and `vfredosum` (**o**rdered, strictly sequential, reproducible).
Not your problem in v1, but know why the pair exists.

---

## 5.8 Mask instructions

Operations on masks themselves.

```
# verified
6621a0d7  vmand.mm  v1,v2,v3   funct6=011001 OPMVV
6a21a0d7  vmor.mm   v1,v2,v3   funct6=011010 OPMVV
6e21a0d7  vmxor.mm  v1,v2,v3   funct6=011011 OPMVV
762120d7  vmnot.m   v1,v2      (alias for vmnand.mm v1,v2,v2)
42282557  vcpop.m   a0,v2      funct6=010000 OPMVV — population count → scalar
4228a557  vfirst.m  a0,v2      funct6=010000 OPMVV — index of first set bit → scalar
5220a0d7  vmsbf.m   v1,v2      funct6=010100 — set-before-first
5221a0d7  vmsif.m   v1,v2      funct6=010100 — set-including-first
522120d7  vmsof.m   v1,v2      funct6=010100 — set-only-first
522820d7  viota.m   v1,v2      funct6=010100 — prefix sum of mask bits
5208a0d7  vid.v     v1         funct6=010100 — write element index to each element
```

Notice `funct6 = 010100` is shared by six instructions, and `010000` by three. **They are
disambiguated by the `vs1` field**, which acts as an opcode extension for unary ops. Your
decoder needs that second level.

The odd-looking ones are surprisingly useful:

- **`vid.v`** writes `[0, 1, 2, 3, …]`. It is how you generate an index vector for
  strided/gather addressing, or a ramp for computing `i` inside a vectorised loop. Cheap
  to implement (a counter per lane) and used constantly. **Put it in v1.**
- **`vcpop.m`** counts active elements — how you find out how many elements passed a filter.
- **`viota.m`** computes the running sum of mask bits, which gives each active element its
  *compacted destination index*. `viota` + `vrgather` is how you implement stream
  compaction (filtering) in a vector machine.
- **`vmsbf/vmsif/vmsof`** find the first set bit — the building blocks of vectorised
  `strlen` and loop-exit conditions.

---

## 5.9 Permutation: slides, gathers, and compress

These are the instructions that require **inter-lane communication**, and therefore the
expensive ones.

```
# verified
3a21b0d7  vslideup.vi    v1,v2,3   funct6=001110 OPIVI
3e21b0d7  vslidedown.vi  v1,v2,3   funct6=001111 OPIVI
3a2560d7  vslide1up.vx   v1,v2,a0  funct6=001110 OPMVX
3e2560d7  vslide1down.vx v1,v2,a0  funct6=001111 OPMVX
322180d7  vrgather.vv    v1,v2,v3  funct6=001100 OPIVV
3a2180d7  vrgatherei16.vv v1,v2,v3 funct6=001110 OPIVV
5e21a0d7  vcompress.vm   v1,v2,v3  funct6=010111 OPMVV
42202557  vmv.x.s        a0,v2     funct6=010000 OPMVV — element 0 → scalar reg
420560d7  vmv.s.x        v1,a0     funct6=010000 OPMVX — scalar reg → element 0
9e2030d7  vmv1r.v        v1,v2     funct6=100111 OPIVI — whole-register move
```

**Slides** shift elements by a fixed amount:
```
   v2      = [ a , b , c , d , e , f , g , h ]
   vslidedown.vi v1, v2, 2
   v1      = [ c , d , e , f , g , h , ? , ? ]
```
`vslide1up`/`vslide1down` shift by exactly one and insert a scalar at the vacated end —
which is precisely what a **FIR filter** needs to build its delay line, and what a prefix
computation needs. Very much worth having.

**`vrgather`** is arbitrary permutation: `vd[i] = vs2[vs1[i]]`. Fully general and fully
expensive — in the worst case it needs a VLMAX×VLMAX crossbar. Real implementations do it
serially or in limited-radix stages.

**`vcompress`** packs the active elements together:
```
   v2   = [ a , b , c , d ]
   mask = [ 1 , 0 , 1 , 1 ]
   vcompress.vm v1, v2, mask
   v1   = [ a , c , d , ? ]
```
This is stream filtering, and it is *the* hard permutation because the destination index of
element *i* depends on all preceding mask bits.

> **🎯 MEDS-V v1 recommendation.** Implement `vmv.x.s`, `vmv.s.x`, `vmv<N>r.v`, `vid.v`,
> and `vslide1up/vslide1down`. **Defer `vrgather` and `vcompress`.** They are a project in
> themselves — there is a whole research paper on implementing RVV permutations
> efficiently (see Appendix D). Deferring them is a defensible, documented decision;
> half-implementing them is not.

---

## 5.10 Moves and merges

One `funct6` value, `010111`, covers a family disambiguated by `vm` and `vs2`:

```
# verified
5e0100d7  vmv.v.v    v1,v2         vm=1, vs2=v0 field unused → plain move
5e03b0d7  vmv.v.i    v1,7          vm=1, OPIVI            → broadcast immediate
5c22b0d7  vmerge.vim v1,v2,5,v0    vm=0                    → select by mask
```

- `vmv.v.x` / `vmv.v.i` **broadcast** a scalar to every element — how you get a constant
  into a vector.
- `vmerge.v*m` selects per element: `vd[i] = mask[i] ? operand : vs2[i]`. This is the
  vector `?:` and the standard way to implement `if/else` without predication on the write
  port.

`vmv<N>r.v` (whole-register move) copies `N` whole registers regardless of `vl` — the
register-to-register partner of `vl<N>re<EEW>.v`.

---

## 5.11 Floating point (out of v1 scope, but know it exists)

`OPFVV` and `OPFVF` cover the FP world: `vfadd`, `vfmul`, `vfmacc`, `vfdiv`, `vfsqrt`,
conversions (`vfcvt.*`), FP comparisons and reductions.

The reason MEDS-V v1 excludes them is not that the vector part is hard — it is that **you
would be building a pipelined IEEE-754 FPU**, which is a substantial project on its own,
with its own verification burden (denormals, NaN propagation, five rounding modes,
exception flags). Chapter 16 discusses adding `Zve32f` as a follow-on.

If your team includes someone who has already built an FPU, this calculus changes. Discuss
it in week 1 and record the decision.

---

## 5.12 The MEDS-V v1 instruction subset

Here is the concrete list. This is the contract; Appendix E is the formal version.

**Configuration (3)**
`vsetvli`, `vsetivli`, `vsetvl`

**Loads / stores (10)**
`vle8/16/32.v`, `vse8/16/32.v`, `vlse32.v`, `vsse32.v`, `vl1re32.v`, `vs1r.v`

**Integer arithmetic (18)**
`vadd`, `vsub`, `vrsub`, `vand`, `vor`, `vxor`, `vsll`, `vsrl`, `vsra`,
`vmin`, `vminu`, `vmax`, `vmaxu`, `vmerge`, `vmv.v.*`, `vzext.vf2`, `vsext.vf2`, `vid.v`
— each in `.vv`/`.vx`/`.vi` forms as applicable.

**Comparisons (6)**
`vmseq`, `vmsne`, `vmslt`, `vmsltu`, `vmsle`, `vmsleu`

**Multiply (5)**
`vmul`, `vmulh`, `vmulhu`, `vmacc`, `vwmacc`

**Widening (3)**
`vwadd`, `vwaddu`, `vwmul`

**Reduction (3)**
`vredsum`, `vredmax`, `vredmin`

**Mask (6)**
`vmand`, `vmor`, `vmxor`, `vmnot`, `vcpop`, `vfirst`

**Permute (4)**
`vmv.x.s`, `vmv.s.x`, `vslide1up`, `vslide1down`

**Total: ~58 distinct operations**, which expand to roughly 120 encodings once you count
`.vv`/`.vx`/`.vi` variants. That is a realistic semester target, it covers every benchmark
in Chapter 14, and it is a genuine subset of `Zve32x`.

**Explicitly deferred**, and why:

| Deferred | Reason |
|---|---|
| All floating point | Requires an FPU project |
| `vdiv`, `vrem` | Iterative unit; low benchmark impact |
| Indexed load/store | Big VLSU complication |
| Segment load/store | Big VLSU complication |
| Fault-only-first | Needs fault-index reporting into `vl` |
| `vrgather`, `vcompress` | Need a full crossbar |
| `viota`, `vmsbf/if/of` | Only useful alongside compress |
| `e64` elements | ELEN = 32 by design |

---

## 🔧 Exercises

**5.1** Assemble `vsub.vv v1, v2, v3` and `vsub.vv v1, v3, v2`. Confirm from the encodings
which register lands in the `vs1` field and which in `vs2`. Then state what
`vsub.vv v1, v2, v3` computes.

**5.2** Find two instructions in this chapter that share a `funct6` but differ in `funct3`,
and two that share both `funct6` and `funct3` but differ in `vs1`. Explain what this means
for the structure of your decoder.

**5.3** Write the vector assembly for `y[i] = max(0, x[i])` (ReLU) using (a) `vmax.vx` with
a zero scalar, and (b) `vmslt` + `vmerge`. Which is better and why?

**5.4** Using `vid.v`, write a sequence that produces the vector `[0, 2, 4, 6, …]`.

**5.5** Why does `vmsgt.vv` not exist while `vmsgt.vx` does? Answer in one sentence.

**5.6 (implementation)** Build the `{funct6, funct3}` → operation lookup table for the 58
instructions in §5.12, as a SystemVerilog `case` statement. This is a direct M1
deliverable. Cross-check every entry by assembling it.

**5.7 (mentors)** Review §5.12 with your team. Argue for **removing** three instructions
and **adding** one. Update Appendix E with the agreed list and date it.

---

## Key takeaways

- Three major opcodes: `LOAD-FP` (0x07), `STORE-FP` (0x27), `OP-V` (0x57).
- **Decode on `{funct6, funct3}` together** — `funct6` alone is ambiguous
  (`vsll.vv` vs `vmul.vv`), and some `funct6` values need a third level of decode on `vs1`.
- **Assembly operand order is `vd, vs2, vs1`** — the first source is `vs2`. `vsub.vv`
  computes `vs2 - vs1`.
- Loads/stores: `mop` selects unit-stride / strided / indexed-ordered / indexed-unordered;
  `width` gives EEW independent of SEW; `lumop` selects whole-register, mask, and
  fault-only-first variants.
- Widening (`vw…`, destination 2×SEW) and narrowing (`vn…`, source 2×SEW) are essential for
  DSP accumulation.
- **Reductions and permutations break the lane model** and need inter-lane wiring. Build
  them serially first.
- **MEDS-V v1 targets ~58 operations / ~120 encodings.** Everything deferred is deferred
  for a written reason.

---

*Next: [Chapter 6 — Writing and Running RVV Code](06-writing-and-running-rvv-code.md)*
