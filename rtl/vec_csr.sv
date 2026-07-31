// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// MEDS-V Block (2) : Vector CSR / vtype unit
//
// Owns vl, vtype, vstart, vxsat, vxrm and vlenb, and implements the
// vsetvli / vsetivli / vsetvl instructions.
//
// This module is provided COMPLETE as a worked reference: it is the smallest
// block that exercises every subtlety of Book Ch 4 (signed vlmul, the four AVL
// cases, vill semantics).  Read it before writing the others.
//
// Milestone M1.  See Book Ch 9 section 9.2.
// =============================================================================

module vec_csr
  import meds_v_pkg::*;
(
  input  logic              clk_i,
  input  logic              rst_ni,

  // ---- vsetvl{i} execution -------------------------------------------------
  input  logic              set_valid_i,
  input  logic [10:0]       set_zimm_i,        // {vma, vta, vsew[2:0], vlmul[2:0]}
  input  logic [XLEN-1:0]   set_avl_i,         // application vector length
  input  logic              set_avl_is_max_i,  // rs1==x0, rd!=x0 -> AVL = infinity
  input  logic              set_keep_vl_i,     // rs1==x0, rd==x0 -> keep current vl
  output logic [XLEN-1:0]   set_vl_o,          // value written back to rd

  // ---- broadcast state -----------------------------------------------------
  output vtype_t            vtype_o,
  output logic [VL_W-1:0]   vl_o,
  output logic [VL_W-1:0]   vstart_o,

  // ---- vstart maintenance --------------------------------------------------
  input  logic              instr_retire_i,    // clear vstart at retire
  input  logic              vstart_we_i,
  input  logic [VL_W-1:0]   vstart_i,

  // ---- generic CSR read port ----------------------------------------------
  input  logic [11:0]       csr_addr_i,
  output logic [XLEN-1:0]   csr_rdata_o
);

  // ---------------------------------------------------------------------------
  // Architectural state
  // ---------------------------------------------------------------------------
  vtype_t          vtype_q,  vtype_d;
  logic [VL_W-1:0] vl_q,     vl_d;
  logic [VL_W-1:0] vstart_q, vstart_d;

  // ---------------------------------------------------------------------------
  // Decode the requested vtype out of the zimm field.
  // Layout (Book Ch 4 section 4.4):  zimm[7]=vma  zimm[6]=vta
  //                                  zimm[5:3]=vsew  zimm[2:0]=vlmul
  // ---------------------------------------------------------------------------
  sew_e  req_sew;
  lmul_e req_lmul;
  logic  req_vta, req_vma, req_rsvd_nz, req_illegal;

  assign req_lmul    = lmul_e'(set_zimm_i[2:0]);
  assign req_sew     = sew_e'(set_zimm_i[5:3]);
  assign req_vta     = set_zimm_i[6];
  assign req_vma     = set_zimm_i[7];
  assign req_rsvd_nz = |set_zimm_i[10:8];          // reserved bits must be zero

  assign req_illegal = vtype_illegal(req_sew, req_lmul) | req_rsvd_nz;

  // ---------------------------------------------------------------------------
  // VLMAX = LMUL * VLEN / SEW.  A single shift -- see meds_v_pkg::calc_vlmax.
  // ---------------------------------------------------------------------------
  logic [VL_W-1:0] vlmax;
  assign vlmax = calc_vlmax(req_sew, req_lmul);

  // ---------------------------------------------------------------------------
  // The four AVL cases (Book Ch 4 section 4.4).
  //
  //   rd != x0, rs1 != x0 : vl = min(AVL, VLMAX)
  //   rd == x0, rs1 != x0 : same, result discarded
  //   rd != x0, rs1 == x0 : AVL is infinite  -> vl = VLMAX
  //   rd == x0, rs1 == x0 : keep the current vl, change only vtype
  //
  // NOTE: rs1 == x0 does NOT mean AVL = 0.  Reading x0 as the value zero here
  // makes vl = 0 and hangs every stripmine loop in existence.
  // ---------------------------------------------------------------------------
  logic avl_fits;
  assign avl_fits = (set_avl_i <= XLEN'(vlmax));

  always_comb begin
    if (req_illegal)            vl_d = '0;                    // vill => vl = 0
    else if (set_keep_vl_i)     vl_d = vl_q;                  // keep current vl
    else if (set_avl_is_max_i)  vl_d = vlmax;                 // AVL = infinity
    else if (avl_fits)          vl_d = set_avl_i[VL_W-1:0];   // vl = AVL
    else                        vl_d = vlmax;                 // vl = VLMAX
  end

  // ---------------------------------------------------------------------------
  // vtype update.  On an illegal request the spec requires vill=1 AND every
  // other field zeroed -- software reads vtype back to probe capabilities.
  // ---------------------------------------------------------------------------
  always_comb begin
    if (req_illegal) begin
      vtype_d = '{vill: 1'b1, vma: 1'b0, vta: 1'b0,
                  vsew: SEW8,  vlmul: LMUL_1};
    end else begin
      vtype_d = '{vill: 1'b0, vma: req_vma, vta: req_vta,
                  vsew: req_sew, vlmul: req_lmul};
    end
  end

  // ---------------------------------------------------------------------------
  // vstart: cleared at instruction retire, writable for trap resumption.
  // ---------------------------------------------------------------------------
  always_comb begin
    vstart_d = vstart_q;
    if      (vstart_we_i)    vstart_d = vstart_i;
    else if (instr_retire_i) vstart_d = '0;
  end

  // ---------------------------------------------------------------------------
  // Sequential state
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vtype_q  <= '{vill: 1'b1, vma: 1'b0, vta: 1'b0, vsew: SEW8, vlmul: LMUL_1};
      vl_q     <= '0;
      vstart_q <= '0;
    end else begin
      if (set_valid_i) begin
        vtype_q <= vtype_d;
        vl_q    <= vl_d;
      end
      vstart_q <= vstart_d;
    end
  end

  assign vtype_o  = vtype_q;
  assign vl_o     = vl_q;
  assign vstart_o = vstart_q;
  assign set_vl_o = XLEN'(vl_d);          // vsetvl{i} returns the NEW vl

  // ---------------------------------------------------------------------------
  // CSR read port.  vl, vtype and vlenb are read-only; they are written only by
  // vsetvl{i}, which guarantees vl and vtype stay mutually consistent.
  // ---------------------------------------------------------------------------
  localparam logic [11:0] CSR_VSTART = 12'h008;
  localparam logic [11:0] CSR_VL     = 12'hC20;
  localparam logic [11:0] CSR_VTYPE  = 12'hC21;
  localparam logic [11:0] CSR_VLENB  = 12'hC22;

  always_comb begin
    unique case (csr_addr_i)
      CSR_VSTART: csr_rdata_o = XLEN'(vstart_q);
      CSR_VL:     csr_rdata_o = XLEN'(vl_q);
      CSR_VTYPE:  csr_rdata_o = {vtype_q.vill, {(XLEN-9){1'b0}},
                                 vtype_q.vma, vtype_q.vta,
                                 vtype_q.vsew, vtype_q.vlmul};
      CSR_VLENB:  csr_rdata_o = XLEN'(VLENB);
      default:    csr_rdata_o = '0;
    endcase
  end

endmodule : vec_csr
