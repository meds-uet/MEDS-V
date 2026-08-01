# Example 04 -- the six MEDS-V benchmark kernels.  Copyright 2026 MEDS. Apache-2.0
include ../common/common.mk

N ?= 1024
SRC := ../common/crt.S bench_main.c kernels_scalar.c kernels_rvv.c

# Correctness oracle: vector kernels vs scalar references, under QEMU.
check.elf: check_qemu.c kernels_rvv.c kernels_scalar.c
	$(CC) -march=rv64gcv $(HOSTFLAGS) $^ -o $@

check: check.elf
	@for v in 128 256 512; do \
	  echo "===== VLEN=$$v ====="; \
	  qemu-riscv64 -cpu rv64,v=true,vlen=$$v,elen=64,vext_spec=v1.0 ./check.elf; \
	done

# Instruction-count benchmark across all six kernels.
bench:
	@python3 ../../scripts/bench_kernels.py --n $(N)

clean: ; rm -f *.elf

.PHONY: check bench clean
