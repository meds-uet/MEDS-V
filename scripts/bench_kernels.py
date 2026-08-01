#!/usr/bin/env python3
# Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
"""Instruction-count benchmark for the six MEDS-V kernels (Book Ch 14, Ch 15).

MEASUREMENT METHOD -- read this before trusting any number it prints.

Each kernel is built twice, identically, except that one build runs the kernel
once (REPS=1) and the other runs it twice (REPS=2).  The reported cost is the
DIFFERENCE.  Everything else -- startup, array initialisation, the checksum
loop, code layout, and whatever the auto-vectoriser decided to do to the
harness -- is identical between the two builds and cancels exactly.

The obvious alternative, subtracting a separate "baseline" build with the kernel
call removed, is not reliable: removing the call changes what the optimiser can
eliminate, so the two builds differ by more than the kernel.  An early version
of this script did exactly that and reported a vector memcpy costing 4.3
instructions per element -- roughly twenty times the true figure.
"""
import argparse, subprocess, sys

KERNELS = [(1,"memcpy"),(2,"saxpy"),(3,"dotprod"),(4,"relu"),(5,"fir"),(6,"gemm")]
SRC_S = "../common/crt.S bench_main.c kernels_scalar.c stubs_rvv.c"
SRC_V = "../common/crt.S bench_main.c kernels_scalar.c kernels_rvv.c"
BARE = ("-mabi=lp64d -mcmodel=medany -O2 -nostdlib -nostartfiles "
        "-fno-tree-loop-distribute-patterns -Wl,--no-warn-rwx-segments "
        "-T ../common/link.ld -I../common")

def build(elf, arch, defines, vec):
    src = SRC_V if vec else SRC_S
    cmd = f"riscv64-unknown-elf-gcc -march={arch} {BARE} {defines} {src} -o {elf}"
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"build failed: {cmd}\n{r.stderr}")

def count(elf, vlen):
    r = subprocess.run(
        f"spike --isa=rv64gcv_zvl{vlen}b -l {elf} 2>&1 | grep -c '^core   0:'",
        shell=True, capture_output=True, text=True)
    return int(r.stdout.strip() or 0)

def kernel_cost(kid, arch, vec, vlen, n):
    """One kernel invocation = (REPS=2 run) - (REPS=1 run)."""
    d = f"-DNELEM={n} -DKERNEL={kid} -DVEC={1 if vec else 0}"
    build("b_r1.elf", arch, d + " -DREPS=1", vec)
    build("b_r2.elf", arch, d + " -DREPS=2", vec)
    return count("b_r2.elf", vlen) - count("b_r1.elf", vlen)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=1024)
    ap.add_argument("--vlens", type=int, nargs="+", default=[128, 256, 512])
    a = ap.parse_args()

    print(f"\nMEDS-V benchmark kernels -- committed instructions per invocation")
    print(f"(Spike; N = {a.n}; one kernel call isolated by the REPS=2 minus REPS=1 method)\n")

    hdr = f"  {'kernel':9s} {'scalar':>8s}"
    for v in a.vlens: hdr += f" {'VLEN='+str(v):>9s}"
    for v in a.vlens: hdr += f" {'x'+str(v):>7s}"
    print(hdr)
    print("  " + "-"*9 + " " + "-"*8 + (" " + "-"*9)*len(a.vlens) + (" " + "-"*7)*len(a.vlens))

    for kid, name in KERNELS:
        s = kernel_cost(kid, "rv64gc", False, 128, a.n)
        vs = {v: kernel_cost(kid, f"rv64gcv_zvl{v}b", True, v, a.n) for v in a.vlens}
        row = f"  {name:9s} {s:8d}"
        for v in a.vlens: row += f" {vs[v]:9d}"
        for v in a.vlens:
            row += f" {(s/vs[v] if vs[v] > 0 else 0):6.2f}x"
        print(row)
    print()

if __name__ == "__main__":
    main()
