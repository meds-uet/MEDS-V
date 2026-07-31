// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// MEDS-V Block (3) : Sequencer and Hazard Unit               [SKELETON -- M3]
//
// THE BRAIN.  Turns one vector instruction into a sequence of passes over the
// lanes, tracks register-GROUP dependencies, and generates the per-element
// write enables that implement vstart, vl and masking all at once.
//
// See Book Ch 9 section 9.5.  Two things to internalise before editing:
//
//  1. The lanes ALWAYS compute; this module decides what to keep.  Do not build
//     logic to prevent computation in the tail -- build logic to discard it.
//
//  2. The scoreboard tracks register GROUPS, not registers.  At LMUL=8,
//     "vadd.vv v0, v8, v16" writes v0..v7.  And a masked instruction reads v0,
//     which is a dependency that appears nowhere in the vs1/vs2 fields.
// =============================================================================

module vec_sequencer
  import meds_v_pkg::*;
(
  input  logic                clk_i,
  input  logic                rst_ni,

  // ---- from the decoder ----------------------------------------------------
  input  vec_uop_t            uop_i,
  input  logic                uop_valid_i,
  output logic                uop_ready_o,

  // ---- architectural state -------------------------------------------------
  input  vtype_t              vtype_i,
  input  logic [VL_W-1:0]     vl_i,
  input  logic [VL_W-1:0]     vstart_i,
  input  logic [VLEN-1:0]     v0_i,

  // ---- to the VRF ----------------------------------------------------------
  output logic [4:0]          vrf_raddr_o [3],
  output logic                vrf_we_o,
  output logic [4:0]          vrf_waddr_o,
  output logic [VLENB-1:0]    vrf_wbe_o,

  // ---- to the lanes --------------------------------------------------------
  output vec_op_e             lane_op_o,
  output sew_e                lane_sew_o,
  output logic                lane_valid_o,

  // ---- completion ----------------------------------------------------------
  output logic                done_o
);

  // ---------------------------------------------------------------------------
  // Elements handled per pass.
  //
  //   elements_per_pass = NR_LANES * (ELEN / SEW)      <-- NOT NR_LANES
  //
  // At SEW=8 a 32-bit lane does four bytes at once (the segmented ALU in
  // vec_lane.sv).  Getting this wrong makes every e8 operation wrong by 4x.
  // Book Ch 10 section 10.5.
  // ---------------------------------------------------------------------------
  logic [VL_W-1:0] elems_per_pass;
  assign elems_per_pass = VL_W'(NR_LANES * (ELEN / sew_bits(vtype_i.vsew)));

  // ---------------------------------------------------------------------------
  // Pass counter.
  //
  // TODO (M3): total_passes = ceil(vl / elems_per_pass) * lmul_regs(emul).
  //   The LMUL factor is there because a register GROUP is walked one register
  //   at a time: reg_offset = element_base / (VLEN / SEW).
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] { S_IDLE, S_RUN, S_DONE } state_e;
  state_e          state_q, state_d;
  logic [VL_W-1:0] elem_base_q, elem_base_d;

  // ---------------------------------------------------------------------------
  // PER-ELEMENT WRITE ENABLES -- the heart of the block.
  //
  // These five lines implement, simultaneously:
  //    * prestart   (index <  vstart)      Book Ch 4 section 4.9
  //    * tail       (index >= vl)          Book Ch 4 section 4.8
  //    * masking    (v0 bit clear)         Book Ch 4 section 4.7
  //
  // Because "retain previous values" is an explicitly permitted implementation
  // of the AGNOSTIC policies, building only this undisturbed path makes us
  // compliant with vta=0/1 and vma=0/1 alike -- with no policy mux at all.
  // That is the single highest-leverage simplification in the whole design.
  // ---------------------------------------------------------------------------
  logic [VLENB-1:0] elem_en;

  always_comb begin
    elem_en = '0;
    for (int unsigned e = 0; e < VLENB; e++) begin
      automatic logic [VL_W-1:0] idx = elem_base_q + VL_W'(e);
      elem_en[e] = (idx >= vstart_i)                   // not prestart
                 && (idx <  vl_i)                      // not tail
                 && (uop_i.vm || v0_i[e]);             // active under the mask
    end
  end

  // Element enables -> byte enables, according to SEW.
  assign vrf_wbe_o = expand_to_bytes(elem_en, vtype_i.vsew);

  // ---------------------------------------------------------------------------
  // Hazard detection.
  //
  // TODO (M3): complete the scoreboard.
  //   * Mark EVERY register of the destination group busy on issue.
  //   * Stall on RAW against vs1, vs2 -- as GROUPS.
  //   * Stall on WAW against vd.
  //   * AND: stall on v0 when the instruction is masked.  A vmseq that writes
  //     v0 followed by a masked vadd is a RAW hazard that is invisible in the
  //     vs1/vs2 fields.  Teams forget this one constantly, and the symptom is
  //     intermittently wrong masked results.
  // ---------------------------------------------------------------------------
  logic [31:0] busy_q, busy_d;
  logic        raw_hazard, waw_hazard, stall;

  function automatic logic [31:0] group_mask(logic [4:0] base, lmul_e l);
    logic [31:0] m;
    m = '0;
    for (int unsigned r = 0; r < 32; r++)
      if (r >= 32'(base) && r < 32'(base) + lmul_regs(l)) m[r] = 1'b1;
    group_mask = m;
  endfunction

  always_comb begin
    raw_hazard = |(busy_q & group_mask(uop_i.vs1, uop_i.emul))
               | |(busy_q & group_mask(uop_i.vs2, uop_i.emul))
               | (!uop_i.vm && busy_q[0]);              // <-- the v0 mask dependency
    waw_hazard = |(busy_q & group_mask(uop_i.vd,  uop_i.emul));
    stall      = uop_valid_i && (raw_hazard || waw_hazard);
  end

  // ---------------------------------------------------------------------------
  // Control FSM.
  //
  // TODO (M3): drive elem_base_d across passes, walk the register group, and
  //            hold uop_ready_o low while an instruction is in flight.
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d     = state_q;
    elem_base_d = elem_base_q;
    busy_d      = busy_q;

    unique case (state_q)
      S_IDLE: begin
        if (uop_valid_i && !stall) begin
          state_d     = S_RUN;
          elem_base_d = vstart_i;
          if (uop_i.writes_vrf)
            busy_d = busy_q | group_mask(uop_i.vd, uop_i.emul);
        end
      end
      S_RUN: begin
        elem_base_d = elem_base_q + elems_per_pass;
        if (elem_base_d >= vl_i) state_d = S_DONE;
      end
      S_DONE: begin
        state_d = S_IDLE;
        busy_d  = busy_q & ~group_mask(uop_i.vd, uop_i.emul);
      end
      default: state_d = S_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= S_IDLE;
      elem_base_q <= '0;
      busy_q      <= '0;
    end else begin
      state_q     <= state_d;
      elem_base_q <= elem_base_d;
      busy_q      <= busy_d;
    end
  end

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------
  assign uop_ready_o  = (state_q == S_IDLE) && !stall;
  assign lane_valid_o = (state_q == S_RUN);
  assign lane_op_o    = uop_i.op;
  assign lane_sew_o   = vtype_i.vsew;
  assign vrf_we_o     = (state_q == S_RUN) && uop_i.writes_vrf;
  assign vrf_waddr_o  = uop_i.vd;      // TODO: + register offset within the group
  assign done_o       = (state_q == S_DONE);

  always_comb begin
    vrf_raddr_o[0] = uop_i.vs1;
    vrf_raddr_o[1] = uop_i.vs2;
    vrf_raddr_o[2] = uop_i.vd;         // for accumulating ops (vmacc)
  end

  // ---------------------------------------------------------------------------
  // Tie-offs for bundle fields this skeleton does not consume yet.  Each one is
  // a TODO above: widening/narrowing change the pass count, the load/store
  // flags route the uop to the VLSU, and vta/vma are deliberately unused
  // because the undisturbed write path is compliant with both policies.
  // ---------------------------------------------------------------------------
  logic _unused;
  assign _unused = uop_i.is_widening | uop_i.is_narrowing | uop_i.is_reduction
                 | uop_i.is_load | uop_i.is_store | uop_i.use_scalar
                 | uop_i.writes_xrf | uop_i.writes_mask | uop_i.valid
                 | |uop_i.scalar_op | |uop_i.fmt | |uop_i.eew | |uop_i.mop
                 | vtype_i.vta | vtype_i.vma | vtype_i.vill | |vtype_i.vlmul;

endmodule : vec_sequencer
