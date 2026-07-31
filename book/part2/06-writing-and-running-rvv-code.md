# Chapter 6 — Writing and Running RVV Code

> **Goal of this chapter.** Get every team member running vector code today, on the
> toolchain you already have. You cannot design hardware for an ISA you have never
> programmed.
>
> **This chapter is hands-on.** Have a terminal open.

Everything here has been run on the exact toolchain in Appendix C. All output shown is
captured, not illustrative.

---

## 6.1 Why you must write RVV code before designing RVV hardware

A recurring failure in hardware projects: the RTL team never uses the ISA. They implement
`vsetvli` from the spec text, get the `rs1 == x0` case wrong, and don't discover it for six
weeks because no test they wrote exercises it — because they'd never written the stripmine
loop that depends on it.

Writing the software first gives you:

- **An intuition for what's common.** You will discover that `vsetvli`, `vle`, `vse`, and
  three arithmetic ops are 90% of real code. That tells you what to optimise.
- **A golden reference.** Every program you write here becomes a test for your RTL later.
- **Test data.** Spike's commit log from these programs is exactly the co-simulation input
  Chapter 13 needs.

> **🎯 Milestone hook.** This chapter *is* milestone **M0**. Every team member, mentor and
> mentee, completes the exercises here before any RTL is written.

---

## 6.2 The three simulators, and what each is for

You have three ways to run RVV code, and they are **not** interchangeable. Pick by task.

| | **Spike** | **QEMU** | **Your RTL** |
|---|---|---|---|
| What it is | The official RISC-V **reference model** | Fast emulator | The thing you're building |
| Speed | ~10 MIPS | ~100+ MIPS | ~10 kHz |
| `printf` | Needs a proxy kernel or bare-metal I/O | **Yes**, user mode, works out of the box | No |
| Instruction trace | **Yes — `-l --log-commits`** | Awkward | Yes (your own) |
| Configurable VLEN | Yes, via `_zvl<N>b` in the ISA string | Yes, via `-cpu ...,vlen=N` | Your parameter |
| **Use it for** | **Golden reference, co-simulation, instruction counts** | **Developing and debugging your C** | Final verification |

**The rule:** develop in QEMU because it has `printf`; verify against Spike because it is
the reference model your hardware must match.

### Spike

```bash
# Bare-metal ELF, VLEN = 128
spike --isa=rv64gcv_zvl128b program.elf

# Same, with a full commit trace -- this is your co-simulation input
spike --isa=rv64gcv_zvl128b -l --log-commits program.elf
```

> **⚠️ Note on the VLEN flag.** Older Spike builds used `--varch=vlen:128,elen:64`. The
> build in Appendix C does **not** accept that flag and instead takes VLEN from the ISA
> string as `_zvl128b`. If `--varch` errors out, use the ISA-string form. Check with
> `spike --help`.

### QEMU

```bash
qemu-riscv64 -cpu rv64,v=true,vlen=128,elen=64,vext_spec=v1.0 ./program.elf
```

Note `vext_spec=v1.0` — QEMU can also emulate the **incompatible 0.7.1** draft. Always pass
it explicitly (Chapter 3 §3.3).

---

## 6.3 Hello, vector — your first program

Three ways to write RVV code, from lowest to highest level. You need to be fluent in the
first two.

### Level 1 — Inline assembly

Complete control, nothing hidden. This is how you'll write directed tests for your RTL.

```c
// examples/01-hello-vector/hello_vector.c  (excerpt)
asm volatile (
    "vsetvli t0, %2, e32, m1, ta, ma \n"
    "vle32.v v1, (%0)                \n"
    "vle32.v v2, (%1)                \n"
    "vadd.vv v3, v1, v2              \n"   // vd, vs2, vs1
    "vse32.v v3, (%3)                \n"
    :: "r"(src_a), "r"(src_b), "r"(vl), "r"(dst)
    : "t0", "v1", "v2", "v3", "memory");
```

Note the clobber list includes the vector registers and `"memory"`. Omit those and the
compiler will happily reorder your loads around the assembly block.

Run it:

```
$ cd examples/01-hello-vector && make run
== Spike, VLEN=128 ==
PASS
```

And the whole point of RVV, in one command — the **same ELF**, three machines:

```
$ make run-all
  VLEN=128  PASS
  VLEN=256  PASS
  VLEN=512  PASS
```

The example self-checks five things worth knowing about:
1. `vsetvli` clamps `vl` to VLMAX,
2. load–add–store produces correct results,
3. **elements beyond `vl` are not written** (the tail is real),
4. a short `vl` touches exactly `vl` elements,
5. **`vsub.vv v3, v2, v1` computes `v2 - v1`** — the operand-order trap from Chapter 5.

Check 5 is there because that bug is so easy to make. If you write an RTL ALU that computes
`vs1 - vs2`, this test catches it immediately.

### Level 2 — Intrinsics

Named C functions that map one-to-one onto instructions. The register allocator does the
work; you keep control of the instruction sequence. **This is how you should write your
benchmark kernels.**

```c
#include <riscv_vector.h>

size_t vl = __riscv_vsetvl_e32m1(n);
vfloat32m1_t vx = __riscv_vle32_v_f32m1(x, vl);
vfloat32m1_t vy = __riscv_vle32_v_f32m1(y, vl);
vy = __riscv_vfmacc_vf_f32m1(vy, a, vx, vl);
__riscv_vse32_v_f32m1(y, vy, vl);
```

The naming scheme is rigid, which makes it guessable:

```
   __riscv_ vfmacc _ vf _ f32m1
      │        │      │      │
      │        │      │      └── element type f32, LMUL = 1
      │        │      └───────── operand form: vector-scalar(float)
      │        └──────────────── the instruction
      └───────────────────────── prefix
```

Types follow the same pattern: `vint32m1_t`, `vuint8m4_t`, `vfloat32m8_t`,
`vint16mf2_t` (fractional LMUL = 1/2). Mask types are `vbool<N>_t`, where N is
**SEW/LMUL** — so `vbool32_t` is the mask type for `e32, m1`. That N is confusing at
first; it is the number of *bits per element position*, chosen so the type is unique.

> **⚠️ Trap — the `__riscv_` prefix.** Intrinsics were renamed in 2023. Older code uses
> bare `vsetvl_e32m1(...)`; current toolchains require `__riscv_vsetvl_e32m1(...)`. If you
> copy an example from a blog post and get "implicit declaration of function", this is why.

Every intrinsic takes `vl` as its **last argument**. That is not decoration — it is how the
compiler knows the operation is `vl`-dependent and must not be hoisted or merged.

### Level 3 — Autovectorisation

Write plain C, let GCC vectorise it:

```bash
riscv64-unknown-elf-gcc -march=rv64gcv -O3 kernel.c -c
```

This genuinely works — recall from Chapter 1 that GCC auto-vectorised our array-init loop
without being asked. But **do not rely on it for your benchmarks.** Small source changes
flip vectorisation on and off, making measurements irreproducible. Use `-fopt-info-vec` to
see what it did:

```bash
riscv64-unknown-elf-gcc -march=rv64gcv -O3 -fopt-info-vec kernel.c -c
```

Autovectorisation *is* useful for one thing: generating diverse RVV instruction sequences to
stress your RTL. Compile a pile of ordinary C at `-O3 -march=rv64gcv` and you get free test
cases.

---

## 6.4 Reading the generated assembly

The single most useful habit. `-S` gives you assembly; compare scalar and vector side by
side:

```
$ cd examples/02-saxpy && make asm
===== scalar inner loop =====
saxpy_scalar:
        ble     a0,zero,.L1
        slli    a0,a0,2
        add     a0,a2,a0
        flw     fa5,0(a1)
        flw     fa4,0(a2)
        addi    a2,a2,4
        addi    a1,a1,4
        fmadd.s fa5,fa5,fa0,fa4
        fsw     fa5,-4(a2)
        bne     a2,a0,.L3
        ret
===== vector loop =====
saxpy_rvv:
        beq     a0,zero,.L11
        vsetvli a5,a0,e32,m1,ta,ma
        vle32.v v2,0(a1)
        vle32.v v1,0(a2)
        slli    a4,a5,2
        sub     a0,a0,a5
        add     a1,a1,a4
        vfmacc.vf v1,fa0,v2
        vse32.v v1,0(a2)
        add     a2,a2,a4
        bne     a0,zero,.L3
        ret
```

Things to notice, and to point out to your mentees:

- The `vsetvli` is **inside** the loop. It must be — `vl` shrinks on the final pass.
- `slli a4, a5, 2` converts the returned `vl` into a byte offset (`vl × 4`). The pointer
  increment is **data-dependent on `vl`**, which is exactly why the code is VLEN-agnostic.
- There is **no remainder loop**. Compare with any SSE/NEON kernel you've seen.
- Four of the ten instructions are scalar bookkeeping. At large `vl` they're negligible;
  at `vl = 2` they dominate. That's Exercise 1.5.

To disassemble a built binary and see real encodings:

```bash
riscv64-unknown-elf-objdump -d program.elf | less
```

Keep this handy: it is how you check every table in Chapter 5, and how you'll debug your
own decoder.

---

## 6.5 Seeing vector-length agnosticism happen

Example 03 prints the `vl` chosen on every pass. This is captured output — **one binary,
three machines**:

```
$ cd examples/03-stripmine && make run-all
================ VLEN=128 ================
VLEN = 128 bits (vlenb = 16 bytes)
SEW = 32, LMUL = 1  =>  VLMAX = 4 elements

  pass   AVL    vl   elements processed
  ----  ----  ----   -------------------
     0    20     4   [ 0 ..  3]
     1    16     4   [ 4 ..  7]
     2    12     4   [ 8 .. 11]
     3     8     4   [12 .. 15]
     4     4     4   [16 .. 19]

  5 passes for 20 elements
  all 20 elements correct

================ VLEN=256 ================
VLEN = 256 bits (vlenb = 32 bytes)
SEW = 32, LMUL = 1  =>  VLMAX = 8 elements

  pass   AVL    vl   elements processed
  ----  ----  ----   -------------------
     0    20     8   [ 0 ..  7]
     1    12     8   [ 8 .. 15]
     2     4     4   [16 .. 19]

  3 passes for 20 elements
  all 20 elements correct

================ VLEN=512 ================
VLEN = 512 bits (vlenb = 64 bytes)
SEW = 32, LMUL = 1  =>  VLMAX = 16 elements

  pass   AVL    vl   elements processed
  ----  ----  ----   -------------------
     0    20    16   [ 0 .. 15]
     1     4     4   [16 .. 19]

  2 passes for 20 elements
  all 20 elements correct
```

Five passes, then three, then two. **Nothing was recompiled.** The loop restructured itself
because `vsetvli` reported a different `vl`.

Look at the VLEN=256 case: passes of 8, 8, 4. The hardware took `min(AVL, VLMAX)` each
time, exactly as Chapter 4 §4.4 recommended for MEDS-V. A machine that chose to balance the
last two passes would legally have produced 8, 6, 6 — and this program would still be
correct. That is what "the implementation may choose" means in practice.

> **🔧 Exercise 6.1.** Run `make run-all` with `N` changed to 17 and to 64. Predict the
> pass structure at each VLEN before running.

---

## 6.6 Measuring: instruction counts from Spike

Chapter 15 does this properly. The mechanism, though, is simple — count lines in Spike's
commit log:

```bash
spike --isa=rv64gcv_zvl128b -l program.elf 2>&1 | grep -c '^core   0:'
```

Example 02 wraps this into a benchmark:

```
$ cd examples/02-saxpy && make bench

SAXPY, N = 1024 elements -- committed instructions (Spike)

  configuration        kernel  instr/elem   speedup
  ------------------ -------- ----------- ---------
  scalar rv64gc          7188       7.020     1.00x
  RVV VLEN=128           2578       2.518     2.79x   (vl=4)
  RVV VLEN=256           1298       1.268     5.54x   (vl=8)
  RVV VLEN=512            658       0.643    10.92x   (vl=16)
```

> **⚠️ Trap — matched baselines.** The harness measures the *kernel*, so it subtracts a
> baseline build with the kernel call removed. **The baseline must be compiled with the
> same `-march` as the thing it's baselining.** We initially used one `rv64gc` baseline for
> everything and got *negative* kernel counts, because GCC had auto-vectorised the
> harness's own initialisation loop in the `rv64gcv` build, making the full program cheaper
> than its "baseline".
>
> The same trap applies to the self-check loop: if it runs only in the kernel builds and
> not the baseline, you charge the check to the kernel. Ours runs in all three builds
> against a per-kernel expected value, so it cancels.
>
> This is not a toy concern. It is the single easiest way to publish a wrong speedup
> number, and it is exactly the sort of thing a reviewer will find. Chapter 15 §15.3
> returns to it.

---

## 6.7 Generating a golden trace for co-simulation

This is the technique your whole verification strategy rests on, so learn it now.

```bash
spike --isa=rv64gcv_zvl128b -l --log-commits program.elf 2>&1 | grep '^core   0:'
```

Real captured output:

```
core   0: 0x000000008000000a (0x0d02f357) vsetvli t1, t0, e32, m1, ta, ma
core   0: 0x0000000080000016 (0x0203e087) vle32.v v1, (t2)
core   0: 0x000000008000001a (0x02108157) vadd.vv v2, v1, v1
core   0: 0x0000000080000026 (0x020e6127) vse32.v v2, (t3)
```

Each line gives the PC, the **raw instruction word**, and the disassembly. With
`--log-commits`, Spike also emits the architectural state each instruction changed.

This is gold. In Chapter 13 you will:
1. run a test program on Spike, capturing this trace;
2. run the same program on your RTL, capturing your own trace;
3. diff them.

The first instruction where they differ is your bug, with the PC that caused it. That is
enormously more useful than "the final answer is wrong".

> **🎯 Milestone hook.** Build the trace-comparison script at **M2**, before you have
> anything substantial to test with it. Chapter 13 §13.4 gives the format.

---

## 6.8 The `mstatus.VS` gotcha, again

Because it will happen to you:

```
Symptom:  bare-metal program hangs forever, or Spike times out with no output.
Cause:    mstatus.VS = Off, so the first vector instruction (usually vsetvli)
          traps as illegal, jumps to mtvec = 0, and loops.
Fix:      li t0, (1 << 9); csrs mstatus, t0     # before ANY vector instruction
```

This is handled for you in `examples/common/crt.S`. When you write your own startup code,
copy it. When your RTL is running and a test hangs at the first `vsetvli`, check this first.

---

## 6.9 A quick reference for the toolchain

```bash
# Compile with vectors, for a specific VLEN (bare metal)
riscv64-unknown-elf-gcc -march=rv64gcv_zvl128b -mabi=lp64d -mcmodel=medany \
    -O2 -nostdlib -nostartfiles -T link.ld crt.S prog.c -o prog.elf

# Compile hosted (newlib, printf works under QEMU) -- note: no _zvl, stays generic
riscv64-unknown-elf-gcc -march=rv64gcv -mabi=lp64d -O2 prog.c -o prog.elf

# Assembly only
riscv64-unknown-elf-gcc -march=rv64gcv -O2 -S prog.c -o prog.s

# Disassemble
riscv64-unknown-elf-objdump -d prog.elf

# Run (reference model)
spike --isa=rv64gcv_zvl128b prog.elf

# Run with trace
spike --isa=rv64gcv_zvl128b -l --log-commits prog.elf

# Run (fast, with printf)
qemu-riscv64 -cpu rv64,v=true,vlen=128,elen=64,vext_spec=v1.0 ./prog.elf

# What did the vectoriser do?
riscv64-unknown-elf-gcc -march=rv64gcv -O3 -fopt-info-vec prog.c -c
```

Two flags worth explaining, since both cost us time:

- **`-mcmodel=medany`** is required for bare metal linked at `0x80000000`. Without it you
  get `relocation truncated to fit: R_RISCV_HI20`.
- **`-fno-tree-loop-distribute-patterns`** stops GCC turning an array-init loop into a call
  to `memset()`, which doesn't exist in a `-nostdlib` build. Without it: `undefined
  reference to memset`.

Both are already in `examples/common/common.mk`.

---

## 🔧 Exercises — milestone M0 checklist

Everyone on the team completes all of these. Mentors verify.

**6.1** Build and run all three examples. Paste the output of `make run-all` from examples
01 and 03 into your project log.

**6.2** Modify example 01 to add a sixth check: prove that `vmv.v.i v1, 7` sets **all `vl`
elements** to 7 and leaves the tail alone.

**6.3** Write, from scratch, a program that computes the dot product of two 100-element
`int32` arrays using `vmul` and `vredsum`. Verify against a scalar loop. *(This is harder
than it looks — you need to accumulate across stripmine passes.)*

**6.4** Take the dot product from 6.3 and capture a Spike commit trace. How many
instructions? How many are vector? What fraction is `vsetvli`?

**6.5** Write a kernel with an `if` inside the loop — `y[i] = (x[i] > 0) ? x[i] : 0` (ReLU)
— using `vmslt` and `vmerge`. Confirm with a trace that no branch appears in the vector
body.

**6.6** Compile `examples/02-saxpy/saxpy_scalar.c` at `-O3 -march=rv64gcv` (no
`-fno-tree-vectorize`) and read the assembly. Did GCC vectorise it? How does its code
differ from the hand-written intrinsic version?

**6.7 (mentors)** Deliberately introduce the `vs1`/`vs2` swap bug into a copy of example
01's check 5 by changing `vsub.vv v3, v2, v1` to `vsub.vv v3, v1, v2`. Confirm the test
catches it. This is the test you will hand to the RTL team.

---

## Key takeaways

- **Write RVV software before designing RVV hardware.** Your programs become your tests.
- **Spike** = golden reference and traces. **QEMU** = fast, has `printf`, use it for
  development. Always pass `vext_spec=v1.0` to QEMU.
- Three ways to write RVV: **inline asm** (tests), **intrinsics** (benchmarks),
  **autovectorisation** (free test-case generation, not for measurements).
- Intrinsics are `__riscv_<op>_<form>_<type><lmul>`, and `vl` is always the last argument.
  The `__riscv_` prefix is mandatory on current toolchains.
- **Read the generated assembly.** The `vsetvli` inside the loop and the `vl`-scaled
  pointer bump are the whole VLA mechanism, visible in ten instructions.
- Spike's `-l --log-commits` gives PC + instruction word + state change. **This is your
  co-simulation input.** Build the diff script early.
- Watch for: `mstatus.VS` off, `-mcmodel=medany`, `-fno-tree-loop-distribute-patterns`,
  and **mismatched baselines** in measurements.

---

*Next: [Chapter 7 — Vector-Length-Agnostic Programming](07-vector-length-agnostic-programming.md)*
