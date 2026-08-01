# Appendix C — Toolchain Setup

The exact toolchain every measurement in this book was produced on, plus what each tool is
for and how to check it works.

---

## C.1 Verified versions

| Tool | Version used | Purpose |
|---|---|---|
| `riscv64-unknown-elf-gcc` | 15.2.0 | Compiler, assembler, linker, objdump |
| `spike` | 1.1.1-dev | **Golden reference model**, traces, instruction counts |
| `qemu-riscv64` | 10.2.0 | Fast user-mode emulation, `printf` |
| `verilator` | 5.020 | RTL lint and simulation |
| `iverilog` | 12.0 | Alternative simulator |
| `gtkwave` | — | Waveform viewer |
| `python3` | 3.12.3 | Benchmark and comparison scripts |
| `make`, `git` | — | |

Nothing here needs to be matched exactly, but two things matter:

- **The compiler must support RVV 1.0 intrinsics with the `__riscv_` prefix.** GCC 13+ or
  Clang 16+. Older toolchains use unprefixed names and will not build the examples.
- **Spike must accept `Zvl<N>b` in the ISA string** (see §C.4).

---

## C.2 Quick check

```bash
riscv64-unknown-elf-gcc --version
spike --help | head -1
qemu-riscv64 --version
verilator --version
```

Then confirm the compiler can actually build vector code:

```bash
cat > /tmp/v.c <<'CEOF'
#include <riscv_vector.h>
void f(size_t n, float a, const float *x, float *y) {
  for (size_t vl; n > 0; n -= vl, x += vl, y += vl) {
    vl = __riscv_vsetvl_e32m8(n);
    __riscv_vse32_v_f32m8(y, __riscv_vfmacc_vf_f32m8(
        __riscv_vle32_v_f32m8(y, vl), a, __riscv_vle32_v_f32m8(x, vl), vl), vl);
  }
}
CEOF
riscv64-unknown-elf-gcc -march=rv64gcv -mabi=lp64d -O2 -S /tmp/v.c -o - | grep vsetvli
```

Expected output:

```
	vsetvli	a5,a0,e32,m8,ta,ma
```

If this fails with *"requires the 'v' ISA extension"*, the compiler is too old.

---

## C.3 The full check

```bash
cd /path/to/RVV
make -C examples/01-hello-vector run-all      # Spike, 3 VLENs -> PASS PASS PASS
make -C examples/03-stripmine run-all         # QEMU, 3 VLENs, prints vl per pass
make -C examples/04-workloads check           # 6 kernels vs scalar, 3 VLENs
make -C verif lint                            # RTL lint -> clean
make -C verif tb_vec_csr                      # unit test -> PASS : 73 checks
python3 scripts/param_sweep.py                # 16 configs -> all PASS
```

If all six pass, the environment is complete. This is the **M0 exit criterion for every
team member** (Chapter 11 §11.2).

---

## C.4 Tool-specific notes

### Spike — setting VLEN

VLEN comes from the ISA string:

```bash
spike --isa=rv64gcv_zvl128b prog.elf
spike --isa=rv64gcv_zvl512b prog.elf
```

> **Older Spike builds used `--varch=vlen:128,elen:64` instead.** The build used here
> rejects that flag. If `--varch` errors out, use the `_zvl<N>b` form; if `_zvl<N>b` is
> rejected, use `--varch`. `spike --help` settles it.

**Traces** — the input to co-simulation:

```bash
spike --isa=rv64gcv_zvl128b -l --log-commits prog.elf > spike.log 2>&1
```

Spike emits two interleaved line formats. Use the **commit** lines (privilege level before
the PC), not the `-l` disassembly lines — the latter are not one-per-instruction. Chapter 13
§13.4 has the detail.

**Instruction counts:**

```bash
spike --isa=rv64gcv_zvl128b -l prog.elf 2>&1 | grep -c '^core   0:'
```

### QEMU — setting VLEN

```bash
qemu-riscv64 -cpu rv64,v=true,vlen=128,elen=64,vext_spec=v1.0 ./prog.elf
```

> **Always pass `vext_spec=v1.0`.** QEMU can also emulate the incompatible 0.7.1 draft
> (Chapter 3 §3.3).

QEMU user mode runs newlib binaries with working `printf`, which makes it the right tool for
developing kernels. Spike is the right tool for verifying them.

### GCC — the flags that matter

| Flag | Why |
|---|---|
| `-march=rv64gcv` | Enable the V extension |
| `-march=rv64gcv_zvl256b` | ...and assume VLEN ≥ 256 |
| `-mabi=lp64d` | 64-bit ABI with hardware doubles |
| `-mcmodel=medany` | **Required** for bare metal at `0x80000000` |
| `-fno-tree-loop-distribute-patterns` | Stops GCC emitting `memset` calls in `-nostdlib` builds |
| `-fno-tree-vectorize` | Force a genuinely scalar baseline |
| `-fopt-info-vec` | Report what the auto-vectoriser did |
| `-Wl,--no-warn-rwx-segments` | Silence a harmless linker warning on flat layouts |

Two of these were learned the hard way:

- Without `-mcmodel=medany`: `relocation truncated to fit: R_RISCV_HI20`.
- Without `-fno-tree-loop-distribute-patterns`: `undefined reference to memset`, because
  GCC turned an array-init loop into a library call that a `-nostdlib` build cannot resolve.

Both are already set in `examples/common/common.mk`.

### Verilator

```bash
verilator --lint-only -Wall -Wno-UNUSEDPARAM --top-module meds_v_top rtl/*.sv
verilator --binary --timing --top-module tb_vec_csr rtl/meds_v_pkg.sv rtl/vec_csr.sv verif/tb_vec_csr.sv
```

`--binary` (Verilator 5+) builds a self-contained simulator, so no C++ harness is needed for
a self-checking SystemVerilog testbench. `--timing` is required for `#` delays.

Testbenches legitimately trip `UNUSEDSIGNAL` (probe signals) and `BLKSEQ` (a blocking clock
assignment), so `verif/Makefile` relaxes those two **for testbenches only**. The RTL is
linted with the full set.

---

## C.5 Building the toolchain from source

If packages are unavailable:

```bash
# GNU toolchain -- takes 30-60 minutes
git clone https://github.com/riscv-collab/riscv-gnu-toolchain
cd riscv-gnu-toolchain
./configure --prefix=$HOME/riscv --with-arch=rv64gcv --with-abi=lp64d
make -j$(nproc)

# Spike
git clone https://github.com/riscv-software-src/riscv-isa-sim
cd riscv-isa-sim && mkdir build && cd build
../configure --prefix=$HOME/riscv && make -j$(nproc) && make install

# Verilator -- prefer the distro package unless a specific version is needed
git clone https://github.com/verilator/verilator
cd verilator && autoconf && ./configure && make -j$(nproc) && sudo make install
```

Add to the shell profile:

```bash
export PATH=$HOME/riscv/bin:$PATH
```

---

## C.6 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `requires the 'v' ISA extension` | Missing `-march=rv64gcv` | Add it |
| `implicit declaration of __riscv_vsetvl_*` | Compiler too old, or unprefixed intrinsics | Upgrade to GCC 13+ |
| `relocation truncated to fit: R_RISCV_HI20` | Bare metal without `-mcmodel=medany` | Add it |
| `undefined reference to memset` | GCC synthesised a `memset` call | `-fno-tree-loop-distribute-patterns` |
| Bare-metal program hangs, no output | **`mstatus.VS` is Off** | `li t0,(1<<9); csrs mstatus,t0` |
| `spike: unrecognized option --varch` | Newer Spike | Use `--isa=rv64gcv_zvl128b` |
| QEMU runs but results are odd | Emulating RVV 0.7.1 | Add `vext_spec=v1.0` |
| `Cannot write build/.../Syms.cpp` | Missing output directory | `mkdir -p build` |
| Verilator `BLKLOOPINIT` at large VLEN | Non-blocking assignment to an array in a loop | Merge combinationally, assign once (Ch 12 §12.4) |
