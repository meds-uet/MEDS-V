# Example 03 -- vector-length agnosticism.  Copyright 2026 MEDS. Apache-2.0
include ../common/common.mk

TARGET := stripmine

# Hosted build: newlib gives us printf, QEMU user mode runs it.
# NOTE: no -zvl flag here -- the binary must NOT be specialised to a VLEN.
$(TARGET).elf: $(TARGET).c
	$(CC) -march=rv64gcv $(HOSTFLAGS) $< -o $@

run: $(TARGET).elf
	@$(QEMU) ./$(TARGET).elf

# The whole point: one binary, three machines, no recompilation.
run-all: $(TARGET).elf
	@for v in 128 256 512; do \
	  echo "================ VLEN=$$v ================"; \
	  qemu-riscv64 -cpu rv64,v=true,vlen=$$v,elen=64,vext_spec=v1.0 ./$(TARGET).elf; \
	  echo; \
	done

clean: ; rm -f *.elf

.PHONY: run run-all clean
