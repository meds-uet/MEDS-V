/* Bare-metal layout for Spike: RAM starts at 0x80000000. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text   : { *(.text.init) *(.text*)   }
  .rodata : { *(.rodata*) *(.srodata*)  }
  .data   : { *(.data*)   *(.sdata*)    }
  .bss    : { *(.bss*)    *(.sbss*) *(COMMON) }
  _stack_top = .;
}
