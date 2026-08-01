#!/usr/bin/env python3
# Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
"""Elaborate the MEDS-V RTL across a VLEN x NR_LANES sweep.

Vector-length agnosticism is only real if the RTL genuinely re-elaborates at
every configuration. This script is the cheap, automatable proof, and it is the
regression that catches a hard-coded literal the moment someone adds one.

Usage:
    python3 scripts/param_sweep.py
    python3 scripts/param_sweep.py --vlens 128 256 --lanes 1 2
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

RTL = pathlib.Path(__file__).resolve().parent.parent / "rtl"
PKG = "meds_v_pkg.sv"
SRCS = [
    "vec_decoder.sv", "vec_csr.sv", "vec_sequencer.sv",
    "vrf.sv", "vec_lane.sv", "vec_lsu.sv", "meds_v_top.sv",
]


def elaborate(vlen: int, lanes: int) -> tuple[bool, str]:
    """Lint + elaborate the design with VLEN and NR_LANES overridden."""
    pkg_src = (RTL / PKG).read_text()
    pkg_src = re.sub(r"(parameter int unsigned VLEN\s*=\s*)\d+",
                     rf"\g<1>{vlen}", pkg_src, count=1)
    pkg_src = re.sub(r"(parameter int unsigned NR_LANES\s*=\s*)\d+",
                     rf"\g<1>{lanes}", pkg_src, count=1)

    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        # Keep the package's ORIGINAL filename: Verilator's DECLFILENAME check
        # requires the file to be named after the package it declares.
        (tmp / PKG).write_text(pkg_src)
        for s in SRCS:
            shutil.copy(RTL / s, tmp / s)

        cmd = ["verilator", "--lint-only", "-Wall", "-Wno-UNUSEDPARAM",
               "--top-module", "meds_v_top", PKG, *SRCS]
        r = subprocess.run(cmd, cwd=tmp, capture_output=True, text=True)
        return r.returncode == 0, r.stderr.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vlens", type=int, nargs="+", default=[128, 256, 512, 1024])
    ap.add_argument("--lanes", type=int, nargs="+", default=[1, 2, 4, 8])
    a = ap.parse_args()

    print("\nMEDS-V RTL parameter sweep (Verilator lint + elaborate)\n")
    print(f"  {'VLEN':>5} {'LANES':>6} {'VRF':>9} {'slice/lane':>11}   result")
    print(f"  {'-'*5} {'-'*6} {'-'*9} {'-'*11}   ------")

    failures = []
    for vlen in a.vlens:
        for lanes in a.lanes:
            if lanes * 32 > vlen:        # a lane slice must hold at least one ELEN
                continue
            ok, err = elaborate(vlen, lanes)
            vrf_kib = 32 * vlen / 1024
            print(f"  {vlen:>5} {lanes:>6} {vrf_kib:>7.0f} Kib {vlen//lanes:>8} b   "
                  f"{'PASS' if ok else 'FAIL'}")
            if not ok:
                failures.append((vlen, lanes, err))

    if failures:
        print(f"\n{len(failures)} configuration(s) failed:\n")
        for vlen, lanes, err in failures:
            print(f"  --- VLEN={vlen} LANES={lanes} ---")
            for line in err.splitlines()[:6]:
                print(f"    {line}")
        return 1

    print("\n  All configurations elaborate cleanly.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
