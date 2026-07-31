// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// MEDS-V Block (5) : Vector Lane -- the segmented ALU        [SKELETON -- M3]
//
// One lane owns an ELEN-bit datapath.  Depending on SEW it behaves as
//   1 x 32-bit ALU,  2 x 16-bit ALUs,  or  4 x 8-bit ALUs.
//
// The trick is CARRY GATING: a 32-bit adder becomes four independent 8-bit
// adders if you break the carry chain at the element boundaries.  The adder
// below is provided complete as a worked example; the shifter and multiplier
// are yours.  See Book Ch 9 section 9.4.
//
// A segmented SHIFTER is genuinely harder than a segmented adder -- budget for
// it.  If you are behind schedule, build an SEW=32-only lane first and get the
// whole pipeline running, then come back and segment it.
// =============================================================================

module vec_lane
  import meds_v_pkg::*;
(
  input  logic                clk_i,
  input  logic                rst_ni,

  input  vec_op_e             op_i,
  input  sew_e                sew_i,
  input  logic                valid_i,

  input  logic [ELEN-1:0]     operand_a_i,   // from vs2  (the FIRST assembly source)
  input  logic [ELEN-1:0]     operand_b_i,   // from vs1 or the scalar
  input  logic [ELEN-1:0]     operand_c_i,   // from vd, for accumulating ops

  output logic [ELEN-1:0]     result_o,
  output logic                valid_o
);

  localparam int unsigned NBYTES = ELEN / 8;

  // ---------------------------------------------------------------------------
  // Carry-break mask: bit b is 1 when the carry OUT of byte b must be killed,
  // because byte b is the top byte of an element.
  //
  //   SEW=8  : every byte is its own element   -> break after every byte
  //   SEW=16 : elements are byte pairs         -> break after bytes 1 and 3
  //   SEW=32 : one element                     -> break only at the top
  // ---------------------------------------------------------------------------
  logic [NBYTES-1:0] carry_break;

  always_comb begin
    unique case (sew_i)
      SEW8:    carry_break = {NBYTES{1'b1}};                 // 4'b1111
      SEW16:   for (int unsigned b = 0; b < NBYTES; b++)
                 carry_break[b] = (b % 2 == 1);              // 4'b1010
      SEW32:   for (int unsigned b = 0; b < NBYTES; b++)
                 carry_break[b] = (b % 4 == 3);              // 4'b1000
      default: carry_break = {1'b1, {(NBYTES-1){1'b0}}};
    endcase
  end

  // ---------------------------------------------------------------------------
  // Segmented add / subtract.
  //
  // Subtraction is add-with-inverted-b and carry-in 1 PER ELEMENT, so the
  // per-element carry-in must be injected at every element boundary, not just
  // at bit 0.  Getting this wrong is a classic bug: 32-bit subtract works,
  // 8-bit subtract is wrong in every byte but the lowest.
  // ---------------------------------------------------------------------------
  logic              is_sub;
  logic [ELEN-1:0]   addend_b;
  // carry[b] enters byte b.  Each element of the chain depends only on lower
  // indices, so this is an ordinary ripple -- but Verilator's granularity
  // analysis treats the array as a single node and reports it as circular
  // combinational logic.  A targeted waiver is correct here; do NOT waive
  // UNOPTFLAT globally, because a genuine comb loop elsewhere would then be
  // silently accepted.
  /* verilator lint_off UNOPTFLAT */
  logic              carry [NBYTES+1];
  /* verilator lint_on UNOPTFLAT */
  logic [ELEN-1:0]   sum;

  assign is_sub   = (op_i == VOP_SUB) || (op_i == VOP_RSUB);
  assign addend_b = is_sub ? ~operand_b_i : operand_b_i;

  // Built as a generate chain rather than a procedural loop: a ripple carry is
  // a structural chain, and writing it this way keeps each stage a genuine
  // continuous assignment (no always_comb ordering hazard).
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

  // ---------------------------------------------------------------------------
  // Bitwise logic -- SEW-independent, so no segmentation needed at all.
  // ---------------------------------------------------------------------------
  logic [ELEN-1:0] logic_res;
  always_comb begin
    unique case (op_i)
      VOP_AND: logic_res = operand_a_i & operand_b_i;
      VOP_OR:  logic_res = operand_a_i | operand_b_i;
      VOP_XOR: logic_res = operand_a_i ^ operand_b_i;
      default: logic_res = '0;
    endcase
  end

  // ---------------------------------------------------------------------------
  // TODO (M3): segmented shifter -- vsll, vsrl, vsra.
  //
  //   * The shift amount is PER ELEMENT and is taken modulo SEW.
  //     At SEW=8 only the low 3 bits of each byte of operand_b_i are used.
  //   * Bits must not cross element boundaries.
  //   * Recommended structure: NBYTES independent 8-bit shifters, plus a
  //     recombination stage that stitches them for SEW=16 and SEW=32.
  // ---------------------------------------------------------------------------
  logic [ELEN-1:0] shift_res;
  assign shift_res = '0;   // TODO

  // ---------------------------------------------------------------------------
  // TODO (M3): segmented comparisons -- vmseq, vmsne, vmslt(u), vmsle(u).
  //   These produce ONE BIT PER ELEMENT, not a full-width result.  Reuse the
  //   subtract above: equality is (sum == 0) per element, and less-than comes
  //   from the per-element carry-out plus the sign bits.
  //   Watch the signed/unsigned distinction.
  // ---------------------------------------------------------------------------
  logic [NBYTES-1:0] cmp_res;
  assign cmp_res = '0;     // TODO

  // ---------------------------------------------------------------------------
  // TODO (M3): min / max, using the comparison result to mux the operands.
  // TODO (M3): multiplier -- vmul, vmulh, vmulhu, vmacc.  Pipeline it over 2-3
  //            cycles; do not attempt single-cycle.  operand_c_i is the
  //            accumulator input for vmacc.
  // TODO (later, or never): divider.  Iterative, non-pipelined -- see the
  //            scope contract in Appendix E.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Result mux
  // ---------------------------------------------------------------------------
  always_comb begin
    unique case (op_i)
      VOP_ADD, VOP_SUB, VOP_RSUB: result_o = sum;
      VOP_AND, VOP_OR, VOP_XOR:   result_o = logic_res;
      VOP_SLL, VOP_SRL, VOP_SRA:  result_o = shift_res;
      default:                    result_o = '0;
    endcase
  end

  // Single-cycle for now; becomes a pipeline register when the multiplier lands.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) valid_o <= 1'b0;
    else         valid_o <= valid_i;
  end

  // carry[NBYTES] is the carry out of the top element -- unused here, but kept
  // because a saturating-add unit (vsadd, Book Ch 5 section 5.6) would need it.
  logic _unused;
  assign _unused = |operand_c_i | |cmp_res | carry[NBYTES];

endmodule : vec_lane
