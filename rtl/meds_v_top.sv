// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// MEDS-V : top-level vector processing unit                  [SKELETON -- M3]
//
// Wires the eight blocks of the Book Ch 8 diagram together and presents the
// decoupled coprocessor interface of Book Ch 8 section 8.4 to the scalar core.
//
// Block map:
//   (1) vec_decoder    (2) vec_csr      (3) vec_sequencer   (4) vrf
//   (5) vec_lane       (6) vec_lsu      (7) vec_mask        (8) vec_reduce
// Blocks 7 and 8 arrive at M5; their absence is why masked arithmetic and
// vredsum do not work yet.
// =============================================================================

module meds_v_top
  import meds_v_pkg::*;
#(
  parameter int unsigned MEM_DW = VLEN
)(
  input  logic                 clk_i,
  input  logic                 rst_ni,

  // ---- issue interface: scalar core -> vector unit -------------------------
  input  logic                 vec_req_valid_i,
  output logic                 vec_req_ready_o,
  input  logic [31:0]          vec_req_instr_i,
  input  logic [XLEN-1:0]      vec_req_rs1_i,
  input  logic [XLEN-1:0]      vec_req_rs2_i,
  input  logic                 vs_enabled_i,      // mstatus.VS != Off

  // ---- response: vector unit -> scalar core --------------------------------
  output logic                 vec_resp_valid_o,
  output logic [XLEN-1:0]      vec_resp_data_o,
  output logic                 vec_resp_illegal_o,
  output logic                 vec_idle_o,

  // ---- memory port ---------------------------------------------------------
  output logic                 mem_req_valid_o,
  input  logic                 mem_req_ready_i,
  output logic [XLEN-1:0]      mem_req_addr_o,
  output logic                 mem_req_we_o,
  output logic [MEM_DW/8-1:0]  mem_req_be_o,
  output logic [MEM_DW-1:0]    mem_req_wdata_o,
  input  logic                 mem_rsp_valid_i,
  input  logic [MEM_DW-1:0]    mem_rsp_rdata_i
);

  // ---------------------------------------------------------------------------
  // Inter-block signals
  // ---------------------------------------------------------------------------
  vec_uop_t          uop;
  logic              decoder_illegal;
  logic              set_valid, set_avl_is_max, set_keep_vl;
  logic [10:0]       set_zimm;
  logic [XLEN-1:0]   set_vl;
  logic [XLEN-1:0]   csr_rdata;

  vtype_t            vtype;
  logic [VL_W-1:0]   vl, vstart;

  logic [4:0]        vrf_raddr [3];
  logic [VLEN-1:0]   vrf_rdata [3];
  logic              vrf_we, alu_we, lsu_we;
  logic [4:0]        vrf_waddr;
  logic [VLEN-1:0]   vrf_wdata, alu_wdata, lsu_wdata;
  logic [VLENB-1:0]  vrf_wbe,  alu_wbe,  lsu_wbe;
  logic [VLEN-1:0]   v0;

  vec_op_e           lane_op;
  sew_e              lane_sew;
  logic              lane_valid, lane_result_valid;
  logic              seq_done, lsu_done, seq_ready, lsu_ready;

  // ---------------------------------------------------------------------------
  // (1) Decoder
  // ---------------------------------------------------------------------------
  vec_decoder u_decoder (
    .instr_i          (vec_req_instr_i),
    .rs1_val_i        (vec_req_rs1_i),
    .vtype_i          (vtype),
    .vs_enabled_i     (vs_enabled_i),
    .uop_o            (uop),
    .illegal_o        (decoder_illegal),
    .set_valid_o      (set_valid),
    .set_zimm_o       (set_zimm),
    .set_avl_is_max_o (set_avl_is_max),
    .set_keep_vl_o    (set_keep_vl)
  );

  // ---------------------------------------------------------------------------
  // (2) CSR / vtype unit
  // ---------------------------------------------------------------------------
  vec_csr u_csr (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .set_valid_i      (set_valid && vec_req_valid_i && !decoder_illegal),
    .set_zimm_i       (set_zimm),
    .set_avl_i        (vec_req_rs1_i),
    .set_avl_is_max_i (set_avl_is_max),
    .set_keep_vl_i    (set_keep_vl),
    .set_vl_o         (set_vl),
    .vtype_o          (vtype),
    .vl_o             (vl),
    .vstart_o         (vstart),
    .instr_retire_i   (seq_done || lsu_done),
    .vstart_we_i      (1'b0),
    .vstart_i         ('0),
    .csr_addr_i       (vec_req_instr_i[31:20]),
    .csr_rdata_o      (csr_rdata)     // TODO: route to the scalar CSR read path
  );

  // ---------------------------------------------------------------------------
  // (3) Sequencer
  // ---------------------------------------------------------------------------
  vec_sequencer u_sequencer (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .uop_i        (uop),
    .uop_valid_i  (vec_req_valid_i && uop.valid && !uop.is_load && !uop.is_store),
    .uop_ready_o  (seq_ready),
    .vtype_i      (vtype),
    .vl_i         (vl),
    .vstart_i     (vstart),
    .v0_i         (v0),
    .vrf_raddr_o  (vrf_raddr),
    .vrf_we_o     (alu_we),
    .vrf_waddr_o  (vrf_waddr),
    .vrf_wbe_o    (alu_wbe),
    .lane_op_o    (lane_op),
    .lane_sew_o   (lane_sew),
    .lane_valid_o (lane_valid),
    .done_o       (seq_done)
  );

  // ---------------------------------------------------------------------------
  // (4) Vector register file
  // ---------------------------------------------------------------------------
  vrf u_vrf (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .raddr_i (vrf_raddr),
    .rdata_o (vrf_rdata),
    .we_i    (vrf_we),
    .waddr_i (vrf_waddr),
    .wdata_i (vrf_wdata),
    .wbe_i   (vrf_wbe),
    .v0_o    (v0)
  );

  // Write-port arbitration: the ALU and the VLSU both write the VRF.  With one
  // instruction in flight they never collide; when M6 allows a load to overlap
  // arithmetic this becomes a real arbiter.
  assign vrf_we    = alu_we | lsu_we;
  assign vrf_wdata = lsu_we ? lsu_wdata : alu_wdata;
  assign vrf_wbe   = lsu_we ? lsu_wbe   : alu_wbe;

  // ---------------------------------------------------------------------------
  // (5) Lane array.  Element i lives in lane i mod NR_LANES (Book Ch 2.3).
  // ---------------------------------------------------------------------------
  logic [ELEN-1:0] lane_result [NR_LANES];
  logic            lane_done   [NR_LANES];

  for (genvar l = 0; l < NR_LANES; l++) begin : gen_lanes
    vec_lane u_lane (
      .clk_i       (clk_i),
      .rst_ni      (rst_ni),
      .op_i        (lane_op),
      .sew_i       (lane_sew),
      .valid_i     (lane_valid),
      .operand_a_i (vrf_rdata[1][l*ELEN +: ELEN]),   // vs2
      .operand_b_i (uop.use_scalar ? uop.scalar_op[ELEN-1:0]
                                   : vrf_rdata[0][l*ELEN +: ELEN]),  // vs1 or scalar
      .operand_c_i (vrf_rdata[2][l*ELEN +: ELEN]),   // vd, for vmacc
      .result_o    (lane_result[l]),
      .valid_o     (lane_done[l])
    );
  end

  always_comb begin
    alu_wdata = '0;
    for (int unsigned l = 0; l < NR_LANES; l++)
      alu_wdata[l*ELEN +: ELEN] = lane_result[l];
  end
  assign lane_result_valid = lane_done[0];

  // ---------------------------------------------------------------------------
  // (6) Vector load/store unit
  // ---------------------------------------------------------------------------
  vec_lsu #(.MEM_DW(MEM_DW)) u_lsu (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .uop_i           (uop),
    .uop_valid_i     (vec_req_valid_i && uop.valid && (uop.is_load || uop.is_store)),
    .uop_ready_o     (lsu_ready),
    .base_addr_i     (vec_req_rs1_i),
    .stride_i        (vec_req_rs2_i),
    .vl_i            (vl),
    .vtype_i         (vtype),
    .v0_i            (v0),
    .store_data_i    (vrf_rdata[1]),
    .mem_req_valid_o (mem_req_valid_o),
    .mem_req_ready_i (mem_req_ready_i),
    .mem_req_addr_o  (mem_req_addr_o),
    .mem_req_we_o    (mem_req_we_o),
    .mem_req_be_o    (mem_req_be_o),
    .mem_req_wdata_o (mem_req_wdata_o),
    .mem_rsp_valid_i (mem_rsp_valid_i),
    .mem_rsp_rdata_i (mem_rsp_rdata_i),
    .vrf_wdata_o     (lsu_wdata),
    .vrf_wbe_o       (lsu_wbe),
    .done_o          (lsu_done)
  );
  assign lsu_we = |lsu_wbe;

  // ---------------------------------------------------------------------------
  // (7) Mask unit and (8) reduction/permute unit -- M5.
  // TODO: instantiate vec_mask.sv and vec_reduce.sv here.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Issue / response handshake (Book Ch 8 section 8.4)
  // ---------------------------------------------------------------------------
  assign vec_req_ready_o    = seq_ready && lsu_ready;
  assign vec_resp_illegal_o = vec_req_valid_i && decoder_illegal;
  // vsetvl{i} returns the new vl to a scalar register; the scalar core stalls
  // on it, which is why every stripmine loop synchronises once per pass.
  assign vec_resp_valid_o   = vec_req_valid_i && set_valid && !decoder_illegal;
  assign vec_resp_data_o    = set_vl;
  assign vec_idle_o         = seq_ready && lsu_ready;

  // Tie-offs for signals that become live in later milestones.
  logic _unused;
  assign _unused = lane_result_valid | |vrf_rdata[2] | |set_zimm | |csr_rdata
                 | |vstart;

endmodule : meds_v_top
