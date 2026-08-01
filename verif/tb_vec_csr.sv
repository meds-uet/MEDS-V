// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// Unit testbench for MEDS-V block (2), the CSR / vtype unit.
//
// This is the reference testbench: it shows the shape every other unit
// testbench in the project should take, and it exercises the four subtleties
// of Book Ch 4 that teams most often get wrong.
//
//   1. vl = min(AVL, VLMAX) across the whole VLMAX range
//   2. the four AVL special cases (rs1==x0 and rd==x0 combinations)
//   3. vill on unsupported vtype -- and NO trap
//   4. the signed vlmul encoding, including fractional LMUL
//
// Run:  make -C verif tb_vec_csr
// =============================================================================

module tb_vec_csr;

  import meds_v_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // DUT connections
  logic            set_valid;
  logic [10:0]     set_zimm;
  logic [XLEN-1:0] set_avl;
  logic            set_avl_is_max, set_keep_vl;
  logic [XLEN-1:0] set_vl;
  vtype_t          vtype;
  logic [VL_W-1:0] vl, vstart;
  logic [11:0]     csr_addr;
  logic [XLEN-1:0] csr_rdata;

  int unsigned errors = 0;
  int unsigned checks = 0;

  vec_csr u_dut (
    .clk_i            (clk),
    .rst_ni           (rst_n),
    .set_valid_i      (set_valid),
    .set_zimm_i       (set_zimm),
    .set_avl_i        (set_avl),
    .set_avl_is_max_i (set_avl_is_max),
    .set_keep_vl_i    (set_keep_vl),
    .set_vl_o         (set_vl),
    .vtype_o          (vtype),
    .vl_o             (vl),
    .vstart_o         (vstart),
    .instr_retire_i   (1'b0),
    .vstart_we_i      (1'b0),
    .vstart_i         ('0),
    .csr_addr_i       (csr_addr),
    .csr_rdata_o      (csr_rdata)
  );

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function automatic logic [10:0] mk_zimm(logic [2:0] lmul, logic [2:0] sew,
                                          logic ta, logic ma);
    mk_zimm = {3'b000, ma, ta, sew, lmul};
  endfunction

  task automatic do_vsetvli(input logic [10:0] zimm, input logic [XLEN-1:0] avl,
                            input logic is_max = 1'b0, input logic keep = 1'b0);
    @(negedge clk);
    set_valid      = 1'b1;
    set_zimm       = zimm;
    set_avl        = avl;
    set_avl_is_max = is_max;
    set_keep_vl    = keep;
    @(negedge clk);
    set_valid      = 1'b0;
    set_avl_is_max = 1'b0;
    set_keep_vl    = 1'b0;
  endtask

  task automatic check(input string name, input int unsigned got,
                       input int unsigned exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  FAIL  %-46s got=%0d expected=%0d", name, got, exp);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------
  initial begin
    set_valid = 1'b0; set_zimm = '0; set_avl = '0;
    set_avl_is_max = 1'b0; set_keep_vl = 1'b0; csr_addr = 12'hC22;

    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    $display("");
    $display("=== tb_vec_csr : VLEN=%0d  ELEN=%0d  VL_W=%0d ===", VLEN, ELEN, VL_W);
    $display("");

    // -------------------------------------------------------------------------
    // 1. vlenb must report VLEN/8. This is how software discovers the machine.
    // -------------------------------------------------------------------------
    csr_addr = 12'hC22;
    #1 check("vlenb == VLEN/8", int'(csr_rdata), VLEN / 8);

    // -------------------------------------------------------------------------
    // 2. vl = min(AVL, VLMAX) for e32,m1.  VLMAX = VLEN/32.
    // -------------------------------------------------------------------------
    begin
      automatic int unsigned vlmax32 = VLEN / 32;
      for (int unsigned avl = 0; avl <= vlmax32 + 4; avl++) begin
        do_vsetvli(mk_zimm(3'b000, 3'b010, 1'b1, 1'b1), XLEN'(avl));
        check($sformatf("e32,m1 AVL=%0d -> vl", avl),
              int'(vl), (avl < vlmax32) ? avl : vlmax32);
      end
    end

    // -------------------------------------------------------------------------
    // 3. VLMAX scales with SEW and LMUL.  These are the numbers from the
    //    worked table in Book Ch 4 section 4.2.
    // -------------------------------------------------------------------------
    do_vsetvli(mk_zimm(3'b000, 3'b000, 1'b1, 1'b1), 64'hFFFF); // e8,  m1
    check("e8,m1   VLMAX", int'(vl), VLEN / 8);
    do_vsetvli(mk_zimm(3'b000, 3'b001, 1'b1, 1'b1), 64'hFFFF); // e16, m1
    check("e16,m1  VLMAX", int'(vl), VLEN / 16);
    do_vsetvli(mk_zimm(3'b011, 3'b010, 1'b1, 1'b1), 64'hFFFF); // e32, m8
    check("e32,m8  VLMAX", int'(vl), 8 * VLEN / 32);
    do_vsetvli(mk_zimm(3'b111, 3'b010, 1'b1, 1'b1), 64'hFFFF); // e32, mf2
    check("e32,mf2 VLMAX", int'(vl), VLEN / 32 / 2);
    do_vsetvli(mk_zimm(3'b101, 3'b000, 1'b1, 1'b1), 64'hFFFF); // e8,  mf8
    check("e8,mf8  VLMAX", int'(vl), VLEN / 8 / 8);

    // -------------------------------------------------------------------------
    // 3b. vsetvli must RETURN the new vl in rd.  The whole stripmine loop is
    //     built on this: software advances its pointers by the returned value
    //     (Book Ch 7 section 7.1).  A unit that computed vl correctly but
    //     reported it wrongly would break every vector program.
    // -------------------------------------------------------------------------
    begin
      automatic int unsigned vlmax32 = VLEN / 32;
      @(negedge clk);
      set_valid = 1'b1;
      set_zimm  = mk_zimm(3'b000, 3'b010, 1'b1, 1'b1);
      set_avl   = XLEN'(vlmax32) + 64'd3;    // more than VLMAX -> expect clamp
      #1 check("vsetvli returns new vl in rd", int'(set_vl), vlmax32);
      @(negedge clk);
      set_valid = 1'b0;
    end

    // -------------------------------------------------------------------------
    // 4. vtype fields must round-trip, including the policy bits.
    // -------------------------------------------------------------------------
    do_vsetvli(mk_zimm(3'b001, 3'b001, 1'b0, 1'b1), 64'd4);    // e16,m2,tu,ma
    check("vtype.vsew  == SEW16", int'(vtype.vsew),  int'(SEW16));
    check("vtype.vlmul == LMUL_2", int'(vtype.vlmul), int'(LMUL_2));
    check("vtype.vta   == 0 (tu)", int'(vtype.vta),   0);
    check("vtype.vma   == 1 (ma)", int'(vtype.vma),   1);
    check("vtype.vill  == 0",      int'(vtype.vill),  0);

    // -------------------------------------------------------------------------
    // 5. The four AVL cases (Book Ch 4 section 4.4).
    //    rs1==x0 means "AVL is infinite" or "keep vl" -- NEVER "AVL = 0".
    // -------------------------------------------------------------------------
    do_vsetvli(mk_zimm(3'b000, 3'b010, 1'b1, 1'b1), 64'd2);
    check("setup: vl = 2", int'(vl), 2);

    // rd != x0, rs1 == x0  ->  vl = VLMAX
    do_vsetvli(mk_zimm(3'b000, 3'b010, 1'b1, 1'b1), 64'd0, /*is_max*/ 1'b1);
    check("rs1==x0,rd!=x0 -> vl = VLMAX", int'(vl), VLEN / 32);

    // rd == x0, rs1 == x0  ->  vl unchanged, vtype changed
    do_vsetvli(mk_zimm(3'b001, 3'b001, 1'b1, 1'b1), 64'd0, 1'b0, /*keep*/ 1'b1);
    check("rs1==x0,rd==x0 -> vl kept",    int'(vl), VLEN / 32);
    check("rs1==x0,rd==x0 -> vtype changed", int'(vtype.vsew), int'(SEW16));

    // AVL = 0 (a real zero in rs1) must give vl = 0.
    do_vsetvli(mk_zimm(3'b000, 3'b010, 1'b1, 1'b1), 64'd0);
    check("AVL=0 -> vl = 0", int'(vl), 0);

    // -------------------------------------------------------------------------
    // 6. vill: an unsupported vtype sets vill, zeroes the other fields and
    //    sets vl = 0 -- and does NOT trap.
    // -------------------------------------------------------------------------
    do_vsetvli(mk_zimm(3'b100, 3'b010, 1'b1, 1'b1), 64'd8);   // reserved vlmul
    check("reserved vlmul -> vill", int'(vtype.vill), 1);
    check("reserved vlmul -> vl=0", int'(vl),         0);
    check("vill zeroes vta",        int'(vtype.vta),  0);
    check("vill zeroes vma",        int'(vtype.vma),  0);

    do_vsetvli(mk_zimm(3'b000, 3'b100, 1'b1, 1'b1), 64'd8);   // reserved vsew
    check("reserved vsew -> vill", int'(vtype.vill), 1);

    // SEW must not exceed ELEN.  With ELEN=32, e64 is unsupported.
    if (ELEN < 64) begin
      do_vsetvli(mk_zimm(3'b000, 3'b011, 1'b1, 1'b1), 64'd8); // e64
      check("e64 on ELEN=32 -> vill", int'(vtype.vill), 1);
    end

    // A legal vtype after an illegal one must clear vill.
    do_vsetvli(mk_zimm(3'b000, 3'b010, 1'b1, 1'b1), 64'd4);
    check("legal vtype clears vill", int'(vtype.vill), 0);

    // -------------------------------------------------------------------------
    // 7. The stripmine guarantee: vl > 0 whenever AVL > 0.  If this ever fails,
    //    every stripmine loop in existence hangs forever (Book Ch 7 section 7.1).
    // -------------------------------------------------------------------------
    for (int unsigned avl = 1; avl <= 40; avl++) begin
      do_vsetvli(mk_zimm(3'b000, 3'b010, 1'b1, 1'b1), XLEN'(avl));
      checks++;
      if (vl == 0) begin
        errors++;
        $display("  FAIL  vl == 0 for AVL = %0d  (stripmine loop would hang)", avl);
      end
    end

    // -------------------------------------------------------------------------
    $display("");
    if (errors == 0)
      $display("=== PASS : %0d checks ===", checks);
    else
      $display("=== FAIL : %0d error(s) out of %0d checks ===", errors, checks);
    $display("");
    if (errors != 0) $fatal(1, "tb_vec_csr failed");
    $finish;
  end

  // Watchdog
  initial begin
    #200000;
    $fatal(1, "tb_vec_csr timeout");
  end

endmodule : tb_vec_csr
