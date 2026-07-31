# Example 02 -- SAXPY: scalar vs vector, measured.  Copyright 2026 MEDS. Apache-2.0
include ../common/common.mk

N ?= 1024
SRC := ../common/crt.S bench_main.c

all: base_s.elf saxpy_s.elf base_v.elf saxpy_v.elf

# Scalar-ISA builds (rv64gc): baseline harness, and harness + scalar kernel.
base_s.elf:  ; $(CC) -march=$(ARCH_S) $(BAREFLAGS) -DN=$(N) -DKERNEL=0 $(SRC) saxpy_scalar.c -o $@
saxpy_s.elf: ; $(CC) -march=$(ARCH_S) $(BAREFLAGS) -DN=$(N) -DKERNEL=1 $(SRC) saxpy_scalar.c -o $@

# Vector-ISA builds (rv64gcv): matched baseline, and harness + vector kernel.
base_v.elf:  ; $(CC) -march=$(ARCH_V) $(BAREFLAGS) -DN=$(N) -DKERNEL=0 $(SRC) saxpy_rvv.c -o $@
saxpy_v.elf: ; $(CC) -march=$(ARCH_V) $(BAREFLAGS) -DN=$(N) -DKERNEL=2 $(SRC) saxpy_rvv.c -o $@

bench: all
	@python3 ../../scripts/count_instr.py --n $(N)

asm:
	@echo "===== scalar inner loop ====="
	@$(CC) -march=$(ARCH_S) -mabi=lp64d -O2 -fno-tree-vectorize -S saxpy_scalar.c -o - \
	  | sed -n '/saxpy_scalar:/,/ret/p' | grep -vE '^\s*\.|^#'
	@echo "===== vector loop ====="
	@$(CC) -march=$(ARCH_V) -mabi=lp64d -O2 -S saxpy_rvv.c -o - \
	  | sed -n '/saxpy_rvv:/,/ret/p' | grep -vE '^\s*\.|^#'

clean: ; rm -f *.elf

.PHONY: all bench asm clean
