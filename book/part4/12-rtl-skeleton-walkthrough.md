# Chapter 12 — RTL Skeleton Walkthrough

> **Purpose of this chapter.** A guided tour of the RTL skeleton shipped in
> [`rtl/`](../../rtl/): what each file contains, which parts are complete, which parts
> carry `TODO` markers, and how the whole thing is built and linted.
>
> The skeleton is not pseudocode. It **lints clean under Verilator with `-Wall` and
> elaborates at all sixteen combinations of VLEN ∈ {128, 256, 512, 1024} and NR_LANES ∈
> {1, 2, 4, 8}**, and the one complete block ships with a passing unit testbench.

---

## 12.1 The file tree

```
rtl/
├── meds_v_pkg.sv        Parameters, types, helper functions   [COMPLETE]
├── vec_csr.sv           Block 2 — CSR / vtype unit            [COMPLETE — worked reference]
├── vrf.sv               Block 4 — Vector register file        [COMPLETE]
├── vec_decoder.sv       Block 1 — Instruction decoder         [SKELETON — M1]
├── vec_lane.sv          Block 5 — Segmented ALU               [SKELETON — M3]
├── vec_sequencer.sv     Block 3 — Sequencer + hazard unit     [SKELETON — M3]
├── vec_lsu.sv           Block 6 — Load/store unit             [SKELETON — M4]
└── meds_v_top.sv        Integration                            [SKELETON — M3]

verif/
├── Makefile             Testbench build and lint targets
└── tb_vec_csr.sv        Reference unit testbench               [COMPLETE — 73 checks]

scripts/
├── param_sweep.py       Elaborate across VLEN × lane sweep
└── count_instr.py       Spike instruction counting
```

Two blocks from the Chapter 8 diagram have no file yet — **⑦ mask unit** and
**⑧ reduction/permute** — because they arrive at M5. Their absence is marked with a `TODO`
at the correct place in `meds_v_top.sv`, so the top level does not change shape when they
land.

### Why two blocks are complete and the rest are skeletons

`vec_csr.sv` and `vrf.sv` are given in full for different reasons.

**`vec_csr.sv` is the worked reference.** It is the smallest block that exercises every
subtlety of Chapter 4 — the signed `vlmul` field, the four AVL cases, `vill` semantics,
the VLMAX shift. Teams should read it before writing anything else, because it demonstrates
the house style and shows what "complete" looks like.

**`vrf.sv` is complete because getting it wrong is expensive and undramatic.** The byte-
enable write path is the mechanism behind tails, masking, and `vstart` all at once
(Chapter 4 §4.8). A team that improvises it tends to produce something that works at
SEW=32 and fails silently everywhere else.

Everything else is a skeleton: the module boundary, the port list, the field extraction,
and the hard structural parts are given; the operation tables and state machines are
`TODO`.

---

## 12.2 `meds_v_pkg.sv` — the single source of truth

Every width in the design derives from three parameters:

```systemverilog
  parameter int unsigned VLEN     = 128;  // bits per vector register
  parameter int unsigned ELEN     = 32;   // widest supported element (Zve32x)
  parameter int unsigned NR_LANES = 1;    // parallel lanes
```

and everything else follows:

```systemverilog
  parameter int unsigned VLENB     = VLEN / 8;
  parameter int unsigned VL_W      = $clog2(VLEN) + 1;
  parameter int unsigned VRF_SLICE = VLEN / NR_LANES;
  parameter int unsigned MAX_ELEM_PER_PASS = NR_LANES * (ELEN / 8);
```

> **⚠️ The `VL_W` line is the one to notice.** `vl` must hold the largest VLMAX across all
> legal configurations, which occurs at SEW=8, LMUL=8: `VLMAX = 8 × VLEN / 8 = VLEN`. At
> VLEN=128 that needs 8 bits. Sizing `vl` from the SEW=32 case gives 3 bits and truncates
> silently the first time anyone writes `e8, m8` (Chapter 8 §8.7).

### The two helper functions that carry the most weight

**`calc_vlmax`** — VLMAX in one shift, because `vlmul` is signed:

```systemverilog
  function automatic logic [VL_W-1:0] calc_vlmax(sew_e s, lmul_e l);
    int signed shift_amt;
    shift_amt = int'(sew_log2(s)) - int'($signed(l));
    calc_vlmax = (shift_amt < 0) ? VL_W'(VLEN) : VL_W'(VLEN >> shift_amt);
  endfunction
```

That is the whole of the "hard" `vsetvli` arithmetic. Chapter 4's insistence that
`vlmul[2:0]` is a two's-complement field pays off exactly here — treat it as signed and
fractional LMUL needs no special case at all.

**`expand_to_bytes`** — element enables to byte enables:

```systemverilog
  function automatic logic [VLENB-1:0] expand_to_bytes(
      input logic [VLEN/8-1:0] elem_en, input sew_e s);
```

This is the function that turns "element 5 is active" into "bytes 20–23 are writable" at
SEW=32. It is used by the sequencer for arithmetic and by the VLSU for loads, so tails,
masking, and `vstart` behave identically on both paths — which is what makes them easy to
verify.

---

## 12.3 `vec_csr.sv` — reading the worked reference

Three passages deserve attention.

**The four AVL cases**, exactly as Chapter 4 §4.4 specifies:

```systemverilog
  always_comb begin
    if (req_illegal)            vl_d = '0;                    // vill => vl = 0
    else if (set_keep_vl_i)     vl_d = vl_q;                  // rs1==x0, rd==x0
    else if (set_avl_is_max_i)  vl_d = vlmax;                 // rs1==x0, rd!=x0
    else if (avl_fits)          vl_d = set_avl_i[VL_W-1:0];   // vl = AVL
    else                        vl_d = vlmax;                 // vl = VLMAX
  end
```

The comment in the source is blunt about why the ordering matters: *reading `x0` as the
value zero here makes `vl = 0` and hangs every stripmine loop in existence.*

**`vill` zeroes the other fields**, which the spec requires and which is easy to skip:

```systemverilog
    if (req_illegal) begin
      vtype_d = '{vill: 1'b1, vma: 1'b0, vta: 1'b0, vsew: SEW8, vlmul: LMUL_1};
    end
```

**`set_vl_o` returns the *new* `vl`, not the registered one:**

```systemverilog
  assign set_vl_o = XLEN'(vl_d);          // vsetvl{i} returns the NEW vl
```

`vl_d`, not `vl_q`. The instruction must report the value it just computed, in the same
cycle, because the scalar core writes it to `rd` and the very next instruction uses it to
bump a pointer. Returning `vl_q` yields a machine that is off by one iteration on every
loop — and passes a surprising number of tests before anyone notices.

---

## 12.4 `vrf.sv` — the byte-enable write path

The interface is deliberately VLEN-wide even though the storage will later be sliced per
lane:

```systemverilog
  input  logic [4:0]        raddr_i [3];     // vs1, vs2, vd
  output logic [VLEN-1:0]   rdata_o [3];
  input  logic [VLENB-1:0]  wbe_i;           // byte enables
  output logic [VLEN-1:0]   v0_o;            // dedicated mask port
```

The write is done as a **combinational merge followed by a single register update**:

```systemverilog
  always_comb begin
    wdata_merged = mem[waddr_i];                    // start from the old value
    for (int unsigned b = 0; b < VLENB; b++)
      if (wbe_i[b])
        wdata_merged[b*8 +: 8] = wdata_i[b*8 +: 8]; // overwrite enabled bytes
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned r = 0; r < 32; r++) mem[r] <= '0;
    end else if (we_i) begin
      mem[waddr_i] <= wdata_merged;
    end
  end
```

> **🔧 A real bug caught while writing this skeleton.** The obvious way to write that
> update is a per-byte non-blocking assignment inside the loop:
> ```systemverilog
>       for (int unsigned b = 0; b < VLENB; b++)
>         if (wbe_i[b]) mem[waddr_i][b*8 +: 8] <= wdata_i[b*8 +: 8];   // don't
> ```
> That elaborates fine at VLEN=128 and VLEN=512, and **fails at VLEN=1024** with
> `%Error-BLKLOOPINIT: Unsupported: Delayed assignment to array inside for loops`. The
> loop is 128 iterations wide at that point and Verilator refuses it.
>
> The combinational-merge form is better RTL regardless — it is one writes to one array
> element, which is what the synthesised hardware actually is: a VLEN-wide register with
> byte write enables. But the important lesson is *how the bug was found*: by running
> `scripts/param_sweep.py`, which elaborates every configuration. Nothing in the VLEN=128
> flow would ever have revealed it, and it would have surfaced in M6 when someone tried
> the large configuration for the final results.

---

## 12.5 `vec_lane.sv` — the segmented adder, in full

The one structurally interesting part of the lane is given complete, because carry gating
is easier to read than to describe:

```systemverilog
  assign carry[0] = is_sub;                  // carry-in for the lowest element

  for (genvar b = 0; b < NBYTES; b++) begin : gen_byte_adder
    logic [8:0] byte_sum;
    assign byte_sum = {1'b0, operand_a_i[b*8 +: 8]}
                    + {1'b0, addend_b   [b*8 +: 8]}
                    + {8'b0, carry[b]};
    assign sum[b*8 +: 8] = byte_sum[7:0];
    // Kill the carry at an element boundary and re-inject the subtract
    // carry-in so the next element starts its own two's-complement add.
    assign carry[b+1] = carry_break[b] ? is_sub : byte_sum[8];
  end
```

Two details worth pausing on:

**The subtract carry-in is re-injected at every element boundary.** Subtraction is
add-with-inverted-operand plus a carry-in of 1 — *per element*. A version that only sets
`carry[0] = is_sub` produces a machine where 32-bit subtract is correct and 8-bit subtract
is wrong in every byte except the lowest. That is a genuinely nasty bug because the obvious
test (SEW=32) passes.

**It is a generate chain, not a procedural loop.** Written as an `always_comb` with a `for`
loop, the linter reports `ALWCOMBORDER: Always_comb variable driven after use`. A ripple
carry is a structural chain, and writing it structurally says so.

The declaration carries a targeted lint waiver:

```systemverilog
  /* verilator lint_off UNOPTFLAT */
  logic              carry [NBYTES+1];
  /* verilator lint_on UNOPTFLAT */
```

> **On lint waivers.** Verilator's granularity analysis treats the carry array as one node
> and reports the ripple as circular combinational logic. It is a false positive, and a
> *targeted* waiver — two lines, scoped to one declaration, with a comment explaining why —
> is the correct engineering response. What teams must not do is disable `UNOPTFLAT`
> globally, because a genuine combinational loop elsewhere would then be silently accepted.
> This distinction is worth teaching explicitly; waiver discipline is a real skill.

The shifter, comparators, multiplier, and result mux are `TODO`, with the recommended
structure noted inline — in particular that a segmented *shifter* is much harder than a
segmented adder and should be built as N independent 8-bit shifters plus a recombination
stage.

---

## 12.6 `vec_sequencer.sv` — the write-enable expression

The skeleton's most valuable few lines:

```systemverilog
  always_comb begin
    elem_en = '0;
    for (int unsigned e = 0; e < VLENB; e++) begin
      automatic logic [VL_W-1:0] idx = elem_base_q + VL_W'(e);
      elem_en[e] = (idx >= vstart_i)                   // not prestart
                 && (idx <  vl_i)                      // not tail
                 && (uop_i.vm || v0_i[e]);             // active under the mask
    end
  end

  assign vrf_wbe_o = expand_to_bytes(elem_en, vtype_i.vsew);
```

That implements prestart, the tail policy, and masking simultaneously — and because
"retain previous values" is an explicitly permitted implementation of the *agnostic*
policies, it is compliant with `vta` = 0 or 1 and `vma` = 0 or 1 alike, **with no policy
mux at all**. This is the highest-leverage simplification in the design (Chapter 4 §4.8),
and the reason `vtype_i.vta` and `vtype_i.vma` appear in the module's tie-off list rather
than in its logic.

The hazard section is partially given, because one term is so easy to miss:

```systemverilog
    raw_hazard = |(busy_q & group_mask(uop_i.vs1, uop_i.emul))
               | |(busy_q & group_mask(uop_i.vs2, uop_i.emul))
               | (!uop_i.vm && busy_q[0]);   // <-- the v0 mask dependency
```

A masked instruction reads `v0`. If a previous comparison is still writing `v0` — an
extremely common sequence — that is a RAW hazard which appears **nowhere in the `vs1`/`vs2`
fields**. The symptom of omitting it is intermittently wrong masked results that depend on
timing, which is among the worst debugging experiences available.

`group_mask()` is given in full, because the scoreboard must track register *groups*: at
LMUL=8, `vadd.vv v0, v8, v16` writes `v0`–`v7`.

---

## 12.7 The tie-off idiom

Every skeleton module ends with something like:

```systemverilog
  // Tie-offs for bundle fields this skeleton does not consume yet.  Each one is
  // a TODO above: widening/narrowing change the pass count, the load/store
  // flags route the uop to the VLSU, and vta/vma are deliberately unused
  // because the undisturbed write path is compliant with both policies.
  logic _unused;
  assign _unused = uop_i.is_widening | uop_i.is_narrowing | ... ;
```

This exists so the skeleton lints clean under `-Wall` **without blanket waivers**. The
alternative — deleting the unused signals — would mean the extraction logic has to be
rewritten when the corresponding `TODO` is implemented, and the port list would churn.

As each `TODO` is completed, the corresponding term is removed from `_unused`. When
`_unused` is empty, the module is done. It is a crude but genuinely useful progress
indicator.

---

## 12.8 Building and checking

```bash
# Lint the whole design with the full warning set
make -C verif lint
#   RTL lint: clean

# Run the reference unit testbench
make -C verif tb_vec_csr
#   === tb_vec_csr : VLEN=128  ELEN=32  VL_W=8 ===
#   === PASS : 73 checks ===

# Elaborate every VLEN x lane-count combination
python3 scripts/param_sweep.py
```

Captured output from the sweep:

```
MEDS-V RTL parameter sweep (Verilator lint + elaborate)

   VLEN  LANES       VRF  slice/lane   result
  ----- ------ --------- -----------   ------
    128      1       4 Kib      128 b   PASS
    128      2       4 Kib       64 b   PASS
    128      4       4 Kib       32 b   PASS
    256      1       8 Kib      256 b   PASS
    256      2       8 Kib      128 b   PASS
    256      4       8 Kib       64 b   PASS
    256      8       8 Kib       32 b   PASS
    512      1      16 Kib      512 b   PASS
    512      2      16 Kib      256 b   PASS
    512      4      16 Kib      128 b   PASS
    512      8      16 Kib       64 b   PASS
   1024      1      32 Kib     1024 b   PASS
   1024      2      32 Kib      512 b   PASS
   1024      4      32 Kib      256 b   PASS
   1024      8      32 Kib      128 b   PASS

  All configurations elaborate cleanly.
```

> **This sweep should run in CI from week 4.** It is cheap, it takes seconds, and it is the
> regression that catches a hard-coded literal the moment someone introduces one.
> Vector-length agnosticism is only real if the RTL genuinely re-elaborates — and as §12.4
> showed, the failures it catches are ones no single-configuration flow would ever reveal.

The unit testbench is parameterised too. The same `tb_vec_csr.sv`, unmodified, at three
vector lengths:

```
=== tb_vec_csr, same testbench, three VLENs ===
  VLEN=128  === PASS : 73 checks ===
  VLEN=256  === PASS : 77 checks ===
  VLEN=512  === PASS : 85 checks ===
```

The check count grows because the testbench sweeps AVL from 0 to VLMAX+4, and VLMAX grows
with VLEN. **Tests should be written this way** — derived from the parameters, not from
constants — or the M6 configuration sweep will require rewriting the entire test suite.

---

## 12.9 What `tb_vec_csr.sv` demonstrates

It is the template for every other unit testbench, and it checks seven things:

| # | Check | Why it matters |
|---|---|---|
| 1 | `vlenb == VLEN/8` | How software discovers the machine |
| 2 | `vl = min(AVL, VLMAX)` across the range | The core `vsetvli` contract |
| 3 | VLMAX for every SEW/LMUL, incl. `mf2`, `mf8` | Proves the signed `vlmul` decode |
| 3b | `vsetvli` *returns* the new `vl` in `rd` | Stripmine pointer arithmetic depends on it |
| 4 | `vtype` fields round-trip, incl. `vta`/`vma` | Policy bits are not dropped |
| 5 | The four AVL cases | `rs1 == x0` is not zero |
| 6 | `vill` set, other fields zeroed, no trap | The probing mechanism |
| 7 | `vl > 0` whenever `AVL > 0`, for AVL 1…40 | **Otherwise every stripmine loop hangs** |

Check 7 is worth singling out. It is a loop over forty values that asserts one trivial
property — and it is the difference between a bug found in five seconds and a bug found by
watching a simulation spin for an hour.

---

## 12.10 Suggested order of work

| Order | File | Milestone | Notes |
|---|---|---|---|
| 1 | Read `vec_csr.sv` and `tb_vec_csr.sv` | M0 | Learn the house style |
| 2 | `vec_decoder.sv` — the `{funct6, funct3}` table | M1 | Verify each entry against the assembler |
| 3 | `tb_vec_decoder.sv` | M1 | Random words vs. Spike's legality |
| 4 | `tb_vrf.sv` | M2 | `vrf.sv` is given; test it anyway |
| 5 | `vec_lane.sv` — shifter, compares, multiplier | M3 | Segmented shifter last |
| 6 | `vec_sequencer.sv` — FSM and pass counting | M3 | The brain |
| 7 | `vec_lsu.sv` | M4 | Four weeks |
| 8 | `vec_mask.sv`, `vec_reduce.sv` | M5 | New files |

Step 2's advice bears repeating: **every entry in the decode table should be verified by
assembling the instruction**, not copied from a table by hand.

```bash
echo 'vmacc.vv v1,v2,v3' | riscv64-unknown-elf-as -march=rv64gcv -o /tmp/t.o -
riscv64-unknown-elf-objdump -d /tmp/t.o
```

Chapter 5's tables were produced exactly this way, which is why they can be trusted.

---

## 🔧 Exercises

**12.1** Run all three checks in §12.8 and confirm the output matches.

**12.2** Deliberately reintroduce the VLEN=1024 bug from §12.4 (per-byte non-blocking
assignment in a loop). Confirm `param_sweep.py` catches it and that a VLEN=128-only build
does not.

**12.3** In `vec_csr.sv`, change `set_vl_o` from `vl_d` to `vl_q`. Which testbench check
fails? Explain the failure in terms of the stripmine loop.

**12.4** Add `vsrl` and `vsra` to `vec_decoder.sv`, verifying the `funct6` values against
the assembler. Extend the `_unused` tie-off accordingly.

**12.5** Write `tb_vec_lane.sv` for the segmented adder: verify that at SEW=8,
`0xFF + 0x01` in byte 0 gives `0x00` and does **not** carry into byte 1; and that at
SEW=32 it does.

**12.6 (mentors)** Add `make -C verif lint` and `python3 scripts/param_sweep.py` to CI as
required checks on every pull request, from week 4.

---

## Key takeaways

- The skeleton **lints clean at `-Wall` and elaborates at 16 VLEN × lane combinations**;
  the complete block ships with a 73-check passing testbench.
- `meds_v_pkg.sv` is the single source of truth. `VL_W = $clog2(VLEN)+1`, sized for the
  SEW=8/LMUL=8 worst case.
- `vec_csr.sv` is the worked reference — the signed `vlmul` shift, the four AVL cases,
  `vill` zeroing, and `set_vl_o = vl_d` (not `vl_q`).
- `vrf.sv` uses a **combinational byte merge plus one register update**. The per-byte
  non-blocking form fails to elaborate at VLEN=1024 — a bug found only by the parameter
  sweep.
- The segmented adder re-injects the subtract carry-in **at every element boundary**, and
  is written as a generate chain with a targeted, commented `UNOPTFLAT` waiver.
- The sequencer's five-line write-enable expression covers prestart, tail, and mask at
  once, with no policy mux. Its hazard logic includes the easily-missed **`v0` mask
  dependency**.
- The `_unused` tie-off keeps skeletons lint-clean without blanket waivers, and shrinks to
  nothing as the module is completed.
- **Run the parameter sweep in CI from week 4.** It catches what single-configuration
  builds never will.

---

*Next: [Chapter 13 — Verification Strategy](13-verification-strategy.md)*
