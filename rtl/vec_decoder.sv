// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// MEDS-V Block (1) : Vector Decoder                          [SKELETON -- M1]
//
// Turns a 32-bit instruction word into a vec_uop_t control bundle, and flags
// illegal encodings.
//
// KEY RULE (Book Ch 5 section 5.1): decode on {funct6, funct3} JOINTLY.
// funct6 alone is ambiguous -- vsll.vv and vmul.vv both use funct6 = 100101
// and differ only in funct3.  A funct6-only case statement compiles fine and
// silently multiplies when asked to shift.
//
// Sections marked TODO are yours to complete.  The structure, the field
// extraction and the legality checks are given.
// =============================================================================

module vec_decoder
  import meds_v_pkg::*;
(
  input  logic [31:0]      instr_i,
  input  logic [XLEN-1:0]  rs1_val_i,
  input  vtype_t           vtype_i,
  input  logic             vs_enabled_i,     // mstatus.VS != Off

  output vec_uop_t         uop_o,
  output logic             illegal_o,

  // vsetvl{i} fields, forwarded to the CSR unit (block 2)
  output logic             set_valid_o,
  output logic [10:0]      set_zimm_o,
  output logic             set_avl_is_max_o,
  output logic             set_keep_vl_o
);

  // ---------------------------------------------------------------------------
  // Field extraction.  All positions verified against the GNU assembler --
  // see Book Ch 5.
  // ---------------------------------------------------------------------------
  logic [6:0]  opcode;
  logic [2:0]  funct3;
  logic [5:0]  funct6;
  logic [4:0]  vd, vs1, vs2, rd, rs1;
  logic        vm;
  logic [2:0]  width;
  logic [1:0]  mop;
  logic [4:0]  lumop;
  logic        mew;
  logic [2:0]  nf;

  assign opcode = instr_i[6:0];
  assign funct3 = instr_i[14:12];
  assign funct6 = instr_i[31:26];
  assign vd     = instr_i[11:7];
  assign rd     = instr_i[11:7];
  assign vs1    = instr_i[19:15];
  assign rs1    = instr_i[19:15];
  assign vs2    = instr_i[24:20];
  assign vm     = instr_i[25];
  assign width  = instr_i[14:12];
  assign mop    = instr_i[27:26];
  assign lumop  = instr_i[24:20];
  assign mew    = instr_i[28];
  assign nf     = instr_i[31:29];

  // OPIVI carries a 5-bit SIGNED immediate in the vs1 field.
  logic [XLEN-1:0] imm_i5;
  assign imm_i5 = {{(XLEN-5){vs1[4]}}, vs1};

  // ---------------------------------------------------------------------------
  // Instruction class
  // ---------------------------------------------------------------------------
  logic is_op_v, is_load, is_store, is_config;
  assign is_op_v   = (opcode == OPCODE_OP_V);
  assign is_load   = (opcode == OPCODE_LOAD_FP)  && !is_scalar_fp_width(width);
  assign is_store  = (opcode == OPCODE_STORE_FP) && !is_scalar_fp_width(width);
  assign is_config = is_op_v && (funct3 == OPCFG);

  // Vector loads/stores share their opcodes with scalar FP loads/stores; the
  // width field distinguishes them.  width = 010 (flw) and 011 (fld) are scalar.
  function automatic logic is_scalar_fp_width(logic [2:0] w);
    is_scalar_fp_width = (w == 3'b001) || (w == 3'b010) ||
                         (w == 3'b011) || (w == 3'b100);
  endfunction

  // ---------------------------------------------------------------------------
  // vsetvl{i} form detection (Book Ch 4 section 4.4)
  //   inst[31]      == 0  -> vsetvli   (zimm in inst[30:20])
  //   inst[31:30]   == 11 -> vsetivli  (zimm in inst[29:20], uimm in inst[19:15])
  //   inst[31:25]   == 1000000 -> vsetvl (vtype from rs2)
  // ---------------------------------------------------------------------------
  logic is_vsetvli, is_vsetivli, is_vsetvl;
  assign is_vsetvli  = is_config && (instr_i[31] == 1'b0);
  assign is_vsetivli = is_config && (instr_i[31:30] == 2'b11);
  assign is_vsetvl   = is_config && (instr_i[31:25] == 7'b1000000);

  assign set_valid_o      = is_config;
  assign set_zimm_o       = is_vsetivli ? {1'b0, instr_i[29:20]} : instr_i[30:20];
  // rs1 == x0 with rd != x0 means "AVL = infinity"; with rd == x0 it means
  // "keep the current vl".  It never means AVL = 0.
  assign set_avl_is_max_o = is_vsetvli && (rs1 == 5'd0) && (rd != 5'd0);
  assign set_keep_vl_o    = is_vsetvli && (rs1 == 5'd0) && (rd == 5'd0);

  // ---------------------------------------------------------------------------
  // EEW / EMUL derivation.
  //   Arithmetic ops:  EEW = SEW,  EMUL = LMUL
  //   Loads/stores:    EEW from the width field, EMUL = LMUL * EEW / SEW
  // See Book Ch 4 section 4.10.
  // ---------------------------------------------------------------------------
  sew_e  eew;
  lmul_e emul;
  logic  emul_out_of_range;

  always_comb begin
    if (is_load || is_store) begin
      unique case ({mew, width})
        4'b0_000: eew = SEW8;
        4'b0_101: eew = SEW16;
        4'b0_110: eew = SEW32;
        4'b0_111: eew = SEW64;
        default:  eew = SEW_RSVD;
      endcase
    end else begin
      eew = vtype_i.vsew;
    end
  end

  // EMUL = LMUL * EEW / SEW.  In log2 terms: emul = vlmul + log2(EEW) - log2(SEW),
  // computed as a signed 3-bit field exactly like vlmul itself.
  logic signed [4:0] emul_log2;
  always_comb begin
    emul_log2 = $signed({{2{vtype_i.vlmul[2]}}, vtype_i.vlmul})
              + $signed(5'(sew_log2(eew)))
              - $signed(5'(sew_log2(vtype_i.vsew)));
    emul_out_of_range = (emul_log2 > 3) || (emul_log2 < -3);
    emul = lmul_e'(emul_log2[2:0]);
  end

  // ---------------------------------------------------------------------------
  // TODO (M1): the primary {funct6, funct3} operation lookup.
  //
  // Build the case statement from the verified table in Book Ch 5 sections
  // 5.4-5.9.  Cross-check EVERY entry by assembling the instruction:
  //     echo 'vadd.vv v1,v2,v3' | riscv64-unknown-elf-as -march=rv64gcv -
  //     riscv64-unknown-elf-objdump -d a.out
  //
  // Remember the third decode level: for funct6 in {010000, 010010, 010100}
  // the vs1 field acts as an opcode extension (vmv.x.s, vcpop.m, vid.v, ...).
  // ---------------------------------------------------------------------------
  vec_op_e op;
  logic    op_valid;

  always_comb begin
    op       = VOP_NONE;
    op_valid = 1'b0;

    if (is_config) begin
      op       = VOP_VSETVL;
      op_valid = 1'b1;
    end else if (is_load) begin
      op       = VOP_LOAD;
      op_valid = 1'b1;
    end else if (is_store) begin
      op       = VOP_STORE;
      op_valid = 1'b1;
    end else if (is_op_v) begin
      unique case ({funct6, funct3})
        // ---- OPIVV / OPIVX / OPIVI : integer ALU -----------------------------
        {6'b000000, OPIVV}, {6'b000000, OPIVX}, {6'b000000, OPIVI}:
          begin op = VOP_ADD;  op_valid = 1'b1; end
        {6'b000010, OPIVV}, {6'b000010, OPIVX}:
          begin op = VOP_SUB;  op_valid = 1'b1; end
        {6'b000011, OPIVX}, {6'b000011, OPIVI}:
          begin op = VOP_RSUB; op_valid = 1'b1; end
        {6'b001001, OPIVV}, {6'b001001, OPIVX}, {6'b001001, OPIVI}:
          begin op = VOP_AND;  op_valid = 1'b1; end
        {6'b001010, OPIVV}, {6'b001010, OPIVX}, {6'b001010, OPIVI}:
          begin op = VOP_OR;   op_valid = 1'b1; end
        {6'b001011, OPIVV}, {6'b001011, OPIVX}, {6'b001011, OPIVI}:
          begin op = VOP_XOR;  op_valid = 1'b1; end

        // NOTE the funct6 collision with vmul below -- this is why the case
        // key includes funct3.
        {6'b100101, OPIVV}, {6'b100101, OPIVX}, {6'b100101, OPIVI}:
          begin op = VOP_SLL;  op_valid = 1'b1; end
        {6'b100101, OPMVV}, {6'b100101, OPMVX}:
          begin op = VOP_MUL;  op_valid = 1'b1; end

        // TODO: vsrl (101000), vsra (101001)
        // TODO: vmin/vminu/vmax/vmaxu (000100..000111)
        // TODO: comparisons vmseq..vmsleu (011000..011101)
        // TODO: vmulh (100111 OPMVV), vmulhu (100100 OPMVV)
        // TODO: vmacc (101101 OPMVV), vwmacc (111101 OPMVV)
        // TODO: vwadd (110001 OPMVV), vwaddu (110000 OPMVV), vwmul (111011 OPMVV)
        // TODO: vmerge / vmv.v.* (010111, disambiguated by vm and vs2)
        // TODO: vredsum (000000 OPMVV), vredmax (000111 OPMVV)
        // TODO: vmand/vmor/vmxor (011001/011010/011011 OPMVV)
        // TODO: vid.v, vmv.x.s, vcpop.m, vfirst.m -- vs1-field secondary decode

        default: begin op = VOP_NONE; op_valid = 1'b0; end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Legality checks (Book Ch 9 section 9.1).  All six are exercised by the
  // RISC-V architectural test suite.
  // ---------------------------------------------------------------------------
  logic [3:0] emul_mask;              // (EMUL-1) for alignment checking
  logic       align_violation;

  always_comb begin
    unique case (emul)
      LMUL_2:  emul_mask = 4'b0001;
      LMUL_4:  emul_mask = 4'b0011;
      LMUL_8:  emul_mask = 4'b0111;
      default: emul_mask = 4'b0000;   // LMUL <= 1: no alignment requirement
    endcase

    align_violation = |(vd[3:0]  & emul_mask)
                    | |(vs1[3:0] & emul_mask)
                    | |(vs2[3:0] & emul_mask);
  end

  logic writes_mask;
  assign writes_mask = (op == VOP_MSEQ) || (op == VOP_MSNE) || (op == VOP_MSLT)
                     || (op == VOP_MSLTU) || (op == VOP_MSLE) || (op == VOP_MSLEU)
                     || (op == VOP_MAND) || (op == VOP_MOR)  || (op == VOP_MXOR)
                     || (op == VOP_MNOT);

  always_comb begin
    illegal_o = 1'b0;

    // 1. Vector unit disabled -- traps EVERY vector instruction, vsetvli included.
    if (!vs_enabled_i)                                  illegal_o = 1'b1;

    // 2. vill is set and this is not a vsetvl{i}.
    if (vtype_i.vill && !is_config)                     illegal_o = 1'b1;

    // 3. Register-group alignment for EMUL > 1.
    if (!is_config && align_violation)                  illegal_o = 1'b1;

    // 4. A masked instruction must not write v0, unless it writes a mask.
    if (!is_config && !vm && (vd == 5'd0) && !writes_mask) illegal_o = 1'b1;

    // 5. EMUL out of the 1/8 .. 8 range is a reserved encoding.
    if (!is_config && emul_out_of_range)                illegal_o = 1'b1;

    // 6. Unrecognised encoding.
    if (!op_valid)                                      illegal_o = 1'b1;

    // TODO (M2): widening / narrowing source-destination overlap rules,
    //            Book Ch 4 section 4.10.
  end

  // ---------------------------------------------------------------------------
  // Assemble the control bundle.
  // ---------------------------------------------------------------------------
  always_comb begin
    uop_o              = '0;
    uop_o.valid        = op_valid && !illegal_o;
    uop_o.op           = op;
    uop_o.fmt          = vfmt_e'(funct3);
    uop_o.vd           = vd;
    uop_o.vs1          = vs1;
    uop_o.vs2          = vs2;
    uop_o.vm           = vm;
    uop_o.eew          = eew;
    uop_o.emul         = emul;
    uop_o.is_load      = is_load;
    uop_o.is_store     = is_store;
    uop_o.mop          = mop_e'(mop);
    uop_o.writes_mask  = writes_mask;

    // Second operand source: OPIVI takes the sign-extended 5-bit immediate,
    // OPIVX / OPMVX take the forwarded rs1 value, OPIVV takes vs1.
    unique case (vfmt_e'(funct3))
      OPIVI:          begin uop_o.use_scalar = 1'b1; uop_o.scalar_op = imm_i5;    end
      OPIVX, OPMVX:   begin uop_o.use_scalar = 1'b1; uop_o.scalar_op = rs1_val_i; end
      default:        begin uop_o.use_scalar = 1'b0; uop_o.scalar_op = rs1_val_i; end
    endcase

    uop_o.writes_vrf = op_valid && !is_config && !is_store;
    uop_o.writes_xrf = is_config;    // TODO: also vmv.x.s, vcpop.m, vfirst.m
  end

  // ---------------------------------------------------------------------------
  // Explicit tie-offs for fields that are decoded but not yet consumed.  Keeping
  // them here (rather than deleting the signals) means the extraction logic is
  // already correct when you implement the corresponding TODO, and it keeps the
  // linter quiet without blanket waivers.
  //   nf        -> segment loads/stores      (deferred, Book Ch 5 section 5.12)
  //   lumop     -> whole-register / mask / fault-only-first loads
  //   is_vsetvl -> the register form of vsetvl (vtype from rs2)
  //   vta/vma   -> consumed by the sequencer, not the decoder
  // ---------------------------------------------------------------------------
  logic _unused;
  assign _unused = |nf | |lumop | is_vsetvl | vtype_i.vta | vtype_i.vma;

endmodule : vec_decoder
