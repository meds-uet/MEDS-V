# Chapter 4 — The RVV Programmer's Model

> **This is the most important chapter in the book.** Everything the hardware must do is
> defined here. Read it twice. Do the exercises. Do not start Chapter 8 until the whole
> team can reproduce the `vtype` layout and the LMUL table from memory.

Every table in this chapter has been verified against the ratified RVV 1.0 specification
*and* cross-checked by assembling real instructions with the GNU toolchain. Where a table
is marked `# verified`, the encoding shown is the actual bit pattern the assembler emits.

---

## 4.1 The architectural state

RVV adds exactly three things to the RISC-V architectural state:

```
  ┌──────────────────────────────────────────────────────────────┐
  │  1.  32 vector registers   v0 … v31,  each VLEN bits wide    │
  │                                                              │
  │  2.  7 control CSRs        vstart vxsat vxrm vcsr            │
  │                            vl  vtype  vlenb                  │
  │                                                              │
  │  3.  mstatus.VS[1:0]       the vector-unit enable/dirty state │
  └──────────────────────────────────────────────────────────────┘
```

That is all. Note what is *not* there: no separate mask register file (masks live in `v0`),
no vector predicate stack, no vector-length-per-register metadata. RVV is deliberately
lean.

### The CSRs

> **📐 Spec box — vector CSRs.** Verified against RVV 1.0 §3.
>
> | Address | Access | Name | Meaning |
> |---|---|---|---|
> | `0x008` | URW | `vstart` | Element index at which the next vector instruction starts |
> | `0x009` | URW | `vxsat`  | Fixed-point saturation flag |
> | `0x00A` | URW | `vxrm`   | Fixed-point rounding mode |
> | `0x00F` | URW | `vcsr`   | `{vxrm[2:1], vxsat[0]}` — a packed view of the two above |
> | `0xC20` | UR**O** | `vl`    | Number of elements the next instruction will operate on |
> | `0xC21` | UR**O** | `vtype` | Current element width, register grouping, and policies |
> | `0xC22` | UR**O** | `vlenb` | **VLEN/8** — the vector register size in bytes. Read-only constant. |

Two things to notice, both of which matter for the RTL:

- **`vl` and `vtype` are read-only via the CSR instructions.** One cannot `csrw vl, t0`.
  They are written *only* by the `vsetvl{i}` family. This is a deliberate simplification:
  it means the two must always be mutually consistent, and only one instruction needs to
  enforce that.
- **`vlenb` is how software discovers the VLEN.** It is a hardwired constant in the
  design. A single `csrr t0, vlenb` and the program knows the machine.

### `mstatus.VS` — the enable bit that will waste the afternoon

> **⚠️ Trap — the single most common "my vector code doesn't work" bug.**
> The vector unit powers up **disabled**. `mstatus.VS[1:0]` (bits **10:9** on RV64) starts
> at `00` = *Off*, and **every vector instruction, including `vsetvli`, traps as an illegal
> instruction** until one enable it.
>
> This surfaced while preparing the examples for this book: a bare-metal test
> looped forever with no output, because the very first `vsetvli` was trapping into a
> non-existent handler. The fix is two instructions in the startup code:
>
> ```asm
> # verified: required before any vector instruction in M-mode bare-metal code
>     li   t0, (1 << 9)      # mstatus.VS = 01 (Initial)
>     csrs mstatus, t0
> ```

The `VS` field has four states, and the hardware must implement the transitions:

| `VS` | Name | Meaning |
|---|---|---|
| `00` | Off | Vector instructions trap. Vector state need not exist. |
| `01` | Initial | Enabled; vector state is all zeros / hasn't been modified. |
| `10` | Clean | Enabled; state matches what's saved in memory. |
| `11` | Dirty | Enabled; state has been modified since last save. |

The point of Clean/Dirty is **context switching**. The VRF at VLEN=512 is 2 KiB of state.
An OS that saved and restored that on every context switch would be crippled. So the
hardware tracks whether the vector state was *touched*: any instruction that writes vector
state sets `VS = Dirty`, and the OS only saves the VRF if it finds `Dirty`. Programs that
never use vectors cost nothing.

> **🎯 Milestone hook.** For a bare-metal MEDS-V (M0–M5) one can implement `VS` as a
> two-state enable and hardwire Dirty. Full Clean/Dirty tracking only matters when one runs
> an OS — Chapter 16. But implement the *trap on disabled* behaviour early, because the
> architectural tests check it.

---

## 4.2 The four parameters that define everything

Four quantities control the meaning of every vector instruction. Get these four straight
and RVV becomes easy; confuse them and nothing will make sense.

| Symbol | Full name | Fixed by | Typical values |
|---|---|---|---|
| **VLEN** | Vector register length in **bits** | **Hardware.** A build-time constant. | 128, 256, 512, 1024 |
| **ELEN** | Maximum **element** width supported | **Hardware.** | 32 or 64 |
| **SEW** | **Selected** element width, *right now* | **Software**, via `vtype` | 8, 16, 32, 64 |
| **LMUL** | Register **group multiplier**, right now | **Software**, via `vtype` | 1/8, 1/4, 1/2, 1, 2, 4, 8 |

**VLEN and ELEN are properties of the design.** One chooses them in `meds_v_pkg.sv` and they
never change at runtime.

**SEW and LMUL are properties of the current moment.** They live in the `vtype` CSR and a
program changes them freely — often several times within one function.

From these four comes the one derived quantity that everything depends on:

```
                 LMUL × VLEN
      VLMAX  =  ─────────────
                     SEW
```

**VLMAX is the maximum number of elements one vector instruction can process** in the
current configuration.

Worked examples — build the intuition now:

| VLEN | SEW | LMUL | VLMAX | In words |
|---|---|---|---|---|
| 128 | 32 | 1   | 4  | 4 words in one register |
| 128 | 8  | 1   | 16 | 16 bytes in one register |
| 128 | 32 | 4   | 16 | 16 words across a 4-register group |
| 128 | 32 | 1/2 | 2  | 2 words in half a register |
| 512 | 16 | 8   | 256| 256 halfwords across an 8-register group |
| 512 | 64 | 1   | 8  | 8 doublewords |

> **⚠️ Trap.** VLMAX is *not* the same as `vl`. VLMAX is the ceiling — the most the
> hardware *could* do. `vl` is how many it *will* do, and is set per-loop-iteration by
> `vsetvli`. `vl ≤ VLMAX` always.

### Constraints teams must enforce

> **📐 Spec box.**
> - `SEW ≤ ELEN`. Asking for `e64` on an ELEN=32 machine is an unsupported configuration.
> - `VLEN ≥ ELEN`.
> - The combination must satisfy `LMUL ≥ SEW/ELEN` — i.e. a register group must be able to
>   hold at least one element. `SEW=64, LMUL=1/2` on a VLEN=64 machine is invalid.
> - **An unsupported configuration does not trap.** It sets `vtype.vill = 1` and `vl = 0`.
>   See §4.5.

---

## 4.3 `vtype` — the configuration register

This is the register the control unit revolves around.

> **📐 Spec box — `vtype` layout.** Verified against RVV 1.0 §3.4.
>
> ```
>    XLEN-1   XLEN-2 ........ 8    7     6     5   3   2   0
>   ┌───────┬──────────────────┬─────┬─────┬───────┬───────┐
>   │ vill  │   reserved (0)   │ vma │ vta │ vsew  │ vlmul │
>   └───────┴──────────────────┴─────┴─────┴───────┴───────┘
>       1            XLEN-10       1     1     3       3
> ```
>
> | Field | Bits | Meaning |
> |---|---|---|
> | `vill`  | XLEN-1 | **Illegal configuration.** Set if the requested `vtype` is unsupported. |
> | reserved| XLEN-2:8 | Must be written zero; non-zero is reserved. |
> | `vma`   | 7 | Mask policy: 0 = mask-undisturbed, 1 = mask-agnostic |
> | `vta`   | 6 | Tail policy: 0 = tail-undisturbed, 1 = tail-agnostic |
> | `vsew`  | 5:3 | Selected element width (table below) |
> | `vlmul` | 2:0 | Register group multiplier (table below) |

Note that `vill` is the **top** bit. That is not arbitrary: it means a program can test for
an illegal configuration with a single sign test (`bltz`) on the value read from `vtype`.

### `vsew` encoding

> **📐 Spec box.**
>
> | `vsew[2:0]` | SEW | Assembly |
> |---|---|---|
> | `000` | 8   | `e8`  |
> | `001` | 16  | `e16` |
> | `010` | 32  | `e32` |
> | `011` | 64  | `e64` |
> | `1xx` | *reserved* | — |

Straightforward: `SEW = 8 << vsew`. One line of RTL.

### `vlmul` encoding — the strange one

> **📐 Spec box.** Note the ordering: this is a **signed** field, so the fractional values
> live at the top of the encoding space.
>
> | `vlmul[2:0]` | LMUL | Registers in a group | VLMAX | Assembly |
> |---|---|---|---|---|
> | `101` | **1/8** | 1 (⅛ used) | VLEN/SEW/8 | `mf8` |
> | `110` | **1/4** | 1 (¼ used) | VLEN/SEW/4 | `mf4` |
> | `111` | **1/2** | 1 (½ used) | VLEN/SEW/2 | `mf2` |
> | `000` | **1**   | 1  | VLEN/SEW    | `m1` |
> | `001` | **2**   | 2  | 2×VLEN/SEW  | `m2` |
> | `010` | **4**   | 4  | 4×VLEN/SEW  | `m4` |
> | `011` | **8**   | 8  | 8×VLEN/SEW  | `m8` |
> | `100` | *reserved* | — | — | — |

Read `vlmul[2:0]` as a 3-bit **two's-complement** number and `LMUL = 2^vlmul`:

```
   vlmul = 000 →  0  →  LMUL = 2^0  = 1
   vlmul = 001 →  1  →  LMUL = 2^1  = 2
   vlmul = 011 →  3  →  LMUL = 2^3  = 8
   vlmul = 111 → -1  →  LMUL = 2^-1 = 1/2
   vlmul = 101 → -3  →  LMUL = 2^-3 = 1/8
   vlmul = 100 → -4  →  LMUL = 2^-4 = 1/16  ← RESERVED (too small to be useful)
```

Suddenly the table is not arbitrary at all. This is the single best example of "know the
history and the rule derives itself" from Chapter 3.

### LMUL > 1: register grouping

When LMUL = 4, registers are glued in groups of 4, and **the instruction may only name the
first register of a group**:

```
   LMUL=4 :   v0  v1  v2  v3  │  v4  v5  v6  v7  │  v8 ... v11 │ ... │ v28 ... v31
              └── group v0 ──┘  └── group v4 ──┘   └─ group v8 ┘       └ group v28 ┘

   Legal:    vadd.vv v0, v4, v8      (all multiples of 4)
   ILLEGAL:  vadd.vv v1, v4, v8      (v1 is not a group base)
```

> **📐 Spec box.** With LMUL = *n* > 1, a vector register operand must be a multiple of
> *n*. Violating this is a **reserved encoding** — the hardware should raise an illegal
> instruction.

This is easy RTL — check the low `log2(LMUL)` bits of each register specifier are zero —
and it is one of the first things the architectural tests will poke at.

### LMUL < 1: fractional groups

With LMUL = 1/2, each register holds only half as many elements as it could. Why would one
ever want that? Chapter 3 §3.4 gave the answer: **mixed-width arithmetic.**

```
   Goal: widen 8-bit data to 32-bit results, 16 elements, VLEN = 128.

   Source, 8-bit:   16 elements × 8 bits = 128 bits = 1 register   → LMUL = 1
   Result, 32-bit:  16 elements × 32 bits = 512 bits = 4 registers → LMUL = 4

   With LMUL = 1/4 on the source instead:
   Source, 8-bit:   VLMAX = (1/4 × 128)/8 = 4 elements ... too few.
```

The actual rule is that **`vl` (the element count) stays constant while widening; LMUL
scales with SEW**. So a widening instruction from SEW=8/LMUL=1/4 produces SEW=16/LMUL=1/2.
Fractional LMUL is what lets the *source* of a widening chain start small enough that the
*destination* doesn't overflow the register file.

> **🔧 Exercise 4.1.** One has 32 elements of 8-bit data at VLEN=256 and want to accumulate
> into 32-bit values. What LMUL for the source? What LMUL for the destination? Check that
> both give VLMAX = 32.

---

## 4.4 `vl` and the `vsetvl` family — the heart of RVV

`vl` says how many elements the next instruction processes. It is set by three
instructions, all sharing major opcode `OP-V` (`0x57`) with `funct3 = 0b111`.

### The three forms

> **📐 Spec box — encodings.** Verified by assembling with `riscv64-unknown-elf-as`.
>
> ```
>  vsetvli  rd, rs1, vtypei      # AVL from register rs1, vtype from an immediate
>   31    30                20 19        15 14  12 11   7 6      0
>  ┌───┬───────────────────────┬───────────┬──────┬──────┬────────┐
>  │ 0 │      zimm[10:0]       │    rs1    │ 111  │  rd  │1010111 │
>  └───┴───────────────────────┴───────────┴──────┴──────┴────────┘
>
>  vsetivli rd, uimm, vtypei     # AVL from a 5-bit immediate (for known short loops)
>   31 30 29             20 19        15 14  12 11   7 6      0
>  ┌──┬──┬──────────────────┬───────────┬──────┬──────┬────────┐
>  │ 1│ 1│    zimm[9:0]     │ uimm[4:0] │ 111  │  rd  │1010111 │
>  └──┴──┴──────────────────┴───────────┴──────┴──────┴────────┘
>
>  vsetvl   rd, rs1, rs2         # AVL from rs1, vtype from register rs2 (for restore)
>   31        25 24    20 19        15 14  12 11   7 6      0
>  ┌────────────┬────────┬───────────┬──────┬──────┬────────┐
>  │  1000000   │  rs2   │    rs1    │ 111  │  rd  │1010111 │
>  └────────────┴────────┴───────────┴──────┴──────┴────────┘
> ```
>
> The `zimm` field carries the same bit layout as `vtype[7:0]`:
> `{vma, vta, vsew[2:0], vlmul[2:0]}`.

Worked decode, checked against the assembler:

```
# verified: riscv64-unknown-elf-as, objdump
0d0572d7   vsetvli t0, a0, e32, m1, ta, ma
           │
           └─ 0000 1101 0000 0101 0111 0010 1101 0111
              opcode[6:0]  = 1010111 = 0x57  → OP-V
              rd[11:7]     = 00101   = x5    → t0
              funct3[14:12]= 111             → configuration instruction
              rs1[19:15]   = 01010   = x10   → a0  (the AVL)
              bit[31]      = 0               → vsetvli form
              zimm[10:0]   = 000 1101 0000
                             ├─ vlmul[2:0] = 000 → LMUL = 1     → m1
                             ├─ vsew[2:0]  = 010 → SEW  = 32    → e32
                             ├─ vta        = 1   → tail agnostic→ ta
                             └─ vma        = 1   → mask agnostic→ ma
```

Two more, to prove the tables:

```
# verified
005572d7   vsetvli t0, a0, e8,  mf8, tu, mu    zimm = 000 0000 0101
                                               vlmul=101 → 1/8 ✓  vsew=000 → 8 ✓
                                               vta=0 → tu ✓       vma=0 → mu ✓
05b572d7   vsetvli t0, a0, e64, m8,  ta, mu    zimm = 000 0101 1011
                                               vlmul=011 → 8 ✓    vsew=011 → 64 ✓
                                               vta=1 → ta ✓       vma=0 → mu ✓
```

### What `vsetvli` actually does

Three things, in one instruction:

1. **Write `vtype`** from the immediate (or from `rs2`, for `vsetvl`).
2. **Compute `vl`** from the AVL (Application Vector Length) and the new VLMAX.
3. **Write the resulting `vl` into `rd`**, so software knows how many elements it got.

Step 3 is the elegant part: the instruction *reports back*. That single return value is
what makes the stripmine loop of Chapter 7 work.

### The rule for computing `vl`

> **📐 Spec box — how `vl` is derived from AVL.** Verified against RVV 1.0 §6.3.
>
> ```
>   if   AVL ≤ VLMAX              →  vl = AVL
>   elif AVL < 2 × VLMAX          →  vl may be anything in  ⌈AVL/2⌉ … VLMAX
>   else (AVL ≥ 2 × VLMAX)        →  vl = VLMAX
> ```
> and in all cases the implementation must be **deterministic**: the same (AVL, VLMAX)
> always yields the same `vl`.
>
> Guaranteed properties:
> - `vl = 0` if and only if `AVL = 0`
> - `vl ≤ VLMAX` and `vl ≤ AVL`
> - Re-using a value read from `vl` as the AVL yields the same `vl`, provided VLMAX is
>   unchanged.

That middle case looks strange. Why is the hardware allowed to *choose*?

It exists so that an implementation can **balance the last two iterations**. Suppose
VLMAX = 8 and 9 elements remain. The obvious answer is `vl = 8` then `vl = 1` — but that
final one-element pass wastes almost an entire vector operation. A machine is permitted to
say `vl = 5` then `vl = 4` instead, keeping both passes efficient.

> **🎯 Implementation guidance.** MEDS-V should take the **simple, legal** option:
> `vl = min(AVL, VLMAX)`. It satisfies every rule above (case 2 is permitted to return
> VLMAX, since `VLMAX ≥ ⌈AVL/2⌉` whenever `AVL < 2×VLMAX`). It is one comparator and one
> mux. Do not implement load balancing in v1; note it in the report as future work.

Here is that rule observed in the wild — the same binary, two machines:

```
# verified: qemu-riscv64 -cpu rv64,v=true,vlen=<VLEN>, N=20 elements, SEW=32, LMUL=1

  VLEN=128 (VLMAX=4)          VLEN=512 (VLMAX=16)
  AVL=20 -> vl= 4             AVL=20 -> vl=16
  AVL=16 -> vl= 4             AVL= 4 -> vl= 4
  AVL=12 -> vl= 4
  AVL= 8 -> vl= 4             (2 iterations instead of 5)
  AVL= 4 -> vl= 4
```

### Two special AVL encodings

There are two important special cases in `vsetvli`, distinguished by the register
specifiers rather than by a separate opcode:

> **📐 Spec box.**
>
> | `rd` | `rs1` | AVL used | Effect on `vl` |
> |---|---|---|---|
> | `!= x0` | `!= x0` | value in `rs1` | normal: `vl = f(AVL, VLMAX)` |
> | `== x0` | `!= x0` | value in `rs1` | normal, but result not written to a register |
> | `!= x0` | `== x0` | **~0 (infinite)** | `vl = VLMAX` — "give me the maximum" |
> | `== x0` | `== x0` | **current `vl`** | **keep `vl`, change only `vtype`** |

That last row is heavily used and easy to miss. `vsetvli x0, x0, e16, m2, ta, ma` means
*"change the element width and grouping but keep processing the same number of elements."*
It is exactly what mixed-width code needs, and the decoder must special-case it.

> **⚠️ Trap.** `rs1 == x0` does **not** mean "AVL = 0". It means "AVL = infinity" (row 3)
> or "keep current `vl`" (row 4). Reading `x0` as the value zero here is a classic
> decoder bug. Write a directed test for it in M2.

---

## 4.5 `vill` — how illegal configurations are reported

> **📐 Spec box.** If a `vsetvl{i}` requests an unsupported `vtype`, the hardware **must
> not** trap. Instead it must:
> - set `vtype.vill = 1`,
> - set **all other `vtype` fields to zero**,
> - set `vl = 0`.
>
> Any subsequent vector instruction (other than another `vsetvl{i}`) executed while
> `vtype.vill = 1` **does** raise an illegal-instruction exception.

This two-stage design is deliberate. It lets software *probe* the machine's capabilities:

```asm
    vsetvli t0, a0, e64, m1, ta, ma   # ask for 64-bit elements
    csrr    t1, vtype
    bltz    t1, no_e64_support        # vill is the sign bit — one branch to test it
```

Configurations teams must reject with `vill` in MEDS-V (`ELEN=32`):
- any `vsew` requesting SEW > ELEN (so `e64` on a 32-bit ELEN machine),
- `vsew = 1xx` (reserved),
- `vlmul = 100` (reserved),
- any combination where `LMUL < SEW/ELEN`,
- non-zero reserved bits in the `zimm`.

---

## 4.6 Element indexing and the register-group view

With LMUL > 1, several registers form one logical vector. Elements are laid out
**register-major**: fill register *n*, then register *n+1*.

```
   VLEN = 128, SEW = 32, LMUL = 2   →  VLMAX = 8, group base v4 means {v4, v5}

     v4 :  ┌────────┬────────┬────────┬────────┐
           │ elem 0 │ elem 1 │ elem 2 │ elem 3 │
           └────────┴────────┴────────┴────────┘
     v5 :  ┌────────┬────────┬────────┬────────┐
           │ elem 4 │ elem 5 │ elem 6 │ elem 7 │
           └────────┴────────┴────────┴────────┘
```

Within a register, element *i* occupies bits `[SEW×(i+1)-1 : SEW×i]` — little-endian
element order, lowest element in the low bits.

**Implementation note.** This layout is why the VRF addressing is so simple: for element
index *e*, the register is `base + (e × SEW) / VLEN` and the bit offset within it is
`(e × SEW) mod VLEN`. Both are shifts and masks when SEW and VLEN are powers of two — which
they always are.

---

## 4.7 Masking

> **📐 Spec box.** The mask always comes from **`v0`**. Every maskable instruction carries a
> single bit, `vm` = `inst[25]`:
> - `vm = 1` → unmasked, all body elements active
> - `vm = 0` → masked, element *i* is active only if `v0.mask[i] == 1`
>
> In assembly, masking is written by appending `, v0.t` ("v0 dot true").

Verified:

```
# verified
022180d7   vadd.vv v1, v2, v3          inst[25] = 1  → unmasked
002180d7   vadd.vv v1, v2, v3, v0.t    inst[25] = 0  → masked by v0
```

The two words differ in exactly one bit. That is the entire cost of masking in the encoding
— compare with AVX-512, which spends three bits naming one of eight mask registers.

### Mask layout — one bit per element, always at the bottom

This trips up everyone, so be careful:

> **📐 Spec box.** A mask register holds **one bit per element**, with element *i*'s mask
> bit at **bit position *i*** of the register — **regardless of SEW**. Mask bits are always
> packed at the low end of the register; the upper bits are unused.

```
   VLEN = 128, SEW = 32, so vl can be up to 4.
   v0 = 0x...0000_000B   (binary ...1011)

        bit:   3   2   1   0
              ┌───┬───┬───┬───┐
        v0    │ 1 │ 0 │ 1 │ 1 │
              └───┴───┴───┴───┘
        elem:   3   2   1   0
               ON  OFF  ON  ON
```

The mask bit position does **not** scale with SEW. At SEW=8 with 16 elements, one uses bits
15:0. At SEW=32 with 4 elements, one uses bits 3:0. Same register, different number of
meaningful bits.

**Why this matters to the implementer:** it means the mask read path is *narrow*. Teams need at most
VLMAX bits — never VLEN bits — from `v0`, and always from the bottom. In a multi-lane
design, lane *l* needs mask bits *l*, *l+L*, *l+2L*, … which is a fixed strided extraction,
not a crossbar.

### The overlap rule

> **📐 Spec box.** The destination register group of a masked instruction **cannot overlap
> `v0`**, unless the destination is itself being written with a mask value. Violating this
> is a reserved encoding.

Sensible: if one overwrote `v0` while still reading it as a mask, the result would depend
on element order.

---

## 4.8 Tail and mask policies — `vta` and `vma`

Chapter 2 §2.5 introduced prestart / body / tail. Now the exact rules.

```
   ┌─────────────┬────────────────────────────────┬────────────────┐
   │  PRESTART   │             BODY               │      TAIL      │
   │ i < vstart  │      vstart ≤ i < vl           │    i ≥ vl      │
   ├─────────────┼───────────────┬────────────────┼────────────────┤
   │  never      │  ACTIVE       │  INACTIVE      │  governed by   │
   │  written    │  (mask=1):    │  (mask=0):     │  vta           │
   │             │  computed     │  governed by   │                │
   │             │  and written  │  vma           │                │
   └─────────────┴───────────────┴────────────────┴────────────────┘
```

> **📐 Spec box — the two policies.**
>
> | Policy | Bit | Value | Behaviour of the affected elements |
> |---|---|---|---|
> | Tail | `vta` | 0 = **undisturbed** (`tu`) | Retain their previous values |
> | | | 1 = **agnostic** (`ta`) | *Either* retain previous values *or* be set to all 1s. Implementation's choice; need not be deterministic. |
> | Mask | `vma` | 0 = **undisturbed** (`mu`) | Inactive body elements retain previous values |
> | | | 1 = **agnostic** (`ma`) | *Either* retain *or* all 1s |
>
> Exception: **mask destination tail elements are always treated as tail-agnostic**,
> regardless of `vta`.

### Why "agnostic" exists, and what it buys the hardware

This is the most implementation-relevant paragraph in the chapter.

**Undisturbed** means: *"preserve the bits I am not writing."* For the VRF, that is a
**read-modify-write**. To write elements 0–5 of `v3` while preserving 6–7, teams must either

- read `v3`, merge, write back — costing an extra read port and adding a **false
  dependency on the destination register** (the instruction now *reads* `v3` even though it
  logically only writes it), or
- have per-element write enables on the VRF write port.

The second is much better and is what teams should build: byte-granular (or element-granular)
write enables. But it still means the write-enable mask must be computed from `vl`, the
mask, *and* the policy.

**Agnostic** means: *"I don't care."* The hardware can write all-1s across the tail, or
leave it, whichever falls out of the datapath naturally.

> **🎯 Implementation guidance for MEDS-V.**
> Implement **element-granular write enables** in the VRF from day one (M3). With those,
> supporting undisturbed is nearly free — one just deassert write-enable for tail and
> inactive elements — and one avoid the false-dependency problem entirely.
>
> Concretely, the write-enable for element *i* is:
> ```systemverilog
> // one bit per element, computed once per pass in the sequencer
> wr_en[i] = (i >= vstart) && (i < vl) && (vm || v0_mask[i]);
> ```
> That single line implements both policies in their undisturbed form, which is **always a
> legal implementation of agnostic too** (agnostic permits "retain previous values"). So
> one gets full `vta`/`vma` compliance without a policy mux.
>
> This is a genuinely useful trick: **building the undisturbed datapath yields
> automatic compliance with both policies.** Note it in the report as a deliberate
> choice — it costs a little performance on machines that would prefer full-width writes,
> and buys simplicity and compliance.

---

## 4.9 `vstart` — interruptible vector instructions

A vector instruction can run for many cycles. If a page fault or interrupt occurs in the
middle, the machine should not have to redo the whole thing.

> **📐 Spec box.** Every vector instruction begins execution at element index `vstart`,
> leaving elements below it undisturbed, and **resets `vstart` to 0 on completion**. On a
> trap mid-instruction, hardware writes the failing element index into `vstart` so the
> instruction can be restarted.

For MEDS-V v1 in a bare-metal setting, `vstart` is almost always zero. **But teams must still
implement it**, because:

1. the architectural tests write non-zero `vstart` and check the behaviour,
2. it is only a comparator in the write-enable expression the team already wrote in §4.8,
3. "the team support precise, restartable vector instructions" is a real claim for the report.

> **🎯 Implementation guidance.** Implement `vstart` as an architectural CSR that gates
> element write-enable, and reset it to 0 at instruction retire. Do **not** implement
> mid-instruction trap reporting in v1 — if the VLSU can fault, take the simpler route of
> making faults precise at instruction granularity and document the limitation.

---

## 4.10 EEW and EMUL — when an operand isn't SEW-shaped

One last concept, and it is the one that most often surprises people reading RVV code.

Most instructions operate at the current SEW. But some operands have a *different* width,
fixed by the instruction itself:

- `vle32.v` loads **32-bit** elements no matter what SEW says.
- `vwadd.vv` writes a destination of **2×SEW**.
- `vnsrl.wi` reads a source of **2×SEW**.
- An indexed load's index vector has the width named in the opcode, not SEW.

The spec calls this the **effective element width (EEW)**, with a corresponding **effective
LMUL (EMUL)**:

> **📐 Spec box.** The element count is held constant, so:
> ```
>      EMUL      EEW
>     ────── =  ─────      ⟹     EMUL = LMUL × (EEW / SEW)
>      LMUL      SEW
> ```
> If the resulting EMUL would fall outside 1/8 … 8, **the encoding is reserved.**

Example:
```
   Current: SEW = 16, LMUL = 1
   vwadd.vv v4, v2, v3      # widening: destination EEW = 32
                            # EMUL = 1 × (32/16) = 2
                            # ⟹ destination is a 2-register group: must be v4 = {v4,v5}
                            #    and v4 must be even.
```

### Register overlap rules for widening and narrowing

Because sources and destinations now have different sizes, they can partially overlap. The
spec permits this only in cases where element order cannot corrupt the result:

> **📐 Spec box.** A destination may overlap a source only if:
> 1. destination EEW **==** source EEW, **or**
> 2. destination EEW **<** source EEW **and** the overlap is in the **lowest**-numbered part
>    of the source group, **or**
> 3. destination EEW **>** source EEW, source EMUL ≥ 1, **and** the overlap is in the
>    **highest**-numbered part of the destination group.
>
> Also: *a single vector register may not supply operands of more than one EEW in the same
> instruction.* Any violation is a **reserved encoding.**

> **🎯 Implementation guidance.** These rules exist so a simple in-order machine can
> process elements low-to-high and never overwrite a source it still needs. One does not have
> to *exploit* them — but teams should **detect violations and raise illegal-instruction**,
> because the compliance tests check it. That is a handful of comparators in the decoder.
> Put it on the M2 checklist.

---

## 4.11 The complete decode checklist

Everything from this chapter, as the specification the decoder must meet. Print this and
stick it on the wall.

For every vector instruction, the decoder must:

- [ ] Reject it (illegal instruction) if `mstatus.VS == Off` (§4.1)
- [ ] Reject it if `vtype.vill == 1` and it isn't a `vsetvl{i}` (§4.5)
- [ ] Extract `vd`, `vs1`, `vs2`, `vm` from fixed positions (§4.7)
- [ ] Compute EEW/EMUL for each operand (§4.10)
- [ ] Check register-group alignment: each operand ≡ 0 mod EMUL, for EMUL > 1 (§4.3)
- [ ] Check overlap rules for widening/narrowing (§4.10)
- [ ] Check destination doesn't overlap `v0` when masked, unless writing a mask (§4.7)
- [ ] Compute the per-element write-enable from `vstart`, `vl`, and the mask (§4.8, §4.9)
- [ ] Sequence `ceil(vl / lanes)` passes over the lanes (Ch 2 §2.3)
- [ ] Reset `vstart` to 0 at retire (§4.9)
- [ ] Set `mstatus.VS = Dirty` if vector state was written (§4.1)

---

## 🔧 Exercises

**4.1** (from §4.3) 32 elements of 8-bit data at VLEN=256, accumulating to 32-bit. Give
LMUL for source and destination; verify both give VLMAX = 32.

**4.2** Decode this word by hand, then check with `objdump`: `0x0d0572d7`. Give `rd`, `rs1`,
SEW, LMUL, `vta`, `vma`.

**4.3** For VLEN=128, ELEN=32, list every `(vsew, vlmul)` pair that must set `vill`. There
are more than one might think — be systematic.

**4.4** Write the `vsetvli` that means "keep the current `vl`, but switch to 16-bit
elements with LMUL=2, tail-agnostic, mask-agnostic." Assemble it and confirm the encoding.

**4.5** VLEN=256, SEW=32, LMUL=1, `vl`=5, `vstart`=2, and `v0 = 0b10110`. For
`vadd.vv v3, v1, v2, v0.t`, state for each of elements 0–7 whether it is prestart, active
body, inactive body, or tail — and whether `v3` is written.

**4.6** Explain why `vsetvli x0, x0, e32, m1, ta, ma` behaves differently from
`vsetvli t0, x0, e32, m1, ta, ma`.

**4.7 (implementation)** Write the SystemVerilog for a `vtype_decode` module: input an
11-bit `zimm`, output `sew`, `lmul_num`, `lmul_den`, `vta`, `vma`, `vill`, given a
parameter `ELEN`. Test it against every one of the 2048 possible inputs. This is a real
M1 deliverable — see Chapter 12.

**4.8 (mentors)** §4.8 claims that building only the undisturbed datapath yields full
compliance with the agnostic policies. Justify this from the spec text, and identify the
performance cost that choice accepts.

---

## Key takeaways

- State: **32 × VLEN-bit registers**, **7 CSRs**, and **`mstatus.VS`**.
- `mstatus.VS` starts **Off** — enable it or everything traps. This will cause trouble.
- Four parameters: **VLEN, ELEN** (hardware) and **SEW, LMUL** (software, in `vtype`).
  `VLMAX = LMUL × VLEN / SEW`.
- `vlmul[2:0]` is **signed**: `LMUL = 2^vlmul`, which is why 1/8, 1/4, 1/2 sit at
  `101`, `110`, `111`. Fractional LMUL exists to make mixed-width code line up.
- `vsetvli` writes `vtype`, computes `vl`, and **returns `vl` in `rd`**. Use
  `vl = min(AVL, VLMAX)` — simple and legal.
- `rs1 = x0` means *infinite AVL*, not zero. With `rd = x0` too, it means *keep `vl`*.
- Illegal `vtype` sets **`vill`**, it does **not** trap — until the next vector instruction.
- The mask is always **`v0`**, one bit per element at **bit position *i***, independent of
  SEW. `vm` is a single bit in the encoding.
- **Agnostic policies exist to make hardware cheaper.** Building element-granular write
  enables gives the implementer compliance with both policies for free.
- **EEW/EMUL**: operands can be wider or narrower than SEW; EMUL scales to keep the element
  count constant, and out-of-range EMUL is a reserved encoding.

---

*Next: [Chapter 5 — The Instruction Set Tour](05-rvv-instruction-set-tour.md)*
