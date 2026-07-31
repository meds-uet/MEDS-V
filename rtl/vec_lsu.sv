// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// MEDS-V Block (6) : Vector Load/Store Unit                  [SKELETON -- M4]
//
// THE HARDEST BLOCK.  Book Ch 9 section 9.6 lists eight reasons why; read them
// before starting.  This gets a whole milestone and your strongest engineer.
//
// The v1 simplifications that make it tractable (Book Ch 10 section 10.7):
//   * memory port is VLEN bits wide  -> a unit-stride access is ONE request
//   * natural EEW alignment required -> no cross-word element splitting
//   * unit-stride and strided only   -> no index vector to read first
//   * one outstanding request        -> no reorder buffer
// Every one of these is a documented limitation, not an oversight.  They go in
// Appendix E and get measured in Ch 15.
//
// NON-NEGOTIABLE CORRECTNESS RULES:
//   * A unit-stride access covers vl ELEMENTS, not VLEN bits.  Fetching a whole
//     register when vl is short can fault on a page the program never touched.
//   * A masked-off element must generate NO memory access at all.  This is a
//     correctness requirement, not an optimisation -- the address may be
//     unmapped.
// =============================================================================

module vec_lsu
  import meds_v_pkg::*;
#(
  parameter int unsigned MEM_DW = VLEN      // memory data width, bits
)(
  input  logic                 clk_i,
  input  logic                 rst_ni,

  // ---- request from the sequencer -----------------------------------------
  input  vec_uop_t             uop_i,
  input  logic                 uop_valid_i,
  output logic                 uop_ready_o,

  input  logic [XLEN-1:0]      base_addr_i,   // rs1
  input  logic [XLEN-1:0]      stride_i,      // rs2, strided mode only
  input  logic [VL_W-1:0]      vl_i,
  input  vtype_t               vtype_i,
  input  logic [VLEN-1:0]      v0_i,
  input  logic [VLEN-1:0]      store_data_i,  // from the VRF, for stores

  // ---- memory port (simple valid/ready; wrap to AXI at the top) ------------
  output logic                 mem_req_valid_o,
  input  logic                 mem_req_ready_i,
  output logic [XLEN-1:0]      mem_req_addr_o,
  output logic                 mem_req_we_o,
  output logic [MEM_DW/8-1:0]  mem_req_be_o,
  output logic [MEM_DW-1:0]    mem_req_wdata_o,
  input  logic                 mem_rsp_valid_i,
  input  logic [MEM_DW-1:0]    mem_rsp_rdata_i,

  // ---- result to the VRF ---------------------------------------------------
  output logic [VLEN-1:0]      vrf_wdata_o,
  output logic [VLENB-1:0]     vrf_wbe_o,
  output logic                 done_o
);

  // ---------------------------------------------------------------------------
  // How many BYTES does this access actually touch?
  //   bytes = vl * (EEW / 8)
  // NOT VLENB.  See the correctness rules above.
  // ---------------------------------------------------------------------------
  logic [VL_W+3:0] access_bytes;
  assign access_bytes = (VL_W+4)'(vl_i) * (VL_W+4)'(sew_bits(uop_i.eew) / 8);

  // ---------------------------------------------------------------------------
  // Per-element active mask: an element participates only if it is in the body
  // AND enabled by v0.  Inactive elements must produce no bus activity.
  // ---------------------------------------------------------------------------
  logic [VLENB-1:0] elem_active;
  always_comb begin
    elem_active = '0;
    for (int unsigned e = 0; e < VLENB; e++)
      elem_active[e] = (VL_W'(e) < vl_i) && (uop_i.vm || v0_i[e]);
  end

  // ---------------------------------------------------------------------------
  // TODO (M4): address generation.
  //
  //   unit-stride : addr(i) = base + i * (EEW/8)          -> one wide request
  //   strided     : addr(i) = base + i * stride           -> one request/element
  //   indexed     : addr(i) = base + index_vector[i]      -> DEFERRED (App. E)
  //
  // Start with unit-stride only and get a compiled C program running (the M4
  // exit criterion).  Add strided afterwards.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // TODO (M4): the request FSM.
  //
  //   S_IDLE  -> accept a uop, latch base/stride/vl
  //   S_REQ   -> drive mem_req_valid_o, wait for mem_req_ready_i
  //   S_RSP   -> wait for mem_rsp_valid_i, align the data, write the VRF
  //   S_DONE  -> pulse done_o
  //
  // Backpressure matters: memory may deassert ready at any time, and your
  // pipeline must hold state rather than dropping the request.  The M4 exit
  // criterion includes a random-stall test.
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] { S_IDLE, S_REQ, S_RSP, S_DONE } state_e;
  state_e state_q, state_d;

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      S_IDLE: if (uop_valid_i && (uop_i.is_load || uop_i.is_store)) state_d = S_REQ;
      S_REQ:  if (mem_req_ready_i)  state_d = uop_i.is_store ? S_DONE : S_RSP;
      S_RSP:  if (mem_rsp_valid_i)  state_d = S_DONE;
      S_DONE:                       state_d = S_IDLE;
      default:                      state_d = S_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= S_IDLE;
    else         state_q <= state_d;
  end

  // ---------------------------------------------------------------------------
  // Outputs -- unit-stride, single-request form.
  // ---------------------------------------------------------------------------
  assign uop_ready_o     = (state_q == S_IDLE);
  assign mem_req_valid_o = (state_q == S_REQ);
  assign mem_req_addr_o  = base_addr_i;
  assign mem_req_we_o    = uop_i.is_store;
  assign mem_req_wdata_o = MEM_DW'(store_data_i);
  assign done_o          = (state_q == S_DONE);

  // Byte enables on the bus: only the bytes belonging to ACTIVE elements.
  // This is what stops a masked-off element touching memory.
  assign mem_req_be_o = (MEM_DW/8)'(expand_to_bytes(elem_active, uop_i.eew));

  // Write-back to the VRF uses the same enables, so tail and inactive elements
  // are left undisturbed exactly as for arithmetic.
  assign vrf_wdata_o = VLEN'(mem_rsp_rdata_i);
  assign vrf_wbe_o   = (state_q == S_RSP && mem_rsp_valid_i)
                     ? expand_to_bytes(elem_active, uop_i.eew) : '0;

  logic _unused;
  assign _unused = |stride_i | |access_bytes | vtype_i.vill | |uop_i.mop;

endmodule : vec_lsu
