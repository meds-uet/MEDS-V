# Example 01 -- hello vector.  Copyright 2026 MEDS. Apache-2.0
include ../common/common.mk

TARGET := hello_vector

all: $(TARGET).elf

$(TARGET).elf: $(TARGET).c ../common/crt.S ../common/link.ld
	$(CC) -march=$(ARCH_V) $(BAREFLAGS) ../common/crt.S $(TARGET).c -o $@

run: $(TARGET).elf
	@echo "== Spike, VLEN=$(VLEN) =="
	@$(SPIKE) $(TARGET).elf && echo "PASS" || echo "FAIL (exit code = failing check number)"

# The same binary at three vector lengths -- vector-length agnosticism in action.
run-all: $(TARGET).elf
	@for v in 128 256 512; do \
	  printf "  VLEN=%-4s " $$v; \
	  spike --isa=rv64gcv_zvl$${v}b $(TARGET).elf >/dev/null 2>&1 && echo PASS || echo "FAIL"; \
	done

dis: $(TARGET).elf
	$(OBJDUMP) -d $(TARGET).elf | less

clean:
	rm -f *.elf *.o

.PHONY: all run run-all dis clean
