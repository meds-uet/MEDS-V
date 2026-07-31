#!/usr/bin/env python3
# Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
"""Count committed instructions under Spike and report scalar-vs-vector SAXPY cost.

Each ISA gets its OWN baseline build, because the harness's array-init loop is
auto-vectorised in the rv64gcv build and would otherwise corrupt the subtraction.
"""
import argparse, subprocess, sys, pathlib

def committed(elf, vlen):
    """Number of instructions Spike commits while running `elf`."""
    if not pathlib.Path(elf).exists():
        sys.exit(f"missing {elf} -- run `make` first")
    r = subprocess.run(
        f"spike --isa=rv64gcv_zvl{vlen}b -l {elf} 2>&1 | grep -c '^core   0:'",
        shell=True, capture_output=True, text=True)
    return int(r.stdout.strip() or 0)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=1024, help="elements in the kernel")
    ap.add_argument("--vlens", type=int, nargs="+", default=[128, 256, 512])
    a = ap.parse_args()

    scalar = committed("saxpy_s.elf", 128) - committed("base_s.elf", 128)

    print(f"\nSAXPY, N = {a.n} elements -- committed instructions (Spike)\n")
    print(f"  {'configuration':18s} {'kernel':>8s} {'instr/elem':>11s} {'speedup':>9s}")
    print(f"  {'-'*18} {'-'*8} {'-'*11} {'-'*9}")
    print(f"  {'scalar rv64gc':18s} {scalar:8d} {scalar/a.n:11.3f} {1.0:8.2f}x")

    for vlen in a.vlens:
        k = committed("saxpy_v.elf", vlen) - committed("base_v.elf", vlen)
        vlmax = vlen // 32                       # SEW=32, LMUL=1
        print(f"  {'RVV VLEN=' + str(vlen):18s} {k:8d} {k/a.n:11.3f} "
              f"{scalar/k:8.2f}x   (vl={vlmax})")
    print("\n  Model: the vector loop is 10 instructions per pass over vl elements,")
    print("         so instr/elem should approach 10/vl.\n")

if __name__ == "__main__":
    main()
