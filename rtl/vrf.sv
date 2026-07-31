// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// MEDS-V Block (4) : Vector Register File
//
// 32 registers x VLEN bits.  Dumb, wide storage: it does NOT know about SEW,
// LMUL or masks.  All of that lives in the sequencer, which presents this
// module with a plain byte-enable.  See Book Ch 9 section 9.3.
//
// Three read ports (vs1, vs2, vd-for-accumulate) plus a dedicated v0 port,
// because the mask is always v0 (Book Ch 4 section 4.7) so there is no reason
// to arbitrate for it.
//
// Milestone M2.
// =============================================================================

module vrf
  import meds_v_pkg::*;
#(
  parameter int unsigned NR_READ_PORTS = 3
)(
  input  logic                     clk_i,
  input  logic                     rst_ni,

  // ---- read ports ----------------------------------------------------------
  input  logic [4:0]               raddr_i [NR_READ_PORTS],
  output logic [VLEN-1:0]          rdata_o [NR_READ_PORTS],

  // ---- write port, byte granular -------------------------------------------
  input  logic                     we_i,
  input  logic [4:0]               waddr_i,
  input  logic [VLEN-1:0]          wdata_i,
  input  logic [VLENB-1:0]         wbe_i,

  // ---- dedicated mask read (always v0) -------------------------------------
  output logic [VLEN-1:0]          v0_o
);

  // ---------------------------------------------------------------------------
  // Storage.
  //
  // Option 1 from Book Ch 9 section 9.3: a flat array.  Synthesises to flops --
  // 32 * VLEN of them.  Trivially correct, and correct is what M2 needs.
  //
  // When you add lanes in M6, replace this with NR_LANES independent slices of
  // VLEN/NR_LANES bits each (Option 2).  The port list above does not change,
  // which is the point of keeping the interface VLEN-wide.
  // ---------------------------------------------------------------------------
  logic [VLEN-1:0] mem [0:31];

  // ---------------------------------------------------------------------------
  // Reads: combinational.  Note there is NO special case for v0 -- unlike the
  // scalar x0, vector register v0 is an ordinary register that merely happens
  // to be where masks live.
  // ---------------------------------------------------------------------------
  always_comb begin
    for (int unsigned p = 0; p < NR_READ_PORTS; p++)
      rdata_o[p] = mem[raddr_i[p]];
  end

  assign v0_o = mem[0];

  // ---------------------------------------------------------------------------
  // Write: byte enables.  This one loop is what implements the tail policy,
  // masking and vstart -- the sequencer folds all three into wbe_i.
  // Book Ch 4 section 4.8 explains why building only the "undisturbed" path
  // makes us compliant with the agnostic policies too.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Zero on reset: keeps simulation X-free and deterministic.
      for (int unsigned r = 0; r < 32; r++)
        mem[r] <= '0;
    end else if (we_i) begin
      for (int unsigned b = 0; b < VLENB; b++)
        if (wbe_i[b])
          mem[waddr_i][b*8 +: 8] <= wdata_i[b*8 +: 8];
    end
  end

`ifndef SYNTHESIS
  // Read-during-write behaviour is READ-OLD (the always_ff updates after the
  // always_comb reads).  Documented deliberately -- see the "Done when" list
  // in Book Ch 9 section 9.3.
`endif

endmodule : vrf
