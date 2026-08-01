# Chapter 9 — The Building Blocks

> **Goal of this chapter.** One section per block from the Chapter 8 diagram. Each gives
> one: what the block does, its interface, its internal structure, the design decisions one
> must make, and the traps waiting for the implementer.
>
> This is a **reference chapter**. Read it once end-to-end for the shape, then return to
> the section for whichever block one own.

Each section follows the same template:

> **Job** — one sentence.
> **Interface** — the ports.
> **Inside** — the structure.
> **Decisions** — what teams must choose.
> **Traps** — what goes wrong.
> **Done when** — the exit criterion.

---

## 9.1 Block ① — Vector Decoder

> **Job.** Turn a 32-bit instruction word into a control bundle the rest of the unit
> understands. Detect illegal encodings.
> **Milestone: M1. Difficulty: ●●○○○.**

### Interface

```systemverilog
module vec_decoder import meds_v_pkg::*; (
    input  logic [31:0]     instr_i,
    input  vtype_t          vtype_i,        // current SEW/LMUL/vta/vma/vill
    input  logic            vs_enabled_i,   // mstatus.VS != Off

    output vec_uop_t        uop_o,          // the decoded control bundle
    output logic            illegal_o
);
```

The control bundle is the block's real output, and getting its fields right is most of the
work:

```systemverilog
typedef struct packed {
    logic              valid;
    vec_op_e           op;          // VADD, VMUL, VLE, ...
    vec_fmt_e          fmt;         // OPIVV / OPIVX / OPIVI / OPMVV / OPMVX / CFG
    logic [4:0]        vd, vs1, vs2;
    logic              vm;          // 0 = masked by v0
    logic [63:0]       scalar_op;   // rs1 value, or sign-extended imm for OPIVI
    logic              use_scalar;  // second operand is scalar_op, not vs1
    logic              writes_vrf;
    logic              writes_xrf;  // vsetvl, vmv.x.s, vcpop, vfirst
    logic              is_load, is_store;
    sew_e              eew;         // EEW for this operand (loads/stores: from width)
    lmul_e             emul;        // derived: EMUL = LMUL * EEW / SEW
    logic              is_widening, is_narrowing;
    logic              is_reduction;
} vec_uop_t;
```

### Inside

Three levels of decode, in this order:

```
   opcode[6:0]
     ├── 0x57 (OP-V)
     │     └── funct3
     │           ├── 111 ────────► CONFIG: vsetvli / vsetivli / vsetvl
     │           └── else ───────► { funct6, funct3 }  ← 9-bit primary lookup
     │                                 └── for funct6 ∈ {010000, 010010, 010100}:
     │                                       └── vs1 field ← secondary lookup (unary ops)
     ├── 0x07 (LOAD-FP)  ─────────► check width != scalar-FP widths
     │                              then { mop, lumop } ← addressing mode
     └── 0x27 (STORE-FP) ─────────► same, with sumop
```

> **⚠️ Trap.** Decode on **`{funct6, funct3}` jointly** — 9 bits. Chapter 5 §5.1 showed
> `vsll.vv` and `vmul.vv` sharing `funct6 = 100101`. A `funct6`-only case statement compiles
> fine and produces a machine that multiplies when asked to shift.

### The legality checks

This is where most of the decoder's logic lives, and every one of these is tested by the
architectural test suite:

```systemverilog
  // 1. Vector unit disabled
  illegal |= !vs_enabled_i;

  // 2. vill set, and this is not a vsetvl{i}
  illegal |= vtype_i.vill && !is_config;

  // 3. Register-group alignment: with EMUL = n > 1, specifiers must be n-aligned
  illegal |= (emul > 1) && (|(vd  & (emul-1)));
  illegal |= (emul > 1) && (|(vs1 & (emul-1)));
  illegal |= (emul > 1) && (|(vs2 & (emul-1)));

  // 4. Masked instruction must not write v0 (unless writing a mask)
  illegal |= !vm && (vd == 5'd0) && !writes_mask;

  // 5. EMUL out of range (>8 or <1/8) -- reserved encoding
  illegal |= emul_out_of_range;

  // 6. Widening/narrowing overlap rules (Ch 4 section 4.10)
  illegal |= overlap_violation;
```

> **🎯 Guidance.** Write checks 1–5 in M1. Check 6 is fiddly; write it in M2 alongside the
> tests that exercise it. But **write it** — "reserved encoding" means the architectural
> tests will hand one one and expect a trap.

### Decisions

| Decision | Recommendation |
|---|---|
| One decoder or one per lane? | **One, centralised.** Lanes receive the decoded bundle. |
| Decode to micro-ops or keep whole? | **Keep whole.** The sequencer handles multi-pass. Cracking into uops is an optimisation for later. |
| Handle `vsetvl{i}` here or in ②? | **Detect here, execute in ②.** Keeps `vtype` state in one place. |

### Done when

- Every one of the ~120 encodings in the implemented subset decodes to the right bundle.
- A directed test sweeps all 2048 `vsetvli` immediates and checks `vill`.
- Illegal-encoding tests trap for each of checks 1–6.
- **A random instruction generator** produces 10 000 words; the decoder's `illegal_o`
  agrees with `spike`'s. (This is a very high-value, cheap test.)

---

## 9.2 Block ② — CSR / `vtype` Unit

> **Job.** Own `vl`, `vtype`, `vstart`, `vxsat`, `vxrm`, `vlenb`. Implement `vsetvl{i}`.
> **Milestone: M1. Difficulty: ●●○○○.**

### Interface

```systemverilog
module vec_csr import meds_v_pkg::*; #(
    parameter int unsigned VLEN = 128,
    parameter int unsigned ELEN = 32
)(
    input  logic            clk_i, rst_ni,

    // vsetvl{i} execution
    input  logic            set_valid_i,
    input  logic [10:0]     set_zimm_i,      // new vtype fields
    input  logic [63:0]     set_avl_i,       // application vector length
    input  logic            set_avl_is_max_i,// rs1 == x0, rd != x0  -> AVL = infinity
    input  logic            set_keep_vl_i,   // rs1 == x0, rd == x0  -> keep vl
    output logic [63:0]     set_vl_o,        // result written back to rd

    // current state, broadcast to the rest of the unit
    output vtype_t          vtype_o,
    output logic [VL_W-1:0] vl_o,
    output logic [VL_W-1:0] vstart_o,

    // ordinary CSR read/write port (csrr vlenb, etc.)
    input  logic [11:0]     csr_addr_i,
    /* ... */
);
```

### Inside — the `vsetvl` datapath

```
   zimm[10:0] ──► decode ──► SEW, LMUL, vta, vma
                    │
                    ├──► legality check ──► vill
                    │
                    ▼
              VLMAX = LMUL × VLEN / SEW      (shifts only -- see below)
                    │
   AVL ─────────────┼──► vl = min(AVL, VLMAX)
                    │
                    ▼
              vl register, vtype register
```

**VLMAX is computed with shifts, not a divider.** SEW and VLEN are powers of two, and LMUL
is a power of two (possibly negative). So:

```systemverilog
  // VLMAX = LMUL * VLEN / SEW = VLEN >> (log2(SEW) - vlmul_signed)
  //   vlmul_signed is the 3-bit two's-complement field: 000->0, 001->1, 111->-1, ...
  localparam int LOG2_VLEN = $clog2(VLEN);
  logic signed [3:0] shift_amt;
  assign shift_amt = $signed({1'b0, log2_sew}) - $signed(vlmul_signed);
  assign vlmax     = VLEN >> shift_amt;      // shift_amt is always >= 0 for legal configs
```

That is the whole of the "hard" `vsetvli` arithmetic. Chapter 4's warning that the
`vlmul` encoding is signed pays off here: treat it as signed and the formula is one line.

### The four AVL cases

From Chapter 4 §4.4 — implement all four, they are all tested:

```systemverilog
  always_comb begin
    if (illegal_vtype)        vl_d = '0;                      // vill: vl = 0
    else if (set_keep_vl_i)   vl_d = vl_q;                    // rd=x0, rs1=x0
    else if (set_avl_is_max_i)vl_d = vlmax;                   // rd!=x0, rs1=x0
    else                      vl_d = (set_avl_i < vlmax) ? set_avl_i[VL_W-1:0]
                                                         : vlmax;
  end
```

> **⚠️ Trap.** `rs1 == x0` is **not** AVL = 0. Two different meanings depending on `rd`.
> A decoder that reads `x0` as the number zero produces `vl = 0`, and every stripmine loop
> hangs. Test this explicitly.

### `vill` handling

```systemverilog
  // On an illegal vtype: set vill, ZERO ALL OTHER FIELDS, and set vl = 0.
  if (illegal_vtype) begin
      vtype_d = '{vill: 1'b1, default: '0};
      vl_d    = '0;
  end
```

Zeroing the other fields is required by the spec, not cosmetic. Software reads `vtype` back
to probe capabilities.

### Decisions

| Decision | Recommendation |
|---|---|
| `vl` width | `$clog2(VLEN)+1` — sized for SEW=8, LMUL=8 (Ch 8 §8.7) |
| `vl = min(AVL, VLMAX)` or load-balanced? | **`min`.** Legal, one comparator. Note the alternative in the report. |
| Where does `vstart` live? | Here. The sequencer reads it and it is cleared at retire. |
| `vxsat`/`vxrm` | Implement the registers even if one skips fixed-point ops — they're cheap and tested. |

### Done when

- All 2048 `vsetvli` immediates produce the right `vtype` or `vill`, checked against Spike.
- All four AVL cases verified.
- `csrr vlenb` returns VLEN/8.
- `vl` survives `vsetvli x0, x0, <new vtype>`.

---

## 9.3 Block ④ — Vector Register File

> **Job.** Store 32 × VLEN bits. Deliver operands, absorb results, with element-granular
> write enables.
> **Milestone: M2. Difficulty: ●●●○○ (but it's the biggest structure one'll build).**

### Interface

```systemverilog
module vrf import meds_v_pkg::*; #(
    parameter int unsigned VLEN     = 128,
    parameter int unsigned NR_LANES = 2
)(
    input  logic                     clk_i, rst_ni,

    // three read ports: vs1, vs2, and vd (for accumulate / undisturbed merge)
    input  logic [4:0]               raddr_i [3],
    output logic [VLEN-1:0]          rdata_o [3],

    // one writes port with per-ELEMENT enables
    input  logic                     we_i,
    input  logic [4:0]               waddr_i,
    input  logic [VLEN-1:0]          wdata_i,
    input  logic [VLEN/8-1:0]        wbe_i,       // byte enables

    // dedicated mask read port -- always v0
    output logic [VLEN-1:0]          v0_o
);
```

Four things to notice, each a deliberate choice:

**Three read ports.** `vs1`, `vs2`, and `vd`. The third is needed for accumulating
instructions (`vmacc` reads `vd`) and, if one support tail-undisturbed by
read-modify-write, for merging. If one uses byte enables instead (recommended), one can
sometimes drop to two — but `vmacc` still needs three.

**Byte enables, not element enables.** Byte granularity handles every SEW from 8 up, with
one uniform mechanism. `wbe_i` is `VLEN/8` bits. This is the single most important
structural decision in the block: it gives the implementer tails, masking, and `vstart` for free.

**A dedicated `v0` port.** The mask always comes from `v0` (Chapter 4 §4.7), so hardwire
it. No arbitration, no extra addressing.

**Whole-VLEN read/write ports at this level.** In a multi-lane design the VRF is physically
*sliced* across lanes, but presenting a VLEN-wide interface at the top keeps the module
boundary clean and lets an implementation change the internal organisation later.

### Inside — organisation options

**Option 1: flat register array (start here)**
```systemverilog
  logic [VLEN-1:0] mem [0:31];
```
Synthesises to flip-flops. At VLEN=128 that is 4096 flops — large but viable on an FPGA.
Trivially correct. **Use this for M2–M5.**

**Option 2: lane-sliced**
```
   Lane 0 holds bits [63:0]   of all 32 registers
   Lane 1 holds bits [127:64] of all 32 registers
```
Each lane's slice is an independent, narrow memory. This is what real designs do, and it's
what makes lane scaling physical rather than notional.

**Option 3: banked SRAM**
```
   Bank 0: v0, v4,  v8, ... v28
   Bank 1: v1, v5,  v9, ... v29
   Bank 2: v2, v6, v10, ... v30
   Bank 3: v3, v7, v11, ... v31
```
Each bank is single-ported SRAM; one gets multiple "ports" by reading different banks
simultaneously. Cheap in area, but **teams must handle bank conflicts** — `vadd.vv v1, v5, v9`
hits bank 1 three times. That means a conflict detector and a stall, in the sequencer.

> **🎯 Guidance.** Build **Option 1** for M2. Move to **Option 2** when one adds lanes in M6.
> Consider Option 3 only when taping out, or targeting a large FPGA where flops are
> the constraint. Banking is a real project; do not start there.

### Register grouping (LMUL > 1)

With LMUL=4, "register `v8`" means `v8`–`v11`. The VRF itself doesn't know this — the
**sequencer** issues four successive accesses. Keep the VRF ignorant of LMUL; it makes both
modules simpler.

### Decisions

| Decision | Recommendation |
|---|---|
| Read ports | 3 (vs1, vs2, vd) + dedicated v0 |
| Write enables | **Byte granularity.** Non-negotiable. |
| Reset behaviour | Zero on reset. Makes simulation deterministic and X-free. |
| `v0` port | Dedicated, always-on read |

### Traps

> **⚠️ Do not build a width-aware VRF.** It stores VLEN bits. Element width is the
> datapath's problem (Ch 2 §2.2).

> **⚠️ Byte enables must be derived from `vstart`, `vl`, the mask, *and* SEW.** A common
> bug: computing enables at element granularity for SEW=32 and forgetting to expand them to
> 4 bytes each. Write the expansion as an explicit, tested function.

### Done when

- Write then read back, every register, every SEW.
- Byte-enable test: write with a sparse enable pattern, confirm untouched bytes are
  preserved.
- `v0` read port returns the same data as a normal read of `v0`.
- Reads and writes to the same register in the same cycle behave as specified (one chooses
  read-old or read-new — **document it**).

---

## 9.4 Block ⑤ — The Lane and its ALU

> **Job.** Do the arithmetic on `ELEN/SEW` elements per cycle.
> **Milestone: M3. Difficulty: ●●●○○.**

### Interface

```systemverilog
module vec_lane import meds_v_pkg::*; #(
    parameter int unsigned ELEN = 32
)(
    input  logic            clk_i, rst_ni,
    input  vec_op_e         op_i,
    input  sew_e            sew_i,
    input  logic [ELEN-1:0] operand_a_i,     // from vs2
    input  logic [ELEN-1:0] operand_b_i,     // from vs1 or the scalar
    input  logic [ELEN-1:0] operand_c_i,     // from vd, for vmacc
    output logic [ELEN-1:0] result_o,
    output logic            result_valid_o
);
```

### Inside — the segmented ALU

The interesting problem: one 32-bit datapath must behave as 1×32, 2×16, or 4×8 independent
adders, depending on SEW.

The trick is **carry gating**. A 32-bit ripple/carry-select adder becomes four independent
8-bit adders if one break the carry chain at byte boundaries:

```
   SEW = 32:   [ b3 ][ b2 ][ b1 ][ b0 ]      carries propagate: ●──●──●──●
   SEW = 16:   [ b3 ][ b2 ]│[ b1 ][ b0 ]     carries broken at the halfway point
   SEW =  8:   [ b3 ]│[ b2 ]│[ b1 ]│[ b0 ]   all carries broken
```

```systemverilog
  // Carry-break mask: 1 where the carry out of this byte must be killed.
  logic [3:0] carry_break;
  always_comb begin
      unique case (sew_i)
          SEW8:  carry_break = 4'b1111;   // every byte independent
          SEW16: carry_break = 4'b1010;   // break after bytes 1 and 3
          SEW32: carry_break = 4'b1000;   // break only at the top
          default: carry_break = 4'b1000;
      endcase
  end
```

Costs roughly 20% more logic than a plain 32-bit adder, and gives the implementer 4× the throughput on
`int8` data. Worth it, and it is a nice, self-contained mentee task.

> **🎯 Guidance for M3.** If segmented arithmetic feels like too much at first, build an
> **SEW=32-only ALU** and get the whole pipeline working end to end. Then come back and
> segment it. Do not let the ALU block the sequencer bring-up.

### What goes in the lane

| Unit | Ops | Notes |
|---|---|---|
| **Adder** | `vadd`, `vsub`, `vrsub`, compares, `vmin`/`vmax` | Segmented. Compares are subtract + sign inspection. |
| **Logic** | `vand`, `vor`, `vxor` | Bitwise — SEW-independent, trivially segmented. |
| **Shifter** | `vsll`, `vsrl`, `vsra` | Shift amount is per-element, mod SEW. Segmentation is harder here. |
| **Multiplier** | `vmul`, `vmulh`, `vmacc`, `vwmul` | Separate unit; multi-cycle. |
| **Divider** | `vdiv`, `vrem` | Iterative, non-pipelined. **Build last, or not at all in v1.** |

> **⚠️ Trap — the segmented shifter.** A segmented adder is easy (break carries). A
> segmented *shifter* is not: at SEW=8, four independent 3-bit shifts must not let bits
> cross byte boundaries. The clean approach is four separate 8-bit shifters plus a
> recombination stage for wider SEW. Budget more time for the shifter than the adder — it
> reliably surprises people.

### Decisions

| Decision | Recommendation |
|---|---|
| Segmented or SEW=32 only? | Segmented — but only after the pipeline works |
| Multiplier latency | 2–3 cycles, pipelined. Do not try single-cycle. |
| Divider | **Defer.** Document it. |
| One ALU per lane, or shared? | One per lane. That is what a lane *is*. |

### Done when

- Every op, every SEW, exhaustively tested for 8-bit; randomly for 16/32.
- **`vsub` verified for operand order** (`vs2 - vs1`, Ch 5 §5.1).
- Signed vs unsigned compares and min/max tested with negative values.
- Shift amounts ≥ SEW tested (must wrap modulo SEW).

---

## 9.5 Block ③ — Sequencer and Hazard Unit

> **Job.** Turn one instruction into a sequence of passes. Stall on dependencies. Generate
> per-element write enables.
> **Milestone: M3. Difficulty: ●●●●○. This is the brain.**

### Interface

```systemverilog
module vec_sequencer import meds_v_pkg::*; (
    input  logic            clk_i, rst_ni,
    input  vec_uop_t        uop_i,
    input  logic            uop_valid_i,
    output logic            uop_ready_o,

    input  vtype_t          vtype_i,
    input  logic [VL_W-1:0] vl_i, vstart_i,
    input  logic [VLEN-1:0] v0_i,

    // to VRF
    output logic [4:0]      vrf_raddr_o [3],
    output logic [4:0]      vrf_waddr_o,
    output logic            vrf_we_o,
    output logic [VLEN/8-1:0] vrf_wbe_o,

    // to lanes
    output vec_op_e         lane_op_o,
    output sew_e            lane_sew_o,
    output logic            lane_valid_o,

    output logic            done_o
);
```

### Inside — the pass loop

```
   elements_per_pass = NR_LANES × (ELEN / SEW)
   total_passes      = ceil(vl / elements_per_pass) × EMUL

   for pass in 0 .. total_passes-1:
       element_base = pass × elements_per_pass
       reg_offset   = element_base / (VLEN / SEW)          // which register in the group
       read  vs1[reg_offset], vs2[reg_offset]
       compute
       write vd[reg_offset]  with byte enables from element_base
```

The write-enable generation is the heart of it, and it implements Chapter 4 §4.8 and §4.9
in one expression:

```systemverilog
  // Per-element enable for element index e within this pass.
  for (genvar e = 0; e < MAX_ELEM_PER_PASS; e++) begin
      localparam int unsigned IDX = element_base + e;
      assign elem_en[e] = (IDX >= vstart_i)          // not prestart
                       && (IDX <  vl_i)              // not tail
                       && (uop_i.vm || v0_i[IDX]);   // active under the mask
  end

  // Expand element enables to byte enables according to SEW.
  assign vrf_wbe_o = expand_to_bytes(elem_en, sew);
```

**Those five lines implement prestart, the tail policy, and masking simultaneously**, and
because "undisturbed" is always a legal implementation of "agnostic", they are compliant
with both `vta` and `vma` settings without a policy mux. That is the trick from Chapter 4
§4.8, and it is the highest-leverage simplification in the whole design.

### Hazard detection

Vector instructions are long. A second instruction must not read a register the first is
still writing.

**The scoreboard must track register *groups*.** From Chapter 7 §7.5: `vadd.vv v0, v8, v16`
at LMUL=8 writes `v0`–`v7`.

```systemverilog
  logic [31:0] busy_q;      // one bit per architectural register

  // On issue: mark every register in the destination group busy.
  for (int i = 0; i < 32; i++)
      if (i >= uop_i.vd && i < uop_i.vd + emul_regs) busy_d[i] = 1'b1;

  // Stall if any source register group -- or the destination group -- is busy.
  assign raw_hazard = |(busy_q & src_group_mask(uop_i.vs1, emul_regs))
                    | |(busy_q & src_group_mask(uop_i.vs2, emul_regs))
                    | (!uop_i.vm && busy_q[0]);        // v0 as mask
  assign waw_hazard = |(busy_q & dst_group_mask(uop_i.vd, emul_regs));
```

> **⚠️ Trap — the `v0` mask dependency.** A masked instruction reads `v0`. If a previous
> instruction is still writing `v0` (very common — comparisons write masks), the team has a RAW
> hazard on `v0` that is *invisible* in the `vs1`/`vs2` fields. The `!uop_i.vm && busy_q[0]`
> term above catches it. Teams forget this constantly, and the symptom is
> intermittently-wrong masked results that depend on timing.

### Decisions

| Decision | Recommendation |
|---|---|
| In-order or out-of-order issue? | **In-order.** Nothing to gain from OoO here. |
| Stall granularity | Whole instruction. Element-level scoreboarding is a chaining project. |
| Chaining? | **Not in v1.** M6 stretch goal. |
| One instruction in flight, or several? | **Start with one.** Then allow a load to overlap arithmetic (that's most of the decoupling win). |

### Done when

- Single instruction, all SEW/LMUL/`vl` combinations, correct pass count.
- RAW, WAR, WAW hazards each caught by a directed test.
- `v0`-mask hazard test passes.
- `vstart` != 0 test passes.
- Back-to-back dependent instructions give the same result as independent ones.

---

## 9.6 Block ⑥ — Vector Load/Store Unit

> **Job.** Turn vector memory instructions into memory transactions, and shuffle the data
> into and out of VRF layout.
> **Milestone: M4. Difficulty: ●●●●● — the hardest block. Give it a whole milestone.**

### Interface

```systemverilog
module vec_lsu import meds_v_pkg::*; (
    input  logic            clk_i, rst_ni,
    input  vec_uop_t        uop_i,
    input  logic            uop_valid_i,
    input  logic [63:0]     base_addr_i,     // rs1
    input  logic [63:0]     stride_i,        // rs2, for strided
    input  logic [VL_W-1:0] vl_i,
    input  vtype_t          vtype_i,
    input  logic [VLEN-1:0] v0_i,

    // memory port (simple valid/ready; wrap to AXI at the top level)
    output logic            mem_req_valid_o,
    input  logic            mem_req_ready_i,
    output logic [63:0]     mem_req_addr_o,
    output logic            mem_req_we_o,
    output logic [DW/8-1:0] mem_req_be_o,
    output logic [DW-1:0]   mem_req_wdata_o,
    input  logic            mem_rsp_valid_i,
    input  logic [DW-1:0]   mem_rsp_rdata_i,

    // to/from VRF
    output logic [VLEN-1:0] vrf_wdata_o,
    output logic [VLEN/8-1:0] vrf_wbe_o,
    output logic            done_o
);
```

### Inside — three sub-problems

**1. Address generation.** Different per mode:

| Mode | Address of element *i* |
|---|---|
| Unit-stride | `base + i × EEW/8` |
| Strided | `base + i × stride` |
| Indexed | `base + index_vector[i]` |

Unit-stride is one counter. Strided is a multiply-accumulate (or repeated add). Indexed
requires reading a whole vector register first, which is why it's deferred.

**2. Request coalescing.** The interesting optimisation. A unit-stride load of 4 × 32-bit
elements from an aligned address is **one** 128-bit memory request, not four 32-bit ones.

```
   vl=4, EEW=32, base = 0x1000 (aligned), memory port = 128 bits
     → 1 request:  addr 0x1000, 16 bytes

   vl=4, EEW=32, base = 0x1004 (unaligned to 128b)
     → 2 requests: 0x1000 (take upper 12 bytes) + 0x1010 (take lower 4 bytes)
                   then realign
```

**3. Data alignment / shuffling.** Memory returns a naturally-aligned word; the VRF wants
elements at particular positions. That is a barrel shifter and a mux network.

### Why this block is so hard

Write these on a card and keep them visible:

1. **Alignment.** Base addresses are not required to be aligned to VLEN, or even to EEW.
2. **Splitting.** One vector access can span multiple memory words, cache lines, and pages.
3. **Partial accesses.** `vl` × EEW is rarely a whole number of memory words.
4. **Masked accesses.** An inactive element must generate **no memory access at all** — it
   might be an unmapped address. This is not an optimisation; it is required.
5. **Byte counting.** `vl` elements, not VLEN bits (Ch 8 §8.6).
6. **Ordering.** Vector stores vs. scalar loads (Ch 8 §8.4).
7. **Exceptions.** A fault partway through must report the element index.
8. **Backpressure.** Memory can stall at any point; the pipeline must hold state.

### Decisions

| Decision | Recommendation for v1 |
|---|---|
| Memory port width | **VLEN bits** if one can afford it — makes unit-stride one request |
| Coalescing | **Yes for unit-stride** (the 90% case). Strided: one request per element. |
| Alignment | **Require natural EEW alignment in v1**; trap otherwise. Document it. Full unaligned support is a large sub-project. |
| Indexed | **Defer** |
| Fault-only-first | **Defer** |
| Outstanding requests | Start with **one**. Add a queue in M6. |

> **🎯 The single most valuable simplification.** Make the memory port **VLEN bits wide**
> and require natural alignment. A unit-stride access becomes one transaction with a byte
> mask, and blocks 2 and 3 above nearly vanish. One loses generality; one gain a working
> VLSU in M4 instead of M7. **Write the limitation into Appendix E and measure its cost in
> Chapter 15.**

### Done when

- Unit-stride load/store, all EEW, all `vl`, aligned — bit-exact vs Spike.
- Masked load generates no request for inactive elements (check with a bus monitor).
- Strided load with positive, negative, and zero stride.
- `vl = 0` generates **no** memory traffic at all.
- Backpressure test: memory stalls randomly; results unchanged.

---

## 9.7 Block ⑦ — Mask Unit

> **Job.** Read `v0`, extract the right bits, generate write enables. Execute mask-to-mask
> operations.
> **Milestone: M5. Difficulty: ●●○○○.**

Structurally trivial, conceptually important.

### Inside

```
   v0 ──► extract bits [vstart .. vl-1] ──► align to lanes ──► AND into write enables
```

For lane *l* on pass *p* with `E` elements per pass, the mask bits needed are at positions
`p×E + l×(ELEN/SEW) + k`. A fixed strided extraction — a mux tree, not a crossbar.

Mask-to-mask ops (`vmand`, `vmor`, `vmxor`, `vmnot`) are **bitwise operations on the low
VLMAX bits** of a register. They ignore SEW entirely. They are almost free.

`vcpop.m` (population count) and `vfirst.m` (find first set) produce **scalar** results and
travel back over the `vec_resp` interface of Chapter 8 §8.4.

### Traps

> **⚠️ Mask bit position does not scale with SEW.** Element *i*'s mask bit is at bit *i*,
> always (Ch 4 §4.7). At SEW=8 one uses bits 15:0 of `v0`; at SEW=32, bits 3:0. Same
> register.

> **⚠️ Mask destination tails are *always* agnostic**, regardless of `vta`. A comparison
> writing a mask leaves bits above `vl` unspecified.

### Done when

- Masked arithmetic matches Spike for random masks, all SEW.
- `vmand`/`vmor`/`vmxor`/`vmnot` correct.
- `vcpop`/`vfirst` return correct scalars, including `vfirst` = −1 when no bit is set.

---

## 9.8 Block ⑧ — Reduction and Permute Unit

> **Job.** Everything that needs data to cross lanes.
> **Milestone: M5. Difficulty: ●●●●○.**

This block exists because reductions and slides break the lane-independence that makes
everything else easy.

### Reductions

Two implementations:

**Serial (recommended for v1)**
```
   acc = vs1[0]
   for i in 0 .. vl-1:
       acc = acc OP vs2[i]
   vd[0] = acc
```
`vl` cycles, one adder, obviously correct.

**Tree (M6 stretch)**
```
   lane0 ─┐
   lane1 ─┴─┐
   lane2 ─┐ ├─┐
   lane3 ─┴─┘ └── acc
```
`log2(NR_LANES)` levels plus `vl/NR_LANES` steps. Faster, more area, more places to be
wrong.

> **🎯 Build serial first and measure it.** Reductions are a small fraction of dynamic
> instructions in the benchmarks; the tree is an optimisation with a measurable but modest
> payoff. "The team implemented serial reduction at `vl` cycles and estimate a tree would save
> X%" is a perfectly good report result.

### Slides

`vslide1up`/`vslide1down` shift the whole vector by one element and insert a scalar. Across
lanes this is a **ring**: lane *l* sends its top element to lane *l+1*.

```
   vslide1down:   lane0 ◄── lane1 ◄── lane2 ◄── lane3 ◄── (scalar in)
   vslide1up:     lane0 ──► lane1 ──► lane2 ──► lane3     (scalar in at lane0)
```

A neighbour-to-neighbour ring, not a crossbar. Cheap, and it makes FIR filters and shift
registers work. **Include it in v1.**

`vslideup`/`vslidedown` with an arbitrary offset need a full shift network. Harder; defer
if pressed.

### `vmv.x.s` / `vmv.s.x`

Move element 0 between the VRF and a scalar register. Structurally simple — a read of
element 0 routed to `vec_resp_data` — but on the critical path of every reduction kernel
(Chapter 7 §7.3). Make sure it isn't accidentally slow.

### Decisions

| Decision | Recommendation for v1 |
|---|---|
| Reduction | Serial |
| `vslide1up`/`vslide1down` | **Yes** — ring, cheap, needed by FIR |
| `vslideup`/`vslidedown` (arbitrary) | Defer |
| `vrgather` | **Defer** — needs a full crossbar |
| `vcompress` | **Defer** |

---

## 9.9 Putting it together: the build order

The dependency graph indicates what must exist before what:

```
   ① Decoder ──┐
               ├──► ③ Sequencer ──► ⑤ Lanes ──► working ALU pipeline
   ② CSR   ────┘         │
                         ├──► ④ VRF (needed by everything)
                         │
                         ├──► ⑥ VLSU ──────────► can run real programs
                         │
                         ├──► ⑦ Mask ─────────► can run conditionals
                         │
                         └──► ⑧ Reduce/Permute► can run dot products, FIR
```

Which gives the milestone order of Chapter 11:

| Milestone | Blocks | One can then... |
|---|---|---|
| M1 | ①, ② | Decode any instruction; execute `vsetvli` |
| M2 | ④ | Store and retrieve vectors |
| M3 | ③, ⑤ | Run `vadd.vv` end to end **from a testbench** |
| M4 | ⑥ | Run real programs from memory |
| M5 | ⑦, ⑧ | Run conditionals and reductions → **all benchmarks** |
| M6 | — | Optimise: more lanes, chaining, tree reduction |
| M7 | — | Measure, compare, write up |

> **⚠️ Note what M3 gives the implementer: a working datapath with *no memory*.** Drive it from a
> testbench that preloads the VRF directly. This is deliberate — it means the sequencer and
> lanes are fully verified *before* the VLSU (the hardest block) can confuse the picture.
> Do not skip this step to "save time"; debugging a broken sequencer through a broken VLSU
> is where projects lose a month.

---

## 🔧 Exercises

**9.1** For each of the eight blocks, write its one-sentence job description from memory.
Compare with the chapter.

**9.2** Write the `expand_to_bytes(elem_en, sew)` function from §9.5 in SystemVerilog. Test
it for SEW = 8, 16, 32 at VLEN = 128.

**9.3** §9.5 lists the `v0`-mask hazard. Write the directed test that catches it: a
`vmseq` writing `v0` immediately followed by a masked `vadd`.

**9.4** The segmented adder in §9.4: implement it and verify that at SEW=8, adding
`0xFF` + `0x01` in byte 0 gives `0x00` in byte 0 and does **not** carry into byte 1.

**9.5** For the VLSU: given base = 0x1004, EEW = 32, `vl` = 4, and a 128-bit memory port,
list the memory requests and the byte lanes each contributes.

**9.6 (design)** §9.6 recommends requiring natural alignment in v1. Estimate what fraction
of accesses in the C codehapter 14 benchmarks would be naturally aligned. Is the simplification
safe?

**9.7 (mentors)** Assign owners to all eight blocks. For each, write the "Done when"
criteria into the issue tracker as a checklist. These are the acceptance tests.

---

## Key takeaways

- **Decoder:** decode on `{funct6, funct3}` jointly, with a third level on `vs1` for unary
  OPMVV ops. Six legality checks, all tested by the architectural suite.
- **CSR unit:** VLMAX is a shift, not a divide, because `vlmul` is signed. Implement all
  four AVL cases; `rs1 == x0` is not zero.
- **VRF:** dumb, wide storage with **byte-granular write enables** and a dedicated `v0`
  port. Flat array first, lane-sliced later.
- **Lane:** a segmented ALU (carry gating) gives 4× throughput on `int8`. The segmented
  *shifter* is harder than the adder.
- **Sequencer:** the brain. Five lines of write-enable logic implement prestart, tail, and
  masking at once — and undisturbed is a legal implementation of agnostic, so no policy mux
  is needed. **The scoreboard must track register groups, and must include the `v0`
  dependency.**
- **VLSU:** hardest block. Wide memory port + natural alignment is the simplification that
  makes it tractable. Masked elements must generate *no* memory access.
- **Mask unit:** trivial structurally; watch that mask bit *i* is at position *i* regardless
  of SEW.
- **Reduction/permute:** serial reduction and a slide *ring* in v1; defer `vrgather` and
  `vcompress`.
- **M3 gives the implementer a working datapath with no memory.** Verify it there before adding the
  VLSU.

---

*Next: [Chapter 10 — The Design Space](10-design-space.md)*
