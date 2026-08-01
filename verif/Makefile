# Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
#
# Unit testbenches for MEDS-V.  Each block gets one; see Book Ch 13.

RTL      := ../rtl
BUILD    := build
VERILATOR:= verilator

# Testbenches legitimately have unused probe signals and a blocking clock
# assignment, so those two checks are relaxed HERE ONLY.  The RTL itself is
# linted with the full -Wall set by `make lint`.
VFLAGS := --binary -j 4 --timing -Wall \
          -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-BLKSEQ

PKG  := $(RTL)/meds_v_pkg.sv
CORE := $(RTL)/vec_decoder.sv $(RTL)/vec_csr.sv $(RTL)/vec_sequencer.sv \
        $(RTL)/vrf.sv $(RTL)/vec_lane.sv $(RTL)/vec_lsu.sv $(RTL)/meds_v_top.sv

TESTS := tb_vec_csr

.PHONY: all clean lint $(TESTS)

all: $(TESTS)

# ---- individual testbenches -------------------------------------------------
tb_vec_csr:
	@$(VERILATOR) $(VFLAGS) --top-module $@ $(PKG) $(RTL)/vec_csr.sv $@.sv \
	    -o $@ --Mdir $(BUILD)/$@ > /dev/null
	@./$(BUILD)/$@/$@

# TODO as the blocks land:
#   tb_vec_decoder   (M1)  -- sweep all 2048 vsetvli immediates vs Spike
#   tb_vrf           (M2)  -- byte-enable patterns, v0 port
#   tb_vec_lane      (M3)  -- every op x every SEW, incl. vsub operand order
#   tb_vec_sequencer (M3)  -- pass counts, RAW/WAR/WAW, the v0 mask hazard
#   tb_vec_lsu       (M4)  -- alignment, masked access, backpressure
#   tb_meds_v_top    (M4)  -- full co-simulation against Spike

# ---- lint the RTL with the full warning set ---------------------------------
lint:
	@$(VERILATOR) --lint-only -Wall -Wno-UNUSEDPARAM \
	    --top-module meds_v_top $(PKG) $(CORE) && echo "  RTL lint: clean"

clean:
	rm -rf $(BUILD)
