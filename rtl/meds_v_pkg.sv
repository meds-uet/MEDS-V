// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// MEDS-V : RISC-V Vector Processor
// Parameter and type package -- the single source of truth for the design.
//
// EVERY width in the design derives from VLEN, ELEN and NR_LANES.  There must
// be no bare numeric literals for these anywhere else in the RTL: that is what
// makes the VLEN / lane-count sweep in Book Ch 10 section 10.8 possible.
// =============================================================================

package meds_v_pkg;

  // ---------------------------------------------------------------------------
  // Build-time parameters.  Change these three; everything else follows.
  // ---------------------------------------------------------------------------
  parameter int unsigned VLEN     = 128;  // bits per vector register
  parameter int unsigned ELEN     = 32;   // widest supported element (Zve32x)
  parameter int unsigned NR_LANES = 1;    // parallel lanes

  parameter int unsigned XLEN     = 64;   // scalar core width

  // ---------------------------------------------------------------------------
  // Derived sizes.
  // ---------------------------------------------------------------------------
  parameter int unsigned VLENB     = VLEN / 8;            // bytes per register
  parameter int unsigned NR_VREGS  = 32;

  // vl must hold the LARGEST VLMAX over all legal configurations, which occurs
  // at SEW=8, LMUL=8:  VLMAX = 8 * VLEN / 8 = VLEN.  Sizing this from the SEW=32
  // case is a classic bug -- see Book Ch 8 section 8.7.
  parameter int unsigned VL_W      = $clog2(VLEN) + 1;

  parameter int unsigned LANE_W    = ELEN;                // lane datapath width
  parameter int unsigned VRF_SLICE = VLEN / NR_LANES;     // VRF bits per lane

  // Maximum elements handled in one pass = NR_LANES * ELEN / SEW_MIN
  parameter int unsigned MAX_ELEM_PER_PASS = NR_LANES * (ELEN / 8);

  // ---------------------------------------------------------------------------
  // vtype encoding (RVV 1.0 section 3.4).  See Book Ch 4 section 4.3.
  // ---------------------------------------------------------------------------

  // vsew[2:0] -> SEW = 8 << vsew
  typedef enum logic [2:0] {
    SEW8   = 3'b000,
    SEW16  = 3'b001,
    SEW32  = 3'b010,
    SEW64  = 3'b011,
    SEW_RSVD = 3'b100
  } sew_e;

  // vlmul[2:0] is a SIGNED field: LMUL = 2 ** $signed(vlmul).
  // That is why the fractional values sit at the top of the encoding space.
  typedef enum logic [2:0] {
    LMUL_1    = 3'b000,
    LMUL_2    = 3'b001,
    LMUL_4    = 3'b010,
    LMUL_8    = 3'b011,
    LMUL_RSVD = 3'b100,
    LMUL_F8   = 3'b101,   // 1/8
    LMUL_F4   = 3'b110,   // 1/4
    LMUL_F2   = 3'b111    // 1/2
  } lmul_e;

  typedef struct packed {
    logic  vill;   // illegal configuration
    logic  vma;    // 1 = mask agnostic
    logic  vta;    // 1 = tail agnostic
    sew_e  vsew;
    lmul_e vlmul;
  } vtype_t;

  // ---------------------------------------------------------------------------
  // Instruction field extraction (RVV 1.0).  Verified against the GNU assembler.
  // ---------------------------------------------------------------------------
  parameter logic [6:0] OPCODE_OP_V     = 7'b1010111;  // 0x57
  parameter logic [6:0] OPCODE_LOAD_FP  = 7'b0000111;  // 0x07
  parameter logic [6:0] OPCODE_STORE_FP = 7'b0100111;  // 0x27

  // funct3 selects WHERE THE SECOND OPERAND COMES FROM, not the operation.
  typedef enum logic [2:0] {
    OPIVV = 3'b000,
    OPFVV = 3'b001,
    OPMVV = 3'b010,
    OPIVI = 3'b011,
    OPIVX = 3'b100,
    OPFVF = 3'b101,
    OPMVX = 3'b110,
    OPCFG = 3'b111   // vsetvli / vsetivli / vsetvl
  } vfmt_e;

  // mop[1:0] -- vector load/store addressing mode
  typedef enum logic [1:0] {
    MOP_UNIT    = 2'b00,
    MOP_IDX_U   = 2'b01,   // indexed-unordered
    MOP_STRIDED = 2'b10,
    MOP_IDX_O   = 2'b11    // indexed-ordered
  } mop_e;

  // ---------------------------------------------------------------------------
  // Internal operation encoding.  Grouped by functional unit so the lane can
  // decode on the high bits.  Extend as you implement more of the subset.
  // ---------------------------------------------------------------------------
  typedef enum logic [5:0] {
    // --- adder / logic (block 5, VALU) ---
    VOP_ADD, VOP_SUB, VOP_RSUB,
    VOP_AND, VOP_OR,  VOP_XOR,
    VOP_MIN, VOP_MINU, VOP_MAX, VOP_MAXU,
    VOP_SLL, VOP_SRL, VOP_SRA,
    // --- comparisons (write a mask) ---
    VOP_MSEQ, VOP_MSNE, VOP_MSLT, VOP_MSLTU, VOP_MSLE, VOP_MSLEU,
    // --- multiplier ---
    VOP_MUL, VOP_MULH, VOP_MULHU, VOP_MACC, VOP_WMACC,
    VOP_WADD, VOP_WADDU, VOP_WMUL,
    // --- moves / merges ---
    VOP_MERGE, VOP_MV, VOP_ID,
    VOP_ZEXT2, VOP_SEXT2,
    // --- reductions ---
    VOP_REDSUM, VOP_REDMAX, VOP_REDMIN,
    // --- mask ops ---
    VOP_MAND, VOP_MOR, VOP_MXOR, VOP_MNOT, VOP_CPOP, VOP_FIRST,
    // --- permute ---
    VOP_SLIDE1UP, VOP_SLIDE1DOWN, VOP_MV_X_S, VOP_MV_S_X,
    // --- memory ---
    VOP_LOAD, VOP_STORE,
    // --- configuration ---
    VOP_VSETVL,
    // --- nothing ---
    VOP_NONE
  } vec_op_e;

  // ---------------------------------------------------------------------------
  // The decoded control bundle -- block 1's output, and the contract between
  // the decoder and everything downstream.  See Book Ch 9 section 9.1.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic             valid;
    vec_op_e          op;
    vfmt_e            fmt;

    logic [4:0]       vd;
    logic [4:0]       vs1;
    logic [4:0]       vs2;
    logic             vm;            // 0 = masked by v0

    logic [XLEN-1:0]  scalar_op;     // rs1 value, or sign-extended OPIVI immediate
    logic             use_scalar;    // second operand is scalar_op

    logic             writes_vrf;
    logic             writes_xrf;    // vsetvl, vmv.x.s, vcpop, vfirst
    logic             writes_mask;   // destination is a mask register

    logic             is_load;
    logic             is_store;
    mop_e             mop;
    sew_e             eew;           // effective element width for this operand
    lmul_e            emul;          // effective LMUL = LMUL * EEW / SEW

    logic             is_widening;
    logic             is_narrowing;
    logic             is_reduction;
  } vec_uop_t;

  // ---------------------------------------------------------------------------
  // Helper functions.
  // ---------------------------------------------------------------------------

  // log2(SEW) -- used to turn element indices into bit offsets.
  function automatic int unsigned sew_log2(sew_e s);
    unique case (s)
      SEW8:    sew_log2 = 3;
      SEW16:   sew_log2 = 4;
      SEW32:   sew_log2 = 5;
      SEW64:   sew_log2 = 6;
      default: sew_log2 = 5;
    endcase
  endfunction

  // SEW = 8 << vsew.  vsew[2] is only set for the reserved encoding, which
  // vtype_illegal() rejects; report the widest legal width so callers that
  // compare against ELEN still see it as out of range.
  function automatic int unsigned sew_bits(sew_e s);
    sew_bits = s[2] ? 128 : (8 << s[1:0]);
  endfunction

  // Number of whole registers in a group.  Fractional LMUL still occupies one.
  function automatic int unsigned lmul_regs(lmul_e l);
    unique case (l)
      LMUL_1, LMUL_F2, LMUL_F4, LMUL_F8: lmul_regs = 1;
      LMUL_2:                            lmul_regs = 2;
      LMUL_4:                            lmul_regs = 4;
      LMUL_8:                            lmul_regs = 8;
      default:                           lmul_regs = 1;
    endcase
  endfunction

  // VLMAX = LMUL * VLEN / SEW.  Both LMUL and SEW are powers of two and vlmul is
  // signed, so this is a single shift:  VLMAX = VLEN >> (log2(SEW) - vlmul).
  // See Book Ch 9 section 9.2.
  function automatic logic [VL_W-1:0] calc_vlmax(sew_e s, lmul_e l);
    int signed shift_amt;
    shift_amt = int'(sew_log2(s)) - int'($signed(l));
    // shift_amt is always >= 0 for a legal (SEW, LMUL) pair with SEW <= ELEN.
    calc_vlmax = (shift_amt < 0) ? VL_W'(VLEN)
                                 : VL_W'(VLEN >> shift_amt);
  endfunction

  // Is this (SEW, LMUL) pair legal on this implementation?
  // Book Ch 4 section 4.5 lists what must set vill.
  function automatic logic vtype_illegal(sew_e s, lmul_e l);
    logic bad;
    bad = 1'b0;
    if (s == SEW_RSVD || s[2])       bad = 1'b1;   // reserved vsew
    if (l == LMUL_RSVD)              bad = 1'b1;   // reserved vlmul
    if (sew_bits(s) > ELEN)          bad = 1'b1;   // SEW must not exceed ELEN
    // LMUL >= SEW/ELEN : a group must hold at least one element.
    if (int'(sew_log2(s)) - int'($signed(l)) > int'($clog2(VLEN))) bad = 1'b1;
    vtype_illegal = bad;
  endfunction

  // Expand per-element write enables into per-byte write enables for the VRF.
  // This is the function that makes tails, masking and vstart work -- see
  // Book Ch 9 section 9.3 and 9.5.
  function automatic logic [VLENB-1:0] expand_to_bytes(
      input logic [VLEN/8-1:0] elem_en,   // one bit per element, element 0 at [0]
      input sew_e              s);
    logic [VLENB-1:0] be;
    int unsigned      bytes_per_elem;
    be             = '0;
    bytes_per_elem = sew_bits(s) / 8;
    for (int unsigned e = 0; e < VLENB; e++) begin
      if (e * bytes_per_elem < VLENB && elem_en[e]) begin
        for (int unsigned b = 0; b < 8; b++) begin
          if (b < bytes_per_elem && (e * bytes_per_elem + b) < VLENB)
            be[e * bytes_per_elem + b] = 1'b1;
        end
      end
    end
    expand_to_bytes = be;
  endfunction

endpackage : meds_v_pkg
