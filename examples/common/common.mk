# Shared build rules for the MEDS-V RVV examples.
# Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0

CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJDUMP := $(CROSS)objdump

COMMON  := $(dir $(lastword $(MAKEFILE_LIST)))

# VLEN used by the simulators. Override on the command line:  make VLEN=512
VLEN    ?= 128

ARCH_V  := rv64gcv_zvl$(VLEN)b
ARCH_S  := rv64gc

# Bare-metal flags (Spike). medany is required because we link at 0x80000000.
# -fno-tree-loop-distribute-patterns stops GCC turning an init loop into a
# call to memset(), which does not exist in a -nostdlib build.
# --no-warn-rwx-segments silences a harmless linker warning about our flat layout.
BAREFLAGS := -mabi=lp64d -mcmodel=medany -O2 -nostdlib -nostartfiles \
             -fno-tree-loop-distribute-patterns \
             -Wl,--no-warn-rwx-segments \
             -T $(COMMON)link.ld -I$(COMMON)
# Hosted flags (QEMU user mode, full newlib with printf).
HOSTFLAGS := -mabi=lp64d -O2

SPIKE   := spike --isa=$(ARCH_V)
QEMU    := qemu-riscv64 -cpu rv64,v=true,vlen=$(VLEN),elen=64,vext_spec=v1.0

# Count committed instructions for an ELF under Spike.
define count_instr
$(shell $(SPIKE) -l $(1) 2>&1 | grep -c '^core   0:')
endef
