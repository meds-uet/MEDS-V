# Appendix A — Instruction Quick Reference

Every encoding in this appendix was produced by assembling the instruction with
`riscv64-unknown-elf-as -march=rv64gcv` and reading back the machine word. Nothing is quoted
from memory.

---

## A.1 Major opcodes

| Opcode | Value | Used for |
|---|---|---|
| `LOAD-FP`  | `0000111` = `0x07` | All vector loads |
| `STORE-FP` | `0100111` = `0x27` | All vector stores |
| `OP-V`     | `1010111` = `0x57` | Configuration and all arithmetic |

## A.2 `OP-V` instruction format

```
   31        26  25   24    20 19    15 14  12 11    7 6           0
  ┌────────────┬────┬─────────┬────────┬──────┬───────┬─────────────┐
  │   funct6   │ vm │   vs2   │  vs1/  │funct3│  vd/  │   1010111   │
  │            │    │         │ rs1/imm│      │  rd   │             │
  └────────────┴────┴─────────┴────────┴──────┴───────┴─────────────┘
```

**Assembly operand order is `vd, vs2, vs1`.** The first source written in assembly lands in
the `vs2` field. `vsub.vv v1, v2, v3` computes `v2 − v3`.

## A.3 `funct3` — operand-source selector

| `funct3` | Name | Second operand |
|---|---|---|
| `000` | OPIVV | vector `vs1` |
| `001` | OPFVV | vector `vs1` (float) |
| `010` | OPMVV | vector `vs1` (mask/mul/reduce) |
| `011` | OPIVI | 5-bit signed immediate |
| `100` | OPIVX | scalar `rs1` |
| `101` | OPFVF | scalar FP `rs1` |
| `110` | OPMVX | scalar `rs1` (mask/mul) |
| `111` | — | configuration (`vsetvl{i}`) |

> **`funct6` alone is ambiguous.** `vsll.vv` and `vmul.vv` share `funct6 = 100101`. Decode
> on `{funct6, funct3}` jointly.

---

## A.4 `vtype` encoding

```
   XLEN-1   XLEN-2 ........ 8    7     6     5   3   2   0
  ┌───────┬──────────────────┬─────┬─────┬───────┬───────┐
  │ vill  │   reserved (0)   │ vma │ vta │ vsew  │ vlmul │
  └───────┴──────────────────┴─────┴─────┴───────┴───────┘
```

**`vsew[2:0]`** — `SEW = 8 << vsew`

| `vsew` | SEW | asm |
|---|---|---|
| `000` | 8 | `e8` |
| `001` | 16 | `e16` |
| `010` | 32 | `e32` |
| `011` | 64 | `e64` |
| `1xx` | reserved | |

**`vlmul[2:0]`** — signed; `LMUL = 2^vlmul`

| `vlmul` | LMUL | regs | VLMAX | asm |
|---|---|---|---|---|
| `101` | 1/8 | 1 | VLEN/SEW/8 | `mf8` |
| `110` | 1/4 | 1 | VLEN/SEW/4 | `mf4` |
| `111` | 1/2 | 1 | VLEN/SEW/2 | `mf2` |
| `000` | 1 | 1 | VLEN/SEW | `m1` |
| `001` | 2 | 2 | 2·VLEN/SEW | `m2` |
| `010` | 4 | 4 | 4·VLEN/SEW | `m4` |
| `011` | 8 | 8 | 8·VLEN/SEW | `m8` |
| `100` | reserved | | | |

**Derived:** `VLMAX = LMUL × VLEN / SEW`

---

## A.5 Vector CSRs

| Addr | Access | Name | Meaning |
|---|---|---|---|
| `0x008` | URW | `vstart` | First element index to execute |
| `0x009` | URW | `vxsat` | Fixed-point saturation flag |
| `0x00A` | URW | `vxrm` | Fixed-point rounding mode |
| `0x00F` | URW | `vcsr` | `{vxrm[2:1], vxsat[0]}` |
| `0xC20` | URO | `vl` | Elements the next instruction processes |
| `0xC21` | URO | `vtype` | Current configuration |
| `0xC22` | URO | `vlenb` | **VLEN/8** — hardwired constant |

**`mstatus.VS[10:9]`** (RV64): `00` Off, `01` Initial, `10` Clean, `11` Dirty.
Vector instructions trap while Off.

---

## A.6 Configuration instructions

```
# verified
0d0572d7   vsetvli  t0, a0, e32, m1, ta, ma
005572d7   vsetvli  t0, a0, e8,  mf8, tu, mu
05b572d7   vsetvli  t0, a0, e64, m8, ta, mu
cd1672d7   vsetivli t0, 12,  e32, m2, ta, ma
80b572d7   vsetvl   t0, a0, a1
```

**`vl` from AVL:**
```
   AVL ≤ VLMAX          →  vl = AVL
   VLMAX < AVL < 2·VLMAX →  ⌈AVL/2⌉ ≤ vl ≤ VLMAX   (implementation choice)
   AVL ≥ 2·VLMAX        →  vl = VLMAX
```
MEDS-V uses `vl = min(AVL, VLMAX)`.

**Special register cases:**

| `rd` | `rs1` | AVL | Effect |
|---|---|---|---|
| ≠`x0` | ≠`x0` | `rs1` | normal |
| =`x0` | ≠`x0` | `rs1` | normal, result discarded |
| ≠`x0` | =`x0` | **∞** | `vl = VLMAX` |
| =`x0` | =`x0` | **current `vl`** | keep `vl`, change `vtype` only |

---

## A.7 Loads and stores

**`mop[1:0]`**

| `mop` | Load | Store | Mode |
|---|---|---|---|
| `00` | `vle<EEW>.v` | `vse<EEW>.v` | unit-stride |
| `01` | `vluxei<EEW>.v` | `vsuxei<EEW>.v` | indexed-unordered |
| `10` | `vlse<EEW>.v` | `vsse<EEW>.v` | strided |
| `11` | `vloxei<EEW>.v` | `vsoxei<EEW>.v` | indexed-ordered |

**`{mew, width}` → EEW:** `0_000`→8, `0_101`→16, `0_110`→32, `0_111`→64
(`width` = 001/010/011/100 with `mew`=0 are the scalar FP loads.)

**`lumop`/`sumop` sub-modes:** `00000` plain · `01000` whole-register ·
`01011` mask · `10000` fault-only-first

```
# verified
02056087   vle32.v     v1, (a0)
0ab56087   vlse32.v    v1, (a0), a1
06256087   vluxei32.v  v1, (a0), v2
0e256087   vloxei32.v  v1, (a0), v2
020560a7   vse32.v     v1, (a0)
02856087   vl1re32.v   v1, (a0)
028500a7   vs1r.v      v1, (a0)
02b50087   vlm.v       v1, (a0)
03056087   vle32ff.v   v1, (a0)
```

> A unit-stride access covers **`vl` elements**, not VLEN bits.

---

## A.8 Integer arithmetic — OPIVV / OPIVX / OPIVI

| `funct6` | Mnemonic | Operation |
|---|---|---|
| `000000` | `vadd` | `vs2 + vs1` |
| `000010` | `vsub` | `vs2 − vs1` |
| `000011` | `vrsub` | `vs1 − vs2` |
| `000100` | `vminu` | unsigned min |
| `000101` | `vmin` | signed min |
| `000110` | `vmaxu` | unsigned max |
| `000111` | `vmax` | signed max |
| `001001` | `vand` | AND |
| `001010` | `vor` | OR |
| `001011` | `vxor` | XOR |
| `001100` | `vrgather` | register gather |
| `001110` | `vslideup` / `vrgatherei16` | |
| `001111` | `vslidedown` | |
| `010111` | `vmerge` / `vmv.v.*` | by `vm`, `vs2` |
| `011000` | `vmseq` | → mask |
| `011001` | `vmsne` | → mask |
| `011010` | `vmsltu` | → mask |
| `011011` | `vmslt` | → mask |
| `011100` | `vmsleu` | → mask |
| `011101` | `vmsle` | → mask |
| `100000` | `vsaddu` | saturating |
| `100001` | `vsadd` | saturating |
| `100101` | `vsll` | shift left |
| `100111` | `vsmul` | fractional multiply |
| `101000` | `vsrl` | shift right logical |
| `101001` | `vsra` | shift right arithmetic |
| `101010` | `vssrl` | scaling shift right |
| `101100` | `vnsrl` | narrowing shift |
| `101101` | `vnsra` | narrowing shift |
| `101110` | `vnclipu` | narrowing clip |
| `101111` | `vnclip` | narrowing clip |

> There is no `vmsgt.vv` — swap the operands and use `vmslt`. `vmsgt.vx`/`.vi` do exist.
> Shift amounts are taken modulo SEW.

---

## A.9 Multiply and mask — OPMVV / OPMVX

| `funct6` | Mnemonic | Operation |
|---|---|---|
| `000000` | `vredsum` | reduction |
| `000001` | `vredand` | reduction |
| `000111` | `vredmax` | reduction |
| `001001` | `vaadd` | averaging add |
| `010000` | `vcpop` / `vfirst` / `vmv.x.s` / `vmv.s.x` | *by `vs1`* |
| `010010` | `vzext` / `vsext` | *by `vs1`* |
| `010100` | `vmsbf` / `vmsif` / `vmsof` / `viota` / `vid` | *by `vs1`* |
| `010111` | `vcompress` | |
| `011001` | `vmand` | mask logic |
| `011010` | `vmor` | mask logic |
| `011011` | `vmxor` | mask logic |
| `011101` | `vmnand` (`vmnot` alias) | mask logic |
| `100000` | `vdivu` | |
| `100001` | `vdiv` | |
| `100010` | `vremu` | |
| `100011` | `vrem` | |
| `100100` | `vmulhu` | high half, unsigned |
| `100101` | `vmul` | low half |
| `100111` | `vmulh` | high half, signed |
| `101001` | `vmadd` | `vd = vd×vs1 + vs2` |
| `101101` | `vmacc` | `vd = vs1×vs2 + vd` |
| `101111` | `vnmsac` | `vd = −(vs1×vs2) + vd` |
| `110000` | `vwaddu` | widening |
| `110001` | `vwadd` | widening |
| `111011` | `vwmul` | widening |
| `111101` | `vwmacc` | widening MAC |

> Rows marked *by `vs1`* need a **third decode level** on the `vs1` field.
> `vmacc` accumulates into `vd`; `vmadd` multiplies `vd`. They are easy to confuse.

---

## A.10 Naming conventions

| Form | Meaning |
|---|---|
| `.vv` | both sources are vectors |
| `.vx` | second source is a scalar `x` register |
| `.vi` | second source is a 5-bit signed immediate |
| `.vs` | vector-scalar (reductions: accumulator in `vs1[0]`) |
| `.mm` | mask-to-mask |
| `.vm` | takes a mask operand explicitly |
| `vw…` | widening — destination is 2×SEW |
| `vn…` | narrowing — `vs2` is 2×SEW |
| `.wv`, `.wx`, `.wi` | the `vs2` operand is the wide one |
| `, v0.t` | masked by `v0` (sets `vm` = 0) |

**EEW/EMUL:** `EMUL = LMUL × EEW / SEW`. Out of the 1/8…8 range is a reserved encoding.

---

## A.11 Common idioms

| Goal | Instruction sequence |
|---|---|
| Broadcast a scalar | `vmv.v.x v1, a0` |
| Zero a vector | `vmv.v.i v1, 0` |
| Negate | `vrsub.vi v1, v2, 0` |
| Index ramp `[0,1,2,…]` | `vid.v v1` |
| ReLU | `vmax.vx v1, v2, x0` |
| Conditional select | `vmerge.vvm v1, v2, v3, v0` |
| Sum a vector | `vredsum.vs v1, v2, v3` then `vmv.x.s a0, v1` |
| Count active elements | `vcpop.m a0, v0` |
| Get maximum vl | `vsetvli t0, x0, e32, m1, ta, ma` |
| Keep `vl`, change `vtype` | `vsetvli x0, x0, e16, m2, ta, ma` |
| Spill a register | `vs1r.v v1, (a0)` / `vl1re32.v v1, (a0)` |

---

## A.12 The MEDS-V v1 subset

~58 operations, ~120 encodings. Full list and rationale in
[Appendix E](E-scope-contract.md).

**Config** `vsetvli` `vsetivli` `vsetvl`
**Memory** `vle8/16/32.v` `vse8/16/32.v` `vlse32.v` `vsse32.v` `vl1re32.v` `vs1r.v`
**Integer** `vadd` `vsub` `vrsub` `vand` `vor` `vxor` `vsll` `vsrl` `vsra` `vmin` `vminu`
`vmax` `vmaxu` `vmerge` `vmv.v.*` `vzext.vf2` `vsext.vf2` `vid.v`
**Compare** `vmseq` `vmsne` `vmslt` `vmsltu` `vmsle` `vmsleu`
**Multiply** `vmul` `vmulh` `vmulhu` `vmacc` `vwmacc`
**Widening** `vwadd` `vwaddu` `vwmul`
**Reduce** `vredsum` `vredmax` `vredmin`
**Mask** `vmand` `vmor` `vmxor` `vmnot` `vcpop` `vfirst`
**Permute** `vmv.x.s` `vmv.s.x` `vslide1up` `vslide1down`

---

## A.13 Verifying an encoding

```bash
echo 'vmacc.vv v1,v2,v3' | riscv64-unknown-elf-as -march=rv64gcv -o /tmp/t.o -
riscv64-unknown-elf-objdump -d /tmp/t.o
```

Every table in this appendix was built this way. Decode-table entries should be checked the
same way rather than transcribed by hand.
